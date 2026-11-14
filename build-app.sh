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
# The marketing version is edited by hand, on EVERY push, by the rule in CLAUDE.md (last number for fixes and
# speed, middle for features, first only for a rewrite), with CHANGELOG.md and UPDATE-NOTE.md. The build number is the commit count,
# so two bundles claiming the same version cannot contain different code. A bug
# report can quote what About says and the answer maps to an exact commit —
# which matters more than usual here, because there is no update mechanism and
# an installed build may be weeks old.
VERSION="1.18.6"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
# Absolute, and resolved through any symlink, because it is written into a
# bundle that will be launched from somewhere else entirely.
SOURCE_PATH="$(cd "$(dirname "$0")" && pwd -P)"
DIRTY=""
if ! git diff --quiet HEAD 2>/dev/null; then DIRTY="+"; fi

echo "› building ($CONFIG)…"
# The Anode helper ships beside the app but is NEVER started by it: it runs as root
# and the user starts it themselves with sudo when they want fan control. It is
# in the bundle so there is one obvious path to type, and so it and the app it
# will only ever talk to are rebuilt together — the helper pins the app's cdhash
# at startup, and an app rebuilt without its helper would simply be refused.
#
# COMPILED FILE BY FILE, not whole-module. SwiftPM's release build is whole-module, which recompiles ALL of
# a module when ONE file changes: 57,000 lines for a one-line fix. Compiling per file in the native build
# backend (`-no-whole-module-optimization`) only redoes what changed. Timed on a 15-core Mac, release,
# AnodeApp: cold 31.8 s -> 17.7 s, one app file changed 17.9 s -> 8.2 s, one PowerKit file 9.3 s -> 3.8 s;
# fewer cores gain more, because files compile in parallel. The cost, measured, is nothing the app can
# show: the sampler's instruction count over 15 samples is the same within noise (0.18 vs 0.19 billion)
# since its time goes into system calls; the .dSYM bundles crash reports are symbolicated from are
# still made. The native backend is deprecated, so if the toolchain does not take this combination (an
# older or a newer SwiftPM) the standard build runs instead and nothing else changes. ANODE_SLOW_BUILD=1
# forces the standard one. The first build after this changes backend compiles everything once.
#
# One product per `swift build`: a repeated --product does not build both, only the last (found by the
# install test: the app was never compiled and the copy below failed).
FAST_FLAGS=(--build-system native -Xswiftc -no-whole-module-optimization)
BUILD_FLAGS=()
if [ "$CONFIG" = "release" ] && [ "${ANODE_SLOW_BUILD:-0}" != "1" ]; then
  if swift build -c "$CONFIG" "${FAST_FLAGS[@]}" --product "$BIN" \
     && swift build -c "$CONFIG" "${FAST_FLAGS[@]}" --product "$HELPER"; then
    BUILD_FLAGS=("${FAST_FLAGS[@]}")
  else
    echo "  (the faster build did not work with this toolchain; building the standard way)"
    swift build -c "$CONFIG" --product "$BIN"
    swift build -c "$CONFIG" --product "$HELPER"
  fi
else
  swift build -c "$CONFIG" --product "$BIN"
  swift build -c "$CONFIG" --product "$HELPER"
fi
BIN_DIR="$(swift build -c "$CONFIG" ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} --show-bin-path)"
BUILT="$BIN_DIR/$BIN"
BUILT_HELPER="$BIN_DIR/$HELPER"

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
#
# actool only comes with full Xcode. The install one-liner is meant to work with
# just the Command Line Tools, where `xcrun --find actool` fails — and the icon
# used to silently become the generic one. So the same two files, compiled once
# by ./make-icon.sh, are committed in Resources/PrebuiltIcon and copied when
# actool is missing. ANODE_NO_ACTOOL=1 forces that path, to test it.
ICON_OK=0
PREBUILT="Resources/PrebuiltIcon"
if [ -d "$ICON" ] && [ "${ANODE_NO_ACTOOL:-0}" != "1" ] && xcrun --find actool >/dev/null 2>&1; then
  echo "› compiling icon…"
  ACTOOL_LOG="$(mktemp)"
  if xcrun actool "$ICON" \
        --compile "$APP/Contents/Resources" \
        --platform macosx \
        --minimum-deployment-target 26.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$APP/Contents/Resources/.icon-partial.plist" \
        --errors --warnings >"$ACTOOL_LOG" 2>&1; then
    ICON_OK=1
    rm -f "$APP/Contents/Resources/.icon-partial.plist"
  else
    echo "  ! actool failed:"
    sed 's/^/    /' "$ACTOOL_LOG"
  fi
  rm -f "$ACTOOL_LOG"
else
  [ "${ANODE_NO_ACTOOL:-0}" = "1" ] || echo "  (actool not found — it comes with full Xcode; using the prebuilt icon)"
fi
if [ "$ICON_OK" != "1" ]; then
  if [ -f "$PREBUILT/AppIcon.icns" ] && [ -f "$PREBUILT/Assets.car" ]; then
    echo "› using prebuilt icon…"
    cp "$PREBUILT/AppIcon.icns" "$PREBUILT/Assets.car" "$APP/Contents/Resources/"
    ICON_OK=1
  else
    echo "  ! no compiled icon and no $PREBUILT — bundle will use the default icon"
  fi
fi

# ── Documentation ───────────────────────────────────────────────────────────
# The Help menu opens these. It looks in Contents/Resources first and falls back
# to walking up to the source checkout, so a `swift build` binary finds them
# either way — but an INSTALLED bundle has no checkout above it, and without
# these two lines the shipped app would have no Help menu at all. That is the
# build that actually gets run.
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
  || echo "  (ad-hoc signing of the Anode helper skipped)"

# The APP is signed with the local identity when one exists, and ad-hoc when not.
#
# An ad-hoc signature is a hash of the code, so every rebuild looks like a
# different program to macOS and its privacy permissions (Screen Recording, for
# the menu bar backdrop) are silently forgotten — measured: cdhash cc285c4f was
# allowed, the next build's ec28de2c was not. The identity made by
# ./make-signing-identity.sh gives the app a designated requirement that names a
# certificate instead — `identifier "dev.anode.app" and certificate leaf = H"…"` —
# which does not change between builds.
#
# This trades some safety for convenience, stated in make-signing-identity.sh: the
# identity can be used by any program running as this user to pass itself off as
# Anode. Anode's own permissions stay narrow because of what it is allowed to do.
#
# Only the app, not the helper: the helper's trust is a pin on the APP's cdhash
# (see FanLink), unaffected by which kind of signature produces it, and leaving it
# alone leaves fan control exactly as it was.
#
# Absent keychain, or ANODE_ADHOC=1 (make-release.sh sets it, because a release
# bundle is described as ad-hoc and must be), means the old behaviour exactly.
SIGN_KEYCHAIN="$HOME/Library/Keychains/anode-signing.keychain-db"
SIGN_NAME="Anode Local Signing"
SIGNED_LOCAL=0

# The identity is made here, on the first build on a machine, rather than left to be asked for.
#
# Left optional it was never made on the machines that needed it: a Mac that built from
# source with install.sh or the in-app updater signed ad-hoc, every update was a new
# signature, and macOS kept ignoring the approvals while System Settings showed them on.
# Accessibility and Screen Recording read as refused with the switch lit, update after
# update (measured on a MacBook Neo). The trade-off is the one stated in
# make-signing-identity.sh. `./make-signing-identity.sh --remove` declines it for good (it
# leaves a marker this checks); a failure to make it is not a failure to build.
OPTOUT="$HOME/Library/Application Support/Anode/no-signing-identity"
if [ "${ANODE_ADHOC:-0}" != "1" ] && [ ! -f "$SIGN_KEYCHAIN" ] && [ ! -f "$OPTOUT" ]; then
  echo "  (making a local signing identity so macOS permissions survive updates;"
  echo "   ./make-signing-identity.sh --remove undoes it and stops builds making it)"
  if ! MADE="$(./make-signing-identity.sh 2>&1)"; then
    echo "  (could not make it; signing ad-hoc. $(printf '%s' "$MADE" | tail -1))"
  fi
fi
if [ "${ANODE_ADHOC:-0}" != "1" ] && [ -f "$SIGN_KEYCHAIN" ] \
   && security unlock-keychain -p "anode-local-signing" "$SIGN_KEYCHAIN" 2>/dev/null \
   && security find-identity -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -q "$SIGN_NAME"; then
  if codesign --force --keychain "$SIGN_KEYCHAIN" --sign "$SIGN_NAME" "$APP" 2>/dev/null; then
    SIGNED_LOCAL=1
    echo "  (signed with the local identity; permissions survive rebuilds)"
  else
    echo "  (local signing failed; falling back to ad-hoc)"
  fi
fi
if [ "$SIGNED_LOCAL" != "1" ]; then
  codesign --force --sign - "$APP" 2>/dev/null || echo "  (ad-hoc signing skipped)"
fi

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
  # Quit a running copy first so the bundle is not swapped under it. By its identifier, not its name: the name can
  # reach another registered copy of Anode.app, or start one. Then it is given a few seconds to be gone: quitting puts
  # macOS's own charge settings back and waits for the helper, and `rm` must not take the bundle from under that.
  osascript -e 'if application id "dev.anode.app" is running then tell application id "dev.anode.app" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$INSTALL_DIR/Anode.app/Contents/MacOS/AnodeApp" >/dev/null 2>&1 || break
    sleep 0.5
  done
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

    # The copy that is RUNNING must be the copy just installed. Seen 2026-11-11: a copy started from the old files while they
    # were being swapped kept running, so the disk said the new build while the process was the old one, and the Anode helper
    # refused it ("caller has no readable code signature": the code on disk did not match what was running). Checking the
    # build commit on disk cannot see that; asking the system whether the process still matches its files can.
    # `|| true` everywhere: under `set -euo pipefail` a pgrep that finds nothing would end the whole install silently.
    RUNNING_OK=0
    for _ in 1 2; do
        PID="$(pgrep -f "$INSTALL_DIR/Anode.app/Contents/MacOS/AnodeApp" | head -1 || true)"
        if [ -z "$PID" ]; then
            open -a "$INSTALL_DIR/Anode.app" || true
            sleep 3
            continue
        fi
        if codesign --verify "$PID" 2>/dev/null; then RUNNING_OK=1; break; fi
        echo "› the running copy is not the one just installed; restarting it"
        osascript -e 'if application id "dev.anode.app" is running then tell application id "dev.anode.app" to quit' >/dev/null 2>&1 || true
        # Wait for it to be gone: `open` on a copy that is still quitting reactivates it, and then nothing is running.
        for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
        kill -0 "$PID" 2>/dev/null && { kill "$PID" 2>/dev/null || true; sleep 1; }
        open -a "$INSTALL_DIR/Anode.app" || true
        sleep 3
    done
    if [ "$RUNNING_OK" != "1" ]; then
        PID="$(pgrep -f "$INSTALL_DIR/Anode.app/Contents/MacOS/AnodeApp" | head -1 || true)"
        if [ -n "$PID" ] && codesign --verify "$PID" 2>/dev/null; then RUNNING_OK=1; fi
    fi
    if [ "$RUNNING_OK" != "1" ]; then
        echo "› WARNING: could not confirm that the running Anode is the copy just installed."
        echo "›   Quit Anode and open it again from $INSTALL_DIR."
    fi
fi
