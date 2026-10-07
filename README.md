# Interview Recorder

A macOS app that records both sides of a call and transcribes them with a local
whisper model. It names the call, writes a brief, and copies the transcript into a
dataset folder. Nothing leaves the machine.

The app records two files, not one mix. The microphone track is you. The system
output track is the other people on the call. Whisper reads each track alone, so
each line of the transcript carries a speaker without any speaker separation
model.

## What it works with

The system output track holds whatever the Mac plays through the output device.
Microsoft Teams, Google Meet, Zoom and WhatsApp all play the far end that way, so
each of them records without any per-app setup. The app excludes its own audio,
so no echo enters the recording.

## There is an iPhone app too

`ios/` holds Call Notes, an iPhone app that records, transcribes and summarises on
the device. It cannot record the far end of a Teams, Zoom, Meet or WhatsApp call,
because iOS gives no app the audio of another app. It records the microphone, so a
call on speakerphone gives one track with both sides on it. See `ios/README.md`.

## Before you record

Ask each person on the call for permission to record. In the United Kingdom a
recording for your own use is lawful, and a recording that you share or publish
without consent is not. Several states of the United States need the consent of
every party.

## Build

```bash
./build.sh
open "build/Interview Recorder.app"
```

The build makes an app bundle and signs it ad hoc. macOS shows a permission
prompt to a bundle and not to a bare executable, so the bundle is not optional.
Keep the bundle at one path, because the permission record follows the path.

macOS asks for two permissions on the first recording:

| Prompt | Why | Where to fix a refusal |
| --- | --- | --- |
| Microphone | Your side of the call | System Settings, Privacy and Security, Microphone |
| Screen and System Audio Recording | The other side of the call | System Settings, Privacy and Security, Screen and System Audio Recording |

ScreenCaptureKit gives the system audio, and macOS puts it behind the screen
recording permission. The app asks for a 2 by 2 pixel video frame at one frame
each second and discards every frame. It records no picture.

## Use

1. Type the company and the role in the toolbar field, or leave it empty.
2. Press Record. Press Stop at the end.
3. Select the call in the list and press Transcribe.
4. Press Summarise for the brief.
5. Type or pick an application folder and press Add to dataset.

The list sorts by date, by name or by length, and the search field filters by
name.

### The title

An empty name field gives the call an automatic title. After the transcription
the model reads the first part of the transcript and writes a title of 5 to 12
words. It names the group and the subject, such as "Board: pay review and new
member recruitment". Press Rename to write a new one over a title you do not
like.

### Two calls in one recording

If you leave the recorder on and join a second call, press Split calls. The app
looks for a spell where both tracks go quiet together for 8 seconds or more. One
track alone proves nothing, because the far end goes quiet whenever you speak.
Both tracks quiet at the same time means nobody is on the line.

The app shows each join it finds and waits for you. It then cuts both tracks at
the middle of the quiet spell, writes one folder for each call, and transcribes
and names each one. The original folder stays as it is.

A test recording ran from one call straight into a second one. The detector found
one join, at 478.9 seconds to 488.6 seconds. Part 1 ended with the goodbye of the
first call and part 2 started with the greeting of the second.

Raise the gap with `--gap` on the command line if a long pause in one call gets
cut by mistake.

### The brief

Summarise sends the transcript to Ollama on this machine and writes `brief.md`
with these headings: The point, Decisions, Actions, Key points, Facts and
numbers, Open questions. Each decision and each key point carries a timestamp.
Each action names an owner and a date, or says "unstated".

Each decision, action and open question ends with a quote of 3 to 12 words from
the transcript. If the quote is in the transcript, the check keeps the line. A
correct paraphrase around the quote therefore survives. A line without a quote must share
half of its longer words with the transcript. A line with a quote that the
transcript does not hold is removed.

In an interview, the brief says who interviewed whom. The script takes the role of
the person who made the recording from these sources, in this order:

1. `"me_role": "candidate"` or `"me_role": "interviewer"` in `meta.json`.
2. The `INTERVIEW_ME_ROLE` environment variable.
3. The questions. If the call name contains "interview" or "screen", the side that
   asks at least twice as many questions is the interviewer.

If "The point" says that the candidate interviewed someone, the script asks the
model once more. If the second answer has the same error, the script removes the
sentence.

The prompts and the model plumbing come from `ytsum.py`, the YouTube brief tool
in the `ytsum` repository. The headings differ, because a call has decisions and
actions and a video has none.

Ollama must run, with the model `gemma4:26b-a4b-it-qat`. Start it with
`ollama serve`. An 8 minute call takes about 15 seconds for the title and the
brief together.

### The live coach

The live coach shows short notes in a small floating panel while you record. The
notes come from the interview prep for the role. Each note has one of these kinds:

- WRAP: end a long answer, with the line to end on.
- MISSING: a prep point or number that you did not say yet.
- ANSWER: the key points for a question that the prep answers.
- FIX: a correction to a statement that conflicts with the prep.
- ASK: a question from the prep to ask the interviewer.

The panel stays on top of the call window and does not take the keyboard focus.
A screen share and a screenshot do not show it. Drag it to the place you want, and
the app keeps that place. Clear "Live coach" next to the name field to record
without it.

Tell the app where your folder of applications is. Do this once:

```bash
defaults write com.davidlee.InterviewRecorder coachApplications ~/path/to/applications
```

The command line uses `COACH_APPLICATIONS` instead. Without either one, the coach
looks in `~/applications`.

`coach.py` does the work, in these steps:

1. It finds the application folder in your folder of applications. Each application
   has its own folder. The words of the call name select the folder, so name the
   call after the company, such as "Acme". If no folder name matches, it uses the
   folder whose tracker line books an interview today.
2. It reads the newest `interview-prep*.md`, the advert and the tracker record.
   The first line of the panel names the files that it uses.
3. Every 10 seconds it cuts the new audio of each track at a quiet point and runs
   whisper-cli with the silero model. The lines go to `live.md`.
4. Every 20 seconds it sends the prep and the transcript so far to the model. The
   model returns one note or none. The notes go to `coach.jsonl`.

A note comes 20 to 40 seconds after the speech that caused it. The coach stops
when the recording stops, and when the app quits.

The coach quotes the prep. If the prep is wrong, the note is wrong too, so correct
the prep before the call.

| Engine | Setting | Time for one note |
| --- | --- | --- |
| Claude Fable 5.1, through the `claude` CLI and your Claude login (the default) | `COACH_ENGINE=claude`, `COACH_MODEL` | 5 to 10 seconds |
| Gemma 4 on this Mac | `COACH_ENGINE=ollama` | 33 seconds |
| Gemma 4 on a second machine with a GPU, through an SSH tunnel | `COACH_ENGINE=ollama OLLAMA_HOST=http://localhost:11435` | 15 seconds (34 seconds for the first call) |

If Fable is busy, the call uses Opus 5.5 (`COACH_FALLBACK`). If the account has
used all of its Fable limit, the coach uses Opus 5.5 for the rest of the call. A
note from Opus takes about 17 seconds. The `claude` engine
sends the transcript text and the prep to Anthropic. It sends no audio. Use an
`ollama` engine to keep all of the call on your own machines.

Open the tunnel to that machine before you start the app. Replace `gpu-box` with
its SSH host name:

```bash
ssh -f -N -L 11435:127.0.0.1:11434 gpu-box
```

The app reads no shell variables when Finder starts it. To use a local engine,
start the app from Terminal:

```bash
COACH_ENGINE=ollama open "build/Interview Recorder.app"
```

To rehearse, replay a finished recording through the coach in real time. The
second command starts the replay 8 minutes into the call:

```bash
open -n "build/Interview Recorder.app" --args --coach-replay ~/Documents/InterviewRecorder/<folder>
python3 Resources/coach.py run ~/Documents/InterviewRecorder/<folder> --speed 1 --start 480
```

## Where the files go

| Item | Path | Environment variable |
| --- | --- | --- |
| Recordings | `~/Documents/InterviewRecorder/<date>-<name>/` | `INTERVIEW_RECORDER_HOME` |
| Dataset | `~/Documents/InterviewDataset/` | `INTERVIEW_DATASET` |
| App icon | `Resources/AppIcon.icns`, drawn by `make_icon.sh` | |
| Whisper model | `ggml-large-v3-turbo.bin` from OpenSuperWhisper | `INTERVIEW_WHISPER_MODEL` |
| Voice activity model | `~/.cache/whisper-vad/ggml-silero-v5.1.2.bin` | `INTERVIEW_VAD_MODEL` |
| Ollama model | `gemma4:26b-a4b-it-qat` | `INTERVIEW_MODEL` |

Each recording folder holds `mic.wav`, `system.wav`, `meta.json` and, after the
transcription, `mic.srt`, `system.srt` and `transcript.md`. Summarise adds
`brief.md`. The live coach adds `live.md`, `coach.jsonl` and `coach.log`.

The brief goes to Ollama on this machine. No audio reaches an external service.
The live coach sends the transcript text and the prep to Anthropic, unless you
pick an `ollama` engine (see "The live coach").

Press Change next to "Dataset" to pick the folder. Finder starts the app with no
shell variables, so the window keeps the choice instead. `INTERVIEW_DATASET`
still works for the command line and for the test.

`Add to dataset` copies `transcript.md` into the application folder as
`interview-transcript-<date>.md` and appends one line to `interviews.jsonl` in the
dataset root. Point `INTERVIEW_DATASET` at the folder your own application
workbench reads, and each transcript lands beside the job ad and the research
notes for that role.

Recordings stay outside the code repositories. A call is private, and a
repository is not the place for it.

## Invented text, and how the app finds the speech

whisper invents text where nobody speaks. It fills silence and room noise with stock
lines, such as "Thank you." It can also loop: one
track of 29 September 2026 gave "So, the third billion dollar company was in 1901." 72
times.

The app tried three ways to stop this:

1. whisper's own `--vad`, with the silero model, until 29 September 2026. It removes
   the invented text, but it maps the times back badly. One segment spanned 171
   seconds, and the speakers came out in the wrong order.
2. No VAD, with `-mc 0` and a loudness gate, from 29 September to 4 October 2026.
   The times were true, but a gate cannot tell a voice from a keyboard. On a call
   where David only listened, the mic track gave 27 invented lines.
3. The speech regions, from 4 October 2026. `whisper-vad-speech-segments` runs the
   silero model and lists where somebody speaks. The app cuts those pieces out, joins
   them with 1.5 seconds of silence between them, and runs whisper once. whisper
   gives each word a DTW time, and the app places each word back in the track by
   that time.

Measured on three calls with the third way:

| | Whole track, gate | Speech regions |
|---|---|---|
| Invented lines on the mic of a listening call | 27 | 1 word |
| Lines that are only a stock phrase | up to 9 a track | 0 or 1 |
| Repetition loops | up to 8 copies | none |
| Time for a 40 minute call, both tracks | about 130 s | about 70 s |
| Words | the reference | 1 to 3 per cent fewer, most of them invented |

The pass needs `whisper-vad-speech-segments`, which Homebrew installs with whisper.cpp,
and the silero model, which `build.sh` downloads. If either is missing, the app reads
the whole track as in the second way, and says so.

The silero settings catch short replies: a minimum speech of 120 ms and a threshold of
0.4. With the defaults of 250 ms and 0.5, short replies such as "Yep." went missing.

## The icon

`make_icon.sh` draws `Resources/icon.svg` and builds `AppIcon.icns`. The blue bars
above the axis are the microphone. The amber bars below are the system output.
The red bar through the middle is the record mark. Run the script only after
you change the drawing, because the repository holds the built icon. It needs
`rsvg-convert` from `brew install librsvg`.

## Audio format

Both tracks write 16 kHz mono WAV at capture time, which is what whisper.cpp
reads. No ffmpeg pass runs after the recording. One hour of a call takes about
220 MB across the two tracks.

## Command line

```bash
APP="build/Interview Recorder.app/Contents/MacOS/InterviewRecorder"

"$APP" --self-test                 # parser, merge and dataset checks
"$APP" --transcribe ~/Documents/InterviewRecorder/20260922-1100-acme

BRIEF="build/Interview Recorder.app/Contents/Resources/callbrief.py"

python3 "$BRIEF" selftest                       # the split maths
python3 "$BRIEF" title  <folder>                # name an unnamed call
python3 "$BRIEF" brief  <folder>                # write brief.md
python3 "$BRIEF" split  <folder>                # report the joins, change nothing
python3 "$BRIEF" split  <folder> --apply --gap 12

COACH="build/Interview Recorder.app/Contents/Resources/coach.py"

python3 "$COACH" selftest                       # the WAV reader, the cut and the prep lookup
python3 "$COACH" run <folder> --speed 3         # replay a call through the coach
```

`--transcribe` writes `transcript.md` for one folder without the window. Use it
for a batch.

## Tests

`--self-test` checks the SRT parser, the turn merge and the folder names. It runs
in the release build, because it uses its own check and not `assert`. Set
`INTERVIEW_DATASET` to a scratch directory and the test also copies a transcript
and writes an index row:

```bash
INTERVIEW_DATASET=/tmp/ds "$APP" --self-test
```

`callbrief.py selftest` checks the split maths against the numbers from that test
recording. It needs no audio and no model.

## Limits

The recorder makes no speaker separation inside one track. If two people share
one microphone, both appear as "Me". A meeting room with one Mac gives one
speaker label for the whole room. Two people on the far end both appear as
"Them", and the brief separates them only where the transcript says a name.

The split detector needs a quiet spell. Two calls with no gap between them stay
as one recording.

The model writes the title from the first part of the transcript. A call that
changes subject after that gets a title from the opening subject.
