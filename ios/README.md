# Call Notes, the iPhone app

An iPhone app that records a conversation, transcribes it on the device, and
writes a title and a brief. Nothing leaves the phone.

## What an iPhone cannot do

iOS gives no app the audio of another app. The Mac app uses ScreenCaptureKit, and
iOS has no equivalent. This app therefore cannot record the far end of a Microsoft
Teams, Zoom, Google Meet or WhatsApp call. A ReplayKit
broadcast extension does not help, because it leaves out the audio of a call.
During a normal telephone call, iOS also keeps the microphone from other apps.

The app records the microphone. Put the call on speakerphone and the microphone
hears both sides. The result is one track, so the transcript names no speaker.
The Mac app records two tracks and labels each line, and that is the reason.

## Before you record

Ask each person on the call for permission to record. In the United Kingdom a
recording for your own use is lawful, and a recording that you share or publish
without consent is not. Several states of the United States need the consent of
every party.

## What it uses

| Job | Framework | Note |
| --- | --- | --- |
| Recording | AVFoundation | 16 kHz mono WAV, about 110 MB for one hour |
| Transcription | Speech, `SpeechAnalyzer` and `SpeechTranscriber` | On the device. iOS installs the language assets on first use |
| Title and brief | FoundationModels | The on-device model. It needs Apple Intelligence |
| Interface | SwiftUI | iPhone only |

The Mac app runs whisper.cpp and Ollama. The iPhone app runs neither, because
iOS 26 ships both jobs as system frameworks. The app downloads no model file of
gigabytes, and it sends no request to a server.

## Build and run

```bash
open ios/InterviewRecorder.xcodeproj
```

Select your iPhone and press Run. The project signs automatically with the team
`5C49Q9G3ML`. From the command line:

```bash
xcodebuild -project ios/InterviewRecorder.xcodeproj -scheme InterviewRecorder \
  -sdk iphoneos -configuration Debug -derivedDataPath ios/build \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build

xcrun devicectl device install app --device <your-device-id> \
  ios/build/Build/Products/Debug-iphoneos/InterviewRecorder.app
```

Unlock the iPhone first. `devicectl` cannot install on a locked device.

## Use

1. Type the company and the role, or leave the field empty.
2. Press Record. The level bar moves, so a dead microphone shows itself at once.
3. Press Stop.
4. Open the call and press Transcribe. An empty name field gets a title here.
5. Press Summarise for the brief. Press Share to send either file out.

The menu sorts the list by date, by name or by length. The search field filters
by name. Swipe a row to delete it.

The app keeps recording when the screen locks, because it declares the audio
background mode. An incoming telephone call takes the microphone, and the app
then stops and keeps the part it has.

## Split calls

Press Split calls if one recording holds two conversations. The app measures the
level in each quarter second and looks for 20 seconds of silence.

This is weaker than the Mac test. The Mac has two tracks and asks where both go
quiet together, which nothing but an empty line explains. One track cannot tell a
long pause from a gap between calls, so the app shows each candidate time and
waits for you.

## Files

Each call is one folder in `Documents/Calls/`, which holds `audio.wav`,
`meta.json` and, after the transcription, `transcript.md` and `brief.md`. The
Files app reaches them, so a folder copies to a Mac or into the dataset by hand.

## Tests

The menu holds Self test. It runs 17 checks that need no microphone, no model and
no network: the clock and the name rules, the transcript layout, the chunking of
a long transcript and the split maths. The same checks run from a terminal:

```bash
xcrun simctl launch --console <simulator-id> com.davidlee.InterviewRecorder --self-test
```

The simulator cannot transcribe. It reports the speech assets as `unsupported`,
and the app then says so instead of failing in a way nobody can read. Test the
transcription on an iPhone.

## Limits

One track, so no line names a speaker. Two people in a room both read the same.

The title comes from the first part of the transcript, so a call that changes
subject later keeps the name of its first subject.

The brief needs Apple Intelligence. Without it the app still records and
transcribes, and it says which part is missing.
