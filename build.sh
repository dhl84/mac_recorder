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

# macOS ties the screen and audio permission to the signature. An ad-hoc
# signature changes with each build, so a rebuild silently loses the permission
# while System Settings still shows it on. A certificate keeps it stable.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [ -z "$SIGN_ID" ]; then
  echo "No Apple Development certificate: ad-hoc signing. Grant the permission again after each build."
  SIGN_ID="-"
fi
codesign --force --sign "$SIGN_ID" --identifier com.davidlee.InterviewRecorder "$APP"

echo "Built $PWD/$APP"
echo "Run it with: open '$PWD/$APP'"
