#!/bin/bash
# Build Unduck.app and ad-hoc sign it.
#
# It has to be a signed .app bundle, not a bare binary: Core Audio taps are gated on
# the audio-capture TCC grant, and tccd will not even prompt unless the responsible
# process has a bundle carrying NSAudioCaptureUsageDescription. An unsigned CLI gets
# silently handed all-zero samples instead of an error.
#
# Signed with a stable self-signed identity (./make-cert.sh), NOT ad-hoc. Ad-hoc
# signatures have no stable identity: the designated requirement is the cdhash, so
# every rebuild looks like a different app and every TCC grant — audio capture,
# Accessibility, Automation — is silently revoked. With a certificate the
# requirement becomes `identifier + certificate leaf`, which survives rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Unduck"

APP="build/Unduck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Unduck"
cp Info.plist "$APP/Contents/Info.plist"
# The icon lives in Resources and is named by CFBundleIconFile. Without it the
# app shows the blank generic tile in the Dock and in Finder.
mkdir -p "$APP/Contents/Resources"
cp assets/Unduck.icns "$APP/Contents/Resources/Unduck.icns"

IDENTITY="Unduck Self Signed"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" --options runtime "$APP"
else
  echo "warning: no signing identity — run ./make-cert.sh, or permissions will reset every build"
  codesign --force --sign - --options runtime "$APP"
fi

echo "built: $APP"
