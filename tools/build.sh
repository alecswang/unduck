#!/bin/bash
# Build the probe, then wrap it in a real .app bundle and ad-hoc sign it.
#
# Why the bundle: Core Audio taps are gated by the TCC audio-capture grant, and a
# bare CLI has no bundle identity for tccd to prompt about — the tap is created
# successfully but every sample comes back zero, with nothing logged. A signed
# bundle with NSAudioCaptureUsageDescription gets a real prompt.
set -euo pipefail
cd "$(dirname "$0")"

swift build "$@"
BIN="$(swift build --show-bin-path "$@")/probe"

APP="build/UnduckProbe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/probe"
cp Info.plist "$APP/Contents/Info.plist"

codesign --force --sign - \
  --entitlements probe.entitlements \
  --options runtime \
  "$APP"

echo "built: $APP/Contents/MacOS/probe"
