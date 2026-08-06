#!/bin/bash
# Assemble BetterStats.app from the SPM build product.
# Usage: ./build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="BetterStats.app"
BIN="BetterStatsApp"
ICON="Resources/AppIcon.icon"

echo "› building ($CONFIG)…"
swift build -c "$CONFIG" --product "$BIN"
BUILT="$(swift build -c "$CONFIG" --show-bin-path)/$BIN"

echo "› assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILT" "$APP/Contents/MacOS/$BIN"

# ── Icon ────────────────────────────────────────────────────────────────────
# Icon Composer (.icon) source, compiled with actool. This emits BOTH:
#   Assets.car    layered rendering incl. the Liquid Glass treatment (macOS 26+)
#   AppIcon.icns  flattened classic icon, used by older macOS and by anything
#                 reading the bundle directly (Finder on older systems, dock tiles)
# Shipping both means the icon degrades gracefully instead of vanishing.
ICON_OK=0
if [ -d "$ICON" ]; then
  echo "› compiling icon…"
  if xcrun actool "$ICON" \
        --compile "$APP/Contents/Resources" \
        --platform macosx \
        --minimum-deployment-target 26.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$APP/Contents/Resources/.icon-partial.plist" \
        --errors --warnings >/dev/null 2>&1; then
    ICON_OK=1
    rm -f "$APP/Contents/Resources/.icon-partial.plist"
  else
    echo "  ! actool failed — bundle will use the default icon"
  fi
else
  echo "  ! $ICON not found — skipping icon"
fi

# ── Info.plist ──────────────────────────────────────────────────────────────
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>BetterStats</string>
  <key>CFBundleDisplayName</key>       <string>BetterStats</string>
  <key>CFBundleIdentifier</key>        <string>dev.noah.betterstats</string>
  <key>CFBundleExecutable</key>        <string>BetterStatsApp</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
$( [ "$ICON_OK" = "1" ] && printf '  <key>CFBundleIconFile</key>          <string>AppIcon</string>\n  <key>CFBundleIconName</key>          <string>AppIcon</string>' )
  <!-- Deliberately NOT sandboxed: App Sandbox denies process-info-listpids,
       which is required to enumerate processes. This also means the app can
       never ship on the Mac App Store. -->
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper lets a locally built bundle launch.
codesign --force --sign - "$APP" 2>/dev/null || echo "  (ad-hoc signing skipped)"

# Nudge Finder/Dock to drop any cached icon for this bundle id.
touch "$APP"

echo "› done: $(pwd)/$APP"
