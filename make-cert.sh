#!/bin/bash
# Create a stable self-signed code-signing identity for Unduck.
#
# Why this is necessary: TCC keys permissions to the app's code signature. An
# ad-hoc signature has no stable identity — its designated requirement is the
# cdhash, which changes on every single build. So Accessibility, Automation and
# audio-capture grants all evaporate each time the app is rebuilt, and no
# permission-dependent feature can ever be tested twice.
#
# A self-signed certificate gives the bundle a stable identity, so grants persist
# across rebuilds. To undo: open Keychain Access, find "Unduck Self Signed" in the
# login keychain, delete it.
set -euo pipefail
cd "$(dirname "$0")"

NAME="Unduck Self Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Check with find-certificate, NOT `find-identity -p codesigning`. A self-signed
# cert that has not been marked as a trusted root is absent from find-identity yet
# `codesign --sign "$NAME"` uses it happily. Checking the wrong one means this
# script never sees its own work and imports a duplicate cert on every run.
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "identity already exists: $NAME"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# Legacy PKCS12 algorithms on purpose: OpenSSL 3 defaults to AES-256-CBC with an
# SHA-256 MAC, which Apple's Security framework cannot read — the import fails with
# "MAC verification failed (wrong password?)" even though the password is right.
openssl pkcs12 -export -out "$TMP/identity.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -passout pass:unduck \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

# -A lets codesign use the key without a keychain prompt on every build.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P unduck -A

echo "created identity: $NAME"

# Verify by actually signing something. Any check based on find-identity reports
# failure here even when signing works, which is worse than no check at all.
PROBE=$(mktemp -d)
trap 'rm -rf "$TMP" "$PROBE"' EXIT
cp /bin/echo "$PROBE/probe"
if codesign --force --sign "$NAME" "$PROBE/probe" 2>/dev/null; then
  echo "verified: the identity can sign"
else
  echo
  echo "The certificate imported but cannot sign."
  echo "Open Keychain Access, find \"$NAME\" in the login keychain, and set"
  echo "Trust > Code Signing to 'Always Trust'."
  exit 1
fi
