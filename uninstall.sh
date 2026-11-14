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
#   * It keeps your history and settings unless you ask for --data. A reinstall
#     that silently lost a month of measurements would be its own bug report.
#
# ── WHAT IT RUNS WITH sudo, AND WHY ─────────────────────────────────────────
#
#   It used to print the commands for what needs the password and leave them to you, and every uninstall then left a
#   root daemon, a sudoers rule and sometimes a Mac that could not sleep behind. The owner decided that an uninstall
#   removes everything, so it now runs sudo, for exactly this and nothing else, at the very end, after everything the
#   account owns is gone:
#
#     sudo <the helper> --uninstall           the helper reconnects the charger if Anode switched it off, then removes
#                                             its launchd job, its binary and its socket (when only the job is left and
#                                             the binary is gone: sudo launchctl bootout, then sudo rm -f of the job
#                                             and the socket)
#     sudo rm -f <the Always Stay Awake rule> the one sudoers rule Always Stay Awake installs
#     sudo pmset -a disablesleep 0            only when macOS reports SleepDisabled 1 (a crashed Anode can leave the
#                                             Mac unable to sleep)
#
#   They are printed first, with a sentence saying the Terminal asks for the Mac's password once. The password is typed
#   at the Terminal, to sudo: no `sudo -S`, nothing here reads it. Where sudo cannot be used (nothing on stdin to type
#   at, ANODE_NO_SUDO=1, a password that was refused or cancelled) the same commands are printed for you to run, and
#   the rest of the uninstall stands, with the exit status it always had.
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
# Where Anode's settings are READ from, to see whether Charge Control was switched on or left a note (below): a defaults
# domain, or the path of a settings file. ANODE_SETTINGS_DOMAIN is for the tests, which must not read the real one.
SETTINGS_DOMAIN="${ANODE_SETTINGS_DOMAIN:-com.anode.settings}"
DAEMON_LABEL="dev.anode.app.fanhelper"
# The two places an Anode can be installed. ANODE_SYSTEM_APPLICATIONS_DIR is for the tests, which must not look at, or
# delete, the real /Applications.
SYSTEM_APPS_DIR="${ANODE_SYSTEM_APPLICATIONS_DIR:-/Applications}"
APP_COPIES=("$HOME/Applications/Anode.app" "$SYSTEM_APPS_DIR/Anode.app")
# Where the helper's launchd job lives. ANODE_LAUNCH_DAEMONS_DIR is for the tests, which must not read the real one.
LAUNCH_DAEMONS_DIR="${ANODE_LAUNCH_DAEMONS_DIR:-/Library/LaunchDaemons}"
# The rest of what is root's, each with a variable for the tests, which must not read or write the real /Library, /etc
# or /var: the folder the helper's binary is installed in, the folder of the sudoers rule Always Stay Awake installs,
# and the helper's socket. Kept in step with FanDaemon.helperPath, KeepAwakeAuthorisation.path and FanSocket.path.
HELPER_TOOLS_DIR="${ANODE_PRIVILEGED_HELPER_TOOLS_DIR:-/Library/PrivilegedHelperTools}"
SUDOERS_DIR="${ANODE_SUDOERS_DIR:-/etc/sudoers.d}"
FAN_SOCKET="${ANODE_FAN_SOCKET:-/var/run/anode-fan.sock}"
HELPER_PLIST="$LAUNCH_DAEMONS_DIR/$DAEMON_LABEL.plist"
HELPER_BIN="$HELPER_TOOLS_DIR/$DAEMON_LABEL"
KEEP_AWAKE_RULE="$SUDOERS_DIR/anode-keep-awake"
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
# The last four are the domains the app and the `anode` tool write under when they run outside the bundle (AnodeApp, anode),
# and what they were called before the rename (BetterStatsApp, betterstats); each has a file in ~/Library/Preferences.
DOMAINS=(com.anode.settings com.betterstats.settings dev.anode.app dev.noah.anode AnodeApp anode BetterStatsApp betterstats)
# The bundle identifiers Anode has had, newest first. macOS keeps a cache folder, three WebKit folders and the privacy
# approvals (Accessibility and the rest) under each. Kept in step with Uninstall.bundleIdentifiers.
IDENTIFIERS=(dev.anode.app dev.noah.anode dev.noah.betterstats)
# What macOS and its crash reporter keep when Anode crashed or hung: files named for the program, then _ or -, then
# anything, then the extension. The names are exact and case-sensitive, never a bare *anode*: a program whose name only
# contains one of them is not Anode's. Kept in step with Uninstall.crashReportNames and crashReportExtensions.
CRASH_NAMES=(AnodeApp AnodeHelper anode BetterStatsApp betterstats)
CRASH_EXTENSIONS=(ips crash diag spin hang)

# Candidates, existence-checked below. Quoted throughout: every one of these
# contains a space on a normal Mac.
CANDIDATES=(
  "${APP_COPIES[0]}"
  "${APP_COPIES[1]}"
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
# The cache folder macOS keeps for the app, under its old identifiers too, and the three folders WebKit keeps for the
# processes its web views run in (GPU, Networking and WebContent), named from the identifier after a +.
# Kept in step with Uninstall.userCacheFolders.
if [ -n "$USER_CACHE_DIR" ]; then
  for id in "${IDENTIFIERS[@]}"; do
    CANDIDATES+=("${USER_CACHE_DIR}${id}"
                 "${USER_CACHE_DIR}com.apple.WebKit.GPU+${id}"
                 "${USER_CACHE_DIR}com.apple.WebKit.Networking+${id}"
                 "${USER_CACHE_DIR}com.apple.WebKit.WebContent+${id}")
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

# Crash records of Anode's names (see CRASH_NAMES), with --data. macOS keeps a plist for each in Application Support, and
# a report for each in DiagnosticReports and, once it has aged, DiagnosticReports/Retired.
add_crash_records() {  # add_crash_records DIR EXTENSION…: the records in DIR named for Anode's programs
  local dir="$1" name sep ext f; shift
  [ -d "$dir" ] || return 0
  for name in "${CRASH_NAMES[@]}"; do
    for sep in _ -; do
      for ext in "$@"; do
        for f in "$dir/$name$sep"*".$ext"; do
          [ -e "$f" ] && FOUND+=("$f")
        done
      done
    done
  done
  return 0
}
# The settings files the test suite makes (a suite for each test) and never always removes. Many; said as a count.
TEST_SETTINGS=()
if [ "$REMOVE_DATA" = "1" ]; then
  add_crash_records "$HOME/Library/Application Support/CrashReporter" plist
  add_crash_records "$HOME/Library/Logs/DiagnosticReports" "${CRASH_EXTENSIONS[@]}"
  add_crash_records "$HOME/Library/Logs/DiagnosticReports/Retired" "${CRASH_EXTENSIONS[@]}"
  for f in "$HOME/Library/Preferences/com.anode.tests."*.plist; do
    [ -e "$f" ] && TEST_SETTINGS+=("$f")
  done
fi

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

# ── What only root can remove ───────────────────────────────────────────────
# macOS says the Mac cannot sleep. A crashed Anode (Always Stay Awake sets it) can leave it so, and only root can say
# otherwise. Empty or absent reads as not disabled.
# It is Anode's to put back only where Always Stay Awake was ever set up: without its rule in the sudoers folder Anode
# could not have set it, and a Mac told not to sleep by something else is left as it is. Read once, before the rule goes.
KEEP_AWAKE_WAS_SET_UP=0
if [ -e "$KEEP_AWAKE_RULE" ]; then KEEP_AWAKE_WAS_SET_UP=1; fi
sleep_is_disabled() {
  [ "$KEEP_AWAKE_WAS_SET_UP" = "1" ] || return 1
  [ "$(pmset -g 2>/dev/null | awk '$1 == "SleepDisabled" { v = $2 } END { print v }')" = "1" ]
}
# Something root owns is still there, or macOS is still told not to sleep.
root_things_left() {
  [ -e "$HELPER_PLIST" ] || [ -e "$HELPER_BIN" ] || [ -e "$KEEP_AWAKE_RULE" ] || sleep_is_disabled
}
# The commands for what is there now, as they are run (and as they are printed for you to run). The helper's own
# uninstall when its binary is there. When only its launchd job is left, that job is booted out and its files removed.
# %q leaves a path alone unless it holds something a shell would read.
print_root_commands() {
  if [ -e "$HELPER_BIN" ]; then
    printf '  sudo %q --uninstall\n' "$HELPER_BIN"
  elif [ -e "$HELPER_PLIST" ]; then
    printf '  sudo launchctl bootout system/%s\n' "$DAEMON_LABEL"
    printf '  sudo rm -f %q %q\n' "$HELPER_PLIST" "$FAN_SOCKET"
  fi
  if [ -e "$KEEP_AWAKE_RULE" ]; then printf '  sudo rm -f %q\n' "$KEEP_AWAKE_RULE"; fi
  if sleep_is_disabled; then printf '  sudo pmset -a disablesleep 0\n'; fi
}
ROOT_LISTED=()
for path in "$HELPER_PLIST" "$HELPER_BIN" "$KEEP_AWAKE_RULE"; do
  [ -e "$path" ] && ROOT_LISTED+=("$path")
done
if { [ -e "$HELPER_PLIST" ] || [ -e "$HELPER_BIN" ]; } && [ -e "$FAN_SOCKET" ]; then ROOT_LISTED+=("$FAN_SOCKET"); fi
SLEEP_DISABLED=0
if sleep_is_disabled; then SLEEP_DISABLED=1; fi
ROOT_NEEDED=0
if [ ${#ROOT_LISTED[@]} -gt 0 ] || [ "$SLEEP_DISABLED" = "1" ]; then ROOT_NEEDED=1; fi

echo "────────────────────────────────────────────────────────────────────────"
echo " Uninstalling Anode"
echo "────────────────────────────────────────────────────────────────────────"
if [ ${#FOUND[@]} -eq 0 ] && [ "$ROOT_NEEDED" != "1" ]; then
  echo " Nothing found to remove."
elif [ ${#FOUND[@]} -gt 0 ]; then
  echo " This will delete:"
  printf '   %s\n' "${FOUND[@]}"
fi
if [ "$ROOT_NEEDED" = "1" ]; then
  if [ ${#FOUND[@]} -gt 0 ]; then
    echo
    echo " …and these, which are root's, so removing them needs the Mac's password (the Terminal asks once):"
  else
    echo " This will remove these, which are root's, so it needs the Mac's password (the Terminal asks once):"
  fi
  if [ ${#ROOT_LISTED[@]} -gt 0 ]; then printf '   %s\n' "${ROOT_LISTED[@]}"; fi
  if [ "$SLEEP_DISABLED" = "1" ]; then
    echo "   macOS's setting that keeps the Mac from sleeping (SleepDisabled), which Anode may have left on"
  fi
fi
if [ "$REMOVE_DATA" = "1" ]; then
  echo
  echo " …and these preference domains:"
  printf '   %s\n' "${DOMAINS[@]}"
  if [ ${#TEST_SETTINGS[@]} -gt 0 ]; then
    echo
    echo " …and ${#TEST_SETTINGS[@]} settings files made by Anode's tests ($HOME/Library/Preferences/com.anode.tests.*.plist)."
  fi
  echo
  echo " …and the record of macOS's own charge settings that every account's Anode shares, $SHARED_RECORD,"
  echo " but only if it holds no record: while an Anode holds a charge limit it is what puts macOS back."
else
  echo
  echo " Your measurement history and settings are KEPT."
  echo " Re-run with --data to remove those too."
fi
echo
echo " The privacy approvals macOS holds for Anode (Accessibility, Screen Recording and the rest) are reset too."
echo
if [ -n "$KEPT_CHECKOUT" ]; then
  echo " $INSTALLED_SRC is KEPT: it $KEPT_CHECKOUT."
else
  echo " A source checkout anywhere else is NOT touched."
fi
echo "────────────────────────────────────────────────────────────────────────"

if [ "$ASSUME_YES" != "1" ] && { [ ${#FOUND[@]} -gt 0 ] || [ "$ROOT_NEEDED" = "1" ]; }; then
  printf '\nRemove these? [y/N] '
  read -r reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "Nothing was removed."; exit 0 ;;
  esac
fi

# Quit a running copy first, or the bundle is deleted out from under it. By its identifier, not its name: on a Mac
# with another copy of Anode.app registered (a build folder, a backup) the name can reach the wrong one, or start one.
osascript -e 'if application id "dev.anode.app" is running then tell application id "dev.anode.app" to quit' >/dev/null 2>&1 || true
sleep 1

# Quitting Anode puts macOS's own charge settings back, but an Anode that crashed or was killed never got to, and
# macOS keeps a limit it was given after the app that set it is gone. So before the app and its settings go, the app
# is run once more to put back what macOS had (no window; it exits 0 when nothing of Charge Control's is left, 2 when
# the limit in force is another account's running Anode's, which is left alone and said, and 1 when something may
# be left). After the quit, so the running copy cannot set its limit again, once it has finished quitting. Only this
# user's copy is waited for: an Anode another account is running from /Applications is not this one's to wait on.
# ANODE_NO_LAUNCH=1 skips running the app (it is not a reason to skip looking for a running one).
#
# EVERY installed copy is looked at, not only the first: with one in ~/Applications and one in /Applications, a
# running second one would be deleted while it holds its limit. An Anode that is still running after the wait stops
# the uninstall, with nothing removed: the restore would clear the record while the live app held its limit and set it
# again, and that limit would outlive the deleted app, with nothing left that could put it back.
#
# "Running" is conservative: any process of this user whose executable's file name is AnodeApp counts, wherever it
# was started from, and so does such a process of any user when the copy in the system Applications folder is among
# the things to remove (it is every account's). `ps` prints the executable as it was exec'd, so an Anode started
# through a relative path (./AnodeApp) or a symbolic link shows that way and not as the installed path; matching only
# the installed paths would miss it, delete the app under it, and leave its limit in force with nothing to put it
# back. The line names each process as `ps` shows it, which is the installed path where it was started from there.
# The file name is compared as a string, never as a pattern (`pgrep -f` would read a `+`, `(` or `.` in a home folder's
# name as part of the pattern).
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
running_anodes() {  # running_anodes SCOPE: how each running Anode is shown by `ps`, one a line. SCOPE: user | all
  local line cmd
  local -a who=(-U "$(id -u)")
  if [ "$1" = all ]; then who=(-A); fi
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"   # the pid column's leading blanks
    cmd="${line#* }"
    [ "${cmd##*/}" = "AnodeApp" ] && printf '%s\n' "$cmd"
  done < <(ps "${who[@]}" -o pid=,comm= 2>/dev/null || true)
  return 0
}
# Set when no installed copy could put macOS's own settings back: --data then keeps Anode's settings (below).
RESTORE_FAILED=0
# What put_charge_settings_back found for the copy it was given: done (it ran, and the limit is put back or is another
# account's to put back), skipped (not run, and the reason was said), or failed (it ran and something may be left).
RESTORE_RESULT=""
put_charge_settings_back() {  # put_charge_settings_back APP: runs it once; sets RESTORE_RESULT
  local app="$1" bin="$1/Contents/MacOS/AnodeApp" version="" restore_status=0
  RESTORE_RESULT="skipped"
  # PlistBuddy on a file that is not there prints a sentence of its own instead of failing quietly, so the file is
  # checked first, and anything that is not a version number is no answer.
  if [ -f "$app/Contents/Info.plist" ]; then
    version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist" \
      2>/dev/null || true)"
  fi
  case "$version" in [0-9]*.[0-9]*) ;; *) version="" ;; esac
  if [ -z "$version" ]; then
    echo "Could not tell which version of Anode is installed in $app, so it was not asked to put macOS's own charge" \
      "settings back (an app older than $RESTORE_ARGUMENT_SINCE cannot do it). If macOS holds a charge limit you did" \
      "not choose, change it in System Settings → Battery."
    return 0
  fi
  if ! version_at_least "$version" "$RESTORE_ARGUMENT_SINCE"; then
    echo "The installed Anode is version $version, older than $RESTORE_ARGUMENT_SINCE, the first that can put macOS's" \
      "own charge settings back, so that step was skipped for $app. If macOS holds a charge limit you did not choose," \
      "change it in System Settings → Battery."
    return 0
  fi
  "$bin" --restore-charge-settings >/dev/null 2>&1 || restore_status=$?
  case "$restore_status" in
    0) RESTORE_RESULT="done" ;;
    2)
      RESTORE_RESULT="done"
      echo "Another account's Anode is holding macOS's charge limit, so it was left in force: that Anode puts it back" \
        "when it quits. If that account no longer uses Anode, change the limit in System Settings → Battery."
      ;;
    *) RESTORE_RESULT="failed" ;;
  esac
}
say_restore_failed() {
  echo "Anode could not put back macOS's own charge settings, so macOS may still hold a charge limit: change it" \
    "in System Settings → Battery. If the battery is not charging on the charger, Anode's helper reconnects it: run" \
    "'sudo /Library/PrivilegedHelperTools/$DAEMON_LABEL --uninstall' if that helper is installed (it reconnects" \
    "the charger, then removes itself), or install Anode again, switch Charge Control on and press Install Anode Helper…"
}
# Whether Charge Control may have left something that only an Anode can put back: the shared record of macOS's own charge
# settings holds something, or the settings say Charge Control is switched on, or they carry a note that a limit was
# held or the charger cut and not yet put right (anode.chargeRestoreRecord, anode.chargeCutUnconfirmed,
# anode.chargeStartPending). Only `defaults read` is used, and a key that is not there reads as nothing.
charge_control_may_have_left_something() {
  [ -s "$SHARED_RECORD" ] && return 0
  local key value
  for key in chargeControlEnabled chargeCutUnconfirmed chargeStartPending; do
    value="$(defaults read "$SETTINGS_DOMAIN" "anode.$key" 2>/dev/null || true)"
    [ "$value" = "1" ] && return 0
  done
  value="$(defaults read "$SETTINGS_DOMAIN" "anode.chargeRestoreRecord" 2>/dev/null || true)"
  [ -n "$value" ]
}
say_nobody_to_ask() {
  echo "No installed Anode could be asked to put macOS's own charge settings back, and Charge Control may have left" \
    "something. If macOS holds a charge limit you did not choose, change it in System Settings → Battery."
  if [ -e "$LAUNCH_DAEMONS_DIR/$DAEMON_LABEL.plist" ]; then
    echo "If the battery is not charging on the charger, Anode's helper reconnects it: run" \
      "'sudo /Library/PrivilegedHelperTools/$DAEMON_LABEL --uninstall' (it reconnects the charger, then removes itself)."
  fi
}

# Processes of any user count when the system Applications copy is among the things to remove: it is every account's.
SCOPE=user
for path in "${FOUND[@]:-}"; do
  [ "$path" = "${APP_COPIES[1]}" ] && SCOPE=all
done
BINS=()
for app in "${APP_COPIES[@]}"; do
  [ -x "$app/Contents/MacOS/AnodeApp" ] && BINS+=("$app/Contents/MacOS/AnodeApp")
done
RUNNING=""
for _ in 1 2 3 4 5; do
  RUNNING="$(running_anodes "$SCOPE" | sort -u | awk 'NR > 1 { printf ", " } { printf "%s", $0 }')"
  [ -z "$RUNNING" ] && break
  sleep 1
done
if [ -n "$RUNNING" ]; then
  echo "Anode is still running ($RUNNING), so nothing was removed: while it runs it holds its charge limit, and that" \
    "would outlive the deleted app. Quit Anode and run this again." >&2
  exit 1
fi
# Each installed copy is asked in turn until one has put it back: the limit is the Mac's, not a copy's, and a copy that
# cannot be asked (too old, or its version unreadable) or that fails is no reason not to ask the next. When none has,
# the restore failed for what follows (--data keeps the settings), and a failure that ran is said once, at the end.
#
# With no copy that has an executable AnodeApp (a bundle that is broken, or an app dragged to the Trash earlier) nobody
# is asked, and that is said, and counts as a restore not done, when Charge Control may have left something behind
# (charge_control_may_have_left_something). With nothing to suggest it did, nothing is said, as before. That does not
# depend on ANODE_NO_LAUNCH, which only keeps a copy that is there from being run.
if [ "${ANODE_NO_LAUNCH:-0}" != "1" ]; then
  asked=0 restored=0 failed=0
  for bin in "${BINS[@]:-}"; do
    [ -n "$bin" ] || continue
    asked=1
    put_charge_settings_back "${bin%/Contents/MacOS/AnodeApp}"
    case "$RESTORE_RESULT" in
      done) restored=1; break ;;
      failed) failed=1 ;;
    esac
  done
  if [ "$asked" = 1 ] && [ "$restored" != 1 ]; then
    RESTORE_FAILED=1
    [ "$failed" = 1 ] && say_restore_failed
  fi
fi
if [ ${#BINS[@]} -eq 0 ] && charge_control_may_have_left_something; then
  RESTORE_FAILED=1
  say_nobody_to_ask
fi

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

# Anode's privacy approvals (Accessibility and the rest) under each bundle identifier it has had. They stay in macOS's list
# after the app is gone, and the signing keychain is deleted below, so an Anode installed again is signed differently: the
# old approval would show as on and not work. Before the app is deleted, after the checks above that can stop the uninstall.
# A reset that fails says nothing.
reset_privacy_approvals() {
  local id reset=0
  for id in "${IDENTIFIERS[@]}"; do
    if tccutil reset All "$id" >/dev/null 2>&1; then
      echo "reset    privacy approvals: $id"
      reset=1
    fi
  done
  if [ "$reset" = "1" ]; then
    echo "Accessibility, Screen Recording and the other approvals were reset: a reinstalled Anode will ask for them again."
  fi
  return 0
}
reset_privacy_approvals

for path in "${FOUND[@]:-}"; do
  [ -z "$path" ] && continue
  case "$path" in
    "$HOME/Library/LaunchAgents/"*.plist)
      # Boot the agent out before deleting its plist, or launchd keeps a job
      # describing a file that no longer exists. Only a login agent's: a .plist
      # is also what macOS keeps for a crash, and that names no job.
      label="$(basename "$path" .plist)"
      launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
      ;;
  esac
  rm -rf "$path"
  echo "removed  $path"
done
if [ ${#TEST_SETTINGS[@]} -gt 0 ]; then
  # Many (a suite for each test the test suite ran): one rm for all of them would not fit on a command line.
  printf '%s\0' "${TEST_SETTINGS[@]}" | xargs -0 rm -f
  echo "removed  ${#TEST_SETTINGS[@]} settings files made by Anode's tests ($HOME/Library/Preferences/com.anode.tests.*.plist)"
fi
# The hidden folder install.sh made to hold the clone, once it is empty. rmdir refuses otherwise.
rmdir "$HOME/.anode" 2>/dev/null && echo "removed  $HOME/.anode" || true

if [ "$REMOVE_DATA" = "1" ] && [ "$RESTORE_FAILED" = "1" ]; then
  # What remembers that the charger may still be switched off, and what macOS held before Charge Control, is in these
  # settings: a reinstalled Anode reads them to put both right. Deleting them after a restore that failed would lose the
  # reminder with the app that could have used it. (The app and the rest of the data go as asked.)
  echo "kept     Anode's settings: Anode could not put macOS's own charge settings back, and they are what a reinstalled" \
    "Anode would use to put the charger and the limit right. Once those are right, remove them with" \
    "'defaults delete <domain>' for each of: ${DOMAINS[*]}"
elif [ "$REMOVE_DATA" = "1" ]; then
  # Clear the domain first, THEN delete the file. macOS keeps a copy of the
  # settings in memory (cfprefsd) which can write the file straight back, so
  # removing only the .plist is not removal. The app was quit above; deleting
  # while it ran would have it write them again.
  for domain in "${DOMAINS[@]}"; do
    defaults delete "$domain" >/dev/null 2>&1 && echo "removed  settings: $domain" || true
    rm -f "$HOME/Library/Preferences/$domain.plist"
  done
fi

why_no_sudo() {  # prints why sudo is not tried, and nothing when it can be
  if [ "${ANODE_NO_SUDO:-0}" = "1" ]; then
    echo "ANODE_NO_SUDO is set"
  elif ! command -v sudo >/dev/null 2>&1; then
    echo "this Mac has no sudo"
  elif [ ! -t 0 ] && [ "${ANODE_SUDO_WITHOUT_TERMINAL:-0}" != "1" ]; then
    # (ANODE_SUDO_WITHOUT_TERMINAL=1 is for the tests, which have no terminal and whose sudo is a stand-in.)
    echo "this window cannot ask for a password"
  fi
  return 0
}
say_removed_or_left() {  # say_removed_or_left PATH…: each was there before; says which of them still is
  local p
  for p in "$@"; do
    if [ -e "$p" ]; then echo "left     $p: still there"; else echo "removed  $p"; fi
  done
}
# The helper, the Always Stay Awake rule and a Mac told not to sleep: root's, so removed with sudo, which asks for the Mac's
# password at the Terminal once (`sudo -v`; the commands that follow ride on what it was given). The helper's own
# uninstall is the one command for the helper, because it reconnects the charger before it removes anything. Each command
# is judged by whether its thing is gone, not by its exit status: the helper's ends with 1 when it could not confirm the
# charger is connected, after removing everything else. A refused or cancelled password stops it, with nothing run.
# Whatever is still there at the end is printed as commands for you to run. Nothing here changes the exit status.
remove_root_items() {
  root_things_left || return 0
  local reason had_rule=0 had_sleep=0 explained=0 p
  local -a had_helper=()
  if [ -e "$HELPER_PLIST" ] || [ -e "$HELPER_BIN" ]; then
    for p in "$HELPER_PLIST" "$HELPER_BIN" "$FAN_SOCKET"; do
      if [ -e "$p" ]; then had_helper+=("$p"); fi
    done
  fi
  if [ -e "$KEEP_AWAKE_RULE" ]; then had_rule=1; fi
  if sleep_is_disabled; then had_sleep=1; fi

  echo "────────────────────────────────────────────────────────────────────────"
  echo " Removing what only root can remove"
  echo "────────────────────────────────────────────────────────────────────────"
  reason="$(why_no_sudo)"
  if [ -z "$reason" ]; then
    echo " The Terminal will ask for the Mac's password once. These are the commands, and nothing else is run as root:"
    echo
    print_root_commands
    echo
    if [ -e "$HELPER_BIN" ]; then
      # The helper's own uninstall, not its files deleted by hand: a drain may have left the charger switched off,
      # and the helper reconnects it before it removes itself (deleting it would leave the charger cut for good).
      echo " The helper's uninstall reconnects the charger if Anode had switched it off, then removes itself."
      echo
      explained=1
    fi
    trap ':' INT   # a ^C at the password prompt ends sudo, not this script: what is left is printed below
    if sudo -v; then
      if [ -e "$HELPER_BIN" ]; then
        sudo "$HELPER_BIN" --uninstall || true
      elif [ -e "$HELPER_PLIST" ]; then
        sudo launchctl bootout "system/$DAEMON_LABEL" >/dev/null 2>&1 || true
        sudo rm -f "$HELPER_PLIST" "$FAN_SOCKET" || true
      fi
      if [ ${#had_helper[@]} -gt 0 ]; then say_removed_or_left "${had_helper[@]}"; fi
      if [ "$had_rule" = "1" ]; then
        sudo rm -f "$KEEP_AWAKE_RULE" || true
        say_removed_or_left "$KEEP_AWAKE_RULE"
      fi
      if [ "$had_sleep" = "1" ] && sleep_is_disabled; then
        sudo pmset -a disablesleep 0 || true
        if sleep_is_disabled; then
          echo "left     SleepDisabled: macOS still says this Mac cannot sleep"
        else
          echo "reset    SleepDisabled: macOS can put this Mac to sleep again"
        fi
      fi
    else
      reason="the password was not given"
    fi
    trap - INT
  fi
  if root_things_left; then
    echo
    if [ -n "$reason" ]; then
      echo " Removing them needs the Mac's password, and $reason, so none of it was run."
    else
      echo " Some of it is still there."
    fi
    echo " Run these yourself, in a Terminal:"
    echo
    print_root_commands
    if [ -e "$HELPER_BIN" ] && [ "$explained" = "0" ]; then
      echo
      echo " The helper's uninstall reconnects the charger if Anode had switched it off, then removes itself."
    fi
  fi
  echo
  return 0
}
echo
remove_root_items
echo "✓ Anode has been removed."
echo
if [ -n "$KEPT_CHECKOUT" ]; then
  echo "  $INSTALLED_SRC was left alone because it $KEPT_CHECKOUT."
  echo "  Delete it yourself if you want it gone."
else
  echo "  A source checkout anywhere else was left alone."
fi
