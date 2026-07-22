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

if security find-identity -v -p codesigning | grep -q "$NAME"; then
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
security find-identity -v -p codesigning | grep "$NAME" || {
  echo
  echo "The certificate imported but is not yet valid for code signing."
  echo "It needs to be trusted. Run:"
  echo "  security add-trusted-cert -d -r trustRoot -p codeSign -k \"$KEYCHAIN\" <cert>"
  echo "or set it to 'Always Trust' for Code Signing in Keychain Access."
  exit 1
}
