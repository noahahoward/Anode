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
cd "$(dirname "$0")"

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
