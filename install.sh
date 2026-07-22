#!/bin/bash
# Install Unduck into /Applications and relaunch it from there.
#
# Running from the build folder works, but it is a bad home for a daily driver: a
# login item pointing into a build directory breaks the moment that directory is
# cleaned, moved, or rebuilt into. /Applications is stable.
#
# Permissions are keyed to the code signature (identifier + certificate leaf), not
# the path, so grants made here survive future rebuilds — but macOS may still ask
# once more after the move.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh release

SRC="build/Unduck.app"
DEST="/Applications/Unduck.app"

pkill -x Unduck 2>/dev/null || true
sleep 1

rm -rf "$DEST"
cp -R "$SRC" "$DEST"

echo "installed: $DEST"
codesign -dvv "$DEST" 2>&1 | grep -E "Identifier|Authority"

open "$DEST"
echo
echo "Now, once:"
echo "  1. System Settings > Privacy & Security > Accessibility"
echo "     remove any old Unduck entry, add /Applications/Unduck.app, turn it on"
echo "  2. Quit and reopen Unduck so it re-reads that grant"
echo "  3. Tick 'Start Unduck at login'"
