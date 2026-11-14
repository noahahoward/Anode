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
# keychain list is compared before and after. `sudo` becomes nobody: it writes down what it was asked and, for a
# path inside this test's folder only, does what was asked as the user the test runs as (a stand-in helper it is told
# to run, `rm -f`); `pmset` answers `pmset -g` from a file of the test's own and writes down anything else; `tccutil`
# writes down what it was asked. The terminal is not the test's either: the scripts are run with nothing on stdin.
#
# The uninstaller also names /Applications/Anode.app, an absolute path no HOME can stand in for; it takes the folder
# from ANODE_SYSTEM_APPLICATIONS_DIR, which run_anode checks is this test's own, so the real one is never looked at.
# It also READS Anode's settings (`defaults read`, which the stub passes to the real tool, and which does not go by
# HOME), to see whether Charge Control left something; it takes the domain from ANODE_SETTINGS_DOMAIN, which run_anode
# checks is a path of this test's own, so the real account's settings are never read.
#
# Two nets keep a mistake in this file itself off the real machine, and section 0 tries both with bad input, so a
# change that weakens either fails there: a static check of this file's own text (a line that runs a script or a
# tool other than through the one door is refused before anything runs), and the runtime guard in run_anode. Under
# both, the stubs are first on PATH and HOME, the folders and the ANODE_* variables the scripts read, and the working
# directory, are the test's own for the whole file, so a spelling the static check cannot read still lands on a stub.
# `ps` shows only the processes the tests started, so the Anode really running on the Mac that runs them is never seen.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
FULL=0; [ "${1:-}" = "--full" ] && FULL=1
T="$(mktemp -d)"
REAL_PIDS=()
OUTSIDE=""   # (a folder of the self-test's that is not the test's own; see section 0)
trap 'for p in ${REAL_PIDS[@]+"${REAL_PIDS[@]}"}; do kill "$p" 2>/dev/null; done; rm -rf "$T" ${OUTSIDE:+"$OUTSIDE"}' EXIT

PASS=0; FAIL=0
ok()    { PASS=$((PASS + 1)); printf '    ok    %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf '    FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/          | /'; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
check_all() {  # check_all WHAT CMD… [-- CMD…]…: it is ok when every command (a function or a test, each with its arguments, set apart by --) succeeds
  local what="$1" a failed=0; shift
  local -a cmd=()
  for a in "$@" "--"; do
    if [ "$a" = "--" ]; then
      if [ ${#cmd[@]} -gt 0 ]; then "${cmd[@]}" || failed=1; fi
      cmd=()
    else
      cmd+=("$a")
    fi
  done
  if [ "$failed" = 0 ]; then ok "$what"; else bad "$what"; fi
}
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
# And the other root-owned places the uninstaller names by an absolute path: the helper's binary, the sudoers rule Always
# Stay Awake installs, and the helper's socket. Places of the test's own that are not there (a scenario that needs them
# points the variables at ones it made), so where an Anode helper is installed on this Mac changes nothing.
export ANODE_PRIVILEGED_HELPER_TOOLS_DIR="$T/no-helper-tools"
export ANODE_SUDOERS_DIR="$T/no-sudoers.d"
export ANODE_FAN_SOCKET="$T/no-fan-socket/anode-fan.sock"
# And the settings the uninstaller reads to see whether Charge Control may have left something: a settings file of the
# test's own that is not there, so no scenario reads the real account's. A scenario that needs settings points it at a
# file it wrote (SCENARIO_ENV=(ANODE_SETTINGS_DOMAIN=…)).
export ANODE_SETTINGS_DOMAIN="$T/no-settings/com.anode.settings"

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
      case "\$a" in -*[sS]*) echo "\$*" >> "$T/security-asked"; exit 0 ;; esac
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
for tool in open pkill killall; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 0\n' "$tool" "$T/other-asked" > "$T/shim/$tool"
done
# pmset: only the read `pmset -g` is answered, and from a file of the test's own ($T/pmset-sleepdisabled; 0 when it is not
# there), never from this Mac. Anything else is written down in pmset-asked (which a scenario may clear) and in
# pmset-asked-all (which nothing clears, and which the end of this file reads), and not run. The uninstaller changes power
# settings only through sudo (whose stub sets the same file), so a line in pmset-asked is a call it must not make.
cat > "$T/shim/pmset" <<EOF
#!/bin/sh
if [ "\$#" = 1 ] && [ "\$1" = "-g" ]; then
  echo "System-wide power settings:"
  echo "Currently in use:"
  echo " standby              1"
  printf ' SleepDisabled\t\t%s\n' "\$(cat "$T/pmset-sleepdisabled" 2>/dev/null || echo 0)"
  exit 0
fi
echo "\$*" >> "$T/pmset-asked"
echo "\$*" >> "$T/pmset-asked-all"
exit 0
EOF
# tccutil: writes down what it was asked (tccutil-asked, which a scenario may clear; tccutil-asked-all, which nothing clears,
# and which the end of this file reads) and changes nothing. It fails, as the real one does for an
# identifier it cannot reset, for each identifier named (one a line) in $T/tccutil-fails.
cat > "$T/shim/tccutil" <<EOF
#!/bin/sh
echo "\$*" >> "$T/tccutil-asked"
echo "\$*" >> "$T/tccutil-asked-all"
if [ -f "$T/tccutil-fails" ] && grep -qxF -- "\$3" "$T/tccutil-fails"; then
  echo "tccutil: Failed to reset \$2 approval status for \$3" >&2
  exit 70
fi
exit 0
EOF
# sudo: becomes nobody. It writes down what it was asked (sudo-asked, a line a call: the arguments) and, while
# $T/sudo-fails exists (a password that was refused or cancelled), fails on every call and runs nothing. Otherwise it does
# what it was asked only for paths inside this test's folder, as the user the test runs as: `rm -f` of them, a program
# there (the stand-in helper a scenario made), `-v`, a launchctl bootout (written down, not run) and
# `pmset -a disablesleep 0|1` (which sets the file the pmset stub answers from). Anything else, and any path outside this
# folder, is refused, written to sudo-refused, and fails the run (the end of this file looks for that file).
cat > "$T/shim/sudo" <<EOF
#!/bin/sh
under_t() { case "\$1" in "$T"/*) return 0 ;; esac; return 1; }
refuse() { echo "\$*" >> "$T/sudo-refused"; exit 1; }
echo "\$*" >> "$T/sudo-asked"
if [ -e "$T/sudo-fails" ]; then echo "sudo: Sorry, try again." >&2; exit 1; fi
case "\$1" in
  -v) exit 0 ;;
  rm)
    shift
    for a in "\$@"; do
      case "\$a" in -f) ;; *) under_t "\$a" || refuse "rm \$*" ;; esac
    done
    exec /bin/rm "\$@" ;;
  launchctl)
    [ "\$2" = bootout ] || refuse "\$*"
    exit 0 ;;
  pmset)
    [ "\$2 \$3 \$4" = "-a disablesleep 0" ] || [ "\$2 \$3 \$4" = "-a disablesleep 1" ] || refuse "\$*"
    echo "\$4" > "$T/pmset-sleepdisabled"
    exit 0 ;;
  *)
    if under_t "\$1" && [ -x "\$1" ]; then exec "\$@"; fi
    refuse "\$*" ;;
esac
EOF
chmod +x "$T"/shim/*
# END STUBS

# ── Everything from here on lands on the stubs, whatever a scenario does ────
# The stubs are first on PATH and HOME and the folders the scripts can be pointed at are the test's own for the WHOLE
# file, not only inside run_anode: a line that gets past the static check below (a spelling it cannot read) can run a
# script or a tool, and it then reaches a stub and a throwaway home instead of this Mac's account. The ANODE_* variables
# the scripts read are cleared, so a caller's environment (ANODE_SRC, say, which puts the installer's clone anywhere)
# cannot send a script somewhere real. The working directory is the test's folder.
export PATH="$T/shim:$PATH"
mkdir -p "$T/home-file"; export HOME="$T/home-file"
unset ANODE_SRC ANODE_REPO ANODE_ADHOC ANODE_KEEP_TERMINAL ANODE_NO_ACTOOL ANODE_SLOW_BUILD ANODE_NO_LAUNCH ANODE_NO_SUDO ANODE_SUDO_WITHOUT_TERMINAL
cd "$T" || exit 1

# ── The one door ────────────────────────────────────────────────────────────
# Every run of install.sh, uninstall.sh, update.sh, build-app.sh or make-signing-identity.sh in this file goes through
# run_anode. It puts the stubs first on PATH itself, checks inside the very environment the script will get (with
# `command -v`, the same lookup the script does) that each guarded tool resolves to a stub, that HOME and the folders
# the scripts can be pointed at are the test's own, that the working directory is, and that a checkout a script is
# pointed at is (update.sh pulls the one it is given, or the one it sits in; install.sh clones ANODE_REPO), and sets
# ANODE_NO_LAUNCH=1 so a real built app is never run to put back this Mac's charge settings; only when the scenario
# has put a stub app in place (a script marked "# anode-test-stub") is it left unset, so that the restore can be asked
# of it. A check that fails ends the whole run (GUARD_STOPS names what is stopped; the self-test below points it
# at a stand-in, to see that the guard really stops).
#
#   SCENARIO_ENV   extra NAME=value pairs for the next run (ANODE_REPO=…); SCENARIO_PATH   directories put before the stubs.
# BEGIN GUARD
exec 3>&2   # the real stderr: a scenario captures the script's own with 2>&1, and the reason for stopping must not go there
GUARDED_TOOLS="osascript getconf defaults launchctl security open pkill killall tccutil pmset sudo"
# (ANODE_SETTINGS_DOMAIN is a settings file and ANODE_FAN_SOCKET a socket, rather than folders, and have to be inside the test's own all the same.)
GUARDED_FOLDERS="HOME ANODE_SHARED_CHARGE_DIR ANODE_LAUNCH_DAEMONS_DIR ANODE_SYSTEM_APPLICATIONS_DIR ANODE_SETTINGS_DOMAIN"
GUARDED_FOLDERS="$GUARDED_FOLDERS ANODE_PRIVILEGED_HELPER_TOOLS_DIR ANODE_SUDOERS_DIR ANODE_FAN_SOCKET"
# Folders that may be empty (the script then uses its own default, which is inside HOME) but are the test's when set.
OPTIONAL_FOLDERS="ANODE_SRC ANODE_REPO"
T_PHYSICAL="$(cd "$T" && pwd -P)"
SCENARIO_ENV=(); SCENARIO_PATH=""
guard_fail() {
  printf '✗ %s; refusing to run, so nothing real is touched\n' "$1" >&3
  kill -TERM "${GUARD_STOPS:-$$}"   # the main shell, also from inside $( ): the whole run ends here
  return 1
}
inside_t() { case "$1" in "$T"/*|"$T_PHYSICAL"/*) return 0 ;; esac; return 1; }
run_anode() {   # run_anode HOME SCRIPT [ARGS…]: prints the script's output; returns its exit status
  local home="$1" script="$2"; shift 2
  local app="$home/Applications/Anode.app/Contents/MacOS/AnodeApp" got tool var checkout
  local -a e
  e=(HOME="$home" PATH="${SCENARIO_PATH:+$SCENARIO_PATH:}$T/shim:$PATH" ${SCENARIO_ENV[@]+"${SCENARIO_ENV[@]}"})
  for tool in $GUARDED_TOOLS; do
    got="$(env -u BASH_ENV -u ENV "${e[@]}" bash -c 'command -v "$1"' _ "$tool" 2>/dev/null)"
    [ "$got" = "$T/shim/$tool" ] || { guard_fail "the $tool stub is not what the script would run (found '$got')"; return 1; }
  done
  got="$(env -u BASH_ENV -u ENV "${e[@]}" bash -c 'command -v ps' 2>/dev/null)"
  inside_t "$got" || { guard_fail "ps is '$got', not a stand-in inside the test's own folder (the real Anode would be seen)"; return 1; }
  for var in $GUARDED_FOLDERS; do
    got="$(env -u BASH_ENV -u ENV "${e[@]}" bash -c 'printf %s "${!1:-}"' _ "$var" 2>/dev/null)"
    inside_t "$got" || { guard_fail "$var is '$got', which is not inside the test's own folder"; return 1; }
  done
  for var in $OPTIONAL_FOLDERS; do
    got="$(env -u BASH_ENV -u ENV "${e[@]}" bash -c 'printf %s "${!1:-}"' _ "$var" 2>/dev/null)"
    [ -z "$got" ] || inside_t "$got" || { guard_fail "$var is '$got', which is not inside the test's own folder"; return 1; }
  done
  inside_t "$(pwd -P)/" || { guard_fail "the working directory is '$(pwd -P)', not inside the test's own folder"; return 1; }
  case "$script" in
    */update.sh)
      # It pulls the checkout it is given, or else the one it sits in: this Mac's own, for $ROOT/update.sh.
      checkout="${1:-$(dirname "$script")}"
      inside_t "$(cd "$checkout" 2>/dev/null && pwd -P)/" \
        || { guard_fail "update.sh would pull '$checkout', which is not inside the test's own folder"; return 1; } ;;
    */install.sh)
      got="$(env -u BASH_ENV -u ENV "${e[@]}" bash -c 'printf %s "${ANODE_REPO:-}"' _ 2>/dev/null)"
      inside_t "$got" || { guard_fail "ANODE_REPO is '$got': install.sh would clone from somewhere real"; return 1; } ;;
  esac
  # Nothing on stdin: whether the person running the tests has a terminal must not change which way a script goes.
  if [ -f "$app" ] && grep -qx '# anode-test-stub' "$app" 2>/dev/null; then
    env -u BASH_ENV -u ENV -u ANODE_NO_LAUNCH "${e[@]}" bash "$script" "$@" < /dev/null
  else
    env -u BASH_ENV -u ENV "${e[@]}" ANODE_NO_LAUNCH=1 bash "$script" "$@" < /dev/null
  fi
}
# The same, read from the text of the file it is given (this one), so a scenario added later cannot forget. It fails
# closed: outside the marked regions (the stubs, this guard, and the self-test below, which holds bad lines on purpose),
#   * a line that names one of the scripts has to be a comment or a call of the form `run_anode "$VAR" "…/script.sh"`
#     with nothing else on it that runs a program, and has to name no more scripts than it has calls: a second call
#     after `;`, `&&` or `||`, or a direct one, is one the guard does not see. The name is read with quotes and
#     backslashes taken out, so "uninstall"".sh" and unin\\stall.sh are read as uninstall.sh;
#   * no word in a path names a script by a pattern (`unins*`, `uninstal?.sh`, `*.sh`);
#   * no `run_anode` is called with a script that is not named in the call, and none of run_anode, guard_fail or
#     static_check is defined again;
#   * no line starts a shell, `exec`, `source` or `eval` of its own, and no script name is put together from a
#     variable (`$s.sh`);
#   * defaults, launchctl, open, pkill, killall, osascript, security, tccutil, pmset, sudo, or the app binary, is not
#     a command by its bare name anywhere in the body (call a stub by its explicit path, as the section on the stubs
#     does).
# What it cannot read stays possible: a script path put together at run time without any of its name on the line (a
# glob over a bare `*`, a name read from a file), a copy made under another name and then run, a tool called from a
# script the scenario wrote. Those still land on the stubs, in the throwaway home, with the test's folders, because
# of the exports above.
static_check() {  # static_check FILE: prints the lines it does not accept; fails if there are any
  awk '
    function count(str, re,    n) { n = 0; while (match(str, re) && RLENGTH > 0) { n++; str = substr(str, RSTART + RLENGTH) } return n }
    function globre(g,    out, i, c, inb) {
      out = "^"; inb = 0
      for (i = 1; i <= length(g); i++) {
        c = substr(g, i, 1)
        if (inb) { out = out c; if (c == "]") inb = 0 }
        else if (c == "[") { if (index(substr(g, i + 1), "]") > 0) { out = out c; inb = 1 } else out = out "[[]" }
        else if (c == "*") out = out ".*"
        else if (c == "?") out = out "."
        else if (c == ".") out = out "[.]"
        else if (c == "-") out = out "[-]"
        else out = out c
      }
      return out "$"
    }
    function globs_a_script(text,    t, n, parts, i, comp, k, lits, j, ch) {
      t = text; gsub(/[;|&()<>=,:{}]/, " ", t)
      n = split(t, parts, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        comp = parts[i]; sub(/^.*\//, "", comp)
        if (comp !~ /[*?[]/) continue
        lits = 0
        for (j = 1; j <= length(comp); j++) { ch = substr(comp, j, 1); if (ch !~ /[*?]/ && ch != "[" && ch != "]") lits++ }
        if (lits < 3) continue
        for (k = 1; k <= NS; k++) if (SCRIPTS[k] ~ globre(comp)) return 1
      }
      return 0
    }
    BEGIN { NS = split("install.sh uninstall.sh update.sh build-app.sh make-signing-identity.sh", SCRIPTS, " ") }
    /^# BEGIN (GUARD|STUBS|SELFTEST)/ { skip = 1; next }
    /^# END (GUARD|STUBS|SELFTEST)/   { skip = 0; next }
    skip || /^[[:space:]]*#/ { next }
    {
      line = $0
      flat = line; gsub(/"/, "", flat); gsub(/\047/, "", flat); gsub(/\\/, "", flat)
      scripts_re = "(^|[^A-Za-z0-9_-])(install|uninstall|update|build-app|make-signing-identity)[.]sh"
      names = count(flat, scripts_re)
      calls = count(line, "run_anode +\"[$][A-Za-z_0-9{}]+\" +\"[^\"]*(install|uninstall|update|build-app|make-signing-identity)[.]sh\"")
      runs = count(line, "(^|[^A-Za-z0-9_])run_anode([^A-Za-z0-9_]|$)")
      other = (line ~ /(^|[^A-Za-z0-9_\/.-])(bash|sh|zsh|dash|ksh|source|eval|exec|env|command|xargs|nohup|open|PATH=|HOME=)([[:space:]]|$|=)/)
      bad = 0
      if (names > 0 && (names != calls || other)) bad = 1
      else if (runs > calls) bad = 1
      else if (line ~ /(^|[;&|({`]|\$\(|(then|do|else)[[:space:]])[[:space:]]*(bash|sh|zsh|dash|ksh|source|eval|exec)[[:space:]]/) bad = 1
      else if (flat ~ /\$\{?[A-Za-z_][A-Za-z_0-9]*\}?[.]sh/) bad = 1
      else if (globs_a_script(flat)) bad = 1
      else if (line ~ /(^|[^A-Za-z0-9_])(function[[:space:]]+)?(run_anode|guard_fail|static_check)[[:space:]]*[(][)]/ \
               || line ~ /(^|[;&|({][[:space:]]*)(alias|readonly|unset[[:space:]]+-f)[[:space:]]+(run_anode|guard_fail|static_check)/) bad = 1
      else {
        cmd = line
        while (cmd ~ /^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*=[A-Za-z0-9_.\/:-]*[[:space:]]+/) sub(/^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*=[A-Za-z0-9_.\/:-]*[[:space:]]+/, "", cmd)
        if (cmd ~ /(^|[;&|(`]|\$\(|[[:space:]](then|do|else|exec|command|env|xargs|nohup|sudo)[[:space:]])[[:space:]]*"?(defaults|launchctl|open|pkill|killall|osascript|security|tccutil|pmset|sudo)"?([[:space:]]|$)/ \
            || cmd ~ /(^|[;&|`]|\$\()[[:space:]]*"?[^[:space:]"]*AnodeApp"?([[:space:])]|$)/ \
            || line ~ /\/(usr|bin|sbin)(\/(bin|sbin))?\/(defaults|launchctl|open|pkill|killall|osascript|security|tccutil|pmset|sudo)([[:space:]]|$)/) bad = 1
      }
      if (bad) { print NR ": " $0; any = 1 }
    }
    END { exit any }' "$1"
}
# END GUARD
SELF="$ROOT/Tests/$(basename "$0")"
if ! BAD_LINES="$(static_check "$SELF")"; then
  echo "✗ a line runs one of the scripts, or a shell, or a tool that is not a stub, other than through the one door:" >&2
  printf '%s\n' "$BAD_LINES" >&2
  exit 1
fi
KEYCHAINS_BEFORE="$("$T/shim/security" list-keychains 2>/dev/null)"

# ═══ 0. the safety nets themselves ══════════════════════════════════════════
# The static check and the runtime guard are what keep this file off the real machine, so each has to be seen to catch
# what it is for: a copy of this file with static_check made to accept everything, or guard_fail made a no-op, must fail
# here, not pass quietly. The bad lines are held below as data and are only ever read by awk; the guard is tried with
# stand-in scripts that write a marker file and nothing else, one of them named update.sh in a folder that is not this
# test's, so even a guard that fails to stop a run runs nothing real.
# BEGIN SELFTEST
echo "0. The safety nets stop what they are there to stop"
cat > "$T/selftest-bad-lines" <<'BADLINES'
bash "$ROOT/uninstall.sh" --yes
"$ROOT/uninstall.sh" --yes
$ROOT/uninstall.sh --yes
sh -c "$ROOT/update.sh"
source "$ROOT/uninstall.sh"
. "$ROOT/uninstall.sh"
eval "$cmd"
run_anode "$H" "$ROOT/uninstall"".sh" --yes
run_anode "$H" "$ROOT/uninst""all.sh" --yes
run_anode "$H" "$ROOT/uninstall"'.sh' --yes
run_anode "$H" "$ROOT/unin\stall.sh" --yes
run_anode "$H" "$ROOT"/unins* --yes
run_anode "$H" "$ROOT/unins"* --yes
run_anode "$H" "$ROOT/uninstal?.sh" --yes
run_anode "$H" "$ROOT"/*.sh
run_anode "$H" "$ROOT"/uninstall.s[h]
run_anode "$H" "$ROOT/$s".sh --yes
run_anode "$H" "$ROOT/${s}.sh"
cp "$ROOT/uninstall.sh" "$T/u" && run_anode "$H" "$T/u"
ln -s "$ROOT/uninstall.sh" "$T/u"
run_anode "$H" "$ROOT/uninstall.sh" ; "$ROOT/uninstall.sh"
run_anode "$H" "$ROOT/uninstall.sh" && bash "$ROOT/update.sh"
run_anode "$H" "$ROOT/uninstall.sh" || "$ROOT/update.sh"
run_anode "$H" "$ROOT/uninstall.sh" ; run_anode "$H" "$T/some-copy"
run_anode "$H" "$T/some-copy"
run_anode() { "$@"; }
function run_anode { "$@"; }
guard_fail() { :; }
static_check() { :; }
unset -f run_anode
alias run_anode=true
defaults delete com.anode.settings
  defaults write com.anode.settings key -int 1
sudo rm -rf /
launchctl bootout gui/501/x
open -a Anode
pkill -x AnodeApp
killall AnodeApp
osascript -e 'quit app "Anode"'
security delete-keychain x
tccutil reset All dev.anode.app
pmset schedule wake "11/13/26 07:00:00"
OUT="$(security list-keychains -s /tmp/x 2>&1)"
if true; then defaults delete com.anode.settings; fi
FOO=bar defaults delete com.anode.settings
echo x | sudo tee /etc/x
/usr/bin/defaults delete com.anode.settings
/usr/bin/security list-keychains -s /tmp/x
"$H/Applications/Anode.app/Contents/MacOS/AnodeApp" --restore-charge-settings
x=$("$ROOT/Anode.app/Contents/MacOS/AnodeApp")
BADLINES
cat > "$T/selftest-good-lines" <<'GOODLINES'
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
run_anode "$1" "$ROOT/make-signing-identity.sh" >/dev/null 2>&1
OUT="$(run_anode "$H" "$H/Developer/Anode/uninstall.sh" --yes 2>&1 || true)"
check "defaults read goes to the real tool" read_reaches_real_defaults
"$T/shim/defaults" delete "$NEVER" >/dev/null 2>&1
KEYCHAINS_BEFORE="$("$T/shim/security" list-keychains 2>/dev/null)"
check "--data asks for the settings to be cleared" grep -qx "delete com.anode.settings" "$T/defaults-asked"
rm -f "$T/security-refused"
GOODLINES
selftest_lines() {  # selftest_lines FILE WANT: static_check each line of FILE alone; WANT is "flagged" or "accepted"
  local file="$1" want="$2" line status wrong=""
  while IFS= read -r line; do
    printf '%s\n' "$line" > "$T/selftest-one-line"
    static_check "$T/selftest-one-line" >/dev/null 2>&1; status=$?
    if [ "$want" = flagged ] && [ "$status" -eq 0 ]; then wrong="$wrong$line"$'\n'; fi
    if [ "$want" = accepted ] && [ "$status" -ne 0 ]; then wrong="$wrong$line"$'\n'; fi
  done < "$file"
  [ -z "$wrong" ] && return 0
  printf '%s' "$wrong" > "$T/selftest-wrong"; return 1
}
if selftest_lines "$T/selftest-good-lines" accepted; then ok "the static check accepts the lines a scenario is made of"
else bad "the static check refuses lines it should accept" "$(cat "$T/selftest-wrong")"; fi
if selftest_lines "$T/selftest-bad-lines" flagged; then ok "the static check flags every bad spelling (quotes, globs, variables, a second call, copies, redefinitions, bare tools)"
else bad "the static check let these through" "$(cat "$T/selftest-wrong")"; fi

# The guard, with stand-ins. GUARD_STOPS points guard_fail at a sleeping process of the self-test's own instead of the
# main shell: the run it stops is the one that would have been this file.
OUTSIDE="$(mktemp -d)"   # a folder that is not this test's
mkdir -p "$T/home-selftest" "$T/probe-dir"
printf '#!/bin/sh\n: > "%s"\n' "$T/probe-ran" > "$T/probe-script"
printf '#!/bin/sh\n: > "%s"\n' "$T/probe-ran" > "$OUTSIDE/update.sh"
printf '#!/bin/sh\n: > "%s"\n' "$T/probe-ran" > "$T/probe-dir/update.sh"
printf '#!/bin/sh\n: > "%s"\n' "$T/probe-ran" > "$T/probe-dir/install.sh"
mkdir -p "$T/decoy"; printf '#!/bin/sh\nexit 0\n' > "$T/decoy/defaults"; chmod +x "$T/decoy/defaults"
# A decoy for each of the tools that reach the person's account or become root: a folder with only that tool in it.
for tool in sudo tccutil pmset; do
  mkdir -p "$T/decoy-$tool"; printf '#!/bin/sh\nexit 0\n' > "$T/decoy-$tool/$tool"; chmod +x "$T/decoy-$tool/$tool"
done
must_stop() {  # must_stop WHAT TRY…: the guard has to stop the run, and the script must not have run
  local what="$1" victim alive=0 i; shift
  rm -f "$T/probe-ran"
  { sleep 60 & victim=$!; } 2>/dev/null
  ( GUARD_STOPS="$victim"; "$@" ) >/dev/null 2>&1 3>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$victim" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$victim" 2>/dev/null && alive=1
  kill "$victim" 2>/dev/null; wait "$victim" 2>/dev/null
  if [ "$alive" = 0 ] && [ ! -e "$T/probe-ran" ]; then ok "$what: the run is stopped"; else bad "$what: the run was let through"; fi
} 2>/dev/null
must_go() {  # must_go WHAT TRY…: an ordinary run is not refused
  local what="$1"; shift
  rm -f "$T/probe-ran"
  ( "$@" ) >/dev/null 2>&1 3>/dev/null
  if [ -e "$T/probe-ran" ]; then ok "$what: the run goes through"; else bad "$what: the run was refused"; fi
}
try_ordinary()          { run_anode "$T/home-selftest" "$T/probe-script"; }
try_update_inside()     { run_anode "$T/home-selftest" "$T/probe-dir/update.sh" "$T/probe-dir"; }
try_install_inside()    { SCENARIO_ENV=(ANODE_REPO="$T/probe-dir"); run_anode "$T/home-selftest" "$T/probe-dir/install.sh"; }
try_bad_home()          { run_anode "/Users/not-the-tests-home" "$T/probe-script"; }
try_no_stubs()          { SCENARIO_PATH="$T/decoy"; run_anode "$T/home-selftest" "$T/probe-script"; }
try_shared_outside()    { export ANODE_SHARED_CHARGE_DIR="$OUTSIDE"; run_anode "$T/home-selftest" "$T/probe-script"; }
try_daemons_outside()   { export ANODE_LAUNCH_DAEMONS_DIR="$OUTSIDE"; run_anode "$T/home-selftest" "$T/probe-script"; }
try_system_apps_outside() { export ANODE_SYSTEM_APPLICATIONS_DIR="$OUTSIDE"; run_anode "$T/home-selftest" "$T/probe-script"; }
try_settings_outside()  { export ANODE_SETTINGS_DOMAIN="$OUTSIDE/com.anode.settings"; run_anode "$T/home-selftest" "$T/probe-script"; }
try_settings_real()     { export ANODE_SETTINGS_DOMAIN="com.anode.settings"; run_anode "$T/home-selftest" "$T/probe-script"; }
try_settings_unset()    { unset ANODE_SETTINGS_DOMAIN; run_anode "$T/home-selftest" "$T/probe-script"; }
try_helper_tools_outside() { export ANODE_PRIVILEGED_HELPER_TOOLS_DIR="$OUTSIDE"; run_anode "$T/home-selftest" "$T/probe-script"; }
try_helper_tools_unset()   { unset ANODE_PRIVILEGED_HELPER_TOOLS_DIR; run_anode "$T/home-selftest" "$T/probe-script"; }
try_sudoers_outside()   { export ANODE_SUDOERS_DIR="$OUTSIDE"; run_anode "$T/home-selftest" "$T/probe-script"; }
try_sudoers_unset()     { unset ANODE_SUDOERS_DIR; run_anode "$T/home-selftest" "$T/probe-script"; }
try_socket_outside()    { export ANODE_FAN_SOCKET="$OUTSIDE/anode-fan.sock"; run_anode "$T/home-selftest" "$T/probe-script"; }
try_socket_unset()      { unset ANODE_FAN_SOCKET; run_anode "$T/home-selftest" "$T/probe-script"; }
try_no_sudo_stub()      { SCENARIO_PATH="$T/decoy-sudo"; run_anode "$T/home-selftest" "$T/probe-script"; }
try_no_tccutil_stub()   { SCENARIO_PATH="$T/decoy-tccutil"; run_anode "$T/home-selftest" "$T/probe-script"; }
try_no_pmset_stub()     { SCENARIO_PATH="$T/decoy-pmset"; run_anode "$T/home-selftest" "$T/probe-script"; }
try_src_outside()       { export ANODE_SRC="$OUTSIDE/src"; run_anode "$T/home-selftest" "$T/probe-script"; }
try_repo_outside()      { SCENARIO_ENV=(ANODE_REPO="$OUTSIDE"); run_anode "$T/home-selftest" "$T/probe-script"; }
try_install_no_repo()   { run_anode "$T/home-selftest" "$T/probe-dir/install.sh"; }
try_cwd_outside()       { cd "$OUTSIDE" || return 1; run_anode "$T/home-selftest" "$T/probe-script"; }
try_update_own_dir()    { run_anode "$T/home-selftest" "$OUTSIDE/update.sh"; }
try_update_given_dir()  { run_anode "$T/home-selftest" "$T/probe-dir/update.sh" "$OUTSIDE"; }
must_go   "an ordinary run"                                          try_ordinary
must_go   "update.sh on a checkout of the test's own"                 try_update_inside
must_go   "install.sh with a clone source of the test's own"          try_install_inside
must_stop "a HOME that is not the test's"                            try_bad_home
must_stop "a PATH where the stubs are not first"                     try_no_stubs
must_stop "a shared charge folder outside the test's folder"         try_shared_outside
must_stop "a LaunchDaemons folder outside the test's folder"         try_daemons_outside
must_stop "a system Applications folder outside the test's folder"   try_system_apps_outside
must_stop "a settings file outside the test's folder"                try_settings_outside
must_stop "the real settings domain by name"                         try_settings_real
must_stop "no settings file named at all (the script's default is the real domain)" try_settings_unset
must_stop "a helper tools folder outside the test's folder"           try_helper_tools_outside
must_stop "no helper tools folder named at all (the script's default is the real one)" try_helper_tools_unset
must_stop "a sudoers folder outside the test's folder"                try_sudoers_outside
must_stop "no sudoers folder named at all (the script's default is the real one)" try_sudoers_unset
must_stop "a socket path outside the test's folder"                   try_socket_outside
must_stop "no socket path named at all (the script's default is the real one)" try_socket_unset
must_stop "a PATH where the sudo stub is not first"                   try_no_sudo_stub
must_stop "a PATH where the tccutil stub is not first"                try_no_tccutil_stub
must_stop "a PATH where the pmset stub is not first"                  try_no_pmset_stub
must_stop "ANODE_SRC outside the test's folder"                      try_src_outside
must_stop "ANODE_REPO outside the test's folder"                     try_repo_outside
must_stop "install.sh with no clone source of the test's own"        try_install_no_repo
must_stop "a working directory outside the test's folder"            try_cwd_outside
must_stop "update.sh sitting in a checkout that is not the test's"   try_update_own_dir
must_stop "update.sh given a checkout that is not the test's"        try_update_given_dir
# END SELFTEST

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
check "and says the other way: install again, switch Charge Control on, then Install Anode Helper…" \
                                                            has "install Anode again, switch Charge Control on and press Install Anode Helper…"
check "and no longer says the button is there with Charge Control off" \
                                                            hasnt "press Install Anode Helper… in Charge Control"
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
      # (The program is this test's own stand-in, compiled from hold.c, not the app; it is run by a name held in a
      # variable because the static check refuses the app binary as a command.)
      local stand_in=./AnodeApp
      ( cd "$(dirname "$bin")" && "$stand_in" 60 "$pidfile" ) &
    else
      "$bin" 60 "$pidfile" &
    fi
    local waited=0
    while [ ! -s "$pidfile" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done   # (the shell's own sleep: there is no stub for it)
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
# The places root owns, as folders of the test's own (the uninstaller takes each from an ANODE_… variable, which run_anode
# holds inside this test's folder), so no scenario reads or writes the real /Library, /etc or /var.
ROOT_DIR="$T/root"
ROOT_PATHS=(ANODE_LAUNCH_DAEMONS_DIR="$ROOT_DIR/LaunchDaemons" ANODE_PRIVILEGED_HELPER_TOOLS_DIR="$ROOT_DIR/PrivilegedHelperTools"
            ANODE_SUDOERS_DIR="$ROOT_DIR/sudoers.d" ANODE_FAN_SOCKET="$ROOT_DIR/anode-fan.sock")
HELPER_PLIST="$ROOT_DIR/LaunchDaemons/dev.anode.app.fanhelper.plist"
HELPER_BIN="$ROOT_DIR/PrivilegedHelperTools/dev.anode.app.fanhelper"
HELPER_SOCKET="$ROOT_DIR/anode-fan.sock"
KEEP_RULE="$ROOT_DIR/sudoers.d/anode-keep-awake"
UNINSTALL_ARGS=()
root_reset() {  # root_reset: nothing root-owned is installed, sudo works, SleepDisabled is 0, nothing has been asked of any tool
  rm -rf "$ROOT_DIR"; mkdir -p "$ROOT_DIR/LaunchDaemons" "$ROOT_DIR/PrivilegedHelperTools" "$ROOT_DIR/sudoers.d"
  rm -f "$T/sudo-asked" "$T/sudo-fails" "$T/pmset-sleepdisabled" "$T/pmset-asked" "$T/helper-ran" "$T/tccutil-asked" "$T/tccutil-fails"
  UNINSTALL_ARGS=()
}
root_helper() {  # root_helper [removes|leaves] [EXIT-STATUS]: the helper's launchd job, its socket and its binary. The binary
  # stands in for AnodeHelper: it writes down how it was run (helper-ran) and takes away what the real one takes away (its
  # job, its socket and itself), or, with "leaves", nothing, and ends with the status given.
  : > "$HELPER_PLIST"; : > "$HELPER_SOCKET"
  if [ "${1:-removes}" = removes ]; then
    printf '#!/bin/sh\necho "$*" >> "%s"\nrm -f "%s" "%s" "$0"\nexit %s\n' "$T/helper-ran" "$HELPER_PLIST" "$HELPER_SOCKET" "${2:-0}" > "$HELPER_BIN"
  else
    printf '#!/bin/sh\necho "$*" >> "%s"\nexit %s\n' "$T/helper-ran" "${2:-0}" > "$HELPER_BIN"
  fi
  chmod +x "$HELPER_BIN"
}
root_helper_plist_only() { : > "$HELPER_PLIST"; : > "$HELPER_SOCKET"; }   # a job and a socket, and no binary to run
root_rule() { printf 'someone ALL=(root) NOPASSWD: pmset\n' > "$KEEP_RULE"; }
sleep_disabled() { printf '%s\n' "$1" > "$T/pmset-sleepdisabled"; }
# The uninstaller with those places, and the terminal standing in (there is nothing on stdin: see run_anode); extra
# NAME=value pairs follow (ANODE_SUDO_WITHOUT_TERMINAL=0 takes the stand-in away). Sets OUT and ROOT_STATUS.
root_run() {  # root_run HOME [NAME=value…]
  local h="$1"; shift
  SCENARIO_ENV=("${ROOT_PATHS[@]}" ANODE_SUDO_WITHOUT_TERMINAL=1 "$@")
  OUT="$(run_anode "$h" "$ROOT/uninstall.sh" --yes ${UNINSTALL_ARGS[@]+"${UNINSTALL_ARGS[@]}"} 2>&1)"; ROOT_STATUS=$?
  SCENARIO_ENV=()
}
listing_part() { printf '%s\n' "$OUT" | awk '/^ Uninstalling Anode$/ { seen = 1; next } seen && /^[^ ]/ { n++; next } n == 1 { print } n >= 2 { exit }'; }   # the list before the question: between the rules that close the title and the list
in_listing() { listing_part | grep -qF -- "$1"; }
yourself_part() { printf '%s\n' "$OUT" | sed -n '/Run these yourself/,$p'; }   # what is printed for the person to run, and after it
says_to_run() { yourself_part | grep -qF -- "$1"; }
says_not_to_run() { ! says_to_run "$1"; }
sudo_calls() { cat "$T/sudo-asked" 2>/dev/null; }
sudo_called_exactly() { [ "$(sudo_calls)" = "$(printf '%s\n' "$@")" ]; }   # sudo_called_exactly CALL…: these calls, in this order, and no others
sudo_never_called() { [ ! -e "$T/sudo-asked" ]; }
sudo_call_line() { grep -nxF -- "$1" "$T/sudo-asked" 2>/dev/null | head -1 | cut -d: -f1; }
root_reset; root_helper
H="$(new_home 17)"; mkdir -p "$H/Applications/Anode.app"
root_run "$H" ANODE_SUDO_WITHOUT_TERMINAL=0
check "tells the helper's own uninstall"                    has "sudo $HELPER_BIN --uninstall"
check "and that it reconnects the charger first"            has "reconnects the charger if Anode had switched it off, then removes itself"
check "and does not tell to delete the helper by hand"      hasnt "sudo rm -f $HELPER_PLIST"
check "nor to boot it out first"                            hasnt "launchctl bootout system"
check "and, with no password to be had, runs nothing as root" sudo_never_called
H="$(new_home 18)"; mkdir -p "$H/Applications/Anode.app"
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
check "with no helper installed it says nothing about one"  hasnt "Anode helper is still installed"

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

echo "6f. No installed copy can be asked: said when Charge Control may have left something, and not otherwise"
# The settings the uninstaller reads here are files of the test's own, one for each state, each at a path of its own (the
# settings service remembers a file it has read). The real account's settings are never read: run_anode holds
# ANODE_SETTINGS_DOMAIN to this test's folder, and a scenario that needs settings points it at one of these.
settings_file() {  # settings_file NAME KEYS: a settings file holding KEYS (plist keys and values); prints its path
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>%s</dict></plist>\n' "$2" > "$T/settings-$1.plist"
  printf '%s\n' "$T/settings-$1.plist"
}
SETTINGS_OFF="$(settings_file off '<key>anode.chargeControlEnabled</key><false/><key>anode.chargeLimit</key><integer>80</integer>')"
SETTINGS_ON="$(settings_file on '<key>anode.chargeControlEnabled</key><true/>')"
SETTINGS_CUT="$(settings_file cut '<key>anode.chargeCutUnconfirmed</key><true/>')"
SETTINGS_PENDING="$(settings_file pending '<key>anode.chargeStartPending</key><true/>')"
SETTINGS_RECORD="$(settings_file record '<key>anode.chargeRestoreRecord</key><string>{"limit":90}</string>')"
uninstall_with_settings() {  # uninstall_with_settings HOME SETTINGS-FILE [ARGS...]: the uninstaller reading that file
  local h="$1" file="$2"; shift 2
  SCENARIO_ENV=(ANODE_SETTINGS_DOMAIN="$file")
  OUT="$(run_anode "$h" "$ROOT/uninstall.sh" --yes "$@" 2>&1 || true)"
  SCENARIO_ENV=()
}
shared_record_empty() { mkdir -p "$ANODE_SHARED_CHARGE_DIR"; : > "$ANODE_SHARED_CHARGE_DIR/charge-control.json"; }
shared_record_held()  { mkdir -p "$ANODE_SHARED_CHARGE_DIR"; printf '{"version":1}' > "$ANODE_SHARED_CHARGE_DIR/charge-control.json"; }
# A bundle that cannot be run: the stub, its marker in place (so the run is not kept from running apps), made not executable.
broken_app() { stub_app "$1" 0; chmod -x "$1/Applications/Anode.app/Contents/MacOS/AnodeApp"; }
NOBODY="No installed Anode could be asked to put macOS's own charge settings back"
KEPT="kept     Anode's settings: Anode could not put macOS's own charge settings back"
says_nobody_was_asked() { has "$NOBODY"; }
keeps_the_settings() {  # keeps_the_settings HOME: --data left the settings alone, and said so, and the rest went
  has "$KEPT" && absent "$T/defaults-asked" && present "$1/Library/Preferences/com.anode.settings.plist" \
    && absent "$1/Library/Application Support/Anode/history.sqlite"
}

# Nothing to suggest Charge Control left anything: silent, and --data clears the settings as it always did.
shared_record_empty
for kind in none broken; do
  for state in absent off; do
    if [ "$state" = off ]; then file="$SETTINGS_OFF"; else file="$ANODE_SETTINGS_DOMAIN"; fi
    rm -f "$T/defaults-asked"
    H="$(new_home "f-quiet-$kind-$state")"; data_home "$H"
    [ "$kind" = broken ] && broken_app "$H"
    uninstall_with_settings "$H" "$file" --data
    check "$kind copy, settings $state, no shared record: nothing is said" hasnt "No installed Anode"
    check "  and nothing is said about keeping settings"         hasnt "kept     Anode's settings"
    check "  --data clears the settings as before"               grep -qx "delete com.anode.settings" "$T/defaults-asked"
    check "  and the app is removed"                             absent "$H/Applications/Anode.app"
  done
done

# A shared record that holds something: said, and --data keeps the settings (and the record).
for kind in none broken; do
  shared_record_held; rm -f "$T/defaults-asked"
  H="$(new_home "f-record-$kind")"; data_home "$H"
  [ "$kind" = broken ] && broken_app "$H"
  OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes --data 2>&1 || true)"
  check "$kind copy, a shared record that holds something: says nobody could be asked" says_nobody_was_asked
  check "  and where to change a limit by hand"                  has "System Settings → Battery"
  check "  no helper is installed, so no sudo line"              hasnt "sudo /Library/PrivilegedHelperTools"
  check "  --data keeps the settings, with the usual reason, and removes the rest" keeps_the_settings "$H"
  check "  and keeps the shared record"                          present "$ANODE_SHARED_CHARGE_DIR/charge-control.json"
  check "  the app is still removed"                             absent "$H/Applications/Anode.app"
  check "  and it is said that Anode was removed"                has "Anode has been removed"
done

# The settings say Charge Control is switched on, or carry a note that something was left.
shared_record_empty
for state in on cut pending record; do
  case "$state" in on) file="$SETTINGS_ON" ;; cut) file="$SETTINGS_CUT" ;; pending) file="$SETTINGS_PENDING" ;; record) file="$SETTINGS_RECORD" ;; esac
  for kind in none broken; do
    rm -f "$T/defaults-asked"
    H="$(new_home "f-$state-$kind")"; data_home "$H"
    [ "$kind" = broken ] && broken_app "$H"
    uninstall_with_settings "$H" "$file" --data
    check "$kind copy, settings '$state': says nobody could be asked" says_nobody_was_asked
    check "  --data keeps the settings, and removes the rest"    keeps_the_settings "$H"
  done
done
rm -f "$T/defaults-asked"
H="$(new_home f-on-without-data)"; data_home "$H"
uninstall_with_settings "$H" "$SETTINGS_ON"
check "without --data it is still said"                          says_nobody_was_asked
check "and nothing is said about keeping settings (they are kept anyway)" hasnt "kept     Anode's settings"
check "and nothing was cleared"                                  absent "$T/defaults-asked"

# The helper's launchd job is there: the way to reconnect a charger it may have left cut is given too.
mkdir -p "$T/launch-daemons"; : > "$T/launch-daemons/dev.anode.app.fanhelper.plist"
H="$(new_home f-helper)"
SCENARIO_ENV=(ANODE_SETTINGS_DOMAIN="$SETTINGS_ON" ANODE_LAUNCH_DAEMONS_DIR="$T/launch-daemons")
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1 || true)"
SCENARIO_ENV=()
check "with the helper installed it says what reconnects the charger" \
                                                                 has "Anode's helper reconnects it: run 'sudo /Library/PrivilegedHelperTools/dev.anode.app.fanhelper --uninstall'"
H="$(new_home f-no-helper)"
uninstall_with_settings "$H" "$SETTINGS_ON"
check "with none installed it gives no sudo line"                hasnt "sudo /Library/PrivilegedHelperTools"

# A copy that can be asked is asked, whatever the evidence, and nothing is said about nobody being asked.
shared_record_held; rm -f "$T/defaults-asked"
H="$(new_home f-asked)"; stub_app "$H" 0; data_home "$H"
uninstall_with_settings "$H" "$SETTINGS_ON" --data
check "a copy that can be run is asked"                          grep -qx -- "--restore-charge-settings" "$H/restore-asked"
check "and nothing is said about nobody being asked"             hasnt "No installed Anode"
shared_record_empty

echo "6g. What only root can remove (the helper, Always Stay Awake's permission, a Mac told not to sleep) goes through sudo, asked for once"
# sudo here is the stub: it writes down each call and does it only inside this test's folder (see the stubs). The stand-in
# helper takes away what the real one does, so "removed" can be told from "still there".
ASKS="The Terminal will ask for the Mac's password once."
YOURSELF="Run these yourself"
root_reset; root_helper; root_rule; sleep_disabled 0
H="$(new_home g-all)"; mkdir -p "$H/Applications/Anode.app"
root_run "$H"
check "the helper's own uninstall is the one command for the helper, and the rule goes after it" \
                                                            sudo_called_exactly -v "$HELPER_BIN --uninstall" "rm -f $KEEP_RULE"
check "the helper was run with --uninstall and nothing else" [ "$(cat "$T/helper-ran")" = "--uninstall" ]
check "it says plainly that the Terminal asks for the password once" has "$ASKS"
check_all "and lists the exact commands first"                  has "sudo $HELPER_BIN --uninstall" -- has "sudo rm -f $KEEP_RULE"
check_all "the helper's job, socket and binary are gone, and said" [ ! -e "$HELPER_PLIST" ] -- [ ! -e "$HELPER_SOCKET" ] -- [ ! -e "$HELPER_BIN" ] \
                                                            -- has "removed  $HELPER_PLIST" -- has "removed  $HELPER_SOCKET" -- has "removed  $HELPER_BIN"
check_all "the rule is gone, and said"                          absent "$KEEP_RULE" -- has "removed  $KEEP_RULE"
check "nothing is left to run by hand"                      hasnt "$YOURSELF"
check "the rest was removed as well"                        absent "$H/Applications/Anode.app"
check "and the exit status is 0"                            [ "$ROOT_STATUS" = 0 ]
check "the script itself removed nothing of the helper's (no rm of it, no bootout)" sudo_called_exactly -v "$HELPER_BIN --uninstall" "rm -f $KEEP_RULE"
check_all "the list before the question names what needs the password" in_listing "$HELPER_PLIST" -- in_listing "$HELPER_BIN" -- in_listing "$HELPER_SOCKET" -- in_listing "$KEEP_RULE"

root_reset; root_helper
H="$(new_home g-helper-only)"
root_run "$H"
check "a helper and no rule: sudo is asked once, for the helper only" sudo_called_exactly -v "$HELPER_BIN --uninstall"
check "the rule is not mentioned"                           hasnt "anode-keep-awake"

root_reset; root_helper leaves; root_rule
H="$(new_home g-leaves)"
root_run "$H"
check_all "a helper uninstall that leaves its files: the script removes none of them itself" present "$HELPER_PLIST" -- present "$HELPER_BIN" -- present "$HELPER_SOCKET"
check "…it only asked for the helper's own uninstall, then for the rule" sudo_called_exactly -v "$HELPER_BIN --uninstall" "rm -f $KEEP_RULE"
check_all "what is still there is said, by path"                has "left     $HELPER_BIN" -- has "left     $HELPER_PLIST"
check_all "and the command for it is printed for the person to run" has "$YOURSELF" -- says_to_run "sudo $HELPER_BIN --uninstall"
check_all "the rule that went is not printed again"             absent "$KEEP_RULE" -- says_not_to_run "sudo rm -f $KEEP_RULE"
check "the exit status is still 0"                          [ "$ROOT_STATUS" = 0 ]

# AnodeHelper --uninstall exits 1 when it could not confirm the charger is connected, after removing everything.
root_reset; root_helper removes 1; root_rule
H="$(new_home g-helper-exit-1)"
root_run "$H"
check "a helper that ends with status 1 but removed everything is not taken for a failure" sudo_called_exactly -v "$HELPER_BIN --uninstall" "rm -f $KEEP_RULE"
check "the rule is still removed"                           absent "$KEEP_RULE"
check "and nothing is printed for the person to run"        hasnt "$YOURSELF"

# A job and a socket with no binary to run: the job is booted out and the two files removed, all through sudo.
root_reset; root_helper_plist_only
H="$(new_home g-plist-only)"
root_run "$H"
check "a job and no binary: bootout, then the removal of the job and the socket" \
                                                            sudo_called_exactly -v "launchctl bootout system/dev.anode.app.fanhelper" "rm -f $HELPER_PLIST $HELPER_SOCKET"
check_all "they are gone, and said"                             [ ! -e "$HELPER_PLIST" ] -- [ ! -e "$HELPER_SOCKET" ] -- has "removed  $HELPER_PLIST" -- has "removed  $HELPER_SOCKET"
check "the helper's own uninstall is not asked for (there is nothing to run)" hasnt "--uninstall"

root_reset; root_rule
H="$(new_home g-rule-only)"
root_run "$H"
check "the rule alone: removed through sudo"                sudo_called_exactly -v "rm -f $KEEP_RULE"
check_all "…and said, with nothing about the helper"            has "removed  $KEEP_RULE" -- hasnt "--uninstall"

# Nothing root-owned, nothing to say about it, and no password asked for.
root_reset
H="$(new_home g-nothing)"; mkdir -p "$H/Applications/Anode.app"
root_run "$H"
check "nothing root-owned and SleepDisabled 0: sudo is never called" sudo_never_called
check_all "and nothing about a password is printed"             hasnt "password" -- hasnt "sudo"
check "the rest is removed all the same"                    absent "$H/Applications/Anode.app"
check "and the exit status is 0"                            [ "$ROOT_STATUS" = 0 ]

# A Mac that macOS says cannot sleep (a crashed Anode can leave it so). It is Anode's to put back only where Always Stay
# Awake was ever set up, which is what its rule in the sudoers folder says: without the rule Anode could not have set it.
root_reset; sleep_disabled 1
H="$(new_home g-sleep-not-ours)"
root_run "$H"
check "SleepDisabled 1 with no Always Stay Awake rule: not Anode's, so sudo is never called" sudo_never_called
check "and macOS still reads 1"                             [ "$("$T/shim/pmset" -g | awk '$1 == "SleepDisabled" { print $2 }')" = 1 ]
root_reset; root_rule; sleep_disabled 1
H="$(new_home g-sleep)"
root_run "$H"
check "SleepDisabled 1 with the rule: the rule goes, then the sleep setting, both through sudo" \
                                                            sudo_called_exactly -v "rm -f $KEEP_RULE" "pmset -a disablesleep 0"
check_all "macOS reads 0 afterwards, and it is said"            [ "$("$T/shim/pmset" -g | awk '$1 == "SleepDisabled" { print $2 }')" = 0 ] -- has "reset    SleepDisabled"
check "it says plainly that the password is asked once"     has "$ASKS"
root_reset; root_helper; root_rule; sleep_disabled 1
H="$(new_home g-all-three)"
root_run "$H"
check "everything at once, in the order: the helper, the rule, the sleep setting" \
                                                            sudo_called_exactly -v "$HELPER_BIN --uninstall" "rm -f $KEEP_RULE" "pmset -a disablesleep 0"
root_reset; root_rule; sleep_disabled 1
H="$(new_home g-sleep-0)"
root_run "$H" ANODE_NO_SUDO=1
check_all "SleepDisabled 1 with sudo off: the pmset command is printed" says_to_run "sudo pmset -a disablesleep 0"

# sudo that fails: a password that is refused or cancelled.
root_reset; root_helper; root_rule; sleep_disabled 1; : > "$T/sudo-fails"
H="$(new_home g-fails)"; mkdir -p "$H/Applications/Anode.app" "$H/Library/Preferences"
root_run "$H"
check "sudo that fails is asked once, and no more is tried"  sudo_called_exactly -v
check_all "nothing root-owned was removed"                      present "$HELPER_BIN" -- present "$HELPER_PLIST" -- present "$KEEP_RULE"
check_all "the commands are printed for the person to run, the rule's too" has "$YOURSELF" -- says_to_run "sudo $HELPER_BIN --uninstall" -- says_to_run "sudo rm -f $KEEP_RULE" -- says_to_run "sudo pmset -a disablesleep 0"
check "it says why they were not run"                       has "password"
check "the rest was still removed"                          absent "$H/Applications/Anode.app"
check "and the exit status is the same as without sudo"     [ "$ROOT_STATUS" = 0 ]
root_reset; root_helper_plist_only; : > "$T/sudo-fails"
H="$(new_home g-fails-plist)"
root_run "$H"
check_all "a failed sudo with a job and no binary: bootout and the removal are printed" \
                                                            says_to_run "sudo launchctl bootout system/dev.anode.app.fanhelper" -- says_to_run "sudo rm -f $HELPER_PLIST $HELPER_SOCKET"
check_all "and the files are still there"                       present "$HELPER_PLIST" -- present "$HELPER_SOCKET"

# sudo switched off, and a window with no keyboard for the password: never called, the commands printed.
root_reset; root_helper; root_rule
H="$(new_home g-no-sudo)"; mkdir -p "$H/Applications/Anode.app"
root_run "$H" ANODE_NO_SUDO=1
check "ANODE_NO_SUDO=1: sudo is never called"               sudo_never_called
check_all "the commands are printed, the rule's too"            has "$YOURSELF" -- says_to_run "sudo $HELPER_BIN --uninstall" -- says_to_run "sudo rm -f $KEEP_RULE"
check "and nothing is said to be asked for"                 hasnt "$ASKS"
check_all "nothing root-owned was touched, the rest was removed" present "$HELPER_BIN" -- present "$KEEP_RULE" -- absent "$H/Applications/Anode.app"
check "the exit status is 0"                                [ "$ROOT_STATUS" = 0 ]
root_reset; root_helper; root_rule
H="$(new_home g-no-terminal)"
root_run "$H" ANODE_SUDO_WITHOUT_TERMINAL=0
check "no terminal on stdin: sudo is never called"          sudo_never_called
check_all "and the commands are printed, the rule's too"        has "$YOURSELF" -- says_to_run "sudo $HELPER_BIN --uninstall" -- says_to_run "sudo rm -f $KEEP_RULE"

# The helper reconnects the charger, so a restore that failed is the very case it must still be run for; --data does not change it.
root_reset; root_helper; root_rule
H="$(new_home g-restore-failed)"; stub_app "$H" 1; data_home "$H"
UNINSTALL_ARGS=(--data)
root_run "$H"
check "after a restore that failed the helper's uninstall is still run" sudo_called_exactly -v "$HELPER_BIN --uninstall" "rm -f $KEEP_RULE"
check "and Anode's settings are kept, as before"            present "$H/Library/Preferences/com.anode.settings.plist"

# An Anode that is still running stops the uninstall with nothing removed, and nothing is asked of sudo.
root_reset; root_helper; root_rule
H="$(new_home g-running)"; stub_app "$H" 0
ps_reset; printf '%s\n' "$H/Applications/Anode.app/Contents/MacOS/AnodeApp" > "$T/running-bins"
SCENARIO_PATH="$T/shim-running"
root_run "$H"
SCENARIO_PATH=""; ps_reset
check_all "a running Anode: the uninstall stops, and sudo is never called" [ "$ROOT_STATUS" != 0 ] -- sudo_never_called
check_all "and the helper and the rule are still there"         present "$HELPER_BIN" -- present "$KEEP_RULE"
root_reset

echo "6h. What macOS keeps for Anode that was still left behind: WebKit caches, privacy approvals, other settings domains, crash records"
IDS="dev.anode.app dev.noah.anode dev.noah.betterstats"
WEBKIT_KINDS="GPU Networking WebContent"
webkit_caches() {  # webkit_caches: the three WebKit folders for each of Anode's identifiers, and look-alikes that are not Anode's
  rm -rf "$T/cache"; mkdir -p "$T/cache"
  local id kind
  for id in $IDS; do
    for kind in $WEBKIT_KINDS; do mkdir -p "$T/cache/com.apple.WebKit.$kind+$id"; done
  done
  mkdir -p "$T/cache/com.apple.WebKit.GPU+com.example.other" "$T/cache/com.apple.WebKit.GPU+dev.anode.app.extra" \
           "$T/cache/com.apple.WebKit.WebContent+dev.anode.application" "$T/cache/com.apple.WebKit.Networking"
}
webkit_all_gone() {
  local id kind
  for id in $IDS; do
    for kind in $WEBKIT_KINDS; do [ ! -e "$T/cache/com.apple.WebKit.$kind+$id" ] || return 1; done
  done
  return 0
}
tcc_asked_exactly() { [ "$(cat "$T/tccutil-asked" 2>/dev/null)" = "$(printf '%s\n' "$@")" ]; }
RESET_SAYS="Accessibility, Screen Recording and the other approvals were reset: a reinstalled Anode will ask for them again."
reset_says_once() { [ "$(printf '%s\n' "$OUT" | grep -cF -- "$RESET_SAYS")" = 1 ]; }
fresh_run() {  # fresh_run HOME [ARGS]: nothing of the last scenario's asks or answers is left, then the uninstaller runs
  local h="$1"; shift
  rm -f "$T/tccutil-asked" "$T/tccutil-fails" "$T/defaults-asked" "$T/launchctl-asked"
  OUT="$(run_anode "$h" "$ROOT/uninstall.sh" --yes "$@" 2>&1)"; ROOT_STATUS=$?
}
root_reset
webkit_caches
H="$(new_home h-webkit)"
fresh_run "$H"
check "the three WebKit folders of every identifier are gone, without --data" webkit_all_gone
check_all "look-alikes are not touched"                      present "$T/cache/com.apple.WebKit.GPU+com.example.other" -- present "$T/cache/com.apple.WebKit.GPU+dev.anode.app.extra" -- present "$T/cache/com.apple.WebKit.WebContent+dev.anode.application" -- present "$T/cache/com.apple.WebKit.Networking"
check "each is said"                                         has "removed  $T/cache/com.apple.WebKit.GPU+dev.anode.app"
check "tccutil reset All was asked once for each identifier, and for nothing else" \
                                                             tcc_asked_exactly "reset All dev.anode.app" "reset All dev.noah.anode" "reset All dev.noah.betterstats"
check_all "each reset is said, in the script's style"        has "reset    privacy approvals: dev.anode.app" -- has "reset    privacy approvals: dev.noah.anode" -- has "reset    privacy approvals: dev.noah.betterstats"
check "and the one line that says what it means is said once" reset_says_once
check "the list before the question says the approvals are reset" in_listing "privacy approvals macOS holds for Anode"
check "the exit status is 0"                                 [ "$ROOT_STATUS" = 0 ]
# One that fails says nothing for itself; the others are said; the line is there while any was reset.
printf '%s\n' dev.noah.anode > "$T/tccutil-fails.keep"
rm -f "$T/tccutil-asked" "$T/defaults-asked" "$T/launchctl-asked"; cp "$T/tccutil-fails.keep" "$T/tccutil-fails"
H="$(new_home h-tcc-one-fails)"
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1)"
check_all "an identifier that cannot be reset is not said"  hasnt "reset    privacy approvals: dev.noah.anode" -- has "reset    privacy approvals: dev.anode.app"
check "and all three were still tried"                       tcc_asked_exactly "reset All dev.anode.app" "reset All dev.noah.anode" "reset All dev.noah.betterstats"
check "the closing line is still said once"                  reset_says_once
printf '%s\n' dev.anode.app dev.noah.anode dev.noah.betterstats > "$T/tccutil-fails"
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1)"
check_all "when every reset fails nothing is said about approvals" hasnt "reset    privacy approvals" -- hasnt "$RESET_SAYS"
rm -f "$T/tccutil-fails" "$T/tccutil-fails.keep"
# A running Anode stops everything before any of it.
H="$(new_home h-running)"; stub_app "$H" 0; webkit_caches
ps_reset; printf '%s\n' "$H/Applications/Anode.app/Contents/MacOS/AnodeApp" > "$T/running-bins"
rm -f "$T/tccutil-asked"
SCENARIO_PATH="$T/shim-running"
OUT="$(run_anode "$H" "$ROOT/uninstall.sh" --yes 2>&1)" || ROOT_STATUS=$?
SCENARIO_PATH=""; ps_reset
check_all "an Anode that is still running: no approval is reset, no cache removed" absent "$T/tccutil-asked" -- present "$T/cache/com.apple.WebKit.GPU+dev.anode.app"
# The login agents are still booted out, and only they.
H="$(new_home h-agent)"; mkdir -p "$H/Library/LaunchAgents" "$H/Library/Application Support/CrashReporter"
: > "$H/Library/LaunchAgents/dev.anode.app.loginagent.plist"; : > "$H/Library/Application Support/CrashReporter/AnodeApp_1234.plist"
fresh_run "$H" --data
check "the login agent is booted out by its label"            grep -qxF -- "bootout gui/$(id -u)/dev.anode.app.loginagent" "$T/launchctl-asked"
check "a crash record that is a .plist is not taken for a launchd job" [ "$(grep -c . "$T/launchctl-asked")" = 1 ]

echo "6i. --data: the other settings domains Anode's app and tool run under, the crash records, and what the tests made"
NEW_DOMAINS="AnodeApp anode BetterStatsApp betterstats"
domain_files() {  # domain_files HOME: the settings files of the four domains
  mkdir -p "$1/Library/Preferences"
  local d; for d in $NEW_DOMAINS; do : > "$1/Library/Preferences/$d.plist"; done
}
crash_home() {  # crash_home HOME: crash records of every name, in the folders macOS keeps them, and look-alikes
  local c="$1/Library/Application Support/CrashReporter" d="$1/Library/Logs/DiagnosticReports"
  mkdir -p "$c" "$d/Retired"
  local n
  for n in AnodeApp AnodeHelper anode BetterStatsApp betterstats; do
    : > "$c/${n}_0A1B2C3D.plist"; : > "$d/${n}-2026-11-12-101010.ips"; : > "$d/Retired/${n}-2026-11-11-090909.ips"
  done
  : > "$c/anode-busy_9F8E.plist"; : > "$c/anode-decoy_7D6C.plist"
  # (not Anode's: a name that only ends or contains one of the names, one with no _ or - after it, another case, another program)
  : > "$c/Canode_x.plist"; : > "$c/AnodeAppX_1.plist"; : > "$c/anodeapp_1.plist"; : > "$c/Safari_1.plist"
  : > "$d/MyAnodeApp-1.ips"; : > "$d/AnodeApp.ips"; : > "$d/Safari-2026-11-12-101010.ips"; : > "$d/Retired/Canode-1.ips"
}
crash_gone() {  # crash_gone HOME: every record of Anode's names is gone
  local c="$1/Library/Application Support/CrashReporter" d="$1/Library/Logs/DiagnosticReports" n
  for n in AnodeApp AnodeHelper anode BetterStatsApp betterstats; do
    [ ! -e "$c/${n}_0A1B2C3D.plist" ] && [ ! -e "$d/${n}-2026-11-12-101010.ips" ] && [ ! -e "$d/Retired/${n}-2026-11-11-090909.ips" ] || return 1
  done
  [ ! -e "$c/anode-busy_9F8E.plist" ] && [ ! -e "$c/anode-decoy_7D6C.plist" ]
}
crash_look_alikes_kept() {  # crash_look_alikes_kept HOME
  local c="$1/Library/Application Support/CrashReporter" d="$1/Library/Logs/DiagnosticReports" f
  for f in "$c/Canode_x.plist" "$c/AnodeAppX_1.plist" "$c/anodeapp_1.plist" "$c/Safari_1.plist" \
           "$d/MyAnodeApp-1.ips" "$d/AnodeApp.ips" "$d/Safari-2026-11-12-101010.ips" "$d/Retired/Canode-1.ips"; do
    [ -e "$f" ] || return 1
  done
}
crash_all_there() { crash_look_alikes_kept "$1" && [ -e "$1/Library/Application Support/CrashReporter/AnodeApp_0A1B2C3D.plist" ] && [ -e "$1/Library/Logs/DiagnosticReports/Retired/betterstats-2026-11-11-090909.ips" ]; }
tests_made() {  # tests_made HOME: settings files the test suite leaves in Preferences, and look-alikes
  mkdir -p "$1/Library/Preferences"
  : > "$1/Library/Preferences/com.anode.tests.one.plist"; : > "$1/Library/Preferences/com.anode.tests.adhoc.two.1A2B.plist"
  : > "$1/Library/Preferences/com.anode.testsX.plist"; : > "$1/Library/Preferences/com.example.anode.tests.plist"
  : > "$1/Library/Preferences/com.apple.finder.plist"
}
deleted_domain() { grep -qxF -- "delete $1" "$T/defaults-asked"; }
all_new_domains_cleared() { local d; for d in $NEW_DOMAINS; do deleted_domain "$d" || return 1; done; }
all_new_domain_files_gone() { local d; for d in $NEW_DOMAINS; do [ ! -e "$1/Library/Preferences/$d.plist" ] || return 1; done; }
all_new_domain_files_there() { local d; for d in $NEW_DOMAINS; do [ -e "$1/Library/Preferences/$d.plist" ] || return 1; done; }

H="$(new_home i-data)"; stub_app "$H" 0; data_home "$H"; domain_files "$H"; crash_home "$H"; tests_made "$H"
fresh_run "$H" --data
check "AnodeApp, anode, BetterStatsApp and betterstats are cleared"  all_new_domains_cleared
check "and their files are removed"                           all_new_domain_files_gone "$H"
check_all "each is said"                                          has "removed  settings: AnodeApp" -- has "removed  settings: betterstats"
check "the crash records of Anode's names are removed (the folders macOS keeps, and Retired)" crash_gone "$H"
check "records that only look like them are NOT removed"      crash_look_alikes_kept "$H"
check_all "the settings files the tests made are removed"         [ ! -e "$H/Library/Preferences/com.anode.tests.one.plist" ] -- [ ! -e "$H/Library/Preferences/com.anode.tests.adhoc.two.1A2B.plist" ]
check_all "and no other settings file is"                         present "$H/Library/Preferences/com.anode.testsX.plist" -- present "$H/Library/Preferences/com.example.anode.tests.plist" -- present "$H/Library/Preferences/com.apple.finder.plist"
check "the test leftovers are said as a count"                has "settings files made by Anode's tests"
check "the exit status is 0"                                  [ "$ROOT_STATUS" = 0 ]
check_all "the list before the question names the crash records and says how many test files" in_listing "$H/Library/Logs/DiagnosticReports/AnodeApp-2026-11-12-101010.ips" -- in_listing "settings files made by Anode's tests"

H="$(new_home i-kept)"; stub_app "$H" 0; data_home "$H"; domain_files "$H"; crash_home "$H"; tests_made "$H"
fresh_run "$H"
check "without --data the four domains are not cleared"       absent "$T/defaults-asked"
check "and their files are kept"                              all_new_domain_files_there "$H"
check "the crash records are kept"                            crash_all_there "$H"
check "the settings files the tests made are kept"            present "$H/Library/Preferences/com.anode.tests.one.plist"

H="$(new_home i-restore-failed)"; stub_app "$H" 1; data_home "$H"; domain_files "$H"; crash_home "$H"; tests_made "$H"
fresh_run "$H" --data
check "a restore that failed keeps the four domains too: not cleared" absent "$T/defaults-asked"
check "and their files"                                       all_new_domain_files_there "$H"
check "the message names them among the domains to clear later" has "AnodeApp anode BetterStatsApp betterstats"
check_all "the crash records and the test leftovers go all the same" crash_gone "$H" -- [ ! -e "$H/Library/Preferences/com.anode.tests.one.plist" ]

H="$(new_home i-clean)"
fresh_run "$H" --data
check_all "a Mac with none of it says nothing about crash records or test settings" hasnt "crash reports" -- hasnt "made by Anode's tests"
check "and the exit status is 0"                              [ "$ROOT_STATUS" = 0 ]

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
check "and none of them reached the real settings"            [ -z "$("$T/shim/defaults" domains | tr ',' '\n' | grep -F "$NEVER")" ]
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
                 "default-keychain -s $T/k.keychain-db" "list-keychains -s $T/k.keychain-db" "set-keychain-password x" "frobnicate" \
                 "list-keychains -sd user" "list-keychains -ds user" "default-keychain -dS user" "login-keychain -S $T/k.keychain-db"; do
  # shellcheck disable=SC2086
  "$T/shim/security" $verb_args >/dev/null 2>&1
  check "security $verb_args is written down, not run"        grep -qxF -- "$verb_args" "$T/security-asked"
done
check "none of them changed the keychain search list"         [ "$("$T/shim/security" list-keychains 2>/dev/null)" = "$KEYCHAINS_BEFORE" ]
"$T/shim/security" create-keychain -p x "$T/placeholder.keychain-db" >/dev/null 2>&1
check "a keychain made inside the test's folder is a placeholder file" grep -q anode-test-keychain "$T/placeholder.keychain-db"
placeholder_has_identity() { local out; out="$("$T/shim/security" find-identity -p codesigning "$T/placeholder.keychain-db")"; printf '%s' "$out" | grep -q "Anode Local Signing"; }
check "…which the identity lookup sees"                       placeholder_has_identity
"$T/shim/security" delete-keychain "$T/placeholder.keychain-db" >/dev/null 2>&1
check "…and delete-keychain takes away"                       absent "$T/placeholder.keychain-db"
check "no keychain verb named a path outside the test's folder" absent "$T/security-refused"
# What the scenarios above made sudo, pmset and tccutil do, looked at before this section calls them on purpose.
only_anode_identifiers() {  # every tccutil call in every scenario was `reset All <one of Anode's own identifiers>`, and there were some
  [ -s "$T/tccutil-asked-all" ] || return 1
  ! grep -vxE 'reset All (dev\.anode\.app|dev\.noah\.anode|dev\.noah\.betterstats)' "$T/tccutil-asked-all" | grep -q .
}
check "no scenario made sudo touch a path outside the test's folder or run a command it does not know" absent "$T/sudo-refused"
check "no scenario changed a power setting except through sudo"   absent "$T/pmset-asked-all"
check "tccutil was only ever asked to reset Anode's own identifiers" only_anode_identifiers
# sudo, pmset and tccutil: what each is asked is written down, and nothing is done outside this test's folder.
rm -f "$T/sudo-asked" "$T/sudo-fails" "$T/sudo-refused" "$T/pmset-asked" "$T/pmset-asked-all" "$T/pmset-sleepdisabled" "$T/tccutil-asked" "$T/tccutil-asked-all" "$T/tccutil-fails"
refused_by_sudo() {  # refused_by_sudo ARGS…: sudo fails on them and writes them down in sudo-refused
  "$T/shim/sudo" "$@" >/dev/null 2>&1 && return 1
  grep -qxF -- "$*" "$T/sudo-refused"
}
for verb_args in "-S" "rm -f /nonexistent-installer-tests/never" "launchctl bootstrap system /nonexistent-installer-tests/never.plist" \
                 "-S rm -f /nonexistent-installer-tests/never" "pmset -a sleep 0" "pmset -a disablesleep 2" "/nonexistent-installer-tests/never --uninstall"; do
  # shellcheck disable=SC2086
  check "sudo $verb_args is refused and written down"          refused_by_sudo $verb_args
done
rm -f "$T/sudo-refused"   # the refusals just made on purpose
"$T/shim/sudo" pmset -a disablesleep 1 >/dev/null 2>&1
sleep_reads() { "$T/shim/pmset" -g | awk '$1 == "SleepDisabled" { print $2 }'; }
check "sudo pmset -a disablesleep 1 sets what the pmset stub answers" [ "$(sleep_reads)" = 1 ]
"$T/shim/sudo" pmset -a disablesleep 0 >/dev/null 2>&1
check "…and 0 sets it back"                                   [ "$(sleep_reads)" = 0 ]
touch "$T/sudo-fails"
sudo_ok() { "$T/shim/sudo" -v >/dev/null 2>&1; }
sudo_fails() { ! sudo_ok; }
check "a sudo whose password is refused fails, even for -v"   sudo_fails
rm -f "$T/sudo-fails"
check "…and without that file it does not"                    sudo_ok
check "sudo never touched a path outside the test's folder"   absent "$T/sudo-refused"
"$T/shim/pmset" -a disablesleep 1 >/dev/null 2>&1
check "pmset with a verb that changes something is written down, not run" grep -qxF -- "-a disablesleep 1" "$T/pmset-asked"
rm -f "$T/pmset-asked"
printf '%s\n' dev.anode.app > "$T/tccutil-fails"
tcc_resets() { "$T/shim/tccutil" reset All "$1" >/dev/null 2>&1; }
tcc_fails() { ! tcc_resets "$1"; }
check "tccutil fails for an identifier named in its failure file"  tcc_fails dev.anode.app
check "…and only for it"                                      tcc_resets dev.noah.anode
rm -f "$T/tccutil-asked" "$T/tccutil-fails"
check "and nothing opened an app or signalled a process"      absent "$T/other-asked"

echo
check "the real login keychain list was not changed by any of this" [ "$("$T/shim/security" list-keychains 2>/dev/null)" = "$KEYCHAINS_BEFORE" ]
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
