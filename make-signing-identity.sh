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
#   - build-app.sh runs this itself, once, on the first build on a machine, so an
#     update never silently kills the approvals the last build was given: without
#     it every update is a new signature and macOS keeps ignoring the old
#     approval while System Settings still shows it switched on (measured on a
#     MacBook Neo: AXIsProcessTrusted=false, signature=ad-hoc, switch on).
#     If creating it fails the build signs ad-hoc as before. `--remove` also
#     leaves a marker so no later build makes it again; running this script
#     with no arguments takes the marker away. Release builds always sign
#     ad-hoc (make-release.sh), whatever is here.
#   - The certificate is trusted by nothing and proves nothing to anyone else.
#
# THE TRADE-OFF, STATED PLAINLY. An ad-hoc approval is pinned to one exact build,
# so nothing else can borrow it. This identity is not: any program that can unlock
# this keychain can sign ITSELF as `dev.anode.app`, and macOS will then treat it
# as Anode and give it whatever Anode has been allowed — Screen Recording today.
#
# The keychain's password is the fixed string below, which is public (it is in this
# repository), so the only thing between such a program and the key is that it must
# be running as you, since the keychain file is in your home directory. That keeps
# out other users and sandboxed apps; it does NOT keep out code already running as
# you, and that code is exactly who this would help. build-app.sh has to unlock the
# keychain unattended, so any scheme that lets it also lets them.
#
# If that matters more to you than re-approving a permission after each rebuild,
# run `./make-signing-identity.sh --remove` and nothing else changes.
#
# To undo:  ./make-signing-identity.sh --remove   (and builds stop making it)
set -euo pipefail

NAME="Anode Local Signing"
KC="$HOME/Library/Keychains/anode-signing.keychain-db"
# Public, and not a secret — see the trade-off above.
PASS="anode-local-signing"
# The system's LibreSSL, by absolute path: a Homebrew OpenSSL 3+ earlier in PATH
# writes a PKCS#12 format `security import` cannot read.
SSL=/usr/bin/openssl

# Written by --remove so that build-app.sh, which makes the identity by itself, does
# not make it again behind the back of someone who said no.
OPTOUT="$HOME/Library/Application Support/Anode/no-signing-identity"

if [ "${1:-}" = "--remove" ]; then
  security delete-keychain "$KC" 2>/dev/null && echo "✓ removed $KC" || echo "nothing to remove"
  mkdir -p "$(dirname "$OPTOUT")" && : > "$OPTOUT"
  echo "  builds will sign ad-hoc and will not make it again; run this script with no arguments to turn it back on."
  exit 0
fi
# Asked for by name: whatever was said before, it is wanted now.
rm -f "$OPTOUT"

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
