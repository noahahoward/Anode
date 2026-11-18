#!/bin/bash
# Run on THIS Mac what GitHub's CI used to run, and a bit more. Free, and the only machine that counts: the app
# is AppKit, IOKit and private frameworks throughout, so it builds and runs nowhere else.
#
#   ./test.sh                build every product (release), then the whole test suite
#   ./test.sh --quick        the test suite only (what the pre-push hook runs)
#   ./test.sh --full         everything above, plus a REAL install in a new folder next to this checkout (a sibling of
#                            Anode), then the installed app is started as a test copy and driven through its own windows:
#                            Settings, the Uninstall button, the Terminal window it opens (which closes itself). Looks for
#                            errors in what the install prints and for anything the uninstall left behind, and that this
#                            Mac's own Anode did not change. Needs Accessibility for the Terminal or editor it is run from
#                            (ANODE_TEST_NO_UI=1 runs the uninstaller directly instead). Compiles the app again, a few
#                            minutes, and shows windows on screen. Run it before a push.
#   ./test.sh --install-hook make git run --quick before every push; `git push --no-verify` skips it once
#
# The suite includes the installer and uninstaller tests (Tests/installer-tests.sh), which never touch this
# Mac's own install, keychain or settings: they run in a home of their own (a temporary folder; for --full, a new one next to
# the checkout), and --full looks at this Mac's own Anode before and after to be sure.
#
# The suite runs as `swift test --parallel`: each test case in a process of its own, all the Mac's cores at once.
# A test that hangs (a socket nobody answers, a run loop nobody turns) would hang the whole run, and XCTest's own
# `executionTimeAllowance` is not enforced by `swift test` (measured), so this watches the test processes: one that
# has been running for ANODE_TEST_LIMIT seconds (default 240; the slowest honest one takes a few) ends the run, and the
# failure names it. Ending a run is TERM to the whole process tree, then KILL to what is still there 5 seconds later:
# tests in this package set TERM to ignored (HelperSignals.routeToStop), and a main thread that hangs never handles it.
# test.sh does not wait for anything that can no longer exit.
# A hang outside a test case (the build, a class's set-up or tear-down) shows no test case running, so the whole
# run also has a limit: ANODE_TEST_TOTAL_LIMIT seconds (default 1800), and the failure says where it stopped.
# ANODE_TEST_FILTER=<name> passes `--filter <name>` to `swift test`.
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
case "$MODE" in
  ""|--quick|--full) ;;
  --install-hook)
    git config core.hooksPath .githooks
    echo "✓ git will run ./test.sh --quick before every push (git push --no-verify skips it once)"
    exit 0 ;;
  -h|--help) sed -n 2,29p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown option: $MODE (try --help)" >&2; exit 2 ;;
esac

step() { printf '\n› %s\n' "$1"; }
START=$SECONDS

LOG="$(mktemp)"
STALLED="$(mktemp)"
TIMED_OUT="$(mktemp)"
BUILD_LOG="$(mktemp)"
LIMIT="${ANODE_TEST_LIMIT:-240}"
TOTAL_LIMIT="${ANODE_TEST_TOTAL_LIMIT:-1800}"
TEST_PID=""; WATCH_PID=""; OVERALL_PID=""; BUILD_PID=""
SUITE_NAMES=(); SUITE_PIDS=(); SUITE_LOGS=()   # the shell suites run beside the XCTest run (below)
KILL_GRACE=5

# kill_tree PID: the process and everything it started. TERM to all of them, and KILL to the ones still there after
# KILL_GRACE seconds. The tree is listed first and once: killing a parent hands its children to launchd, and they would
# not be found again.
tree_pids() {  # tree_pids PID: the process and its descendants, one a line
  local child
  echo "$1"
  for child in $(pgrep -P "$1" 2>/dev/null || true); do tree_pids "$child"; done
}
kill_tree() {
  local pids p waited=0 alive
  pids="$(tree_pids "$1")"
  for p in $pids; do kill -TERM "$p" 2>/dev/null || true; done
  while [ "$waited" -lt "$KILL_GRACE" ]; do
    alive=0
    for p in $pids; do kill -0 "$p" 2>/dev/null && alive=1; done
    [ "$alive" = 0 ] && return 0
    sleep 1; waited=$((waited + 1))
  done
  for p in $pids; do kill -KILL "$p" 2>/dev/null || true; done
}
trap '[ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null; [ -n "$OVERALL_PID" ] && kill_tree "$OVERALL_PID"; [ -n "$BUILD_PID" ] && kill_tree "$BUILD_PID"; [ -n "$TEST_PID" ] && kill_tree "$TEST_PID"; for p in ${SUITE_PIDS[@]+"${SUITE_PIDS[@]}"}; do kill -0 "$p" 2>/dev/null && kill_tree "$p"; done; rm -f "$LOG" "$STALLED" "$TIMED_OUT" "$BUILD_LOG" ${SUITE_LOGS[@]+"${SUITE_LOGS[@]}"}' EXIT

# overall PARENT: after TOTAL_LIMIT seconds the run is over whatever it is doing, including what no test case shows
# (the build, a class's set-up or tear-down): everything PARENT started, except this watcher, is killed, and TIMED_OUT
# says so.
overall() {
  local me child
  me="$(sh -c 'echo $PPID')"   # this watcher's own pid ($BASHPID needs bash 4; macOS ships 3.2)
  sleep "$TOTAL_LIMIT"
  # Only if PARENT is still this run. A watcher that outlived its run must do nothing: by now the pid may belong to
  # some other program, and its children are not this run's to kill.
  ps -o command= -p "$1" 2>/dev/null | grep -q "test\.sh" || return 0
  printf '%s' "$TOTAL_LIMIT" > "$TIMED_OUT"
  for child in $(pgrep -P "$1" 2>/dev/null || true); do [ "$child" = "$me" ] || kill_tree "$child"; done
}
overall $$ &
OVERALL_PID=$!

# await PID: until it exits, or a watchdog has ended the run. Not `wait`: a process that cannot exit (stuck in the
# kernel, say) would hold test.sh as well. AWAITED is its exit status; 1 is returned when a watchdog ended the run.
AWAITED=0
await() {
  while kill -0 "$1" 2>/dev/null; do
    if [ -s "$STALLED" ] || [ -s "$TIMED_OUT" ]; then return 1; fi
    sleep 1
  done
  # Gone because a watchdog killed it, which its note (written first) says.
  if [ -s "$STALLED" ] || [ -s "$TIMED_OUT" ]; then return 1; fi
  AWAITED=0
  wait "$1" || AWAITED=$?
  return 0
}
# A watchdog ended the run: it is given the time its kills take (they always end), and the process it killed is not
# waited for. Says which, and exits with a failing status.
ended_by_a_watchdog() {
  if [ -s "$STALLED" ]; then
    wait "$WATCH_PID" 2>/dev/null || true
    # The whole-run watcher is still asleep, and nothing else would stop it: left behind, it would wake after the
    # run's limit and look for this run's children under a pid that is no longer this run's.
    { kill_tree "$OVERALL_PID"; wait "$OVERALL_PID"; } 2>/dev/null || true
    echo "✗ $(cat "$STALLED") was still running after ${LIMIT} s, so the run was stopped. A test that waits for a socket," \
      "a timer or a run loop that never comes hangs the whole suite; this is the one." >&2
  else
    wait "$OVERALL_PID" 2>/dev/null || true
    local last where="No test case had finished yet."
    last="$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" 2>/dev/null | grep -E '^\[[0-9]+/[0-9]+\] Testing ' | tail -n 1 || true)"
    [ -n "$last" ] && where="The last test case that finished: $last"
    echo "✗ the run was still going after $(cat "$TIMED_OUT") s (ANODE_TEST_TOTAL_LIMIT), so it was stopped. No single" \
      "test case ran past its own limit, so what hung is outside one: the build, or a test class's set-up or tear-down." \
      "$where" >&2
  fi
  WATCH_PID=""; OVERALL_PID=""; TEST_PID=""; BUILD_PID=""
  exit 1
}

# The two shell suites (Tests/installer-tests.sh and Tests/watchdog-tests.sh) are most of the XCTest run's time and spend it
# waiting, not computing; each runs in a home or folder of its own and shares nothing with it. So they run BESIDE the build
# and the XCTest run, and the XCTest wrappers that would run them again (InstallerScriptTests, TestRunnerWatchdogTests) skip
# themselves when ANODE_SHELL_SUITES is set. It is also set for what the suites start (watchdog-tests.sh runs this very
# script against a stand-in `swift`, which must not start them again). Under ANODE_TEST_FILTER only what was asked for runs,
# and a plain `swift test` runs the wrappers as before.
# With --full the installer suite runs as `installer-tests.sh --full`: the same scenarios and then the real install (its own
# compile, in a clone) and the installed app's own Uninstall button, which need nothing of the XCTest run and are driven
# through the test copy's own windows (by Accessibility, per process), so they go beside it too, not after it.
SUITES_BESIDE=0
if [ -z "${ANODE_TEST_FILTER:-}" ] && [ -z "${ANODE_SHELL_SUITES:-}" ]; then
  export ANODE_SHELL_SUITES=beside
  SUITES_BESIDE=1
  for suite in installer-tests watchdog-tests; do
    [ -x "Tests/$suite.sh" ] || continue
    suite_args=()
    [ "$suite" = installer-tests ] && [ "$MODE" = "--full" ] && suite_args=(--full)
    suite_log="$(mktemp)"
    SUITE_NAMES+=("$suite"); SUITE_LOGS+=("$suite_log")
    "Tests/$suite.sh" ${suite_args[@]+"${suite_args[@]}"} > "$suite_log" 2>&1 &
    SUITE_PIDS+=("$!")
  done
fi

if [ "$MODE" != "--quick" ]; then
  step "building every product (release)"
  for product in AnodeApp AnodeHelper anode; do
    swift build -c release --product "$product" > "$BUILD_LOG" 2>&1 &
    BUILD_PID=$!
    await "$BUILD_PID" || ended_by_a_watchdog
    BUILD_STATUS="$AWAITED"; BUILD_PID=""
    grep -E "error:|Compiling|Build complete" "$BUILD_LOG" | grep -vE "^\[" | tail -1 || true
    [ "$BUILD_STATUS" -eq 0 ] || { echo "✗ $product did not build" >&2; exit 1; }
  done
fi

step "running the test suite"
# watch PID LIMIT OUT: while PID (`swift test --parallel`) runs, look every 2 seconds at the test processes it started. Each
# is `xctest -XCTest Module.Class/test <bundle>`, one test case to a process, so its own age says how long that test case
# has been running; one that has been running for LIMIT seconds is written to OUT, as -[Module.Class test], and the whole
# run is stopped. (ps's elapsed time is [[days-]hours:]minutes:seconds.)
watch() {
  local pid="$1" limit="$2" out="$3" pids found
  while kill -0 "$pid" 2>/dev/null; do
    sleep 2
    pids="$(tree_pids "$pid" | paste -sd, -)"
    found="$(ps -o etime=,args= -p "$pids" 2>/dev/null | awk -v limit="$limit" '
      function secs(t,   d, a, p, n, i, s) {
        d = 0; if (t ~ /-/) { split(t, a, "-"); d = a[1]; t = a[2] }
        n = split(t, p, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + p[i]
        return d * 86400 + s
      }
      { for (i = 2; i < NF; i++) if ($i == "-XCTest" && secs($1) >= limit) { print $(i + 1); exit } }' || true)"
    if [ -n "$found" ]; then
      printf '%s' "$found" | sed -E 's#^(.*)/([^/]*)$#-[\1 \2]#' > "$out"
      kill_tree "$pid"
      return 0
    fi
  done
}

# `--parallel`: a process to each test case, as many at once as the Mac has cores. The run was one process, because tests
# raced over the real start-fan-helper.command; they no longer can (a test run's Application Support is a folder of the
# process's own, AnodeFiles.applicationSupport, and its settings are in memory, VolatileDefaults), and a test that only
# passed after another had set something up (NSApplication.shared) now fails alone, where it can be seen and fixed.
# The run was 280 s on one core; this is about 55 s, with the cores busy instead of waiting.
FILTER=()
[ -n "${ANODE_TEST_FILTER:-}" ] && FILTER=(--filter "$ANODE_TEST_FILTER")
swift test --parallel ${FILTER[@]+"${FILTER[@]}"} > "$LOG" 2>&1 &
TEST_PID=$!
watch "$TEST_PID" "$LIMIT" "$STALLED" &
WATCH_PID=$!
await "$TEST_PID" || ended_by_a_watchdog
TEST_STATUS="$AWAITED"
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
{ kill_tree "$OVERALL_PID"; wait "$OVERALL_PID"; } 2>/dev/null || true   # (the shell's "Terminated" notice is not news)
WATCH_PID=""; TEST_PID=""; OVERALL_PID=""
if [ "$TEST_STATUS" -eq 0 ]; then
  # A parallel run prints a line a test case as each finishes, "[n/N] Testing Module.Class/test", and no total.
  printf '%s tests passed\n' "$(grep -cE '^\[[0-9]+/[0-9]+\] Testing ' "$LOG" || true)"
else
  # Only what failed, not several thousand lines of passes.
  sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -E "error:|failed|Fatal|Executed [0-9]+ tests?" | grep -v "^\[" | tail -25 >&2
  echo "✗ tests failed (full output: $LOG is removed on exit; re-run \`swift test\` for it)" >&2
  exit 1
fi

# The shell suites started beside it: normally finished long before (they are shorter), and given LIMIT seconds more if not.
SUITES_FAILED=0
i=0
for suite_pid in ${SUITE_PIDS[@]+"${SUITE_PIDS[@]}"}; do
  suite="${SUITE_NAMES[$i]}"; suite_log="${SUITE_LOGS[$i]}"; i=$((i + 1))
  waited=0
  while kill -0 "$suite_pid" 2>/dev/null && [ "$waited" -lt "$LIMIT" ]; do sleep 1; waited=$((waited + 1)); done
  if kill -0 "$suite_pid" 2>/dev/null; then
    kill_tree "$suite_pid"
    echo "✗ Tests/$suite.sh was still running ${LIMIT} s after the XCTest run ended, so it was stopped" >&2
    SUITES_FAILED=1
  elif wait "$suite_pid"; then
    printf '%s: %s\n' "$suite" "$(grep -E ' passed, [0-9]+ failed' "$suite_log" | tail -1 | sed 's/^[[:space:]]*//')"
  else
    # The failed checks with what each found (the lines under a FAIL begin with "|").
    grep -E "FAIL|^ +\| |passed|✗|kept for the diagnosis" "$suite_log" >&2 || tail -20 "$suite_log" >&2
    echo "✗ Tests/$suite.sh failed" >&2
    SUITES_FAILED=1
  fi
done
SUITE_PIDS=()
[ "$SUITES_FAILED" -eq 0 ] || exit 1

# (Only when the suites did not run beside the XCTest run: under ANODE_TEST_FILTER, or started by another test.sh.)
if [ "$MODE" = "--full" ] && [ "$SUITES_BESIDE" = 0 ]; then
  step "a real install and uninstall (compiles the app)"
  if FULL_OUT="$(Tests/installer-tests.sh --full 2>&1)"; then
    printf '%s\n' "$FULL_OUT" | tail -1
  else
    printf '%s\n' "$FULL_OUT" | grep -E "FAIL|passed" >&2
    echo "✗ the full install test failed" >&2
    exit 1
  fi
fi

printf '\n✓ all passed in %ss\n' "$((SECONDS - START))"
