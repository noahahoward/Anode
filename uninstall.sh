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
#   * It never deletes your source checkout. You may have work in it, and an
#     uninstaller that removes a git repository is a story people tell for years.
#     The path is printed instead.
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
)
if [ "$REMOVE_DATA" = "1" ]; then
  CANDIDATES+=(
    "$SUPPORT/history.sqlite"
    "$SUPPORT/history.sqlite-wal"
    "$SUPPORT/history.sqlite-shm"
    "$SUPPORT/discharge-trend.json"
  )
fi

FOUND=()
for path in "${CANDIDATES[@]}"; do
  [ -e "$path" ] && FOUND+=("$path")
done

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
  echo "   com.anode.settings"
  echo "   com.betterstats.settings"
else
  echo
  echo " Your measurement history and settings are KEPT."
  echo " Re-run with --data to remove those too."
fi
echo
echo " Your source checkout is NOT touched."
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

if [ "$REMOVE_DATA" = "1" ]; then
  for domain in com.anode.settings com.betterstats.settings; do
    defaults delete "$domain" >/dev/null 2>&1 && echo "removed  settings: $domain" || true
  done
  # Only if empty — the directory may hold something a future version put there.
  rmdir "$SUPPORT" >/dev/null 2>&1 && echo "removed  $SUPPORT" || true
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
echo "  Your source checkout was left alone. Delete it yourself if you want it gone."
