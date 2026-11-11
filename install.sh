#!/bin/bash
# Install Anode from source.
#
#   curl -fsSL https://raw.githubusercontent.com/noahahoward/Anode/main/install.sh | bash
#
# ── WHY THERE IS NO DOWNLOAD BUTTON ─────────────────────────────────────────
#
# Anode is ad-hoc signed and not notarised, because notarisation needs an Apple
# Developer ID and this is an unfunded hobby project. Measured on the shipped
# bundle:
#
#   codesign -dvv  →  Signature=adhoc, TeamIdentifier=not set
#   spctl --assess →  rejected
#
# A .app that arrives through a browser gets the quarantine attribute, and that
# rejection then stops it opening. The usual advice is to strip quarantine with
# `xattr -dr`, and for THIS app that is a genuinely bad trade: it is deliberately
# unsandboxed and enumerates every process on the machine, which is exactly the
# situation Gatekeeper exists for. Asking a stranger to disable it would be
# teaching the habit that gets people owned.
#
# Nothing this script fetches passes through a browser, so nothing is
# quarantined, so there is no check to disable. The app is built on your machine
# from source you can read.
#
# ── WHAT IT DOES ────────────────────────────────────────────────────────────
#
#   1. checks for git and a Swift toolchain, and stops with instructions if not
#   2. clones (or updates) the repo into ~/.anode/source
#   3. runs ./build-app.sh, which installs to ~/Applications/Anode.app
#
# WHERE THE SOURCE GOES. Not ~/Developer: that is a developer's folder, and most Macs this is
# installed on have no developer using them. A hidden folder of its own, named in the README and
# known to uninstall.sh. A checkout an earlier version of this script made in ~/Developer/Anode is
# found and updated where it is, never cloned a second time; ANODE_SRC puts it anywhere else.
#
# IF IT FAILS, for any reason, everything THIS run made is taken away again: the source it
# cloned, the folder it made for it, an app it installed, a signing keychain it created. What was
# there before is never touched. The compiler errors are printed (not the hundreds of warnings)
# with the macOS and Swift versions to send with them, and the full build log is kept at
# ~/Library/Logs/Anode-install.log, which is the one thing left, because it is the diagnosis.
#
# Nothing runs as root. Nothing is installed outside your home directory. Fan
# control — the one privileged feature — is not touched here and stays off until
# you ask for it inside the app.
set -euo pipefail

REPO="${ANODE_REPO:-https://github.com/noahahoward/Anode.git}"
NEW_SRC="$HOME/.anode/source"
LEGACY_SRC="$HOME/Developer/Anode"
if [ -n "${ANODE_SRC:-}" ]; then
  SRC="$ANODE_SRC"
elif [ -d "$LEGACY_SRC/.git" ] && [ ! -d "$NEW_SRC/.git" ]; then
  SRC="$LEGACY_SRC"
else
  SRC="$NEW_SRC"
fi

say()  { printf '› %s\n' "$1"; }
die()  { printf '\n✗ %s\n' "$1" >&2; exit 1; }

# ── What this run makes, so a failed run can take exactly that away ────────
# Read BEFORE anything is touched: "was it there already?" is the whole difference between a thing
# this run made (and may remove) and a thing that was the user's.
KEYCHAIN="$HOME/Library/Keychains/anode-signing.keychain-db"
APP="$HOME/Applications/Anode.app"
HAD_SRC_PARENT=0; [ -d "$(dirname "$SRC")" ] && HAD_SRC_PARENT=1
HAD_APPS_DIR=0;   [ -d "$HOME/Applications" ] && HAD_APPS_DIR=1
HAD_APP=0;        [ -e "$APP" ] && HAD_APP=1
HAD_KEYCHAIN=0;   [ -e "$KEYCHAIN" ] && HAD_KEYCHAIN=1
FRESH_CLONE=0
INSTALLED_OK=0
UNDONE=0

undo() {
  [ "$UNDONE" = 1 ] && return 0
  UNDONE=1
  cd "$HOME" 2>/dev/null || true
  local lines=()
  # The source, only if this run cloned it, and never the home folder or the root.
  if [ "$FRESH_CLONE" = 1 ] && [ -n "$SRC" ] && [ "$SRC" != "$HOME" ] && [ "$SRC" != "/" ] && [ -e "$SRC" ]; then
    rm -rf "$SRC"; lines+=("removed $SRC")
  fi
  # The folder made to hold it, if it is empty now (rmdir refuses otherwise).
  if [ "$HAD_SRC_PARENT" = 0 ] && rmdir "$(dirname "$SRC")" 2>/dev/null; then
    lines+=("removed $(dirname "$SRC")")
  fi
  if [ "$HAD_APP" = 0 ] && [ -e "$APP" ]; then
    rm -rf "$APP"; lines+=("removed $APP")
  fi
  if [ "$HAD_APPS_DIR" = 0 ] && rmdir "$HOME/Applications" 2>/dev/null; then
    lines+=("removed $HOME/Applications")
  fi
  if [ "$HAD_KEYCHAIN" = 0 ] && [ -e "$KEYCHAIN" ]; then
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || rm -f "$KEYCHAIN"
    lines+=("removed the signing keychain this run made")
  fi
  # Said only when there was something to say: a run that failed before it made anything has nothing to undo.
  if [ ${#lines[@]} -gt 0 ]; then
    echo >&2; echo "Undoing what this run did:" >&2
    printf '  %s\n' "${lines[@]}" >&2
  fi
  return 0
}
trap '[ "$INSTALLED_OK" = 1 ] || undo' EXIT

# ── Prerequisites ───────────────────────────────────────────────────────────
command -v git >/dev/null 2>&1 || die \
"git is not installed. Run this, then try again:

    xcode-select --install"

# `swift build` needs a toolchain. The Command Line Tools carry one; a full Xcode
# also does. Checking for the compiler rather than for Xcode.app means a machine
# with only the CLT installed is correctly treated as ready.
command -v swift >/dev/null 2>&1 || die \
"No Swift toolchain found. Install Apple's command line tools, then try again:

    xcode-select --install"

case "$(uname -m)" in
  arm64) ;;
  *) say "warning: this is built for Apple Silicon; on $(uname -m) expect missing readings." ;;
esac

# ── Source ──────────────────────────────────────────────────────────────────
if [ -d "$SRC/.git" ]; then
  say "updating ${SRC}…"
  # --ff-only, so a checkout someone has been editing is never clobbered. If it
  # refuses, that is the correct outcome and the message says what to do.
  git -C "$SRC" fetch --quiet
  git -C "$SRC" pull --ff-only --quiet || die \
"Could not fast-forward $SRC — it has local commits or changes.
Sort it out there, or set ANODE_SRC to a different directory and re-run."
else
  [ -e "$SRC" ] && die "$SRC exists and is not a git checkout. Move it, or set ANODE_SRC."
  say "cloning into ${SRC}…"
  mkdir -p "$(dirname "$SRC")"
  # Set BEFORE the clone: a clone that dies half way leaves a folder, and it is this run's (the test
  # above refused to go on if one was already there).
  FRESH_CLONE=1
  git clone --quiet "$REPO" "$SRC"
fi

# ── Build ───────────────────────────────────────────────────────────────────
LOG="$HOME/Library/Logs/Anode-install.log"
mkdir -p "$(dirname "$LOG")"
# "swift-driver version: 1.168 Apple Swift version 6.4.2 (…)" on one line: keep the compiler's half.
SWIFT_LINE="$(swift --version 2>&1 | head -1 | sed 's/^.*\(Apple Swift version\)/\1/')"
ENV_LINE="macOS $(sw_vers -productVersion 2>/dev/null || echo '?') ($(uname -m)), $SWIFT_LINE"
say "$ENV_LINE"
say "building — the first one takes a few minutes…"
cd "$SRC"
{ echo "$ENV_LINE"; echo "source $(git rev-parse --short HEAD 2>/dev/null || echo '?')"; echo; } > "$LOG"

# Everything goes to the log; the terminal gets the stage lines and any compiler error, not a few
# hundred warnings that bury the one line that matters. Colour codes are taken out of what is shown.
UNCOLOUR=$'s/\033\\[[0-9;]*m//g'
ERRORS_ONLY='\.swift:[0-9]+:[0-9]+: error:'
set +e
./build-app.sh 2>&1 | tee -a "$LOG" | sed "$UNCOLOUR" | { grep -E "^(›|  \\()|$ERRORS_ONLY" || true; }
BUILD_STATUS=${PIPESTATUS[0]}
set -e

if [ "$BUILD_STATUS" -ne 0 ]; then
  {
    echo
    echo "✗ the build failed."
    echo "  $ENV_LINE"
    echo
    # The compiler's own error lines, once each and without the checkout's path; with none (not a
    # compile error), the end of the log.
    if sed "$UNCOLOUR" "$LOG" | grep -qE "$ERRORS_ONLY"; then
      sed "$UNCOLOUR" "$LOG" | grep -E "$ERRORS_ONLY" | sed "s#$SRC/##" | awk '!seen[$0]++' | head -8 | sed 's/^/  /'
    else
      sed "$UNCOLOUR" "$LOG" | tail -15 | sed 's/^/  /'
    fi
    echo
    echo "  Send those lines and the line above. Everything the build printed: $LOG"
  } >&2
  undo
  exit 1
fi

INSTALLED_OK=1
cat <<EOF

✓ Installed: ~/Applications/Anode.app
  Source:    $SRC

  To update later, either press Update in Anode's settings, or run:
      $SRC/update.sh
EOF
