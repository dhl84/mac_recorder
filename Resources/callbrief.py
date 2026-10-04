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


def me_name():
    """Who "Me" is. The transcript labels the microphone track "Me" and gives no
    name, so the model binds any name that falls near the recorder to them. On
    28 September 2026 whisper heard "walk through" as "james" and the brief
    renamed the recorder James throughout. The name comes from the machine now,
    never from the transcript."""
    name = os.environ.get("INTERVIEW_ME", "").strip()
    if name:
        return name
    try:
        import pwd
        full = pwd.getpwuid(os.getuid()).pw_gecos.split(",")[0].strip()
        if full:
            return full
    except Exception:
        pass
    return "Me"


ME = me_name()

# Who asked the questions. On 28 September 2026 the brief of a talent screen said that
# the recorder interviewed the interviewer, because the prompt said only who made the
# recording. The role now comes from meta.json, INTERVIEW_ME_ROLE or the questions.
ROLES = {"candidate", "interviewer"}
ROLE_LINES = {
    "candidate": ('"{me}" is the candidate in this interview. The other speaker interviewed '
                  '"{me}". Never write that "{me}" interviewed anyone.'),
    "interviewer": ('"{me}" is the interviewer in this call. "{me}" interviewed the other '
                    'speaker. Never write that the other speaker interviewed "{me}".'),
    "": ("Do not say who interviewed whom unless a speaker says it. The person who made "
         "the recording can be the candidate."),
}

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
- The person who made the recording is {me}. Never give them another name.
- Write the subject, not the tone. "Board: pay review and payroll cut-off",
  not "A positive discussion".
- No date, no quotation marks, no full stop, no prefix such as "Title:".
- Output the title alone and nothing else.

TRANSCRIPT:
{transcript}"""

# No example content in here. A model given a thin transcript copies examples
# into the brief as fact, so every format uses placeholders and no section asks
# for a count. ground() below checks what comes back.
BRIEF = """You read the transcript of one call. Write a brief for a reader who was not on it.

{style}

"{me}" is the person who made the recording. "Them" is every other speaker, on one
track, so two of them can appear in one block. {role} Use the names the transcript gives
for the other speakers only. Never call "{me}" by another name, whatever the
transcript says, because a mis-heard word can look like a name.
Use only what the transcript says. Never copy words from these instructions into the
brief. If the transcript gives nothing for a section, write "- none" under it.

Output this Markdown structure and nothing else:

## The point
One sentence: what this call settled or moved forward.

## Decisions
One bullet for each thing the speakers agreed, as
"- [mm:ss] what they agreed ("words copied from the transcript")".
mm:ss is the time in the transcript heading above those words.

## Actions
One bullet for each task someone took on, as
"- [who] the task, by when ("words copied from the transcript")".
Write "unstated" when the transcript gives no date. A promise to follow up, such as a
speaker saying they will be in touch, is an action for that speaker.

## Key points
At most ten bullets, as "- [mm:ss] the point". Fewer is better than padding.

## Facts and numbers
One line for each amount, date or name the transcript states, as
"- value: what it measures". A bare number is wrong: name what it measures.

## Open questions
At most four bullets, as "- [mm:ss] what is unsettled ("words copied from the transcript")".
What the call left unsettled, or where a speaker guessed. A next step with no date or
no name is unsettled.

Each quote holds 3 to 12 words, copied exactly from the transcript, in straight double
quotes. The quote shows where the transcript says it. Write the rest of the line in
your own words.

TRANSCRIPT ({title}):
{transcript}"""

MERGE = """You have several briefs from consecutive parts of one call. Merge them into one brief.

{style}

Use the same headings: The point, Decisions, Actions, Key points, Facts and numbers,
Open questions. Keep the timestamps and keep each quoted phrase exactly as it is.
Remove each repeated point. Keep the strongest 10 bullets under Key points. Under Facts
and numbers, keep the "value: what it measures" form. {role}

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


# ------------------------------------------------------------------ ground ---

MINIMUM_WORDS = 40
COMMON = set("""about after again also because been before being call could does done
each from have into just like made make more most none only other over said same
should some speaker such than that their them then there these they this those
through unstated very want were what when where which while will with would your
them""".split())


def words(text):
    """The words a line must share with the transcript: four letters or more, not common."""
    return [w for w in re.findall(r"[a-z0-9]+", text.lower())
            if len(w) >= 4 and w not in COMMON and not w.isdigit()]


QUOTE = re.compile(r'["\u201c]([^"\u201d]{3,240})["\u201d]')


def tokens(text):
    """Lower-case words with the apostrophes taken out, so "we'll" matches "we'll"."""
    return re.findall(r"[a-z0-9]+", text.lower().replace("'", "").replace("\u2019", ""))


def said(quote, spoken):
    """True when the quote is in the transcript. Whisper and the model differ in small
    words, so 80% of the quote's words in order inside a window of the same length
    plus three words is enough."""
    want = tokens(quote)
    if len(want) < 3:
        return False
    first = set(want[:2])
    for i, word in enumerate(spoken):
        if word not in first:
            continue
        window, at, found = spoken[i:i + len(want) + 3], 0, 0
        for w in want:
            try:
                at = window.index(w, at) + 1
                found += 1
            except ValueError:
                pass
        if found / len(want) >= 0.8:
            return True
    return False


def failure(line, transcript, duration):
    """Returns why a bullet is not backed by the transcript, or None when it is.

    A bullet with a quote passes when the quote is in the transcript, so a correct
    paraphrase around it survives. A bullet without a quote must share half its
    words with the transcript. The paraphrase "the interviewer will contact the candidate" for "we'll be
    in touch" shares too few words, and on 28 September 2026 that emptied the Actions."""
    body = line.strip()
    if body.startswith("- "):
        body = body[2:]
    if body.lower() in ("none", "none stated", "nothing relevant"):
        return None
    stamp = re.match(r"^\[(\d{1,2}):(\d{2})(?::(\d{2}))?\]\s*", body)
    if stamp:
        parts = [int(x) for x in stamp.groups() if x is not None]
        seconds = parts[0] * 60 + parts[1] if len(parts) == 2 else parts[0] * 3600 + parts[1] * 60 + parts[2]
        if duration and seconds > duration + 5:
            return "timestamp past the end"
        body = body[stamp.end():]
    body = re.sub(r"^\[[^\]]*\]\s*", "", body)
    quotes = QUOTE.findall(body)
    if quotes:
        spoken = tokens(transcript)
        missing = [q for q in quotes if not said(q, spoken)]
        if missing:
            return f"quote not in the transcript: {missing[0][:40]}"
        body = QUOTE.sub(" ", body)
    numbers = set(re.findall(r"\d+", transcript))
    stray = [n for n in re.findall(r"\d+", body) if n not in numbers]
    if stray:
        return f"number {stray[0]} not in the transcript"
    if quotes:
        return None
    own = words(body)
    if not own:
        return "no checkable words"
    # Five letters of stem, so "reviewed" matches "review".
    stems = {w[:5] for w in words(transcript)}
    hits = sum(1 for w in own if w[:5] in stems)
    return None if hits / len(own) >= 0.5 else f"{hits} of {len(own)} words in the transcript"


def reanchor(brief, transcript):
    """Moves each timestamp to the block that actually holds the words.

    The model writes a plausible timestamp, not a true one. On 29 September 2026 it
    put "Sonnet 5.5 is eight times cheaper than Opus" at 00:24:41, where the other
    speaker says only "Yeah." The timestamp is how David finds the moment in the
    audio, so a near miss wastes his time. This picks the block that shares the most
    words with the line, and leaves the timestamp alone when no block is a clear
    match, because a wrong guess is worse than the model's own guess.
    """
    blocks = []
    for match in re.finditer(r"^#*\s*(\d\d:\d\d:\d\d) \S.*$", transcript, flags=re.M):
        start = match.end()
        nxt = re.search(r"^#*\s*\d\d:\d\d:\d\d \S", transcript[start:], flags=re.M)
        text = transcript[start:start + (nxt.start() if nxt else len(transcript))]
        clock = match.group(1)
        hh, mm, ss = (int(x) for x in clock.split(":"))
        blocks.append((clock, hh * 3600 + mm * 60 + ss, {w[:5] for w in words(text)}))
    if not blocks:
        return brief

    out = []
    for line in brief.splitlines():
        stamp = re.match(r"^(- )?\[(\d{1,2}):(\d{2})(?::(\d{2}))?\]\s*", line)
        if not stamp:
            out.append(line)
            continue
        own = words(line[stamp.end():])
        if not own:
            out.append(line)
            continue
        parts = [int(x) for x in stamp.groups()[1:] if x is not None]
        guess = (parts[0] * 60 + parts[1] if len(parts) == 2
                 else parts[0] * 3600 + parts[1] * 60 + parts[2])

        def pick(window, floor):
            best, score = None, 0.0
            for clock, when, stems in blocks:
                if window and abs(when - guess) > window:
                    continue
                hit = sum(1 for w in own if w[:5] in stems) / len(own)
                if hit > score:
                    best, score = clock, hit
            return best if score >= floor else None

        # Near the model's own guess a third of the words is enough, because the guess
        # is usually right to about a minute. Far from it the bar is two thirds, so a
        # chance overlap somewhere else in the call cannot move the line.
        found = pick(120, 0.34) or pick(0, 0.67)
        out.append(f"{stamp.group(1) or ''}[{found}] {line[stamp.end():]}" if found else line)
    return "\n".join(out)


def ground(brief, transcript, duration):
    """Keeps the headings, drops unsupported lines and repeats, and writes
    "- none" under a section that ends up empty."""
    out, seen, kept, in_section = [], set(), 0, False
    for raw in brief.splitlines():
        line = raw.strip()
        if line.startswith("## "):
            if in_section and not kept:
                out.append("- none")
            out += ["", line]
            in_section, kept = True, 0
            continue
        if not line or not in_section or line.lower() in seen:
            continue
        if failure(line, transcript, duration):
            continue
        seen.add(line.lower())
        out.append(line)
        kept += 1
    if in_section and not kept:
        out.append("- none")
    return "\n".join(out).strip()


def too_short(count):
    sections = ["The point", "Decisions", "Actions", "Key points", "Facts and numbers", "Open questions"]
    return (f"The transcript holds {count} words, under the {MINIMUM_WORDS} a brief needs, "
            "so no model ran.\n\n" + "\n\n".join(f"## {s}\n\n- none" for s in sections))


# ------------------------------------------------------------------- brief ---

def speech(folder):
    """The transcript without the header block, so the model reads speech only."""
    transcript = folder / "transcript.md"
    if not transcript.exists():
        sys.exit(f"No transcript.md in {folder}. Transcribe the call first.")
    body = transcript.read_text(encoding="utf-8").split("\n## ", 1)[-1]
    # The model sees the recorder's real name on their own blocks, so no name in
    # the speech can take that slot. transcript.md on disk stays unchanged.
    return re.sub(r"^(#*\s*\d\d:\d\d:\d\d) Me\s*$", lambda m: m.group(1) + " " + ME,
                  body, flags=re.M)


def title(folder, force=False):
    """Names an unnamed call from its first chunk. Returns the label."""
    meta = read_meta(folder)
    label = (meta.get("label") or "").strip()
    if not force and label.lower() not in GENERIC:
        return label
    print("  asking for a title...", file=sys.stderr)
    new = ask(TITLE.format(me=ME, transcript=chunks(speech(folder))[0]))
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


def questions(body):
    """Question marks said by the recorder and by the other side."""
    mine = theirs = 0
    for block in re.split(r"^#*\s*\d\d:\d\d:\d\d ", body, flags=re.M)[1:]:
        speaker, _, text = block.partition("\n")
        if speaker.strip() == "Them":
            theirs += text.count("?")
        else:
            mine += text.count("?")
    return mine, theirs


def me_role(folder, body):
    """"candidate", "interviewer" or "" when the transcript does not show it.

    meta.json "me_role" or INTERVIEW_ME_ROLE decides when set. Otherwise an interview
    (the name says interview or screen) takes the role from the questions: the
    interviewer asks at least twice as many as the other side."""
    meta = read_meta(folder)
    stated = (meta.get("me_role") or os.environ.get("INTERVIEW_ME_ROLE", "")).strip().lower()
    if stated in ROLES:
        return stated
    name = f"{meta.get('label') or ''} {folder.name}".lower()
    if not re.search(r"interview|screen", name):
        return ""
    mine, theirs = questions(body)
    if theirs >= 3 and theirs >= 2 * mine:
        return "candidate"
    if mine >= 3 and mine >= 2 * theirs:
        return "interviewer"
    return ""


def wrong_direction(text, role):
    """The sentence under "The point", when it says the candidate interviewed someone."""
    if role != "candidate":
        return ""
    first = re.escape(ME.split()[0]) if ME and ME != "Me" else "Me"
    point = re.search(r"## The point\s*\n+(.+)", text)
    line = point.group(1) if point else ""
    pattern = rf"\b{first}\b(?:\s+\w+)?\s+(?:interviewed|interviews|is interviewing)\b(?!\s+(?:for|with|at)\b)"
    return line if re.search(pattern, line, re.I) else ""


def brief(folder, force_title=False):
    body = speech(folder)
    duration = float(read_meta(folder).get("duration") or 0)
    spoken = len(re.sub(r"^\d\d:\d\d:\d\d (Me|Them)$", "", body, flags=re.M).split())
    if spoken < MINIMUM_WORDS:
        label = (read_meta(folder).get("label") or folder.name)
        (folder / "brief.md").write_text(f"# {label}\n\n{too_short(spoken)}\n", encoding="utf-8")
        print(str(folder / "brief.md"))
        return label
    label = title(folder, force=force_title)
    role = me_role(folder, body)
    role_line = ROLE_LINES[role].format(me=ME)
    print(f"  recorder's role: {role or 'not shown'}", file=sys.stderr)
    parts = chunks(body)
    briefs = []
    for i, part in enumerate(parts, 1):
        print(f"  part {i} of {len(parts)}...", file=sys.stderr)
        briefs.append(ask(BRIEF.format(style=STYLE, me=ME, role=role_line,
                                       title=label or folder.name, transcript=part)))
    if len(briefs) == 1:
        out = briefs[0]
    else:
        print("  merging...", file=sys.stderr)
        joined = "\n\n".join(f"--- PART {i + 1} ---\n{b}" for i, b in enumerate(briefs))
        out = ask(MERGE.format(style=STYLE, role=role_line, parts=joined))
    wrong = wrong_direction(out, role)
    if wrong:
        # One more try with the mistake named. A second failure drops the sentence.
        print("  the point had the roles the wrong way round, asking again...", file=sys.stderr)
        out = ask(f"{MERGE.format(style=STYLE, role=role_line, parts=out)}\n\n"
                  f'This sentence has the roles the wrong way round: "{wrong}". Correct it.')
        if wrong_direction(out, role):
            out = re.sub(r"(## The point\s*\n+).+", r"\1- none", out, count=1)

    head = (f"# {label or folder.name}\n\nBrief from {MODEL}. "
            "Every line below appears in the transcript.\n\n")
    (folder / "brief.md").write_text(
        head + reanchor(ground(out, body, duration), body) + "\n", encoding="utf-8")
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

    # The brief an on-device model wrote for "hello? hello? testing 1, 2, 3".
    said = "Hello? Hello? Testing 1, 2, 3."
    invented = """## The point
The call settled an issue with a project.

## Decisions
- [01:12] The project will proceed with the current timeline.

## Actions
- [01:12] The project manager will review the current progress and report back.

## Key points
- [01:12] The project manager will review the current progress and report back.
- [01:12] The project manager will review the current progress and report back.

## Facts and numbers
- 40: the agreed price in pounds.

## Open questions
- [01:12] Are there any other concerns before the project begins?"""
    cleaned = ground(invented, said, 5)
    left = [l for l in cleaned.splitlines() if l.startswith("- ") and l != "- none"]
    assert left == [], left
    assert cleaned.count("- none") == 6, cleaned
    assert failure("- [01:12] Testing hello", said, 5) == "timestamp past the end"
    assert failure("- 40: the salary", "the salary is agreed", 90).startswith("number 40")
    real = "We agreed the price at 40 pounds. Sarah will send the contract by Friday."
    assert failure("- [00:04] The price is agreed at 40 pounds", real, 30) is None

    # reanchor moves a timestamp to the block that holds the words, and leaves a line
    # alone when no block is a clear match.
    spoken = ("00:00:05 Them\n\nTell me about the reconciliation of the ledger.\n\n"
              "## 00:02:30 Me\n\nWe automated the safeguarding reconciliation.\n\n"
              "## 00:09:10 Them\n\nYeah.\n")
    moved = reanchor("- [00:07:00] We automated the safeguarding reconciliation.", spoken)
    assert moved == "- [00:02:30] We automated the safeguarding reconciliation.", moved
    first = reanchor("- [00:08:00] Tell me about the reconciliation of the ledger.", spoken)
    assert first == "- [00:00:05] Tell me about the reconciliation of the ledger.", first
    kept = reanchor("- [00:01:00] Nobody said any of these particular words here.", spoken)
    assert kept == "- [00:01:00] Nobody said any of these particular words here.", kept
    assert reanchor("## Key points", spoken) == "## Key points"
    assert failure("- [Sarah] Send the contract, by Friday", real, 30) is None
    assert too_short(6).count("- none") == 6

    # The recorder keeps their own name. A mis-heard word once put "james" next
    # to the recorder and the brief renamed them throughout.
    import tempfile
    global ME
    keep, ME = ME, "David Lee"
    try:
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d)
            (folder / "transcript.md").write_text(
                "# Interview\n\nRecorded.\n\n## 00:00:01 Them\n\n"
                "morning david also walk through your cv james\n\n"
                "## 00:00:05 Me\n\nMorning Daniel.\n", encoding="utf-8")
            body = speech(folder)
        assert "00:00:05 David Lee" in body, body
        assert "00:00:05 Me" not in body, body
        assert "00:00:01 Them" in body, body
        assert "james" in body, "the speech text must survive untouched"
        assert "David Lee" in TITLE.format(me=ME, transcript="x")
        assert "David Lee" in BRIEF.format(style="s", me=ME, role="r", title="t", transcript="x")

        # The talent screen of 28 September 2026: the far end asked the questions, so
        # the recorder is the candidate, and the brief must not say they interviewed.
        screen = ("## 00:00:01 Them\n\nCan you walk me through your CV? What did you build at your last company?\n\n"
                  "## 00:01:10 David Lee\n\nI was the second finance hire.\n\n"
                  "## 00:05:00 Them\n\nHow did you forecast headcount? Any questions for me?\n\n"
                  "## 00:37:40 Them\n\nI have another meeting now, but we'll be in touch.\n")
        assert questions(screen) == (0, 4), questions(screen)
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d) / "20260928-0855-interview"
            folder.mkdir()
            assert me_role(folder, screen) == "candidate"
            assert me_role(folder, screen.replace("?", ".")) == ""
            write_meta(folder, {"label": "", "me_role": "interviewer"})
            assert me_role(folder, screen) == "interviewer", "meta.json decides"
            other = Path(d) / "20260928-1000-board"
            other.mkdir()
            assert me_role(other, screen) == "", "a call that is not an interview has no role"
        assert "candidate" in ROLE_LINES["candidate"].format(me=ME)
        wrong = "## The point\n\nDavid Lee interviewed Sam Jones for the finance role.\n"
        assert wrong_direction(wrong, "candidate").startswith("David Lee interviewed")
        for right in ("Sam Jones interviewed David Lee for the finance role.",
                      "David interviewed with Sam Jones for the finance role."):
            assert not wrong_direction(f"## The point\n\n{right}\n", "candidate"), right
        assert not wrong_direction(wrong, ""), "no role, no check"

        # A paraphrased action survives when its quote is in the transcript.
        action = '- [Them] Contact David about the next step, date unstated ("we\'ll be in touch")'
        assert failure(action, screen, 2400) is None, failure(action, screen, 2400)
        question = '- [37:40] No date for the next round ("I have another meeting now, but we\'ll be in touch")'
        assert failure(question, screen, 2400) is None
        invented_quote = '- [Them] Send an offer by Friday ("we will send you an offer on Friday")'
        assert failure(invented_quote, screen, 2400).startswith("quote not in the transcript")
        assert failure('- [Them] Contact David about the next step, date unstated', screen, 2400), \
            "without a quote the old word test still applies"
        assert failure('- [00:05] Them asked about 12 hires ("How did you forecast headcount")',
                       screen, 2400).startswith("number 12"), "a number outside the quote still counts"
    finally:
        ME = keep
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

