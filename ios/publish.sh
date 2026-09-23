#!/bin/bash
# Archives Call Notes, uploads it to TestFlight and gives the internal group the
# build. The App Store Connect details come from the environment, never from
# this repository:
#
#   export ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=...
#   ios/publish.sh
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}" "${ASC_KEY_PATH:?set ASC_KEY_PATH}"
export FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1

# TestFlight refuses a build number it has seen, so each run takes the clock.
BUILD=${BUILD:-$(date +%y%m%d%H%M)}
TESTER=${TESTER:-you@example.com}
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

echo "=== archive, build $BUILD ==="
rm -rf ios/build/CallNotes.xcarchive ios/build/export
xcodebuild -project ios/InterviewRecorder.xcodeproj -scheme InterviewRecorder \
  -sdk iphoneos -configuration Release -archivePath ios/build/CallNotes.xcarchive \
  -destination 'generic/platform=iOS' "${AUTH[@]}" \
  CURRENT_PROJECT_VERSION="$BUILD" archive | grep -E "error:|ARCHIVE" || true
[ -d ios/build/CallNotes.xcarchive ] || { echo "archive failed"; exit 1; }

echo "=== export ==="
xcodebuild -exportArchive -archivePath ios/build/CallNotes.xcarchive \
  -exportOptionsPlist ios/ExportOptions.plist -exportPath ios/build/export \
  "${AUTH[@]}" | grep -E "error|EXPORT" || true
IPA=$(ls "$PWD"/ios/build/export/*.ipa 2>/dev/null | head -1)
[ -n "$IPA" ] || { echo "export failed"; exit 1; }

cd ios
echo "=== upload $IPA ==="
fastlane up ipa:"$IPA"
echo "=== internal testers ==="
fastlane group email:"$TESTER"
fastlane state
echo "Apple processes the build for 5 to 15 minutes. Then it shows in the TestFlight app."
