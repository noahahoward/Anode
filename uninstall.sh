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
# The record of macOS's own charge settings every account's Anode shares (it is the Mac's, not this account's).
# ANODE_SHARED_CHARGE_DIR is for the tests, which must not touch the real one.
SHARED_DIR="${ANODE_SHARED_CHARGE_DIR:-/Users/Shared/Anode}"
SHARED_RECORD="$SHARED_DIR/charge-control.json"
DAEMON_LABEL="dev.anode.app.fanhelper"
# Where the helper's launchd job lives. ANODE_LAUNCH_DAEMONS_DIR is for the tests, which must not read the real one.
LAUNCH_DAEMONS_DIR="${ANODE_LAUNCH_DAEMONS_DIR:-/Library/LaunchDaemons}"
# The first version of the app that takes --restore-charge-settings. An older app would start its whole interface
# instead and this script would wait on it.
RESTORE_ARGUMENT_SINCE="1.17.0"
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
  echo
  echo " …and the record of macOS's own charge settings that every account's Anode shares, $SHARED_RECORD,"
  echo " but only if it holds no record: while an Anode holds a charge limit it is what puts macOS back."
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

# Quitting Anode puts macOS's own charge settings back, but an Anode that crashed or was killed never got to, and
# macOS keeps a limit it was given after the app that set it is gone. So before the app and its settings go, the app
# is run once more to put back what macOS had (no window; it exits 0 when nothing of Charge Control's is left, 2 when
# the limit in force is another account's running Anode's, which is left alone and said, and 1 when something may
# be left). After the quit, so the running copy cannot set its limit again, once it has finished quitting. Only this
# user's copy is waited for: an Anode another account is running from /Applications is not this one's to wait on.
# ANODE_NO_LAUNCH=1 skips it.
#
# An Anode that is still running after the wait stops the uninstall, with nothing removed: the restore would clear the
# record while the live app held its limit and set it again, and that limit would outlive the deleted app, with nothing
# left that could put it back.
#
# An installed app older than the one that knows the argument is not run: it would start its whole interface, and this
# script would wait on it. Such a version has no Charge Control, so there is nothing of it to put back; the line says
# what was skipped.
version_at_least() {  # version_at_least FOUND NEEDED: both MAJOR.MINOR.PATCH, compared number by number
  local IFS=. i x y
  local -a found=($1) needed=($2)
  for i in 0 1 2; do
    x="${found[$i]:-0}"; y="${needed[$i]:-0}"
    case "$x$y" in *[!0-9]*) return 1 ;; esac
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
  done
  return 0
}
for app in "$HOME/Applications/Anode.app" "/Applications/Anode.app"; do
  bin="$app/Contents/MacOS/AnodeApp"
  { [ -x "$bin" ] && [ "${ANODE_NO_LAUNCH:-0}" != "1" ]; } || continue
  for _ in 1 2 3 4 5; do pgrep -U "$(id -u)" -f "$bin" >/dev/null || break; sleep 1; done
  if pgrep -U "$(id -u)" -f "$bin" >/dev/null; then
    echo "Anode is still running, so nothing was removed: while it runs it holds its charge limit, and that would" \
      "outlive the deleted app. Quit Anode and run this again." >&2
    exit 1
  fi
  # PlistBuddy on a file that is not there prints a sentence of its own instead of failing quietly, so the file is
  # checked first, and anything that is not a version number is no answer.
  version=""
  if [ -f "$app/Contents/Info.plist" ]; then
    version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist" \
      2>/dev/null || true)"
  fi
  case "$version" in [0-9]*.[0-9]*) ;; *) version="" ;; esac
  if [ -z "$version" ]; then
    echo "Could not tell which version of Anode is installed in $app, so it was not asked to put macOS's own charge" \
      "settings back (an app older than $RESTORE_ARGUMENT_SINCE cannot do it). If macOS holds a charge limit you did" \
      "not choose, change it in System Settings → Battery."
    break
  fi
  if ! version_at_least "$version" "$RESTORE_ARGUMENT_SINCE"; then
    echo "The installed Anode is version $version, older than $RESTORE_ARGUMENT_SINCE, the first that can put macOS's" \
      "own charge settings back, so that step was skipped. If macOS holds a charge limit you did not choose, change" \
      "it in System Settings → Battery."
    break
  fi
  restore_status=0
  "$bin" --restore-charge-settings >/dev/null 2>&1 || restore_status=$?
  case "$restore_status" in
    0) ;;
    2)
      echo "Another account's Anode is holding macOS's charge limit, so it was left in force: that Anode puts it back" \
        "when it quits. If that account no longer uses Anode, change the limit in System Settings → Battery."
      ;;
    *)
      echo "Anode could not put back macOS's own charge settings, so macOS may still hold a charge limit: change it" \
        "in System Settings → Battery. If the battery is not charging on the charger, Anode's helper reconnects it: run" \
        "'sudo /Library/PrivilegedHelperTools/$DAEMON_LABEL --uninstall' if that helper is installed (it reconnects" \
        "the charger, then removes itself), or install Anode again and start its helper from the Fans tab."
      ;;
  esac
  break
done

# The shared record goes with --data only when it holds no record: the restore above empties it when this Anode was
# the last to hold the limit (or nothing ever recorded). A record that is still there is what another account's Anode
# needs to put macOS back, or what a restore that failed leaves for the next launch.
if [ "$REMOVE_DATA" = "1" ] && [ -e "$SHARED_RECORD" ]; then
  if [ ! -s "$SHARED_RECORD" ]; then
    if rm -f "$SHARED_RECORD" 2>/dev/null; then echo "removed  $SHARED_RECORD"; fi
    rmdir "$SHARED_DIR" 2>/dev/null || true
  else
    echo "kept     $SHARED_RECORD: it still holds a record of macOS's own charge settings, which another account's" \
      "Anode (or a later Anode) needs to put them back."
  fi
fi

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
if [ -e "$LAUNCH_DAEMONS_DIR/$DAEMON_LABEL.plist" ]; then
  # The helper's own uninstall, not its files deleted by hand: a discharge may have left the charger switched off,
  # and the helper reconnects it before it removes itself (deleting it would leave the charger cut for good).
  cat <<EOF
The fan helper is still installed and runs as ROOT. It cannot be removed from
here without a password. To remove it, run:

  sudo /Library/PrivilegedHelperTools/$DAEMON_LABEL --uninstall

It reconnects the charger if Anode had switched it off, then removes itself.

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
