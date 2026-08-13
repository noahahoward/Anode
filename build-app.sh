#!/bin/bash
# Assemble Anode.app from the SPM build product.
# Usage: ./build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="Anode.app"
BIN="AnodeApp"
HELPER="AnodeHelper"
ICON="Resources/AppIcon.icon"

# ── Version ─────────────────────────────────────────────────────────────────
# The marketing version is edited by hand; the build number is the commit count,
# so two bundles claiming the same version cannot contain different code. A
# tester reporting a bug can be asked "what does About say" and the answer maps
# to an exact commit — which matters more than usual here, because there is no
# update mechanism and a tester may be running something weeks old.
VERSION="0.2.0"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
# Absolute, and resolved through any symlink, because it is written into a
# bundle that will be launched from somewhere else entirely.
SOURCE_PATH="$(cd "$(dirname "$0")" && pwd -P)"
DIRTY=""
if ! git diff --quiet HEAD 2>/dev/null; then DIRTY="+"; fi

echo "› building ($CONFIG)…"
swift build -c "$CONFIG" --product "$BIN"
# The fan helper ships beside the app but is NEVER started by it: it runs as root
# and the user starts it themselves with sudo when they want fan control. It is
# in the bundle so there is one obvious path to type, and so it and the app it
# will only ever talk to are rebuilt together — the helper pins the app's cdhash
# at startup, and an app rebuilt without its helper would simply be refused.
swift build -c "$CONFIG" --product "$HELPER"
BUILT="$(swift build -c "$CONFIG" --show-bin-path)/$BIN"
BUILT_HELPER="$(swift build -c "$CONFIG" --show-bin-path)/$HELPER"

echo "› assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILT" "$APP/Contents/MacOS/$BIN"
cp "$BUILT_HELPER" "$APP/Contents/MacOS/$HELPER"

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

# ── Documentation ───────────────────────────────────────────────────────────
# The Help menu opens these. It looks in Contents/Resources first and falls back
# to walking up to the source checkout, so a `swift build` binary finds them
# either way — but an INSTALLED bundle has no checkout above it, and without
# these two lines the shipped app would have no Help menu at all. That is the
# build every tester actually runs.
for doc in README.md TESTING.md; do
  [ -f "$doc" ] && cp "$doc" "$APP/Contents/Resources/$doc"
done

# The updater ships INSIDE the bundle, and that is not tidiness.
#
# The Update button used to run update.sh out of the checkout. Move the checkout
# to any commit older than the updater — `git reset --hard HEAD~1` will do it —
# and the button reports its own script missing, which is precisely when someone
# needs it. A tool that repairs a checkout cannot be stored in the checkout at
# the version it is repairing. The bundled copy always matches the build that is
# running, and takes the checkout path as an argument.
for script in update.sh uninstall.sh; do
  [ -f "$script" ] && cp "$script" "$APP/Contents/Resources/$script" \
                   && chmod +x "$APP/Contents/Resources/$script"
done

# ── Info.plist ──────────────────────────────────────────────────────────────
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Anode</string>
  <key>CFBundleDisplayName</key>       <string>Anode</string>
  <key>CFBundleIdentifier</key>        <string>dev.anode.app</string>
  <key>CFBundleExecutable</key>        <string>AnodeApp</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key>           <string>${BUILD}</string>
  <!-- The exact source this bundle was built from, so "which build is that"
       is answerable rather than guessed. -->
  <key>BSSourceCommit</key>            <string>${COMMIT}${DIRTY}</string>
  <!-- And WHERE that source is, which is how the Update button in settings
       finds the checkout to pull. Recorded rather than searched for: hunting
       the disk for something that looks like the right repo is how an updater
       ends up rebuilding a stranger's clone. An app with no such key, or whose
       checkout has since moved, simply says so instead. -->
  <key>BSSourcePath</key>              <string>${SOURCE_PATH}</string>
  <!-- Shown under the version in the About box. GPL §5 asks an interactive
       program to carry its notice where a user can reach it; AppKit takes this
       key for that line and offers no API to set it. -->
  <key>NSHumanReadableCopyright</key>  <string>Copyright 2026 noahahoward. Licensed under the GNU General Public License v3.0 or later.</string>
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
#
# INSIDE OUT, and the order is load-bearing. Signing the app seals everything in
# the bundle, so signing the nested helper afterwards would break that seal and
# the app's own cdhash would no longer describe what is on disk. Fan control
# depends on that hash being right: the helper pins it from the bundle at startup
# and compares it to the caller's, so a broken seal is a fan control that refuses
# every connection with an identity mismatch nobody can explain.
codesign --force --sign - "$APP/Contents/MacOS/$HELPER" 2>/dev/null \
  || echo "  (ad-hoc signing of the fan helper skipped)"
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
if [ -d "$INSTALL_DIR/Anode.app" ]; then
  # Quit a running copy first so the bundle is not swapped under it.
  osascript -e 'tell application "Anode" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf "$INSTALL_DIR/Anode.app"
fi
cp -R "$APP" "$INSTALL_DIR/"

# Remove the build-directory copy once it is installed.
#
# Leaving it there leaves a LAUNCHABLE bundle at the one path whose
# LaunchServices registrations are poisoned, and launching that copy produces an
# app whose menu bar widgets are silently placed off-screen at (-1, 1157) while
# every health check reports them present. That has now happened twice, both
# times because something ran `open Anode.app` from the repo out of habit.
#
# The install is the artifact. Deleting the intermediate makes the failure
# unreachable rather than merely documented.
rm -rf "$APP"

echo "› installed: $INSTALL_DIR/Anode.app"
# Printed every build because the pin is per-build: this helper only recognises
# the app it was just built beside, and a helper left running from before this
# build will refuse the new one until it is restarted. Nothing is installed and
# nothing runs as root unless the user runs this line themselves.
echo "›"
echo "› fan control (optional, nothing is installed):"
echo "›   sudo '$INSTALL_DIR/Anode.app/Contents/MacOS/AnodeHelper'"
echo "› to undo everything this project has ever done as root:"
echo "›   sudo '$INSTALL_DIR/Anode.app/Contents/MacOS/AnodeHelper' --uninstall"
echo "› (the build-directory copy is removed on purpose — that path's"
echo "›  LaunchServices state hides the menu bar widgets. See WIDGET-BUG.md.)"

# ── Launch it ───────────────────────────────────────────────────────────────
#
# TWICE, and that is a workaround rather than a nicety.
#
# `AppPresence.showsWindowAtLaunch` is `!(startInMenuBarOnly && widgetsEnabled)`,
# so with both settings on NO launch opens the window — the second `open` is what
# produces one, because it arrives as a REOPEN and takes a different path
# (`applicationShouldHandleReopen`). A developer who quits to pick up a new build
# therefore gets widgets and no window, every time, and learns to build twice.
#
# The real bug is that "start in menu bar only" is a statement about LOGIN and is
# being applied to every launch including a deliberate one. Fixing it needs the
# app to tell those apart, and the obvious signal cannot:
# `NSApplicationLaunchIsDefaultLaunchKey` is true for a manual launch and Apple
# documents it as false only for file/print/Apple-event launches, so a login
# launch reports true as well. Measured here, not assumed.
#
# So this is the dev workflow papering over a product bug, deliberately and in
# one place. Skip it with ANODE_NO_LAUNCH=1 — for CI, or for a build made
# while the app is deliberately not running.
if [ "${ANODE_NO_LAUNCH:-0}" != "1" ]; then
    echo "›"
    echo "› launching…"
    open -a "$INSTALL_DIR/Anode.app"
    # Long enough for the first launch to finish registering; a reopen that lands
    # while the app is still starting is swallowed and the window never appears.
    sleep 2
    open -a "$INSTALL_DIR/Anode.app"
fi
