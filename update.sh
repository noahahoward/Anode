#!/bin/bash
# Pull the latest source and rebuild Anode.
#
#   ./update.sh
#
# Also what the Update button in Anode's settings runs — in a visible Terminal
# window, deliberately. Rebuilding replaces the running app, and an app that
# quietly replaces itself while you are looking at it is a worse thing to ship
# than one extra window. The same reasoning as the fan helper's install: if the
# app is going to run a command on your behalf, you get to watch it.
set -euo pipefail

# The checkout to update. Defaults to this script's own directory, which is the
# right answer when it is run from the repo — and is the WRONG answer for the
# copy that ships inside Anode.app, which is why it can be overridden.
#
# That copy exists because of a real failure: the settings button used to run
# the script out of the checkout, so moving the checkout to any commit from
# before the updater existed took the updater with it. `git reset --hard HEAD~1`
# and the Update button reports itself missing. A tool that repairs a thing
# cannot live inside the thing it repairs.
REPO="${1:-$(cd "$(dirname "$0")" && pwd -P)}"
cd "$REPO" 

say() { printf '› %s\n' "$1"; }

command -v git >/dev/null 2>&1 || { echo "✗ git is not installed." >&2; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "✗ $(pwd) is not a git checkout — nothing to pull." >&2; exit 1; }

BEFORE="$(git rev-parse --short HEAD)"

# --ff-only: never rewrite, never merge, never touch uncommitted work. If someone
# has been editing their checkout this refuses, which is the right answer — the
# alternative is an update button that silently stashes a stranger's changes.
say "fetching…"
git fetch --quiet
if ! git pull --ff-only --quiet; then
  cat >&2 <<'EOF'
✗ Could not fast-forward. The checkout has local commits or uncommitted
  changes, so pulling would have to merge or discard them, and neither is
  something an update button should decide for you.

  Have a look with:  git status
EOF
  exit 1
fi

AFTER="$(git rev-parse --short HEAD)"
if [ "$BEFORE" = "$AFTER" ]; then
  say "already up to date ($AFTER) — rebuilding anyway so the bundle matches."
else
  say "updated $BEFORE → $AFTER:"
  git --no-pager log --oneline "$BEFORE..$AFTER" | sed 's/^/›   /'
fi

# build-app.sh quits a running copy, installs to ~/Applications and relaunches.
./build-app.sh

echo
echo "✓ Anode is now at $(git rev-parse --short HEAD)."

# ── Close the window, on SUCCESS only ───────────────────────────────────────
#
# Terminal's default profile is "Don't close the window when the shell exits",
# so a clean run otherwise leaves a finished window sitting there. Only on
# success: a failure has to stay on screen, because being able to read what went
# wrong is the entire reason this runs where you can see it.
#
# Apple events are used here and NOT for opening the window, and the asymmetry is
# deliberate. A silently denied event on the way IN would break the feature with
# no way to tell; denied on the way OUT it does nothing, and "nothing" is the
# behaviour we already had. So this is allowed to fail and says nothing when it
# does.
#
# It closes the window running THIS script, matched on the tty, rather than the
# frontmost one — closing whatever happened to be in front is how a tool eats
# someone's other work. Backgrounded with a delay so the shell has exited by the
# time it lands, or Terminal asks whether to terminate a running process.
#
# ANODE_KEEP_TERMINAL=1 to keep it open.
if [ "${ANODE_KEEP_TERMINAL:-0}" != "1" ] && [ -t 1 ]; then
  MY_TTY="$(tty 2>/dev/null || true)"
  if [ -n "$MY_TTY" ]; then
    (
      sleep 1
      osascript >/dev/null 2>&1 <<APPLESCRIPT || true
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "$MY_TTY" then
                close w saving no
              end if
            end repeat
          end repeat
        end tell
APPLESCRIPT
    ) &
  fi
fi
