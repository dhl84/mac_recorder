#!/bin/bash
# Builds Interview Recorder.app. macOS gives a permission prompt to a bundle,
# not to a bare executable, so the bundle is not optional.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Interview Recorder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/InterviewRecorder "$APP/Contents/MacOS/InterviewRecorder"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/callbrief.py "$APP/Contents/Resources/callbrief.py"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# whisper invents speech in the quiet parts of a call without this model.
VAD="$HOME/.cache/whisper-vad/ggml-silero-v5.1.2.bin"
if [ ! -f "$VAD" ]; then
  echo "Downloading the voice activity model once, to $VAD"
  mkdir -p "$(dirname "$VAD")"
  curl -fsSL -o "$VAD" https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin
fi

# An ad-hoc signature is enough for the permission records to survive a restart,
# while the bundle stays at the same path.
codesign --force --sign - --identifier com.davidlee.InterviewRecorder "$APP"

echo "Built $PWD/$APP"
echo "Run it with: open '$PWD/$APP'"
