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
# not yet committed are what is tested), cloned from a local path. A HOME protects only file paths, so every run
# of install.sh, uninstall.sh, update.sh, build-app.sh and make-signing-identity.sh goes through ONE function
# (run_anode) that puts stubs for osascript, getconf, defaults, launchctl, security, open, pkill, killall, tccutil,
# pmset and sudo first on PATH, checks with `command -v` that the script will find them, and sets
# ANODE_NO_LAUNCH=1 unless a stub app stands in. The stubs go by VERB: `defaults` and `security` pass only reads
# to the real tool and write down every change they were asked for, naming any domain or keychain. The login
# keychain list is compared before and after.
#
# The uninstaller also names /Applications/Anode.app, an absolute path no HOME can stand in for; it takes the folder
# from ANODE_SYSTEM_APPLICATIONS_DIR, which run_anode checks is this test's own, so the real one is never looked at.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
FULL=0; [ "${1:-}" = "--full" ] && FULL=1
T="$(mktemp -d)"
REAL_PIDS=()
trap 'for p in ${REAL_PIDS[@]+"${REAL_PIDS[@]}"}; do kill "$p" 2>/dev/null; done; rm -rf "$T"' EXIT

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
# And /Applications, the second place an Anode can be installed.
export ANODE_SYSTEM_APPLICATIONS_DIR="$T/system-applications"

# `defaults`, `launchctl` and `security` do not go by HOME: they talk to the settings service, to launchd and to the
# keychain service of the person running the tests. An uninstall --data scenario with the real `defaults` once deleted
# the real Anode settings of the Mac it ran on, and a later version of this file still named four domains and passed
# every other one on to the real tool. So the stubs go by what is asked, not by what it is asked about.
#
# BEGIN STUBS
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$T/osascript-asked" > "$T/shim/osascript"
cat > "$T/shim/getconf" <<EOF
#!/bin/sh
case "\$1" in
  DARWIN_USER_CACHE_DIR) echo "$T/cache/" ;;
  DARWIN_USER_TEMP_DIR)  echo "$T/tmp/" ;;
  *) exec /usr/bin/getconf "\$@" ;;
esac
EOF
# defaults: only a plain read reaches the real tool, for any domain or file. Every other verb (delete, write, import,
# remove, rename, and anything not named here) is written down and not run.
cat > "$T/shim/defaults" <<EOF
#!/bin/sh
verb=""; skip=0
for a in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  case "\$a" in
    -host) skip=1 ;;
    -*) ;;
    *) verb="\$a"; break ;;
  esac
done
case "\$verb" in
  read|read-type|export|domains|find|help) exec /usr/bin/defaults "\$@" ;;
esac
echo "\$*" >> "$T/defaults-asked"
exit 0
EOF
# security: reads reach the real tool; nothing that changes a keychain does. A keychain file the test's own scripts
# make, inside this test's folder, is a one-line placeholder file the stub keeps itself (so "the keychain is made / is
# gone" can still be checked); the same verbs naming any path outside the test's folder are refused and written to
# security-refused, which fails the run. No real keychain is created, changed, unlocked or searched for these.
cat > "$T/shim/security" <<EOF
#!/bin/sh
under_t() { case "\$1" in "$T"/*) return 0 ;; esac; return 1; }
last=""; for a in "\$@"; do last="\$a"; done
verb="\$1"
case "\$verb" in
  list-keychains|default-keychain|login-keychain)
    for a in "\$@"; do
      case "\$a" in -s|-S) echo "\$*" >> "$T/security-asked"; exit 0 ;; esac
    done
    exec /usr/bin/security "\$@" ;;
  find-identity)
    if under_t "\$last"; then
      if [ -f "\$last" ] && grep -q anode-test-keychain "\$last"; then
        echo '  1) 0000000000000000000000000000000000000000 "Anode Local Signing"'
        echo '     1 valid identities found'
      else
        echo '     0 valid identities found'
      fi
      exit 0
    fi
    exec /usr/bin/security "\$@" ;;
  find-certificate|find-key|show-keychain-info|verify-cert|help|error)
    exec /usr/bin/security "\$@" ;;
  create-keychain)
    echo "\$*" >> "$T/security-asked"
    if under_t "\$last"; then mkdir -p "\$(dirname "\$last")"; echo anode-test-keychain > "\$last"; exit 0; fi
    echo "\$*" >> "$T/security-refused"; exit 1 ;;
  delete-keychain)
    echo "\$*" >> "$T/security-asked"
    if under_t "\$last"; then rm -f "\$last"; exit 0; fi
    echo "\$*" >> "$T/security-refused"; exit 1 ;;
esac
echo "\$*" >> "$T/security-asked"
exit 0
EOF
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$T/launchctl-asked" > "$T/shim/launchctl"
# Nothing the scripts under test run may open an app, signal a process, change a privacy approval or the power
# settings, or become root.
# ps shows only the processes this test started (their pids are in test-pids): the Anode that really runs on the Mac
# that runs the tests is not one of a scenario's, and the uninstaller must not see it. Scenarios that need a process
# table of their own put another ps first on the path (shim-running, below).
cat > "$T/shim/ps" <<EOF
#!/bin/sh
pids=\$(tr '\\n' ',' < "$T/test-pids" 2>/dev/null)
[ -n "\$pids" ] || exit 0
exec /bin/ps -p "\${pids%,}" -o pid=,comm=
EOF
for tool in open pkill killall tccutil pmset sudo; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 0\n' "$tool" "$T/other-asked" > "$T/shim/$tool"
done
chmod +x "$T"/shim/*
# END STUBS

# ── The one door ────────────────────────────────────────────────────────────
# Every run of install.sh, uninstall.sh, update.sh, build-app.sh or make-signing-identity.sh in this file goes through
# run_anode. It puts the stubs first on PATH itself, checks inside the very environment the script will get (with
# `command -v`, the same lookup the script does) that each guarded tool resolves to a stub, that HOME and the folders
# the scripts can be pointed at are the test's own, and sets ANODE_NO_LAUNCH=1 so a real built app is never run to put
# back this Mac's charge settings; only when the scenario has put a stub app in place (a script marked
# "# anode-test-stub") is it left unset, so that the restore can be asked of it. A check that fails ends the whole run.
#
#   SCENARIO_ENV   extra NAME=value pairs for the next run (ANODE_REPO=…); SCENARIO_PATH   directories put before the stubs.
# BEGIN GUARD
exec 3>&2   # the real stderr: a scenario captures the script's own with 2>&1, and the reason for stopping must not go there
GUARDED_TOOLS="osascript getconf defaults launchctl security open pkill killall tccutil pmset sudo"
GUARDED_FOLDERS="HOME ANODE_SHARED_CHARGE_DIR ANODE_LAUNCH_DAEMONS_DIR ANODE_SYSTEM_APPLICATIONS_DIR"
SCENARIO_ENV=(); SCENARIO_PATH=""
guard_fail() {
  printf '✗ %s; refusing to run, so nothing real is touched\n' "$1" >&3
  kill -TERM $$   # the main shell, also from inside $( ): the whole run ends here
  return 1
}
run_anode() {   # run_anode HOME SCRIPT [ARGS…]: prints the script's output; returns its exit status
  local home="$1" script="$2"; shift 2
  local app="$home/Applications/Anode.app/Contents/MacOS/AnodeApp" got tool var
  local -a e
  e=(HOME="$home" PATH="${SCENARIO_PATH:+$SCENARIO_PATH:}$T/shim:$PATH" ${SCENARIO_ENV[@]+"${SCENARIO_ENV[@]}"})
  for tool in $GUARDED_TOOLS; do
    got="$(env -u BASH_ENV -u ENV "${e[@]}" bash -c 'command -v "$1"' _ "$tool" 2>/dev/null)"
    [ "$got" = "$T/shim/$tool" ] || { guard_fail "the $tool stub is not what the script would run (found '$got')"; return 1; }
  done
  got="$(env -u BASH_ENV -u ENV "${e[@]}" bash -c 'command -v ps' 2>/dev/null)"
  case "$got" in "$T"/*) ;; *) guard_fail "ps is '$got', not a stand-in inside the test's own folder (the real Anode would be seen)"; return 1 ;; esac
  for var in $GUARDED_FOLDERS; do
    got="$(env -u BASH_ENV -u ENV "${e[@]}" bash -c 'printf %s "${!1:-}"' _ "$var" 2>/dev/null)"
    case "$got" in "$T"/*) ;; *) guard_fail "$var is '$got', which is not inside the test's own folder"; return 1 ;; esac
  done
  if [ -f "$app" ] && grep -qx '# anode-test-stub' "$app" 2>/dev/null; then
    env -u BASH_ENV -u ENV -u ANODE_NO_LAUNCH "${e[@]}" bash "$script" "$@"
  else
    env -u BASH_ENV -u ENV "${e[@]}" ANODE_NO_LAUNCH=1 bash "$script" "$@"
  fi
}
# The same, read from the text of this file, so a scenario added later cannot forget. It fails closed: outside the two
# marked regions, a line that names one of the scripts has to be a comment or a call of the form
# `run_anode "$VAR" "…/script.sh"` with nothing else on it that runs a program, and no line may start a shell, `exec`,
# `source` or `eval` of its own, and no script name is put together from a variable.
static_check() {
  awk '
    /^# BEGIN (GUARD|STUBS)/ { skip = 1; next }
    /^# END (GUARD|STUBS)/   { skip = 0; next }
    skip || /^[[:space:]]*#/ { next }
    {
      names = ($0 ~ /(^|[^A-Za-z0-9_-])(install|uninstall|update|build-app|make-signing-identity)\.sh/)
      callform = ($0 ~ /run_anode +"\$[A-Za-z_0-9{}]+" +"[^"]*\.sh"/)
      other = ($0 ~ /(^|[^A-Za-z0-9_\/.-])(bash|sh|zsh|dash|ksh|source|eval|exec|env|command|xargs|nohup|open|PATH=|HOME=)([[:space:]]|$|=)/)
      if (names && !(callform && !other)) { print NR ": " $0; bad = 1 }
      else if ($0 ~ /(^|[;&|({`]|\$\(|(then|do|else)[[:space:]])[[:space:]]*(bash|sh|zsh|dash|ksh|source|eval|exec)[[:space:]]/) { print NR ": " $0; bad = 1 }
      else if ($0 ~ /\$\{?[A-Za-z_][A-Za-z_0-9]*\}?\.sh/) { print NR ": " $0; bad = 1 }
    }
    END { exit bad }' "$0"
}
# END GUARD
if ! BAD_LINES="$(static_check)"; then
  echo "✗ a line runs one of the scripts, or a shell, other than through run_anode:" >&2
  printf '%s\n' "$BAD_LINES" >&2
  exit 1
fi
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

# A variant of it whose build-app.sh is `$2`, committed. These only WRITE the stand-in build; install.sh runs it, through run_anode.
# BEGIN STUBS
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
# END STUBS

new_home() { local h="$T/home-$1"; rm -rf "$h"; mkdir -p "$h"; echo "$h"; }

run_install() {   # run_install HOME REPO
  SCENARIO_ENV=(ANODE_REPO="$2")
  OUT="$(run_anode "$1" "$ROOT/install.sh" 2>&1)"; STATUS=$?
  SCENARIO_ENV=()
}
run_uninstall() { # run_uninstall HOME
  OUT="$(run_anode "$1" "$1/.anode/source/uninstall.sh" --yes 2>&1 || true)"
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
run_anode "$H" "$ROOT/make-signing-identity.sh" >/dev/null 2>&1
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
echo precious > "$H/keep-me.txt"; mkdir -p "$H/Documents"; echo precious > "$H/Documents/keep-me-too.txt"
mkdir -p "$T/cache/dev.anode.app" "$T/cache/other.app"   # the test's own per-user cache folder (see getconf stub)
run_anode "$H" "$ROOT/make-signing-identity.sh" >/dev/null 2>&1   # a real keychain to remove
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
OUT="$(run_anode "$H" "$H/Developer/Anode/uninstall.sh" --yes 2>&1 || true)"
check "an install in ~/Developer/Anode is found and removed" absent "$H/Developer/Anode"
check "and its app"                                         absent "$H/Applications/Anode.app"

echo "6b. Charge Control's limit is put back before the app goes (a stub app answers)"
# The stub stands in for AnodeApp: it writes down how it was run, and whether its settings were still there.
stub_app() {  # stub_app HOME EXIT-STATUS [VERSION: default 1.17.0, the first that takes the argument; "none" writes no Info.plist]
  mkdir -p "$1/Applications/Anode.app/Contents/MacOS"
  printf '#!/bin/sh\n# anode-test-stub\necho "$*" > "$HOME/restore-asked"\nexit %s\n' "$2" \
    > "$1/Applications/Anode.app/Contents/MacOS/AnodeApp"
  chmod +x "$1/Applications/Anode.app/Contents/MacOS/AnodeApp"
  if [ "${3:-1.17.0}" != "none" ]; then
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>%s</string></dict></plist>\n' \
      "${3:-1.17.0}" > "$1/Applications/Anode.app/Contents/Info.plist"
  fi
}
H="$(new_home 9)"; stub_app "$H" 1
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
check "the app is asked to put macOS's charge settings back" grep -qx -- "--restore-charge-settings" "$H/restore-asked"
check "a failure says macOS may still hold a charge limit"  has "macOS may still hold a charge limit"
check "a failure says where to change the limit"            has "System Settings → Battery"
check "a failure says what reconnects a charger left off"   has "sudo /Library/PrivilegedHelperTools/dev.anode.app.fanhelper --uninstall"
check "and does not promise that a restart reconnects it"   hasnt "restarting the Mac"
check "and says the other way: install again, switch Charge Control on, then Install Helper…" \
                                                            has "install Anode again, switch Charge Control on and press Install Helper…"
check "and no longer says the button is there with Charge Control off" \
                                                            hasnt "press Install Helper… in Charge Control"
check "and does not send a Charge Control user to the Fans tab" hasnt "start its helper from the Fans tab"
check "a restore that ran says nothing about Anode running" hasnt "still running"
check "the app is still removed"                            absent "$H/Applications/Anode.app"
# Anode does not finish quitting: a `ps` that lists the programs in $T/running-bins as this user's processes (and
# writes down how it was asked), for as many asks as $T/ps-running-for says (forever when it is absent), and a sleep
# that does not wait, so the scenario takes no time. Whatever else it lists is not Anode's: the uninstaller must go by
# the executable's exact path, and the lines that only look like it must not count.
mkdir -p "$T/shim-running"
cat > "$T/shim-running/ps" <<EOF
#!/bin/sh
echo "\$*" >> "$T/ps-asked"
n=\$(cat "$T/ps-calls" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$T/ps-calls"
limit=\$(cat "$T/ps-running-for" 2>/dev/null || echo 999999)
echo "   101 /usr/sbin/cfprefsd"
cat "$T/ps-extra" 2>/dev/null
case "\$*" in *"-A"*) cat "$T/ps-extra-all" 2>/dev/null ;; esac
[ "\$n" -le "\$limit" ] || exit 0
while IFS= read -r bin; do
  [ -n "\$bin" ] || continue
  printf '%6d %s\n' 4242 "\$bin"
  printf '%6d %s\n' 4243 "\$bin-old"
  printf '%6d %s\n' 4244 "\$(dirname "\$bin")/x/\$(basename "\$bin")"
done < "$T/running-bins"
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/shim-running/sleep"
chmod +x "$T/shim-running/ps" "$T/shim-running/sleep"
ps_reset() { rm -f "$T/ps-asked" "$T/ps-calls" "$T/ps-running-for" "$T/running-bins" "$T/ps-extra" "$T/ps-extra-all"; }
ps_calls() { cat "$T/ps-calls" 2>/dev/null || echo 0; }
H="$(new_home 12)"; stub_app "$H" 0
ps_reset; printf '%s\n' "$H/Applications/Anode.app/Contents/MacOS/AnodeApp" > "$T/running-bins"
RUNNING_STATUS=0
SCENARIO_PATH="$T/shim-running"
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1)" || RUNNING_STATUS=$?
SCENARIO_PATH=""
check "Anode still running after the wait is said, in one line" [ "$(printf '%s\n' "$OUT" | grep -c "still running")" = 1 ]
check "and it stops, with a failing exit status"            [ "$RUNNING_STATUS" != 0 ]
check "and says to quit Anode and run it again"             has "Quit Anode and run this again"
check "and names the copy that is running"                  has "$H/Applications/Anode.app/Contents/MacOS/AnodeApp"
check "and removes nothing (the live app would set its limit again)" present "$H/Applications/Anode.app"
check "and does not run the restore against the live app"   absent "$H/restore-asked"
check "and does not claim it removed Anode"                 hasnt "Anode has been removed"
only_this_user() { [ -s "$T/ps-asked" ] && ! grep -qv -- "^-U $(id -u) " "$T/ps-asked"; }
check "only this user's Anode is waited for"                only_this_user
check "it was waited for, not given up on at the first look" [ "$(ps_calls)" -ge 5 ]

echo "6b1. Every installed copy is looked at before anything is removed, and a slow quit is waited for"
# Both places an Anode can be installed (the second is the test's own folder: see ANODE_SYSTEM_APPLICATIONS_DIR).
two_copies() {  # two_copies HOME: a stub app in ~/Applications and another in the system Applications folder
  stub_app "$1" 0
  rm -rf "$ANODE_SYSTEM_APPLICATIONS_DIR/Anode.app"
  mkdir -p "$ANODE_SYSTEM_APPLICATIONS_DIR/Anode.app/Contents/MacOS"
  printf '#!/bin/sh\n# anode-test-stub\nexit 0\n' > "$ANODE_SYSTEM_APPLICATIONS_DIR/Anode.app/Contents/MacOS/AnodeApp"
  chmod +x "$ANODE_SYSTEM_APPLICATIONS_DIR/Anode.app/Contents/MacOS/AnodeApp"
}
SYSTEM_BIN="$ANODE_SYSTEM_APPLICATIONS_DIR/Anode.app/Contents/MacOS/AnodeApp"
H="$(new_home 20)"; two_copies "$H"
ps_reset; printf '%s\n' "$SYSTEM_BIN" > "$T/running-bins"
RUNNING_STATUS=0
SCENARIO_PATH="$T/shim-running"
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1)" || RUNNING_STATUS=$?
SCENARIO_PATH=""
check "the second copy running stops the uninstall"         [ "$RUNNING_STATUS" != 0 ]
check "and is named"                                        has "$SYSTEM_BIN"
check "and nothing is removed: not that copy"               present "$ANODE_SYSTEM_APPLICATIONS_DIR/Anode.app"
check "not the first copy either"                           present "$H/Applications/Anode.app"
check "and the restore was not run"                         absent "$H/restore-asked"
# The first copy quits slowly: running for the first two looks, gone at the third.
H="$(new_home 21)"; two_copies "$H"
ps_reset; printf '%s\n' "$H/Applications/Anode.app/Contents/MacOS/AnodeApp" > "$T/running-bins"; echo 2 > "$T/ps-running-for"
SCENARIO_PATH="$T/shim-running"
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
SCENARIO_PATH=""
check "a first copy that quits slowly is waited for"        [ "$(ps_calls)" -ge 3 ]
check "and then both copies are removed"                    [ ! -e "$H/Applications/Anode.app" ] && [ ! -e "$ANODE_SYSTEM_APPLICATIONS_DIR/Anode.app" ]
check "after the restore was asked of the first copy"       grep -qx -- "--restore-charge-settings" "$H/restore-asked"
check "and it says nothing about a copy still running"      hasnt "still running"
# The second copy quits slowly.
H="$(new_home 22)"; two_copies "$H"
ps_reset; printf '%s\n' "$SYSTEM_BIN" > "$T/running-bins"; echo 3 > "$T/ps-running-for"
SCENARIO_PATH="$T/shim-running"
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
SCENARIO_PATH=""
check "a second copy that quits slowly is waited for"       [ "$(ps_calls)" -ge 4 ]
check "and then both copies are removed"                    [ ! -e "$H/Applications/Anode.app" ] && [ ! -e "$ANODE_SYSTEM_APPLICATIONS_DIR/Anode.app" ]
# Look-alikes are not Anode: the same path with something after it. (A program called AnodeApp from anywhere else is,
# below: the check goes by the file name, because a relative path or a link hides the installed path.)
H="$(new_home 23)"; two_copies "$H"
ps_reset; : > "$T/running-bins"
printf '  4300 %s\n  4301 %s\n' "$SYSTEM_BIN-old" "/usr/bin/AnodeApp-helper" > "$T/ps-extra"
SCENARIO_PATH="$T/shim-running"
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
SCENARIO_PATH=""
check "a process that only looks like Anode's path does not stop it" hasnt "still running"
check "and the copies are removed"                          [ ! -e "$H/Applications/Anode.app" ] && [ ! -e "$ANODE_SYSTEM_APPLICATIONS_DIR/Anode.app" ]
# An AnodeApp from a folder that is not an installed copy's (a build folder, a link, a relative path) is a running Anode.
H="$(new_home 23b)"; two_copies "$H"
ps_reset; : > "$T/running-bins"
printf '  4300 %s\n' "/somewhere/else/AnodeApp" > "$T/ps-extra"
SCENARIO_PATH="$T/shim-running"
RUNNING_STATUS=0; OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1)" || RUNNING_STATUS=$?
SCENARIO_PATH=""
check "an AnodeApp started from anywhere else stops it"     [ "$RUNNING_STATUS" != 0 ] && has "still running"
check "and is named as ps shows it"                         has "(/somewhere/else/AnodeApp)"
check "and nothing is removed"                              present "$H/Applications/Anode.app"
# Another user's Anode counts only when the copy in the system Applications folder is to be removed.
H="$(new_home 23c)"; two_copies "$H"
ps_reset; : > "$T/running-bins"
printf '  4400 %s\n' "/Users/someone-else/Applications/Anode.app/Contents/MacOS/AnodeApp" > "$T/ps-extra-all"
SCENARIO_PATH="$T/shim-running"
RUNNING_STATUS=0; OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1)" || RUNNING_STATUS=$?
SCENARIO_PATH=""
check "another user's Anode stops the removal of the system copy" [ "$RUNNING_STATUS" != 0 ] && has "someone-else"
check "and it was looked for among every user's processes"  grep -q -- "^-A " "$T/ps-asked"
rm -rf "$ANODE_SYSTEM_APPLICATIONS_DIR/Anode.app"   # (the scenarios above left it: they stopped before removing anything)
H="$(new_home 23d)"; stub_app "$H" 0
ps_reset; : > "$T/running-bins"
printf '  4400 %s\n' "/Users/someone-else/Applications/Anode.app/Contents/MacOS/AnodeApp" > "$T/ps-extra-all"
SCENARIO_PATH="$T/shim-running"
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
SCENARIO_PATH=""
check "with no copy in the system folder it is not this user's to wait for" hasnt "still running"
check "and only this user's processes were looked at"       only_this_user
check "the app is removed"                                  absent "$H/Applications/Anode.app"
ps_reset

echo "6b2a. A running Anode is found by its file name, however it was started (real processes)"
# A real program that sleeps, so `ps` lists it by the path it was started with; compiled here (the Command Line Tools
# have the compiler). It writes its own pid to the file named second, so the scenario knows which process is the program
# and not a shell that started it.
printf '#include <unistd.h>\n#include <stdio.h>\n#include <stdlib.h>\nint main(int c, char **v) { if (c > 2) { FILE *f = fopen(v[2], "w"); if (f) { fprintf(f, "%%d\\n", (int)getpid()); fclose(f); } } sleep(c > 1 ? atoi(v[1]) : 30); return 0; }\n' > "$T/hold.c"
mkdir -p "$T/shim-nosleep"; printf '#!/bin/sh\nexit 0\n' > "$T/shim-nosleep/sleep"; chmod +x "$T/shim-nosleep/sleep"
if cc -o "$T/hold" "$T/hold.c" 2>/dev/null; then
  live_anode() {  # live_anode HOME [relative]: the app there is a real process that stays up until killed; sets LIVE_PID
    local bin="$1/Applications/Anode.app/Contents/MacOS/AnodeApp" pidfile="$T/live-pid"
    mkdir -p "$(dirname "$bin")"; cp "$T/hold" "$bin"; rm -f "$pidfile"
    if [ "${2:-}" = relative ]; then
      # Started from inside its own folder as ./AnodeApp: ps shows "./AnodeApp", not the installed path.
      ( cd "$(dirname "$bin")" && ./AnodeApp 60 "$pidfile" ) &
    else
      "$bin" 60 "$pidfile" &
    fi
    local waited=0
    while [ ! -s "$pidfile" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done   # (the shell's own sleep, not the stub: this is not in a run_anode)
    LIVE_PID="$(cat "$pidfile")"; REAL_PIDS+=("$LIVE_PID"); echo "$LIVE_PID" >> "$T/test-pids"
  }
  stop_live() { kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null; : > "$T/test-pids"; }
  : > "$T/test-pids"
  H="$(new_home 'a+(b).c')"; live_anode "$H"
  SCENARIO_PATH="$T/shim-nosleep"
  RUNNING_STATUS=0; OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1)" || RUNNING_STATUS=$?
  SCENARIO_PATH=""
  check "a copy running from a home named a+(b).c is found"   [ "$RUNNING_STATUS" != 0 ] && has "still running"
  check "and kept"                                            present "$H/Applications/Anode.app"
  check "and named by the path it was started with"           has "$H/Applications/Anode.app/Contents/MacOS/AnodeApp"
  stop_live
  SCENARIO_PATH="$T/shim-nosleep"; OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"; SCENARIO_PATH=""
  check "gone, it is removed"                                 absent "$H/Applications/Anode.app"
  # Started through a relative path, ps shows ./AnodeApp and not the installed path.
  H="$(new_home 'relative')"; live_anode "$H" relative
  SCENARIO_PATH="$T/shim-nosleep"
  RUNNING_STATUS=0; OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1)" || RUNNING_STATUS=$?
  SCENARIO_PATH=""
  check "a copy started through a relative path is found"     [ "$RUNNING_STATUS" != 0 ] && has "still running"
  check "and kept"                                            present "$H/Applications/Anode.app"
  stop_live
  SCENARIO_PATH="$T/shim-nosleep"; OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"; SCENARIO_PATH=""
  check "gone, it is removed"                                 absent "$H/Applications/Anode.app"
  # A path with spaces in it (the usual home folder is not far from one).
  H="$(new_home 'with some spaces')"; live_anode "$H"
  SCENARIO_PATH="$T/shim-nosleep"
  RUNNING_STATUS=0; OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1)" || RUNNING_STATUS=$?
  SCENARIO_PATH=""
  check "a copy running from a path with spaces is found"     [ "$RUNNING_STATUS" != 0 ] && has "still running"
  check "and named whole"                                     has "($H/Applications/Anode.app/Contents/MacOS/AnodeApp)"
  stop_live
  # Another home's Anode of this user is counted too: a link or a relative path hides which copy a process is, so the
  # check is conservative. (Its path is not read as a pattern: the first scenario's name is made of pattern characters.)
  OTHER="$(new_home 'abZc')"; live_anode "$OTHER"
  H="$(new_home 'a+(b).c')"; stub_app "$H" 0
  SCENARIO_PATH="$T/shim-nosleep"
  RUNNING_STATUS=0; OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1)" || RUNNING_STATUS=$?
  SCENARIO_PATH=""
  check "another home's Anode of this user stops it too"      [ "$RUNNING_STATUS" != 0 ] && has "$OTHER/Applications/Anode.app/Contents/MacOS/AnodeApp"
  check "and nothing is removed"                              present "$H/Applications/Anode.app"
  stop_live
else
  echo "    skip  no C compiler here (xcode-select --install), so no real process to look for"
fi

H="$(new_home 10)"; stub_app "$H" 0
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
check "a restore that worked says nothing about it"         hasnt "System Settings → Battery"
H="$(new_home 11)"; stub_app "$H" 1
SCENARIO_ENV=(ANODE_NO_LAUNCH=1)
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
SCENARIO_ENV=()
check "ANODE_NO_LAUNCH=1 runs no app"                       absent "$H/restore-asked"

echo "6b2. An installed app too old to take --restore-charge-settings is not run"
# An older app would start its whole interface for the unknown argument, and the script would wait on it.
for old in 1.16.0 1.9.9 0.9.0; do
  H="$(new_home "old-$old")"; stub_app "$H" 1 "$old"
  OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
  check "$old is not run"                                   absent "$H/restore-asked"
  check "$old: says what was skipped, and why"              has "The installed Anode is version $old, older than 1.17.0"
  check "$old: says where to change a limit by hand"        has "System Settings → Battery"
  check "$old: the app is still removed"                    absent "$H/Applications/Anode.app"
done
for new in 1.17.0 1.17.1 1.18.0 1.100.0 2.0.0; do
  H="$(new_home "new-$new")"; stub_app "$H" 0 "$new"
  OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
  check "$new is asked to put the charge settings back"     grep -qx -- "--restore-charge-settings" "$H/restore-asked"
  check "$new: says nothing was skipped"                    hasnt "older than 1.17.0"
done
H="$(new_home no-plist)"; stub_app "$H" 1 none
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
check "an app whose version cannot be read is not run"      absent "$H/restore-asked"
check "and says so"                                         has "Could not tell which version of Anode is installed"
check "the app is still removed"                            absent "$H/Applications/Anode.app"

echo "6b3. The helper that is still installed is removed by its own uninstall, which reconnects the charger"
mkdir -p "$T/launch-daemons"; : > "$T/launch-daemons/dev.anode.app.fanhelper.plist"
H="$(new_home 17)"; mkdir -p "$H/Applications/Anode.app"
SCENARIO_ENV=(ANODE_LAUNCH_DAEMONS_DIR="$T/launch-daemons")
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
SCENARIO_ENV=()
check "tells the helper's own uninstall"                    has "sudo /Library/PrivilegedHelperTools/dev.anode.app.fanhelper --uninstall"
check "and that it reconnects the charger first"            has "reconnects the charger if Anode had switched it off, then removes itself"
check "and no longer tells to delete the helper by hand"    hasnt "sudo rm -f"
check "nor to boot it out first"                            hasnt "launchctl bootout system"
H="$(new_home 18)"; mkdir -p "$H/Applications/Anode.app"
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
check "with no helper installed it says nothing about one"  hasnt "fan helper is still installed"

echo "6c. A limit another account's Anode holds is left alone, and said so; the shared record goes only when empty"
# Exit status 2 from the restore: the limit in force is another account's running Anode's.
H="$(new_home 13)"; stub_app "$H" 2
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
check "says another account's Anode is holding the limit"   has "Another account's Anode is holding macOS's charge limit"
check "and that it was left in force"                       has "left in force"
check "and does not claim the restore failed"               hasnt "could not put back"
check "and does not tell the sudo command for the charger"  hasnt "sudo /Library/PrivilegedHelperTools"
check "the app is still removed"                            absent "$H/Applications/Anode.app"
# --data and the shared record.
mkdir -p "$ANODE_SHARED_CHARGE_DIR"
: > "$ANODE_SHARED_CHARGE_DIR/charge-control.json"
H="$(new_home 14)"; stub_app "$H" 0
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes --data 2>&1 || true)"
check "--data removes the shared record when it is empty"   absent "$ANODE_SHARED_CHARGE_DIR/charge-control.json"
check "and says so"                                         has "removed  $ANODE_SHARED_CHARGE_DIR/charge-control.json"
check "the list says the shared record goes only if empty"  has "but only if it holds no record"
check "--data asks for the settings to be cleared"          grep -qx "delete com.anode.settings" "$T/defaults-asked"
check "and the app's own domain"                            grep -qx "delete dev.anode.app" "$T/defaults-asked"
mkdir -p "$ANODE_SHARED_CHARGE_DIR"
printf '{"version":1}' > "$ANODE_SHARED_CHARGE_DIR/charge-control.json"
H="$(new_home 15)"; stub_app "$H" 2
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes --data 2>&1 || true)"
check "--data keeps a shared record that holds a record"    present "$ANODE_SHARED_CHARGE_DIR/charge-control.json"
check "and says why"                                        has "kept     $ANODE_SHARED_CHARGE_DIR/charge-control.json"
H="$(new_home 16)"; stub_app "$H" 0
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
check "without --data the shared record is not touched"     present "$ANODE_SHARED_CHARGE_DIR/charge-control.json"

echo "6d. --data after a restore that failed keeps Anode's settings, which remember a charger that may still be off"
data_home() {  # data_home HOME: settings files and a history in the places --data clears
  mkdir -p "$1/Library/Preferences" "$1/Library/Application Support/Anode"
  : > "$1/Library/Preferences/com.anode.settings.plist"; : > "$1/Library/Preferences/dev.anode.app.plist"
  : > "$1/Library/Application Support/Anode/history.sqlite"
}
rm -f "$T/defaults-asked"
H="$(new_home 24)"; stub_app "$H" 1; data_home "$H"
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes --data 2>&1 || true)"
check "the app is still removed"                            absent "$H/Applications/Anode.app"
check "and the rest of the data (the history)"              absent "$H/Library/Application Support/Anode/history.sqlite"
check "no settings were cleared"                            absent "$T/defaults-asked"
check "nor their files deleted"                             present "$H/Library/Preferences/com.anode.settings.plist"
check "it says the settings were kept, and why"             has "kept     Anode's settings: Anode could not put macOS's own charge settings back"
check "and how to remove them later, naming the domains"    has "'defaults delete <domain>' for each of: com.anode.settings"
check "and does not say they were removed"                  hasnt "removed  settings:"
rm -f "$T/defaults-asked"
H="$(new_home 25)"; stub_app "$H" 0; data_home "$H"
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes --data 2>&1 || true)"
check "a restore that worked clears them as before"         grep -qx "delete com.anode.settings" "$T/defaults-asked"
check "and their files"                                     absent "$H/Library/Preferences/com.anode.settings.plist"
check "and says nothing about keeping them"                 hasnt "kept     Anode's settings"
rm -f "$T/defaults-asked"
H="$(new_home 26)"; stub_app "$H" 2; data_home "$H"
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes --data 2>&1 || true)"
check "another account's limit left in force clears this account's settings" grep -qx "delete com.anode.settings" "$T/defaults-asked"
rm -f "$T/defaults-asked"
H="$(new_home 27)"; stub_app "$H" 1
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
check "without --data a failed restore says nothing about settings being kept" hasnt "kept     Anode's settings"

echo "6e. Every installed copy is asked in turn until one has put macOS's charge settings back"
system_stub() {  # system_stub EXIT-STATUS [VERSION: default 1.17.0; "none" writes no Info.plist]: a stub app in the system Applications folder
  local dir="$ANODE_SYSTEM_APPLICATIONS_DIR/Anode.app"
  rm -rf "$dir"; mkdir -p "$dir/Contents/MacOS"
  printf '#!/bin/sh\n# anode-test-stub\necho "$*" > "$HOME/restore-asked-system"\nexit %s\n' "$1" > "$dir/Contents/MacOS/AnodeApp"
  chmod +x "$dir/Contents/MacOS/AnodeApp"
  if [ "${2:-1.17.0}" != "none" ]; then
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>%s</string></dict></plist>\n' \
      "${2:-1.17.0}" > "$dir/Contents/Info.plist"
  fi
}
# An older copy first (skipped as too old) and a current one second: the current one is asked, both are removed, and
# --data clears the settings because the restore was done.
rm -f "$T/defaults-asked"
H="$(new_home 30)"; stub_app "$H" 1 1.16.0; system_stub 0; data_home "$H"
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes --data 2>&1 || true)"
check "the older copy is not run"                           absent "$H/restore-asked"
check "and the current one, second, is asked"               grep -qx -- "--restore-charge-settings" "$H/restore-asked-system"
check "the skip of the older one is said, naming it"        has "older than 1.17.0, the first that can put macOS's own charge settings back, so that step was skipped for $H/Applications/Anode.app"
check "nothing is said about a restore that failed"         hasnt "could not put back"
check "both copies are removed"                             [ ! -e "$H/Applications/Anode.app" ] && [ ! -e "$ANODE_SYSTEM_APPLICATIONS_DIR/Anode.app" ]
check "--data clears the settings, as the restore was done" grep -qx "delete com.anode.settings" "$T/defaults-asked"
check "and says nothing about keeping them"                 hasnt "kept     Anode's settings"
# A copy whose version cannot be read, first, is skipped the same way.
H="$(new_home 31)"; stub_app "$H" 1 none; system_stub 0
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
check "a copy whose version cannot be read does not stop the next being asked" grep -qx -- "--restore-charge-settings" "$H/restore-asked-system"
# A copy that fails first and a second that succeeds: the second has done it, so nothing is said to have failed.
rm -f "$T/defaults-asked"
H="$(new_home 32)"; stub_app "$H" 1; system_stub 0; data_home "$H"
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes --data 2>&1 || true)"
check "the first copy was asked and failed"                 grep -qx -- "--restore-charge-settings" "$H/restore-asked"
check "the second was asked after it"                       grep -qx -- "--restore-charge-settings" "$H/restore-asked-system"
check "and since it did it, no failure is said"             hasnt "could not put back"
check "and --data clears the settings"                      grep -qx "delete com.anode.settings" "$T/defaults-asked"
# The first one that has done it is the last asked.
H="$(new_home 33)"; stub_app "$H" 0; system_stub 0
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
check "a first copy that did it means the second is not asked" absent "$H/restore-asked-system"
# Another account's limit left in force is a restore that has been dealt with.
H="$(new_home 34)"; stub_app "$H" 2; system_stub 0
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
check "another account's limit ends the asking too"         absent "$H/restore-asked-system"
# Nothing could be asked: all too old. The restore did not happen, so --data keeps the settings.
rm -f "$T/defaults-asked"
H="$(new_home 35)"; stub_app "$H" 1 1.16.0; system_stub 1 1.15.0; data_home "$H"
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes --data 2>&1 || true)"
check "neither is run"                                      [ ! -e "$H/restore-asked" ] && [ ! -e "$H/restore-asked-system" ]
check "--data keeps the settings"                           absent "$T/defaults-asked"
check "and says why"                                        has "kept     Anode's settings: Anode could not put macOS's own charge settings back"
check "the apps and the rest of the data go as asked"       [ ! -e "$H/Applications/Anode.app" ] && [ ! -e "$ANODE_SYSTEM_APPLICATIONS_DIR/Anode.app" ] && [ ! -e "$H/Library/Application Support/Anode/history.sqlite" ]
# The same for copies whose versions cannot be read.
rm -f "$T/defaults-asked"
H="$(new_home 36)"; stub_app "$H" 1 none; system_stub 1 none; data_home "$H"
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes --data 2>&1 || true)"
check "copies with unreadable versions: --data keeps the settings" absent "$T/defaults-asked"
# Both ran and both failed: said once, and --data keeps the settings.
rm -f "$T/defaults-asked"
H="$(new_home 37)"; stub_app "$H" 1; system_stub 1; data_home "$H"
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes --data 2>&1 || true)"
check "both were asked"                                     [ -e "$H/restore-asked" ] && [ -e "$H/restore-asked-system" ]
check "the failure is said once"                            [ "$(printf '%s\n' "$OUT" | grep -c "could not put back macOS's own charge settings")" = 1 ]
check "and --data keeps the settings"                       absent "$T/defaults-asked"
# Without --data a restore nobody could do says nothing about settings being kept.
H="$(new_home 38)"; stub_app "$H" 1 1.16.0
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
check "without --data nothing is said about keeping settings" hasnt "kept     Anode's settings"
rm -rf "$ANODE_SYSTEM_APPLICATIONS_DIR/Anode.app"

# ═══ 7. optional: the real thing ════════════════════════════════════════════
if [ "$FULL" = 1 ]; then
  echo "7. A REAL install (compiles the app) and uninstall"
  H="$(new_home 8)"
  run_install "$H" "$BASE"
  check "exits cleanly"                                       [ "$STATUS" -eq 0 ]
  check "the real app is installed"                           present "$H/Applications/Anode.app/Contents/MacOS/AnodeApp"
  # The security stub keeps every keychain change out of the run (see the stubs above), so the build finds no real
  # signing key and signs ad hoc; the app must still be signed and verify. Signing with the local identity is
  # what ./make-signing-identity.sh makes, and is not exercised here.
  check "it is signed, and the signature verifies"            codesign --verify --strict "$H/Applications/Anode.app"
  run_uninstall "$H"
  check "uninstall removes the app and the source"            [ ! -e "$H/Applications/Anode.app" ] && [ ! -e "$H/.anode" ]
  check "and the signing keychain"                            absent "$H/Library/Keychains/anode-signing.keychain-db"
fi

echo
echo "8. The stubs themselves"
# Written to be read with the stubs' own verbs in mind: each of these would reach this Mac if the stub let it through.
NEVER="com.anode.installer-tests.never-a-real-domain"
for verb_args in "delete $NEVER" "write $NEVER key -string v" "import $NEVER /dev/null" "remove $NEVER" "rename $NEVER old new" \
                 "-currentHost write $NEVER key -int 1" "-host localhost delete $NEVER" "frobnicate $NEVER"; do
  # shellcheck disable=SC2086
  "$T/shim/defaults" $verb_args >/dev/null 2>&1
  check "defaults $verb_args is written down"                 grep -qxF -- "$verb_args" "$T/defaults-asked"
done
check "and none of them reached the real settings"            [ -z "$(/usr/bin/defaults domains | tr ',' '\n' | grep -F "$NEVER")" ]
read_reaches_real_defaults() { local out; out="$("$T/shim/defaults" read "$NEVER" 2>&1)"; printf '%s' "$out" | grep -qE "not found|does not exist"; }
check "defaults read goes to the real tool"                   read_reaches_real_defaults
check "…and is not written down as a change"                  [ -z "$(grep -F -- "read $NEVER" "$T/defaults-asked")" ]
NEVER_KEYCHAIN="/nonexistent-installer-tests/never.keychain-db"
for verb_args in "delete-keychain $NEVER_KEYCHAIN" "create-keychain -p x $NEVER_KEYCHAIN"; do
  # shellcheck disable=SC2086
  "$T/shim/security" $verb_args >/dev/null 2>&1
  check "security $verb_args is refused and written down"     grep -qxF -- "$verb_args" "$T/security-refused"
done
rm -f "$T/security-refused"   # the two refusals just made on purpose
for verb_args in "unlock-keychain -p x $T/k.keychain-db" "set-keychain-settings $T/k.keychain-db" "import /dev/null -k $T/k.keychain-db" \
                 "set-key-partition-list -S apple: -s $T/k.keychain-db" "add-generic-password -s anode-test -a x -w y" \
                 "default-keychain -s $T/k.keychain-db" "list-keychains -s $T/k.keychain-db" "set-keychain-password x" "frobnicate"; do
  # shellcheck disable=SC2086
  "$T/shim/security" $verb_args >/dev/null 2>&1
  check "security $verb_args is written down, not run"        grep -qxF -- "$verb_args" "$T/security-asked"
done
check "none of them changed the keychain search list"         [ "$(security list-keychains 2>/dev/null)" = "$KEYCHAINS_BEFORE" ]
"$T/shim/security" create-keychain -p x "$T/placeholder.keychain-db" >/dev/null 2>&1
check "a keychain made inside the test's folder is a placeholder file" grep -q anode-test-keychain "$T/placeholder.keychain-db"
placeholder_has_identity() { local out; out="$("$T/shim/security" find-identity -p codesigning "$T/placeholder.keychain-db")"; printf '%s' "$out" | grep -q "Anode Local Signing"; }
check "…which the identity lookup sees"                       placeholder_has_identity
"$T/shim/security" delete-keychain "$T/placeholder.keychain-db" >/dev/null 2>&1
check "…and delete-keychain takes away"                       absent "$T/placeholder.keychain-db"
check "no keychain verb named a path outside the test's folder" absent "$T/security-refused"
check "and nothing opened an app, signalled a process, or changed privacy or power settings" absent "$T/other-asked"

echo
check "the real login keychain list was not changed by any of this" [ "$(security list-keychains 2>/dev/null)" = "$KEYCHAINS_BEFORE" ]
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
