#!/bin/bash
# Remove Anode from this machine.
#
#   ./uninstall.sh            the app, login agents and the scripts it wrote
#   ./uninstall.sh --data     …and the measurement history and settings
#   ./uninstall.sh --yes      skip the confirmation (the app passes this, having
#                             already shown the same list in a dialog)
#
# Also what the Uninstall button in Anode's settings runs, in a visible Terminal.
#
# ── WHAT IT WILL NOT DO ─────────────────────────────────────────────────────
#
#   * It never deletes a source checkout you made yourself. You may have work in
#     it, and an uninstaller that removes a git repository is a story people tell
#     for years. The ONE exception is the clone install.sh makes (~/.anode/source, or
#     ~/Developer/Anode where an earlier version put it) — and even that only when git says it has no uncommitted, stashed or
#     unpushed work. Otherwise it is left and the reason is printed.
#   * It never runs sudo. The fan helper is a root daemon and removing it needs a
#     password; this project's rule is that anything needing root is a command
#     you read and type yourself, so it prints that command at the end.
#   * It keeps your history and settings unless you ask for --data. A reinstall
#     that silently lost a month of measurements would be its own bug report.
set -euo pipefail

REMOVE_DATA=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --data) REMOVE_DATA=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

SUPPORT="$HOME/Library/Application Support/Anode"
DAEMON_LABEL="dev.anode.app.fanhelper"
# Where install.sh clones to: ~/.anode/source, or ~/Developer/Anode where an earlier version put it.
# A checkout anywhere else is never touched.
INSTALLED_SRC="$HOME/.anode/source"
if [ ! -d "$INSTALLED_SRC/.git" ] && [ -d "$HOME/Developer/Anode/.git" ]; then
  INSTALLED_SRC="$HOME/Developer/Anode"
fi
# Settings domains: the named suite, the one before the rename, and the bundle
# identifiers (now and before the rename) — the last is where the app's window
# frame and menu bar widgets live. Kept in step with Uninstall.defaultsDomainNames.
# macOS's per-user cache and temp folders (under /var/folders). Each ends in a
# slash. Empty if getconf cannot say, which turns the entries below into nothing.
USER_CACHE_DIR="$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null || true)"
USER_TEMP_DIR="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
DOMAINS=(com.anode.settings com.betterstats.settings dev.anode.app dev.noah.anode)

# Candidates, existence-checked below. Quoted throughout: every one of these
# contains a space on a normal Mac.
CANDIDATES=(
  "$HOME/Applications/Anode.app"
  "/Applications/Anode.app"
  "$HOME/Library/LaunchAgents/dev.anode.app.loginagent.plist"
  "$HOME/Library/LaunchAgents/dev.noah.anode.loginagent.plist"
  "$HOME/Library/LaunchAgents/dev.noah.betterstats.loginagent.plist"
  "$SUPPORT/update.command"
  "$SUPPORT/start-fan-helper.command"
  "$SUPPORT/uninstall.command"
  # What macOS keeps for the bundle identifier. Not data, so it always goes.
  # Kept in step with Uninstall.systemFileLocations.
  "$HOME/Library/Caches/dev.anode.app"
  "$HOME/Library/HTTPStorages/dev.anode.app"
  "$HOME/Library/HTTPStorages/dev.anode.app.binarycookies"
  "$HOME/Library/WebKit/dev.anode.app"
  "$HOME/Library/Saved Application State/dev.anode.app.savedState"
  "$HOME/Library/Logs/dev.anode.app"
  # The signing identity build-app.sh makes so permissions survive updates. A credential this app
  # created and only it uses, so it goes with the app. Kept in step with Uninstall.systemFileLocations.
  "$HOME/Library/Keychains/anode-signing.keychain-db"
  # The install log, which is the diagnosis of a failed install and is not worth keeping after a good one.
  "$HOME/Library/Logs/Anode-install.log"
)
# The cache folder macOS keeps for the app, under its old identifiers too.
# Kept in step with Uninstall.userCacheFolders.
if [ -n "$USER_CACHE_DIR" ]; then
  for id in dev.anode.app dev.noah.anode dev.noah.betterstats; do
    CANDIDATES+=("${USER_CACHE_DIR}${id}")
  done
fi
if [ "$REMOVE_DATA" = "1" ]; then
  CANDIDATES+=(
    "$SUPPORT/history.sqlite"
    "$SUPPORT/history.sqlite-wal"
    "$SUPPORT/history.sqlite-shm"
    "$SUPPORT/discharge-trend.json"
    "$SUPPORT/lifetime-drain.json"
    "$SUPPORT/dock-previews.log"
    "$SUPPORT/update.log"
    "$SUPPORT/widget-squeeze.log"
    "$SUPPORT/window-stranding.log"
    # The folder itself, last, with whatever else a version of the app put in it.
    "$SUPPORT"
  )
fi

FOUND=()
for path in "${CANDIDATES[@]}"; do
  [ -e "$path" ] && FOUND+=("$path")
done

# The clone install.sh made, if it is safe to lose. "Safe" is git's answer, not
# ours: nothing uncommitted or untracked, nothing stashed, nothing ahead of the
# upstream. A clone with no upstream to compare against is not provably safe.
KEPT_CHECKOUT=""
if [ -d "$INSTALLED_SRC/.git" ]; then
  if [ -n "$(git -C "$INSTALLED_SRC" status --porcelain 2>/dev/null || echo unknown)" ]; then
    KEPT_CHECKOUT="has uncommitted or untracked changes"
  elif [ -n "$(git -C "$INSTALLED_SRC" stash list 2>/dev/null)" ]; then
    KEPT_CHECKOUT="has stashed changes"
  elif ! UNPUSHED="$(git -C "$INSTALLED_SRC" rev-list --count '@{u}..HEAD' 2>/dev/null)" \
       || [ "$UNPUSHED" != "0" ]; then
    KEPT_CHECKOUT="has commits that are not on its upstream (or no upstream to check)"
  else
    FOUND+=("$INSTALLED_SRC")
    # `swift build` leaves lock files in the temp folder, named from the clone's
    # path with the slashes turned into underscores. They go with the clone.
    if [ -n "$USER_TEMP_DIR" ]; then
      for lock in "${USER_TEMP_DIR}${INSTALLED_SRC//\//_}_.build"*.lock; do
        [ -e "$lock" ] && FOUND+=("$lock")
      done
    fi
  fi
fi

echo "────────────────────────────────────────────────────────────────────────"
echo " Uninstalling Anode"
echo "────────────────────────────────────────────────────────────────────────"
if [ ${#FOUND[@]} -eq 0 ]; then
  echo " Nothing found to remove."
else
  echo " This will delete:"
  printf '   %s\n' "${FOUND[@]}"
fi
if [ "$REMOVE_DATA" = "1" ]; then
  echo
  echo " …and these preference domains:"
  printf '   %s\n' "${DOMAINS[@]}"
else
  echo
  echo " Your measurement history and settings are KEPT."
  echo " Re-run with --data to remove those too."
fi
echo
if [ -n "$KEPT_CHECKOUT" ]; then
  echo " $INSTALLED_SRC is KEPT: it $KEPT_CHECKOUT."
else
  echo " A source checkout anywhere else is NOT touched."
fi
echo "────────────────────────────────────────────────────────────────────────"

if [ "$ASSUME_YES" != "1" ] && [ ${#FOUND[@]} -gt 0 ]; then
  printf '\nRemove these? [y/N] '
  read -r reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "Nothing was removed."; exit 0 ;;
  esac
fi

# Quit a running copy first, or the bundle is deleted out from under it.
osascript -e 'tell application "Anode" to quit' >/dev/null 2>&1 || true
sleep 1

# Charge Control's limit is macOS's own setting and outlives the app. Before the app and its settings go, the app
# puts back what macOS had (no window; it exits 0 when nothing of Charge Control's is left). After the quit, so the
# running copy cannot set its limit again, once it has finished quitting. Only this user's copy is waited for: an
# Anode another account is running from /Applications is not this one's to wait on. ANODE_NO_LAUNCH=1 skips it.
for app in "$HOME/Applications/Anode.app" "/Applications/Anode.app"; do
  bin="$app/Contents/MacOS/AnodeApp"
  { [ -x "$bin" ] && [ "${ANODE_NO_LAUNCH:-0}" != "1" ]; } || continue
  for _ in 1 2 3 4 5; do pgrep -U "$(id -u)" -f "$bin" >/dev/null || break; sleep 1; done
  if pgrep -U "$(id -u)" -f "$bin" >/dev/null; then
    echo "Anode is still running, so it may set its charge limit again; putting macOS's own back anyway."
  fi
  if ! "$bin" --restore-charge-settings >/dev/null 2>&1; then
    echo "Anode could not put back macOS's own charge settings, so macOS may still hold a charge limit: change it in" \
      "System Settings → Battery. If the battery is not charging on the charger, restarting the Mac or reinstalling" \
      "Anode's helper reconnects it."
  fi
  break
done

for path in "${FOUND[@]:-}"; do
  [ -z "$path" ] && continue
  case "$path" in
    *.plist)
      # Boot the agent out before deleting its plist, or launchd keeps a job
      # describing a file that no longer exists.
      label="$(basename "$path" .plist)"
      launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
      ;;
  esac
  rm -rf "$path"
  echo "removed  $path"
done
# The hidden folder install.sh made to hold the clone, once it is empty. rmdir refuses otherwise.
rmdir "$HOME/.anode" 2>/dev/null && echo "removed  $HOME/.anode" || true

if [ "$REMOVE_DATA" = "1" ]; then
  # Clear the domain first, THEN delete the file. macOS keeps a copy of the
  # settings in memory (cfprefsd) which can write the file straight back, so
  # removing only the .plist is not removal. The app was quit above; deleting
  # while it ran would have it write them again.
  for domain in "${DOMAINS[@]}"; do
    defaults delete "$domain" >/dev/null 2>&1 && echo "removed  settings: $domain" || true
    rm -f "$HOME/Library/Preferences/$domain.plist"
  done
fi

echo
if [ -e "/Library/LaunchDaemons/$DAEMON_LABEL.plist" ]; then
  cat <<EOF
The fan helper is still installed and runs as ROOT. It cannot be removed from
here without a password. To remove it, run:

  sudo launchctl bootout system/$DAEMON_LABEL; sudo rm -f /Library/LaunchDaemons/$DAEMON_LABEL.plist /Library/PrivilegedHelperTools/$DAEMON_LABEL

EOF
fi
echo "✓ Anode has been removed."
echo
if [ -n "$KEPT_CHECKOUT" ]; then
  echo "  $INSTALLED_SRC was left alone because it $KEPT_CHECKOUT."
  echo "  Delete it yourself if you want it gone."
else
  echo "  A source checkout anywhere else was left alone."
fi
