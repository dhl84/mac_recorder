# Interview Recorder

A macOS app that records both sides of a call and transcribes them with a local
whisper model. It copies each transcript into a dataset folder.

The app records two files, not one mix. The microphone track is you. The system
output track is the other people on the call. Whisper reads each track alone, so
each line of the transcript carries a speaker without any speaker separation
model.

## What it works with

The system output track holds whatever the Mac plays through the output device.
Microsoft Teams, Google Meet, Zoom and WhatsApp all play the far end that way, so
each of them records without any per-app setup. The app excludes its own audio,
so no echo enters the recording.

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

1. Type the company and the role in the toolbar field.
2. Press Record. Press Stop at the end.
3. Select the call in the list and press Transcribe.
4. Type or pick an application folder and press Add to dataset.

The list sorts by date, by name or by length, and the search field filters by
name.

## Where the files go

| Item | Path | Environment variable |
| --- | --- | --- |
| Recordings | `~/Documents/InterviewRecorder/<date>-<name>/` | `INTERVIEW_RECORDER_HOME` |
| Dataset | `~/Documents/InterviewDataset/` | `INTERVIEW_DATASET` |
| Whisper model | `ggml-large-v3-turbo.bin` from OpenSuperWhisper | `INTERVIEW_WHISPER_MODEL` |

Each recording folder holds `mic.wav`, `system.wav`, `meta.json` and, after the
transcription, `mic.srt`, `system.srt` and `transcript.md`.

`Add to dataset` copies `transcript.md` into the application folder as
`interview-transcript-<date>.md` and appends one line to `interviews.jsonl` in the
dataset root. A workbench that reads the same folders sees the transcript beside the
job ad and the research notes for that role.

Recordings stay outside the code repositories. A call is private, and a
repository is not the place for it. Keep the dataset folder out of any public repository.

## Audio format

Both tracks write 16 kHz mono WAV at capture time, which is what whisper.cpp
reads. No ffmpeg pass runs after the recording. One hour of a call takes about
220 MB across the two tracks.

## Command line

```bash
APP="build/Interview Recorder.app/Contents/MacOS/InterviewRecorder"

"$APP" --self-test                 # parser, merge and dataset checks
"$APP" --transcribe ~/Documents/InterviewRecorder/20260922-1100-acme
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

## Limits

The recorder makes no speaker separation inside one track. If two people share
one microphone, both appear as "Me". A meeting room with one Mac gives one
speaker label for the whole room.
