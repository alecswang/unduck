#!/bin/bash
# Launch the probe through LaunchServices so it is its OWN responsible process.
#
# Running the binary from a shell makes Terminal (or whatever launched the shell)
# the responsible process for TCC, so the audio-capture verdict is Terminal's —
# and a previously-denied verdict is sticky and silent, with no re-prompt ever.
# `open -a` gives the bundle its own identity, so the prompt says "Unduck Spike".
#
# Usage: ./run-as-app.sh selftest --db -20 --seconds 6
set -uo pipefail
cd "$(dirname "$0")"

APP="$PWD/build/UnduckProbe.app"
LOG="$PWD/build/app-run.log"
[ -x "$APP/Contents/MacOS/probe" ] || { echo "build first: ./build.sh"; exit 1; }

rm -f "$LOG"
open -a "$APP" --args "$@" --log "$LOG"

echo "launched $APP"
echo "if a permission dialog appears naming 'Unduck Spike', approve it"
echo "--- live log ($LOG) ---"

# Follow until the app exits, then leave a copy next to the other measurements.
while [ ! -f "$LOG" ]; do sleep 0.2; done
tail -f "$LOG" &
TAIL=$!
while pgrep -f "UnduckProbe.app/Contents/MacOS/probe" > /dev/null; do sleep 1; done
sleep 1
kill $TAIL 2>/dev/null

cp "$LOG" ../docs/duck-run.log
echo "--- done, copied to docs/duck-run.log ---"
