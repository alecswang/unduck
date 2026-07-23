#!/bin/bash
# Build a distributable Unduck.dmg.
#
# Signing tiers, best available wins. The script tells you which one it used,
# because the tier decides what a downloader sees on first launch:
#
#   Developer ID + notarized  ->  opens with no warning at all
#   Developer ID, not notarized -> "Apple could not verify" block
#   self-signed / ad-hoc      ->  same block; user must approve in System Settings
#
# Only the first tier is a clean install for someone who is not a developer, and it
# requires a paid Apple Developer Program membership. See docs/releasing.md.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
APP="build/Unduck.app"
DMG="build/Unduck-$VERSION.dmg"

# --- pick a signing identity -------------------------------------------------
# `find-identity -p codesigning` only lists certs chaining to a trusted root, so a
# Developer ID shows up there but the local self-signed one does not. Look for each
# the way that actually finds it.
# `|| true`: no Developer ID is the normal case, but grep exits 1 on no match and
# `set -e` + `pipefail` turn that into a silent abort of the whole script.
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null \
          | grep "Developer ID Application" | head -1 \
          | sed -E 's/.*"(.*)"/\1/' || true)"

if [ -n "$DEV_ID" ]; then
  IDENTITY="$DEV_ID"
  TIER="developer-id"
elif security find-certificate -c "Unduck Self Signed" >/dev/null 2>&1; then
  IDENTITY="Unduck Self Signed"
  TIER="self-signed"
else
  IDENTITY="-"
  TIER="ad-hoc"
fi

echo "signing identity: $IDENTITY  (tier: $TIER)"

# --- build -------------------------------------------------------------------
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Unduck"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Unduck"
cp Info.plist "$APP/Contents/Info.plist"
# The icon lives in Resources and is named by CFBundleIconFile. Without it the
# app shows the blank generic tile in the Dock and in Finder.
mkdir -p "$APP/Contents/Resources"
cp assets/Unduck.icns "$APP/Contents/Resources/Unduck.icns"

# --hardened-runtime is required for notarization and harmless without it.
# --timestamp needs the network and is only meaningful for a real identity.
if [ "$TIER" = "developer-id" ]; then
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
else
  codesign --force --sign "$IDENTITY" --options runtime "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

# --- notarize ----------------------------------------------------------------
# Skipped unless there is a Developer ID AND stored credentials. Notarizing a
# self-signed build is impossible, not merely inadvisable: Apple rejects anything
# not signed with a Developer ID certificate.
NOTARIZED=no
if [ "$TIER" = "developer-id" ] && xcrun notarytool history --keychain-profile unduck-notary >/dev/null 2>&1; then
  echo "notarizing (this takes a few minutes)..."
  ZIP="build/Unduck-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile unduck-notary --wait
  # Staple so the app validates offline. Without this a downloader with no network
  # still sees the unverified-developer block.
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  NOTARIZED=yes
elif [ "$TIER" = "developer-id" ]; then
  echo "warning: Developer ID found but no notary credentials — see docs/releasing.md"
fi

# --- package -----------------------------------------------------------------
# dmgbuild lays the window out (background art, icon positions, no chrome) by writing
# the .DS_Store directly. The traditional approach scripts Finder over AppleEvents,
# which needs Automation permission, prompts the first time, and cannot run headless.
rm -f "$DMG"
if ! python3 -c "import dmgbuild" 2>/dev/null; then
  echo "error: dmgbuild missing. Install it with:  pip3 install --user dmgbuild"
  exit 1
fi
UNDUCK_APP="$APP" python3 -m dmgbuild -s dmg-settings.py "Unduck" "$DMG"

# The DMG itself is signed too, so Gatekeeper checks it before anything is copied.
[ "$IDENTITY" = "-" ] || codesign --force --sign "$IDENTITY" "$DMG"

if [ "$NOTARIZED" = yes ]; then
  xcrun stapler staple "$DMG"
fi

echo
echo "built: $DMG"
echo "tier:  $TIER, notarized: $NOTARIZED"
if [ "$NOTARIZED" != yes ]; then
  echo
  echo "This build will show 'Apple could not verify Unduck is free of malware'"
  echo "on any machine other than this one. Only a notarized Developer ID build"
  echo "installs cleanly — docs/releasing.md explains what that takes."
fi
