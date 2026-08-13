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
  say "updating $SRC…"
  # --ff-only, so a checkout someone has been editing is never clobbered. If it
  # refuses, that is the correct outcome and the message says what to do.
  git -C "$SRC" fetch --quiet
  git -C "$SRC" pull --ff-only --quiet || die \
"Could not fast-forward $SRC — it has local commits or changes.
Sort it out there, or set ANODE_SRC to a different directory and re-run."
else
  [ -e "$SRC" ] && die "$SRC exists and is not a git checkout. Move it, or set ANODE_SRC."
  say "cloning into $SRC…"
  mkdir -p "$(dirname "$SRC")"
  git clone --quiet "$REPO" "$SRC"
fi

# ── Build ───────────────────────────────────────────────────────────────────
say "building — the first one takes a few minutes…"
cd "$SRC"
./build-app.sh

cat <<EOF

✓ Installed: ~/Applications/Anode.app
  Source:    $SRC

  To update later, either press Update in Anode's settings, or run:
      $SRC/update.sh
EOF
