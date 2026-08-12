#!/bin/bash
# Cut a versioned release bundle into releases/.
# Usage: ./make-release.sh
#
# WHY THIS IS SEPARATE FROM build-app.sh: that script deliberately DELETES the
# bundle it assembles once it has installed it to ~/Applications, because a
# launchable copy left in the build directory is the one whose LaunchServices
# registrations are poisoned and whose menu bar widgets get placed off-screen
# while every health check reports them present (see WIDGET-BUG.md). That
# deletion is load-bearing and is not worth weakening for packaging, so the
# release is taken from the INSTALLED copy instead.
set -euo pipefail
cd "$(dirname "$0")"

./build-app.sh release

SRC="$HOME/Applications/Anode.app"
[ -d "$SRC" ] || { echo "! build-app.sh did not produce $SRC"; exit 1; }

VERSION="$(defaults read "$SRC/Contents/Info.plist" CFBundleShortVersionString)"
BUILD="$(defaults read "$SRC/Contents/Info.plist" CFBundleVersion)"
COMMIT="$(defaults read "$SRC/Contents/Info.plist" BSSourceCommit 2>/dev/null || echo unknown)"
NAME="Anode-${VERSION}"

mkdir -p releases
rm -rf "releases/${NAME}.app" "releases/${NAME}.zip"
cp -R "$SRC" "releases/${NAME}.app"

# ditto, not zip: it preserves the bundle structure, resource forks and the code
# signature. A plain `zip` can invalidate the signature, and an app whose
# signature does not verify is one macOS refuses to open with a message that
# says nothing useful.
ditto -c -k --sequesterRsrc --keepParent "releases/${NAME}.app" "releases/${NAME}.zip"

SHA="$(shasum -a 256 "releases/${NAME}.zip" | cut -d' ' -f1)"
SIZE="$(du -h "releases/${NAME}.zip" | cut -f1)"

cat > "releases/${NAME}.txt" <<EOF
Anode ${VERSION} (build ${BUILD})
source commit  ${COMMIT}
built          $(date -u '+%Y-%m-%d %H:%M:%S UTC')
sha256         ${SHA}
size           ${SIZE}

Signature: ad-hoc, NOT notarised. See releases/README.md before sending this
to anyone.
EOF

echo
echo "› releases/${NAME}.app"
echo "› releases/${NAME}.zip   ${SIZE}"
echo "› sha256 ${SHA}"
echo "› NOTE: ad-hoc signed and not notarised — read releases/README.md before"
echo "›       handing the zip to another machine."
