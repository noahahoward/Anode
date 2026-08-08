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
  <!-- Every bundled AppKit app declares this; ours did not. It did NOT fix the
       status-item problem (see WIDGET-BUG.md) but it is correct regardless. -->
  <key>NSPrincipalClass</key>          <string>NSApplication</string>
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

# Install to ~/Applications and run from THERE, not from the build directory.
#
# This is not tidiness, it is a workaround for a real failure. Rebuilding an
# ad-hoc-signed bundle repeatedly at one path accumulates LaunchServices
# registrations for that path — 29 of them here — and once that happens macOS
# stops laying out the app's NSStatusItems: they are created, hold correctly
# sized buttons and images, report isVisible, and their status windows sit at
# (0, 0, w, 0), zero height, forever. The menu bar shows nothing while every
# check says healthy.
#
# Proven by copying the byte-identical bundle elsewhere: /tmp/verify.app placed
# its first item at (1399, 7) while the build directory's copy reported
# (-1, 1157) in the same minute. Same bytes, same signature, same binary.
#
# `lsregister -kill` would clear it but Apple removed that option, and
# unregistering by path does not undo it. Installing to a stable location the
# build does not churn keeps the registration stable, which is what a real user
# has anyway.
INSTALL_DIR="$HOME/Applications"
mkdir -p "$INSTALL_DIR"
if [ -d "$INSTALL_DIR/BetterStats.app" ]; then
  # Quit a running copy first so the bundle is not swapped under it.
  osascript -e 'tell application "BetterStats" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf "$INSTALL_DIR/BetterStats.app"
fi
cp -R "$APP" "$INSTALL_DIR/"

echo "› built:     $(pwd)/$APP"
echo "› installed: $INSTALL_DIR/BetterStats.app   <- launch THIS one"
