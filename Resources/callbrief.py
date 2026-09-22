#!/usr/bin/env python3
"""Titles, briefs and call splitting for Interview Recorder.

The model plumbing comes from ytsum.py (the YouTube brief tool). The prompts
change, because a call has decisions and actions and a video has none.

    callbrief.py title FOLDER [--force]
    callbrief.py brief FOLDER [--force-title]
    callbrief.py split FOLDER [--apply] [--gap 8]
"""

import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

OLLAMA = os.environ.get("OLLAMA_HOST", "http://localhost:11434") + "/api/generate"
MODEL = os.environ.get("INTERVIEW_MODEL", "gemma4:26b-a4b-it-qat")
CHUNK_WORDS = int(os.environ.get("INTERVIEW_CHUNK_WORDS", 3500))
GENERIC = {"", "interview", "untitled", "recording"}

STYLE = """Write in Simple Technical English:
- One idea per sentence. 25 words maximum.
- Active voice. Name the actor.
- Simple present, simple past or simple future. No perfect tense.
- Plain words: use, not utilise. Before, not prior to. After, not subsequent to.
- No adjectives of praise, no marketing words, no irony.
- Give the number. "Wait 30 seconds", not "wait a moment".
Keep every name exactly as the speaker says it: a person, an organisation, a system, a date."""

TITLE = """You read the transcript of one call. Write its title.

Rules:
- Between 5 and 12 words.
- Name the group or the organisation, and name the subject of the call.
- Name the people only when the transcript says who they are.
- Write the subject, not the tone. "Board: pay review and payroll cut-off",
  not "A positive discussion".
- No date, no quotation marks, no full stop, no prefix such as "Title:".
- Output the title alone and nothing else.

TRANSCRIPT:
{transcript}"""

BRIEF = """You read the transcript of one call. Write a brief for a reader who was not on it.

{style}

"Me" is the person who made the recording. "Them" is every other speaker, on one
track, so two of them can appear in one block. Use the names the transcript gives.

Output this Markdown structure and nothing else:

## The point
One sentence. What this call settled or moved forward.

## Decisions
Bullets. Start each line with "- " and then a timestamp in brackets, like
"- [mm:ss] what they agreed". Write only what the speakers agreed.
Write "- none" if the call agreed nothing.

## Actions
Bullets. Write each line as "- [owner] the action, by when", like
"- [who] the task, by when".
Write "unstated" in place of a date the call did not give.
Write "- none" if the call set no action.

## Key points
At most ten bullets, as "- [mm:ss] the point". Fewer is better than padding.
State the claim and the name. Keep each bullet under 25 words.

## Facts and numbers
Only the amounts, dates, names and titles the call states. Write each line as
"value: what it measures", like "- 40: the agreed price in pounds" or
"- 3 March: the date of the next review". A reader sees these lines alone, so a
bare number is wrong. Write "none stated" if the call gives none.

## Open questions
One to four bullets. What the call left unsettled, or where a speaker guessed.
Write "- none" if the call settled everything.

TRANSCRIPT ({title}):
{transcript}"""

MERGE = """You have several briefs from consecutive parts of one call. Merge them into one brief.

{style}

Use the same headings: The point, Decisions, Actions, Key points, Facts and numbers,
Open questions. Keep the timestamps. Remove each repeated point. Keep the strongest 10
bullets under Key points. Under Facts and numbers, keep the "value: what it measures" form.

PARTS:
{parts}"""


def ask(prompt):
    """One model call. Times it, because a slow call is the failure mode here."""
    start = time.time()
    # think=False matters more than any other setting. With reasoning on, this model
    # loops to the token cap and returns an empty response. num_predict is the second belt.
    body = json.dumps({"model": MODEL, "prompt": prompt, "stream": False, "think": False,
                       "options": {"temperature": 0.2, "num_predict": 2000}}).encode()
    request = urllib.request.Request(OLLAMA, body, {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=600) as response:
            data = json.load(response)
    except OSError as e:
        sys.exit(f"Ollama did not answer at {OLLAMA}: {e}. Start it with: ollama serve")
    reply = (data.get("response") or "").strip()
    if not reply:
        sys.exit(f"The model returned nothing (done_reason={data.get('done_reason')}). "
                 f"Try INTERVIEW_MODEL=gemma4:latest, or INTERVIEW_CHUNK_WORDS=2000.")
    print(f"  model call: {time.time() - start:.0f}s, {len(reply.split())} words back", file=sys.stderr)
    return reply


def chunks(text, size=CHUNK_WORDS):
    words = text.split(" ")
    return [" ".join(words[i:i + size]) for i in range(0, len(words), size)] or [""]


def read_meta(folder):
    try:
        return json.loads((folder / "meta.json").read_text())
    except (OSError, ValueError):
        return {}


def write_meta(folder, meta):
    (folder / "meta.json").write_text(json.dumps(meta, indent=2))


# ------------------------------------------------------------------- brief ---

def speech(folder):
    """The transcript without the header block, so the model reads speech only."""
    transcript = folder / "transcript.md"
    if not transcript.exists():
        sys.exit(f"No transcript.md in {folder}. Transcribe the call first.")
    return transcript.read_text(encoding="utf-8").split("\n## ", 1)[-1]


def title(folder, force=False):
    """Names an unnamed call from its first chunk. Returns the label."""
    meta = read_meta(folder)
    label = (meta.get("label") or "").strip()
    if not force and label.lower() not in GENERIC:
        return label
    print("  asking for a title...", file=sys.stderr)
    new = ask(TITLE.format(transcript=chunks(speech(folder))[0]))
    new = new.strip().strip('"').strip("'").rstrip(".").split("\n")[0]
    new = re.sub(r"^(title|call)\s*:\s*", "", new, flags=re.I).strip()
    if not 2 <= len(new.split()) <= 20:
        print(f"  the model gave an unusable title: {new!r}", file=sys.stderr)
        return label
    meta["label"] = new
    meta["title_auto"] = True
    write_meta(folder, meta)
    print(new)
    return new


def brief(folder, force_title=False):
    body = speech(folder)
    label = title(folder, force=force_title)
    parts = chunks(body)
    briefs = []
    for i, part in enumerate(parts, 1):
        print(f"  part {i} of {len(parts)}...", file=sys.stderr)
        briefs.append(ask(BRIEF.format(style=STYLE, title=label or folder.name, transcript=part)))
    if len(briefs) == 1:
        out = briefs[0]
    else:
        print("  merging...", file=sys.stderr)
        joined = "\n\n".join(f"--- PART {i + 1} ---\n{b}" for i, b in enumerate(briefs))
        out = ask(MERGE.format(style=STYLE, parts=joined))

    head = f"# {label or folder.name}\n\nBrief from {MODEL}. Source: transcript.md.\n\n"
    (folder / "brief.md").write_text(head + out.strip() + "\n", encoding="utf-8")
    print(str(folder / "brief.md"))
    return label


# ------------------------------------------------------------------- split ---

def ffmpeg():
    for path in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"):
        if os.access(path, os.X_OK):
            return path
    return "ffmpeg"


def silences(wav, seconds):
    """Return [(start, end)] where the track stays under -40 dB for `seconds`."""
    out = subprocess.run([ffmpeg(), "-nostdin", "-i", str(wav), "-af",
                          f"silencedetect=noise=-40dB:d={seconds}", "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    starts = [float(x) for x in re.findall(r"silence_start: ([\d.]+)", out)]
    ends = [float(x) for x in re.findall(r"silence_end: ([\d.]+)", out)]
    if len(ends) < len(starts):
        ends.append(float(re.findall(r"time=(\d+):(\d\d):(\d\d)", out)[-1][0] or 0) or 1e9)
    return list(zip(starts, ends))


def overlaps(mic, system, gap):
    """Return the spells where both lists are quiet together for `gap` seconds.

    One track alone proves nothing. The far end goes quiet whenever you speak,
    and your microphone goes quiet whenever they speak. Both tracks quiet at the
    same time means nobody is on the line.
    """
    shared = []
    for s1, e1 in mic:
        for s2, e2 in system:
            start, end = max(s1, s2), min(e1, e2)
            if end - start >= gap:
                shared.append((start, end))
    shared.sort()
    # The midpoint of the quiet spell is the cut, so neither call loses a word.
    return [(round((s + e) / 2, 1), round(s, 1), round(e, 1)) for s, e in shared]


def boundaries(folder, gap):
    """Find where the recording ran on from one call into the next."""
    mic, system = folder / "mic.wav", folder / "system.wav"
    if not (mic.exists() and system.exists()):
        return []
    return overlaps(silences(mic, 3), silences(system, 3), gap)


def shift(stamp, seconds):
    """The second call started later than the recording did, so move its clock."""
    try:
        from datetime import datetime, timedelta
        base = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        return (base + timedelta(seconds=seconds)).isoformat().replace("+00:00", "Z")
    except ValueError:
        return stamp


def split(folder, gap, apply_it):
    found = boundaries(folder, gap)
    meta = read_meta(folder)
    total = float(meta.get("duration") or 0)
    report = {"folder": str(folder), "duration": total,
              "boundaries": [{"cut": c, "quiet_from": s, "quiet_to": e} for c, s, e in found]}
    if not apply_it:
        print(json.dumps(report, indent=2))
        return report

    cuts = [0.0] + [c for c, _, _ in found] + [total]
    made = []
    for i in range(len(cuts) - 1):
        start, end = cuts[i], cuts[i + 1]
        if end - start < 20:
            print(f"  part {i + 1} is {end - start:.0f}s, keeping it anyway", file=sys.stderr)
        part = folder.parent / f"{folder.name}-{i + 1}"
        part.mkdir(exist_ok=True)
        for track in ("mic.wav", "system.wav"):
            subprocess.run([ffmpeg(), "-nostdin", "-loglevel", "error", "-y", "-i",
                            str(folder / track), "-ss", f"{start}", "-to", f"{end}",
                            "-c:a", "pcm_s16le", str(part / track)], check=True)
        write_meta(part, {"label": "", "started": shift(meta.get("started", ""), start),
                          "duration": end - start, "offset": start, "split_from": folder.name})
        made.append(str(part))
        print(f"  wrote {part.name}: {start:.0f}s to {end:.0f}s", file=sys.stderr)
    report["parts"] = made
    print(json.dumps(report, indent=2))
    return report


# -------------------------------------------------------------------- main ---

def selftest():
    """The split maths, which decides where a recording gets cut."""
    # Numbers from a test recording that ran two calls together: the microphone
    # went quiet often, the far end rarely, and the two overlapped once, at the
    # switch between the calls.
    mic = [(100.0, 140.0), (470.0, 495.0)]
    system = [(138.0, 143.0), (478.9, 488.6)]
    found = overlaps(mic, system, 8)
    assert found == [(483.8, 478.9, 488.6)], found
    # The 2 second overlap at 138 to 140 is shorter than the gap, so it is not a join.
    assert overlaps(mic, system, 8) == overlaps(mic, system, 9.5), "9.8s must survive both"
    assert overlaps(mic, system, 12) == [], "a 9.8s quiet spell is not a 12s join"
    # Quiet on one track alone is never a join, however long it runs.
    assert overlaps([(0.0, 300.0)], [(400.0, 500.0)], 8) == []
    assert overlaps([], [(0.0, 99.0)], 8) == []

    assert shift("2026-09-22T10:55:56Z", 483.8) == "2026-09-22T11:03:59.800000Z"
    assert shift("not a date", 10) == "not a date"

    assert "interview" in GENERIC and "Board: pay review".lower() not in GENERIC
    print("callbrief self-test passed")


def main():
    args = sys.argv[1:]
    if args[:1] == ["selftest"]:
        return selftest()
    if len(args) < 2 or args[0] not in ("brief", "split", "title"):
        sys.exit(__doc__)
    folder = Path(os.path.expanduser(args[1]))
    if not folder.is_dir():
        sys.exit(f"No folder at {folder}")
    if args[0] == "title":
        title(folder, force="--force" in args)
    elif args[0] == "brief":
        brief(folder, force_title="--force-title" in args)
    else:
        gap = 8.0
        if "--gap" in args:
            gap = float(args[args.index("--gap") + 1])
        split(folder, gap, "--apply" in args)


if __name__ == "__main__":
    main()
