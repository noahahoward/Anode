#!/bin/bash
# Create the local code-signing identity that keeps macOS permissions across rebuilds.
#
#   ./make-signing-identity.sh
#
# WHY. Anode is ad-hoc signed, and an ad-hoc signature is just a hash of the code,
# so every rebuild is a different signature to macOS. Privacy permissions (Screen
# Recording, for the menu bar backdrop's follow mode) are remembered against the
# signature, so each rebuild silently dropped them while System Settings still
# showed the switch on. Measured: the build with cdhash cc285c4f was allowed and
# the next build, ec28de2c, was not, with nothing else changed.
#
# A certificate-based signature has a "designated requirement" that names the
# certificate rather than the code, and that stays the same across rebuilds.
#
# WHAT THIS DOES, AND DOES NOT DO.
#   - It makes a self-signed certificate and puts it, with its private key, in a
#     keychain of its own: ~/Library/Keychains/anode-signing.keychain-db. Your
#     login keychain is not touched and no trust settings are changed, so nothing
#     here needs your password.
#   - build-app.sh uses the identity when that keychain exists and signs ad-hoc
#     when it does not, so a machine that never ran this still builds exactly as
#     before. Release builds always sign ad-hoc.
#   - The certificate is not trusted by anything and proves nothing to anyone
#     else. It exists only so one Mac can recognise its own successive builds.
#   - The keychain password below is not a secret. The key signs local builds and
#     has no other use; the password only lets the build unlock it unattended.
#
# To undo:  ./make-signing-identity.sh --remove
set -euo pipefail

NAME="Anode Local Signing"
KC="$HOME/Library/Keychains/anode-signing.keychain-db"
PASS="anode-local-signing"
# The system's LibreSSL, by absolute path: a Homebrew OpenSSL 3+ earlier in PATH
# writes a PKCS#12 format `security import` cannot read.
SSL=/usr/bin/openssl

if [ "${1:-}" = "--remove" ]; then
  security delete-keychain "$KC" 2>/dev/null && echo "✓ removed $KC" || echo "nothing to remove"
  exit 0
fi

if [ -f "$KC" ] && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
  echo "✓ the signing identity already exists in $KC"
  exit 0
fi
rm -f "$KC"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/ssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

"$SSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/ssl.cnf" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
"$SSL" pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -out "$tmp/id.p12" -passout "pass:$PASS" 2>/dev/null

security create-keychain -p "$PASS" "$KC"
# No auto-lock timeout: build-app.sh unlocks it anyway, but a locked keychain
# partway through a build would be a baffling failure.
security set-keychain-settings "$KC"
security unlock-keychain -p "$PASS" "$KC"
security import "$tmp/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
# Lets codesign use the key without a "wants to use your keychain" dialog.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null 2>&1

security find-identity -p codesigning "$KC" | grep "$NAME" >/dev/null \
  && echo "✓ created '$NAME' in $KC" \
  || { echo "✗ the identity was not created" >&2; exit 1; }
