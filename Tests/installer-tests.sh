#!/bin/bash
# Tests for install.sh and uninstall.sh: that an install puts things where they should be, that a FAILED
# install takes away everything it made and nothing it did not, and that an uninstall leaves nothing of Anode.
#
#   Tests/installer-tests.sh           the fast scenarios (a few seconds each; the build is replaced by a stub)
#   Tests/installer-tests.sh --full    also one REAL install and uninstall (a few minutes: it compiles the app)
#
# Also run by `swift test` (InstallerScriptTests), without --full.
#
# NOTHING HERE TOUCHES THE REAL MACHINE. Every scenario gets a HOME of its own under a temporary folder; the
# source the installer "downloads" is a copy of THIS working tree (files git tracks or would track, so changes
# not yet committed are what is tested), cloned from a local path; `osascript` is stubbed so the test cannot
# quit the Anode that is running; `getconf` is stubbed so the per-user cache and temp folders the uninstaller
# clears are the test's own, not macOS's. The login keychain list is compared before and after.
#
# The uninstaller also names /Applications/Anode.app, an absolute path no HOME can stand in for; where that
# exists the uninstall scenarios are skipped rather than risk deleting it.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
FULL=0; [ "${1:-}" = "--full" ] && FULL=1
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()    { PASS=$((PASS + 1)); printf '    ok    %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf '    FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/          | /'; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
present() { [ -e "$1" ]; }
absent()  { [ ! -e "$1" ]; }
has()     { printf '%s' "$OUT" | grep -qF -- "$1"; }
hasnt()   { ! printf '%s' "$OUT" | grep -qF -- "$1"; }

# ── Stubs that keep the real machine out of it ──────────────────────────────
mkdir -p "$T/shim" "$T/cache" "$T/tmp" "$T/shared-charge"
# The uninstaller names the record every account's Anode shares by an absolute path under /Users/Shared; this is the
# test's own, so no scenario can touch the real one.
export ANODE_SHARED_CHARGE_DIR="$T/shared-charge"
# Likewise the helper's launchd job: where a helper is installed on this Mac must not change what a scenario prints.
export ANODE_LAUNCH_DAEMONS_DIR="$T/no-launch-daemons"
printf '#!/bin/sh\nexit 0\n' > "$T/shim/osascript"
cat > "$T/shim/getconf" <<EOF
#!/bin/sh
case "\$1" in
  DARWIN_USER_CACHE_DIR) echo "$T/cache/" ;;
  DARWIN_USER_TEMP_DIR)  echo "$T/tmp/" ;;
  *) exec /usr/bin/getconf "\$@" ;;
esac
EOF
chmod +x "$T/shim/osascript" "$T/shim/getconf"
KEYCHAINS_BEFORE="$(security list-keychains 2>/dev/null)"

# ── The source the installer will clone: this working tree, as a local git repo ──
BASE="$T/base"
mkdir -p "$BASE"
( cd "$ROOT" && git ls-files -co --exclude-standard -z | rsync -a --from0 --files-from=- ./ "$BASE/" )
# No background tidying in these throwaway repos. A commit starts git's maintenance detached, and it packs the
# loose objects away while the next step is still copying them: the installer's clone of this repo then died with
# "failed to copy file … No such file or directory" about one run in four (git 2.54), failing scenario 1.
quiet_commit() { git -c user.name=t -c user.email=t@t -c gc.auto=0 -c maintenance.auto=false commit -qm "$1"; }
( cd "$BASE" && git init -q && git add -A && quiet_commit base )

# A variant of it whose build-app.sh is `$2`, committed.
variant() {
  local name="$1" script="$2"
  git clone -q "$BASE" "$T/repo-$name"
  printf '%s\n' "$script" > "$T/repo-$name/build-app.sh"
  chmod +x "$T/repo-$name/build-app.sh"
  ( cd "$T/repo-$name" && git add -A && quiet_commit "$name" )
}

# Makes the things the real build makes (signing keychain, the app), then fails with a compiler-style error.
variant fails-after-making-things '#!/bin/bash
echo "› stub build"
./make-signing-identity.sh >/dev/null 2>&1
mkdir -p "$HOME/Applications/Anode.app"; echo built > "$HOME/Applications/Anode.app/binary"
echo "/x/y.swift:1:1: error: stub failure after making things"
exit 1'

# Makes the same things and succeeds.
variant succeeds '#!/bin/bash
echo "› stub build"
./make-signing-identity.sh >/dev/null 2>&1
mkdir -p "$HOME/Applications/Anode.app"; echo built > "$HOME/Applications/Anode.app/binary"
exit 0'

new_home() { local h="$T/home-$1"; rm -rf "$h"; mkdir -p "$h"; echo "$h"; }

run_install() {   # run_install HOME REPO
  OUT="$(HOME="$1" PATH="$T/shim:$PATH" ANODE_NO_LAUNCH=1 ANODE_REPO="$2" bash "$ROOT/install.sh" 2>&1)"; STATUS=$?
}
run_uninstall() { # run_uninstall HOME
  # ANODE_NO_LAUNCH=1: a real built app (--full) must not be run to put back THIS Mac's charge settings.
  OUT="$(HOME="$1" PATH="$T/shim:$PATH" ANODE_NO_LAUNCH=1 bash "$1/.anode/source/uninstall.sh" --yes 2>&1 || true)"
}
files_in() { ( cd "$1" && find . -mindepth 1 ! -path './Library/Keychains/.fl*' | sort ); }

# ═══ 1. a failed install leaves nothing of itself on a fresh Mac ════════════
echo "1. A build that fails AFTER making the app and the signing keychain, on a Mac with nothing of Anode's"
H="$(new_home 1)"
run_install "$H" "$T/repo-fails-after-making-things"
check "exits with an error"                                  [ "$STATUS" -ne 0 ]
check "prints the compiler's error line"                     has "error: stub failure after making things"
check "says what it undid"                                    has "Undoing what this run did"
check "the downloaded source is gone"                         absent "$H/.anode/source"
check "the hidden folder made for it is gone"                 absent "$H/.anode"
check "the installed app is gone"                             absent "$H/Applications/Anode.app"
check "the Applications folder it made is gone"               absent "$H/Applications"
check "the signing keychain it made is gone"                  absent "$H/Library/Keychains/anode-signing.keychain-db"
check "the build log is kept, because it is the diagnosis"    present "$H/Library/Logs/Anode-install.log"
# What may remain: the log, and the empty Library folders it sits in (the signing keychain's folder is made
# before the keychain). Anything else is something the failed run made and did not take away.
LEFT="$(files_in "$H" | grep -vE '^\./Library(/Keychains|/Logs)?$|^\./Library/Logs/Anode-install\.log$' || true)"
if [ -z "$LEFT" ]; then ok "nothing else is left in the home folder"; else bad "nothing else is left in the home folder" "$LEFT"; fi

# ═══ 2. a failed install never touches what was there before ═══════════════
echo "2. The same failure on a Mac that already had an install, a keychain and files of its own"
H="$(new_home 2)"
mkdir -p "$H/Applications/Anode.app" "$H/.anode" "$H/Library/Keychains"
echo old > "$H/Applications/Anode.app/old-binary"; echo mine > "$H/.anode/theirs.txt"
HOME="$H" "$ROOT/make-signing-identity.sh" >/dev/null 2>&1
KEYCHAIN_SUM="$(shasum "$H/Library/Keychains/anode-signing.keychain-db" | cut -d' ' -f1)"
run_install "$H" "$T/repo-fails-after-making-things"
check "exits with an error"                                  [ "$STATUS" -ne 0 ]
check "the existing app is still there"                       present "$H/Applications/Anode.app/old-binary"
check "the existing keychain is still there, unchanged"       [ "$(shasum "$H/Library/Keychains/anode-signing.keychain-db" 2>/dev/null | cut -d' ' -f1)" = "$KEYCHAIN_SUM" ]
check "a file the user had in the hidden folder survives"     present "$H/.anode/theirs.txt"
check "the source this run downloaded is gone"                absent "$H/.anode/source"

# ═══ 3. an install an earlier version made is found, not duplicated ═════════
echo "3. A Mac whose earlier install is in ~/Developer/Anode"
H="$(new_home 3)"
mkdir -p "$H/Developer"; git clone -q "$T/repo-fails-after-making-things" "$H/Developer/Anode"
run_install "$H" "$T/repo-fails-after-making-things"
check "it updates the old folder in place"                    has "updating $H/Developer/Anode"
check "it does not clone a second copy"                       absent "$H/.anode"
check "the old install is not removed by the failed run"      present "$H/Developer/Anode/.git"

# ═══ 4. a good install lands where it says, and a repeat updates ════════════
echo "4. A good install on a fresh Mac"
H="$(new_home 4)"
run_install "$H" "$T/repo-succeeds"
check "exits cleanly"                                         [ "$STATUS" -eq 0 ]
check "says it installed"                                     has "✓ Installed"
check "the source is in the hidden folder, not ~/Developer"   present "$H/.anode/source/.git"
check "nothing was put in ~/Developer"                        absent "$H/Developer"
check "the app is installed"                                  present "$H/Applications/Anode.app/binary"
check "the install is not undone on success"                  hasnt "Undoing"
run_install "$H" "$T/repo-succeeds"
check "running it again updates instead of cloning"           has "updating $H/.anode/source"
check "and still succeeds"                                    [ "$STATUS" -eq 0 ]

# ═══ 5. uninstall removes all of it ═════════════════════════════════════════
echo "5. Uninstalling that install"
if [ -e /Applications/Anode.app ]; then
  echo "    skip  /Applications/Anode.app exists on this Mac, and the uninstaller names it by absolute path"
else
  echo precious > "$H/keep-me.txt"; mkdir -p "$H/Documents"; echo precious > "$H/Documents/keep-me-too.txt"
  mkdir -p "$T/cache/dev.anode.app" "$T/cache/other.app"   # the test's own per-user cache folder (see getconf stub)
  HOME="$H" "$ROOT/make-signing-identity.sh" >/dev/null 2>&1   # a real keychain to remove
  check "(the keychain exists before)"                        present "$H/Library/Keychains/anode-signing.keychain-db"
  run_uninstall "$H"
  check "the app is gone"                                     absent "$H/Applications/Anode.app"
  check "the source is gone"                                  absent "$H/.anode/source"
  check "the hidden folder is gone"                           absent "$H/.anode"
  check "the signing keychain is gone"                        absent "$H/Library/Keychains/anode-signing.keychain-db"
  check "the install log is gone"                             absent "$H/Library/Logs/Anode-install.log"
  check "Anode's cache folder is gone"                        absent "$T/cache/dev.anode.app"
  check "another app's cache folder is NOT touched"           present "$T/cache/other.app"
  check "the user's own files are NOT touched"                [ -f "$H/keep-me.txt" ] && [ -f "$H/Documents/keep-me-too.txt" ]
  check "says it removed Anode"                               has "Anode has been removed"

  echo "6. Uninstalling a clone with work in it, and one an earlier version made"
  H="$(new_home 6)"
  run_install "$H" "$T/repo-succeeds"
  echo "work in progress" > "$H/.anode/source/uncommitted.txt"
  run_uninstall "$H"
  check "a clone with uncommitted work is KEPT"               present "$H/.anode/source/uncommitted.txt"
  check "and says why"                                        has "KEPT"
  check "the app is still removed"                            absent "$H/Applications/Anode.app"

  H="$(new_home 7)"
  mkdir -p "$H/Developer"; git clone -q "$T/repo-succeeds" "$H/Developer/Anode"
  mkdir -p "$H/Applications/Anode.app"
  OUT="$(HOME="$H" PATH="$T/shim:$PATH" bash "$H/Developer/Anode/uninstall.sh" --yes 2>&1 || true)"
  check "an install in ~/Developer/Anode is found and removed" absent "$H/Developer/Anode"
  check "and its app"                                         absent "$H/Applications/Anode.app"

  echo "6b. Charge Control's limit is put back before the app goes (a stub app answers)"
  # The stub stands in for AnodeApp: it writes down how it was run, and whether its settings were still there.
  stub_app() {  # stub_app HOME EXIT-STATUS [VERSION: default 1.17.0, the first that takes the argument; "none" writes no Info.plist]
    mkdir -p "$1/Applications/Anode.app/Contents/MacOS"
    printf '#!/bin/sh\necho "$*" > "$HOME/restore-asked"\nexit %s\n' "$2" \
      > "$1/Applications/Anode.app/Contents/MacOS/AnodeApp"
    chmod +x "$1/Applications/Anode.app/Contents/MacOS/AnodeApp"
    if [ "${3:-1.17.0}" != "none" ]; then
      printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>%s</string></dict></plist>\n' \
        "${3:-1.17.0}" > "$1/Applications/Anode.app/Contents/Info.plist"
    fi
  }
  H="$(new_home 9)"; stub_app "$H" 1
  OUT="$(HOME="$H" PATH="$T/shim:$PATH" bash "$ROOT/uninstall.sh" --yes 2>&1 || true)"
  check "the app is asked to put macOS's charge settings back" grep -qx -- "--restore-charge-settings" "$H/restore-asked"
  check "a failure says macOS may still hold a charge limit"  has "macOS may still hold a charge limit"
  check "a failure says where to change the limit"            has "System Settings → Battery"
  check "a failure says what reconnects a charger left off"   has "sudo /Library/PrivilegedHelperTools/dev.anode.app.fanhelper --uninstall"
  check "and does not promise that a restart reconnects it"   hasnt "restarting the Mac"
  check "a restore that ran says nothing about Anode running" hasnt "still running"
  check "the app is still removed"                            absent "$H/Applications/Anode.app"
  # Anode does not finish quitting: a pgrep that always finds it (and writes down how it was asked), and a sleep
  # that does not wait, so the scenario takes no time.
  mkdir -p "$T/shim-running"
  printf '#!/bin/sh\necho "$*" >> "$HOME/pgrep-asked"\nexit 0\n' > "$T/shim-running/pgrep"
  printf '#!/bin/sh\nexit 0\n' > "$T/shim-running/sleep"
  chmod +x "$T/shim-running/pgrep" "$T/shim-running/sleep"
  H="$(new_home 12)"; stub_app "$H" 0
  RUNNING_STATUS=0
  OUT="$(HOME="$H" PATH="$T/shim-running:$T/shim:$PATH" bash "$ROOT/uninstall.sh" --yes 2>&1)" || RUNNING_STATUS=$?
  check "Anode still running after the wait is said, in one line" [ "$(printf '%s\n' "$OUT" | grep -c "still running")" = 1 ]
  check "and it stops, with a failing exit status"            [ "$RUNNING_STATUS" != 0 ]
  check "and says to quit Anode and run it again"             has "Quit Anode and run this again"
  check "and removes nothing (the live app would set its limit again)" present "$H/Applications/Anode.app"
  check "and does not run the restore against the live app"   absent "$H/restore-asked"
  check "and does not claim it removed Anode"                 hasnt "Anode has been removed"
  only_this_user() { [ -s "$H/pgrep-asked" ] && ! grep -qv -- "-U $(id -u) " "$H/pgrep-asked"; }
  check "only this user's Anode is waited for"                only_this_user
  H="$(new_home 10)"; stub_app "$H" 0
  OUT="$(HOME="$H" PATH="$T/shim:$PATH" bash "$ROOT/uninstall.sh" --yes 2>&1 || true)"
  check "a restore that worked says nothing about it"         hasnt "System Settings → Battery"
  H="$(new_home 11)"; stub_app "$H" 1
  OUT="$(HOME="$H" PATH="$T/shim:$PATH" ANODE_NO_LAUNCH=1 bash "$ROOT/uninstall.sh" --yes 2>&1 || true)"
  check "ANODE_NO_LAUNCH=1 runs no app"                       absent "$H/restore-asked"

  echo "6b2. An installed app too old to take --restore-charge-settings is not run"
  # An older app would start its whole interface for the unknown argument, and the script would wait on it.
  for old in 1.16.0 1.9.9 0.9.0; do
    H="$(new_home "old-$old")"; stub_app "$H" 1 "$old"
    OUT="$(HOME="$H" PATH="$T/shim:$PATH" bash "$ROOT/uninstall.sh" --yes 2>&1 || true)"
    check "$old is not run"                                   absent "$H/restore-asked"
    check "$old: says what was skipped, and why"              has "The installed Anode is version $old, older than 1.17.0"
    check "$old: says where to change a limit by hand"        has "System Settings → Battery"
    check "$old: the app is still removed"                    absent "$H/Applications/Anode.app"
  done
  for new in 1.17.0 1.17.1 1.18.0 1.100.0 2.0.0; do
    H="$(new_home "new-$new")"; stub_app "$H" 0 "$new"
    OUT="$(HOME="$H" PATH="$T/shim:$PATH" bash "$ROOT/uninstall.sh" --yes 2>&1 || true)"
    check "$new is asked to put the charge settings back"     grep -qx -- "--restore-charge-settings" "$H/restore-asked"
    check "$new: says nothing was skipped"                    hasnt "older than 1.17.0"
  done
  H="$(new_home no-plist)"; stub_app "$H" 1 none
  OUT="$(HOME="$H" PATH="$T/shim:$PATH" bash "$ROOT/uninstall.sh" --yes 2>&1 || true)"
  check "an app whose version cannot be read is not run"      absent "$H/restore-asked"
  check "and says so"                                         has "Could not tell which version of Anode is installed"
  check "the app is still removed"                            absent "$H/Applications/Anode.app"

  echo "6b3. The helper that is still installed is removed by its own uninstall, which reconnects the charger"
  mkdir -p "$T/launch-daemons"; : > "$T/launch-daemons/dev.anode.app.fanhelper.plist"
  H="$(new_home 17)"; mkdir -p "$H/Applications/Anode.app"
  OUT="$(HOME="$H" PATH="$T/shim:$PATH" ANODE_LAUNCH_DAEMONS_DIR="$T/launch-daemons" bash "$ROOT/uninstall.sh" --yes 2>&1 || true)"
  check "tells the helper's own uninstall"                    has "sudo /Library/PrivilegedHelperTools/dev.anode.app.fanhelper --uninstall"
  check "and that it reconnects the charger first"            has "reconnects the charger if Anode had switched it off, then removes itself"
  check "and no longer tells to delete the helper by hand"    hasnt "sudo rm -f"
  check "nor to boot it out first"                            hasnt "launchctl bootout system"
  H="$(new_home 18)"; mkdir -p "$H/Applications/Anode.app"
  OUT="$(HOME="$H" PATH="$T/shim:$PATH" bash "$ROOT/uninstall.sh" --yes 2>&1 || true)"
  check "with no helper installed it says nothing about one"  hasnt "fan helper is still installed"

  echo "6c. A limit another account's Anode holds is left alone, and said so; the shared record goes only when empty"
  # Exit status 2 from the restore: the limit in force is another account's running Anode's.
  H="$(new_home 13)"; stub_app "$H" 2
  OUT="$(HOME="$H" PATH="$T/shim:$PATH" bash "$ROOT/uninstall.sh" --yes 2>&1 || true)"
  check "says another account's Anode is holding the limit"   has "Another account's Anode is holding macOS's charge limit"
  check "and that it was left in force"                       has "left in force"
  check "and does not claim the restore failed"               hasnt "could not put back"
  check "and does not tell the sudo command for the charger"  hasnt "sudo /Library/PrivilegedHelperTools"
  check "the app is still removed"                            absent "$H/Applications/Anode.app"
  # --data and the shared record.
  mkdir -p "$ANODE_SHARED_CHARGE_DIR"
  : > "$ANODE_SHARED_CHARGE_DIR/charge-control.json"
  H="$(new_home 14)"; stub_app "$H" 0
  OUT="$(HOME="$H" PATH="$T/shim:$PATH" bash "$ROOT/uninstall.sh" --yes --data 2>&1 || true)"
  check "--data removes the shared record when it is empty"   absent "$ANODE_SHARED_CHARGE_DIR/charge-control.json"
  check "and says so"                                         has "removed  $ANODE_SHARED_CHARGE_DIR/charge-control.json"
  check "the list says the shared record goes only if empty"  has "but only if it holds no record"
  mkdir -p "$ANODE_SHARED_CHARGE_DIR"
  printf '{"version":1}' > "$ANODE_SHARED_CHARGE_DIR/charge-control.json"
  H="$(new_home 15)"; stub_app "$H" 2
  OUT="$(HOME="$H" PATH="$T/shim:$PATH" bash "$ROOT/uninstall.sh" --yes --data 2>&1 || true)"
  check "--data keeps a shared record that holds a record"    present "$ANODE_SHARED_CHARGE_DIR/charge-control.json"
  check "and says why"                                        has "kept     $ANODE_SHARED_CHARGE_DIR/charge-control.json"
  H="$(new_home 16)"; stub_app "$H" 0
  OUT="$(HOME="$H" PATH="$T/shim:$PATH" bash "$ROOT/uninstall.sh" --yes 2>&1 || true)"
  check "without --data the shared record is not touched"     present "$ANODE_SHARED_CHARGE_DIR/charge-control.json"
fi

# ═══ 7. optional: the real thing ════════════════════════════════════════════
if [ "$FULL" = 1 ]; then
  echo "7. A REAL install (compiles the app) and uninstall"
  H="$(new_home 8)"
  run_install "$H" "$BASE"
  check "exits cleanly"                                       [ "$STATUS" -eq 0 ]
  check "the real app is installed"                           present "$H/Applications/Anode.app/Contents/MacOS/AnodeApp"
  check "it is signed with the local identity"                codesign -d -r- "$H/Applications/Anode.app" 2>&1 | grep -q 'certificate leaf'
  if [ ! -e /Applications/Anode.app ]; then
    run_uninstall "$H"
    check "uninstall removes the app and the source"          [ ! -e "$H/Applications/Anode.app" ] && [ ! -e "$H/.anode" ]
    check "and the signing keychain"                          absent "$H/Library/Keychains/anode-signing.keychain-db"
  fi
fi

echo
check "the real login keychain list was not changed by any of this" [ "$(security list-keychains 2>/dev/null)" = "$KEYCHAINS_BEFORE" ]
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
