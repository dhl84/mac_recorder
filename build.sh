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

# An ad-hoc signature is enough for the permission records to survive a restart,
# while the bundle stays at the same path.
codesign --force --sign - --identifier com.davidlee.InterviewRecorder "$APP"

echo "Built $PWD/$APP"
echo "Run it with: open '$PWD/$APP'"
