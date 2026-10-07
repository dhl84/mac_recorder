#!/usr/bin/env python3
"""Live coach: reads the two tracks while they record and writes short notes.

The recorder starts this script beside each recording. Every few seconds it cuts
the new audio of each track at a quiet point, runs whisper-cli on it and adds the
lines to live.md. Every 20 seconds it gives the model the interview prep for the
role and the transcript so far. The model returns a note only when a note changes
what you say next. The notes go to coach.jsonl, and the app shows them in a
floating panel.

    coach.py run FOLDER [--label TEXT] [--prep DIR] [--speed N] [--start SECONDS]
    coach.py selftest

The model is Claude by default (COACH_ENGINE=claude, through the claude CLI, so
it uses your Claude login). COACH_ENGINE=ollama uses a local model at OLLAMA_HOST.
--speed replays a finished recording at N times real time, for a rehearsal.
--start begins the replay that many seconds into the recording.
"""
import argparse
import array
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import wave
from pathlib import Path

ENGINE = os.environ.get("COACH_ENGINE", "claude")
MODEL = os.environ.get("COACH_MODEL") or (
    "claude-fable-5-1" if ENGINE == "claude" else "gemma4:26b-a4b-it-qat")
EFFORT = os.environ.get("COACH_EFFORT", "low")
FALLBACK = os.environ.get("COACH_FALLBACK", "claude-opus-5-5")
spent = False   # set when MODEL hits its usage limit; the rest of the run uses FALLBACK
OLLAMA = os.environ.get("OLLAMA_HOST", "http://localhost:11434").rstrip("/") + "/api/chat"
APPLICATIONS = Path(os.environ.get(
    "COACH_APPLICATIONS", "~/applications")).expanduser()
WHISPER_MODEL = os.environ.get("INTERVIEW_WHISPER_MODEL") or str(Path.home() / (
    "Library/Application Support/ru.starmel.OpenSuperWhisper/whisper-models/ggml-large-v3-turbo.bin"))
VAD_MODEL = str(Path.home() / ".cache/whisper-vad/ggml-silero-v5.1.2.bin")
RATE = 16_000
EVERY = float(os.environ.get("COACH_EVERY", 20))  # seconds between model calls
GAP = 25        # seconds between two shown notes, except "wrap" and "fix"
CHUNK = 10      # seconds of new audio before a track is cut
SPEAKERS = {"mic.wav": "You", "system.wav": "Interviewer"}
# A Finder launch gives a short PATH, so look in the usual places.
PATH = os.pathsep.join([os.environ.get("PATH", ""), str(Path.home() / ".local/bin"),
                        "/opt/homebrew/bin", "/usr/local/bin"])

RULES = """You are a discreet live coach for the candidate during a job interview.
You see the interview prep that the candidate wrote for this role and the live transcript.
"You" in the transcript is the candidate. "Interviewer" is the other side of the call.
The transcript comes from speech recognition, so expect wrong words and names.

The candidate reads your notes on a small panel while talking. Give a note only when
it changes what the candidate says in the next minute. Most calls must return no note.

Give a note for one of these:
- wrap: the current answer runs long (past about 90 seconds) or circles. Give the
  one line to end on, for example the result with its number.
- missing: the question calls for a point, story or number from the prep that the
  candidate did not say yet. Name the exact fact.
- answer: the interviewer asked something that the prep answers. Give the key
  points of the prep answer in a few words.
- fix: the candidate said something that conflicts with the prep (a wrong number, a date,
  blame, or the private salary floor). Give the correction.
- ask: the interviewer invites questions, or the call nears its end. Give the best
  one or two questions from the prep that nobody answered yet.

Each note is at most 25 words. Lead with the action. Use the exact names, numbers
and words from the prep. No greeting, no praise, no hedging. Never repeat a note
that is in the shown list, and never give two notes about the same point.

Reply with JSON only: {"notes": []} or {"notes": [{"kind": "wrap", "text": "..."}]}.
Return at most one note."""


# --- the prep ----------------------------------------------------------------

STOP = {"interview", "screen", "call", "with", "and", "the", "for", "role",
        "first", "second", "final", "stage", "recruiter", "test", "meeting"}


def tokens(text):
    return {w for w in re.findall(r"[a-z0-9]+", text.lower()) if len(w) > 2} - STOP


def find_application(label, root=APPLICATIONS, today=None):
    """The application folder for this call: the best match of the label words to
    the folder name, else the one whose tracker line books an interview today."""
    if not root.is_dir():
        return None
    folders = [p for p in root.iterdir() if p.is_dir()]
    want = tokens(label)
    scored = sorted(((len(want & tokens(p.name)), p.stat().st_mtime, p) for p in folders),
                    key=lambda row: row[:2], reverse=True)
    if scored and scored[0][0] > 0:
        return scored[0][2]
    today = today or time.strftime("%Y-%m-%d")
    for p in folders:
        status = p / "status.md"
        if status.exists() and re.search(rf"^- Interview:.*{today}", status.read_text(), re.M):
            return p
    return None


def prep_text(folder):
    """The newest prep brief, the advert and the tracker record, as one context."""
    parts, used = [], []
    preps = sorted(folder.glob("interview-prep*.md"), key=lambda p: p.stat().st_mtime)
    advert = next((folder / n for n in ("job-ad-applied.md", "job-ad.md")
                   if (folder / n).exists()), None)
    status = folder / "status.md"
    for title, path in (("Interview prep", preps[-1] if preps else None),
                        ("Job advert", advert), ("Tracker record", status)):
        if path and path.exists():
            text = path.read_text()
            if path == status:
                text = text.split("<!-- tracker:end -->")[0]
            parts.append(f"# {title} ({path.name})\n\n{text}")
            used.append(path.name)
    return "\n\n".join(parts), used


# --- the audio ---------------------------------------------------------------

def data_offset(path):
    """Where the samples start. The recorder writes the sizes in the header only at
    the end, so read the chunk ids, not the sizes, of a file that still grows."""
    with open(path, "rb") as f:
        head = f.read(8192)
    pos = 12
    while pos + 8 <= len(head):
        size = int.from_bytes(head[pos + 4:pos + 8], "little")
        if head[pos:pos + 4] == b"data":
            return pos + 8
        pos += 8 + size + (size & 1)
    return None


class Track:
    def __init__(self, path):
        self.path, self.speaker = path, SPEAKERS[path.name]
        self.start = None  # byte offset of sample 0
        self.done = 0      # samples already read

    def available(self):
        if self.start is None and self.path.exists():
            self.start = data_offset(self.path)
        if self.start is None:
            return 0
        return max(0, (self.path.stat().st_size - self.start) // 2)

    def read(self, first, last):
        with open(self.path, "rb") as f:
            f.seek(self.start + first * 2)
            samples = array.array("h")
            samples.frombytes(f.read((last - first) * 2))
        return samples


def cut_point(samples, low, high):
    """The quietest 0.2 s between two sample indexes, so a cut lands between words."""
    step = RATE // 5
    best, quiet = high, None
    for at in range(low, max(low, high - step) + 1, step):
        energy = sum(abs(s) for s in samples[at:at + step:8])
        if quiet is None or energy < quiet:
            best, quiet = at + step // 2, energy
    return best


def loud(samples):
    return bool(samples) and max(abs(s) for s in samples[::4]) > 300


def whisper(samples, offset, speaker, binary):
    """Lines with their time in the recording. Silero inside whisper-cli drops the
    stretches with no speech, so the room noise on a quiet track gives no text."""
    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / "chunk.wav"
        with wave.open(str(wav), "wb") as w:
            w.setnchannels(1), w.setsampwidth(2), w.setframerate(RATE)
            w.writeframes(samples.tobytes())
        args = [binary, "-m", WHISPER_MODEL, "-f", str(wav), "-l", "en", "-mc", "0",
                "-np", "-oj", "-of", str(Path(tmp) / "out")]
        if Path(VAD_MODEL).exists():
            args += ["--vad", "-vm", VAD_MODEL]
        run = subprocess.run(args, capture_output=True, text=True, timeout=120)
        out = Path(tmp) / "out.json"
        if run.returncode or not out.exists():
            raise RuntimeError(f"whisper-cli failed: {run.stderr[-300:]}")
        rows = json.loads(out.read_text(errors="replace")).get("transcription", [])
    return [(offset + row["offsets"]["from"] / 1000, speaker, row["text"].strip())
            for row in rows if row["text"].strip()]


# --- the model ---------------------------------------------------------------

def ask(system, user):
    if ENGINE == "ollama":
        body = json.dumps({"model": MODEL, "stream": False, "think": False, "format": "json",
                           "options": {"num_ctx": 32768, "temperature": 0.2},
                           "messages": [{"role": "system", "content": system},
                                        {"role": "user", "content": user}]}).encode()
        request = urllib.request.Request(OLLAMA, body, {"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=90) as response:
            return json.load(response)["message"]["content"]
    claude = shutil.which("claude", path=PATH)
    if not claude:
        raise RuntimeError("no claude CLI on the PATH. Set COACH_ENGINE=ollama for the local model.")
    # --safe-mode skips the hooks, plugins and CLAUDE.md, so each call is plain and fast.
    def call(model):
        return subprocess.run([claude, "-p", "--safe-mode", "--strict-mcp-config", "--tools", "",
                               "--no-session-persistence", "--model", model, "--effort", EFFORT,
                               "--fallback-model", FALLBACK,
                               "--system-prompt", system],
                              input=user, capture_output=True, text=True, timeout=90,
                              cwd=tempfile.gettempdir())
    global spent
    run = call(FALLBACK if spent else MODEL)
    # --fallback-model covers an overloaded model only. A spent usage limit
    # ("You've reached your Fable limit") needs a call on the fallback, and the
    # failed call costs about 14 seconds, so the rest of the call skips the main model.
    if run.returncode and not spent and MODEL != FALLBACK and "limit" in (run.stderr + run.stdout).lower():
        spent = True
        run = call(FALLBACK)
    if run.returncode:
        raise RuntimeError(f"claude failed: {(run.stderr or run.stdout)[-300:]}")
    return run.stdout


def parse_notes(reply):
    """The notes in a model reply. A reply that is not JSON gives no note."""
    match = re.search(r"\{.*\}", reply, re.S)
    try:
        notes = json.loads(match.group(0)).get("notes", []) if match else []
    except (json.JSONDecodeError, AttributeError):
        return []
    return [{"kind": str(n.get("kind", "note")).lower(), "text": str(n["text"]).strip()}
            for n in notes if isinstance(n, dict) and str(n.get("text", "")).strip()][:1]


def clock(seconds):
    return f"{int(seconds) // 60:02d}:{int(seconds) % 60:02d}"


def current_turn(lines, now):
    """How long you have talked since the interviewer last spoke, and their last words."""
    asked, start, words = [], None, 0
    for at, speaker, text in lines:
        if speaker == "Interviewer":
            if start is not None:
                asked, start, words = [], None, 0
            asked.append(text)
        else:
            start = at if start is None else start
            words += len(text.split())
    talk = now - start if start is not None else 0
    return talk, words, " ".join(asked)[-400:]


def brief_for_model(lines, now, shown, tail_words=None):
    talk, words, asked = current_turn(lines, now)
    body = "\n".join(f"[{clock(at)}] {speaker}: {text}" for at, speaker, text in lines)
    if tail_words:
        body = " ".join(body.split(" ")[-tail_words:])
    return (f"Elapsed: {clock(now)}.\n"
            f"Your current answer: {talk:.0f} seconds, {words} words.\n"
            f"Interviewer's last words: {asked or '(none yet)'}\n\n"
            "Notes already shown:\n" + ("\n".join(f"- {n}" for n in shown) or "- none") +
            f"\n\nTranscript so far:\n{body}\n\nReply with the JSON now.")


# --- the loop ----------------------------------------------------------------

def run(folder, label="", prep=None, speed=0.0, start=0.0):
    folder = Path(folder)
    notes_file = folder / "coach.jsonl"
    live = folder / "live.md"
    binary = shutil.which("whisper-cli", path=PATH)
    began = time.time()

    def note(kind, text, at):
        with open(notes_file, "a") as f:
            f.write(json.dumps({"at": round(at, 1), "clock": clock(at), "kind": kind,
                                "text": text}) + "\n")
        print(f"[{clock(at)}] {kind}: {text}", flush=True)

    meta = folder / "meta.json"
    if not label and meta.exists():
        label = json.loads(meta.read_text()).get("label", "")
    app = Path(prep).expanduser() if prep else find_application(label)
    context, used = prep_text(app) if app else ("", [])
    who = (f"{app.name}: {', '.join(used)}" if app else
           f"no application folder matches \"{label}\". The notes use no prep.")
    note("status", f"{MODEL} reads {who}", 0)
    if not binary:
        note("status", "No whisper-cli on the PATH, so no live transcript. Install whisper-cpp.", 0)
        return
    system = RULES + ("\n\n" + context if context else "")

    tracks = [Track(folder / name) for name in SPEAKERS]
    for track in tracks:
        track.done = int(start * RATE)
    lines, shown = [], []
    last_note, last_call, seen = -GAP, -EVERY, 0
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=1)
    pending, asked_at = None, 0.0
    parent = os.getppid()  # the app; when it quits, this script stops too
    while True:
        now = (time.time() - began) * speed + start if speed else None
        ends = []
        for track in tracks:
            end = track.available()
            if now is not None:
                end = min(end, int(now * RATE))
            ends.append(end)
            if end - track.done < CHUNK * RATE:
                continue
            samples = track.read(track.done, end)
            cut = len(samples) if len(samples) > 3 * CHUNK * RATE else \
                cut_point(samples, int(0.7 * CHUNK * RATE), len(samples))
            if loud(samples[:cut]):
                try:
                    found = whisper(samples[:cut], track.done / RATE, track.speaker, binary)
                except (RuntimeError, subprocess.TimeoutExpired) as e:
                    found = []
                    print(e, file=sys.stderr, flush=True)
                for row in found:
                    same = [l for l in lines if l[1] == row[1]]
                    if not same or same[-1][2] != row[2]:  # whisper repeats a line on a cut
                        lines.append(row)
                lines.sort()
            track.done += cut
        elapsed = max(ends) / RATE

        if pending and pending.done():
            print(f"  model call {time.time() - asked_at:.1f}s", flush=True)
            try:
                for n in parse_notes(pending.result()):
                    if n["kind"] in ("wrap", "fix") or elapsed - last_note >= GAP:
                        note(n["kind"], n["text"], elapsed)
                        shown.append(n["text"])
                        last_note = elapsed
            except Exception as e:  # a failed call must not stop the transcript
                note("status", f"The model call failed: {str(e)[:200]}", elapsed)
            pending = None
        if not pending and len(lines) > seen and elapsed - last_call >= EVERY:
            seen, last_call = len(lines), elapsed
            user = brief_for_model(lines, elapsed, shown[-12:],
                                   tail_words=2500 if ENGINE == "ollama" else None)
            pending, asked_at = pool.submit(ask, system, user), time.time()

        live.write_text("".join(f"[{clock(at)}] {s}: {t}\n" for at, s, t in lines))
        finished = all(t.done >= t.available() - CHUNK * RATE for t in tracks)
        if (speed and finished and not pending) or (not speed and meta.exists()) \
                or os.getppid() != parent:
            break
        time.sleep(1 if not speed else 0.2)
    note("status", "The coach stopped.", elapsed)


def selftest():
    import shutil as sh
    tmp = Path(tempfile.mkdtemp())
    try:
        # A growing file: the header says 0 bytes of data, the samples follow it.
        wav = tmp / "mic.wav"
        head = b"RIFF\0\0\0\0WAVE" + b"JUNK" + (28).to_bytes(4, "little") + bytes(28) \
            + b"fmt " + (16).to_bytes(4, "little") + bytes(16) + b"data" + bytes(4)
        wav.write_bytes(head + array.array("h", [5] * 100).tobytes())
        track = Track(wav)
        assert track.available() == 100, track.available()
        assert list(track.read(10, 12)) == [5, 5]

        quiet = array.array("h", [3000] * RATE * 2 + [0] * (RATE // 5) + [3000] * RATE)
        at = cut_point(quiet, RATE, len(quiet))
        assert 2 * RATE <= at <= 2 * RATE + RATE // 5, at
        assert not loud(array.array("h", [100] * 1000)) and loud(quiet)

        assert parse_notes('x {"notes": [{"kind": "WRAP", "text": " End on 5%. "}]} y') == \
            [{"kind": "wrap", "text": "End on 5%."}]
        assert parse_notes("no json") == [] and parse_notes('{"notes": []}') == []

        lines = [(0, "Interviewer", "Tell me about Acme?"), (5, "You", "So at Acme"),
                 (50, "You", "I owned the forecast")]
        talk, words, asked = current_turn(lines, 100)
        assert (talk, words, asked) == (95, 7, "Tell me about Acme?")
        assert current_turn(lines + [(101, "Interviewer", "Thanks.")], 102)[:2] == (0, 0)

        apps = tmp / "apps"
        for name in ("acme-finance-manager-20261001", "globex-operations-lead-20260924"):
            (apps / name).mkdir(parents=True)
        (apps / "acme-finance-manager-20261001" / "status.md").write_text(
            "- Interview: Recruiter screen, Mon 2026-10-05 10:00\n")
        assert find_application("Globex call", apps).name.startswith("globex")
        assert find_application("Interview", apps, today="2026-10-05").name.startswith("acme")
        assert find_application("Interview", apps, today="2026-10-06") is None

        # A spent usage limit on the main model retries once on the fallback.
        calls, real_run, real_which = [], subprocess.run, shutil.which
        def fake_run(args, **kw):
            model = args[args.index("--model") + 1]
            calls.append(model)
            spent = model == MODEL != FALLBACK
            return subprocess.CompletedProcess(args, 1 if spent else 0,
                                               "" if spent else '{"notes": []}',
                                               "You've reached your Fable limit." if spent else "")
        subprocess.run, shutil.which = fake_run, lambda *a, **k: "/bin/claude"
        global spent
        try:
            if ENGINE == "claude":
                assert ask("s", "u") == '{"notes": []}' and ask("s", "u") == '{"notes": []}'
                want = [MODEL, FALLBACK, FALLBACK] if MODEL != FALLBACK else [MODEL, MODEL]
                assert calls == want, calls
        finally:
            subprocess.run, shutil.which, spent = real_run, real_which, False
        print("coach self-test: ok")
    finally:
        sh.rmtree(tmp)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["run", "selftest"])
    parser.add_argument("folder", nargs="?")
    parser.add_argument("--label", default="")
    parser.add_argument("--prep", help="the application folder, when the label does not match one")
    parser.add_argument("--speed", type=float, default=0.0, help="replay a finished recording")
    parser.add_argument("--start", type=float, default=0.0, help="replay from this second")
    args = parser.parse_args()
    if args.action == "selftest":
        return selftest()
    if not args.folder:
        parser.error("run needs a recording folder")
    run(args.folder, args.label, args.prep, args.speed, args.start)


if __name__ == "__main__":
    main()
