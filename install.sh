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
#   2. clones (or updates) the repo into ~/Developer/Anode
#   3. runs ./build-app.sh, which installs to ~/Applications/Anode.app
#
# IF THE BUILD FAILS it prints the compiler errors (not the hundreds of warnings), the macOS and
# Swift versions to send with them, and where the full log is (~/Library/Logs/Anode-install.log).
# A copy of the source that THIS run cloned is then removed, so a failed first install leaves
# nothing behind; a checkout that was already there is never touched.
#
# Nothing runs as root. Nothing is installed outside your home directory. Fan
# control — the one privileged feature — is not touched here and stays off until
# you ask for it inside the app.
set -euo pipefail

REPO="${ANODE_REPO:-https://github.com/noahahoward/Anode.git}"
SRC="${ANODE_SRC:-$HOME/Developer/Anode}"

say()  { printf '› %s\n' "$1"; }
die()  { printf '\n✗ %s\n' "$1" >&2; exit 1; }

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
  git clone --quiet "$REPO" "$SRC"
  # Remembered so a failed build can take away what this run made, and only that.
  FRESH_CLONE=1
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
    # Only a copy this run made, and only when it is where git says a checkout is.
    if [ "${FRESH_CLONE:-0}" = 1 ] && [ -d "$SRC/.git" ] && [ "$SRC" != "$HOME" ] && [ "$SRC" != "/" ]; then
      cd "$HOME" && rm -rf "$SRC"
      echo "  Nothing was installed, and the source this run downloaded ($SRC) was removed."
      echo "  Running the installer again starts from the beginning."
    else
      echo "  Nothing was installed. The source in $SRC was there before and is left as it was."
    fi
  } >&2
  exit 1
fi

cat <<EOF

✓ Installed: ~/Applications/Anode.app
  Source:    $SRC

  To update later, either press Update in Anode's settings, or run:
      $SRC/update.sh
EOF
