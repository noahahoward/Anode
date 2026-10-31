#!/bin/bash
# Regenerate Resources/PrebuiltIcon/ from Resources/AppIcon.icon.
#
#   ./make-icon.sh        (needs full Xcode, for actool)
#
# Run it, and commit the result, whenever the .icon source changes.
#
# WHY THE COMPILED ICON IS COMMITTED: actool ships only with full Xcode, and the
# install one-liner is meant to work on a machine with just the Command Line
# Tools. Without these files such a machine built a bundle with the generic app
# icon. build-app.sh uses actool when it is there and copies these when it is
# not, so everyone ends up with the same Liquid Glass icon.
#
# build-app.sh does not refresh them itself: a build that rewrote tracked files
# would leave every developer's checkout dirty, and update.sh refuses to pull
# into a dirty checkout.
set -euo pipefail
cd "$(dirname "$0")"

xcrun --find actool >/dev/null 2>&1 || { echo "✗ actool not found — this needs full Xcode, not just the Command Line Tools." >&2; exit 1; }

OUT="Resources/PrebuiltIcon"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

xcrun actool Resources/AppIcon.icon \
  --compile "$TMP" \
  --platform macosx \
  --minimum-deployment-target 26.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$TMP/partial.plist" \
  --errors --warnings

mkdir -p "$OUT"
cp "$TMP/AppIcon.icns" "$TMP/Assets.car" "$OUT/"
echo "› wrote $OUT/ — commit it."
