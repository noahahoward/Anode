#!/bin/bash
# Run on THIS Mac what GitHub's CI used to run, and a bit more. Free, and the only machine that counts: the app
# is AppKit, IOKit and private frameworks throughout, so it builds and runs nowhere else.
#
#   ./test.sh                build every product (release), then the whole test suite
#   ./test.sh --quick        the test suite only (what the pre-push hook runs)
#   ./test.sh --full         everything above, plus a REAL install and uninstall into a throwaway home
#                            (compiles the app again, a few minutes)
#   ./test.sh --install-hook make git run --quick before every push; `git push --no-verify` skips it once
#
# The suite includes the installer and uninstaller tests (Tests/installer-tests.sh), which never touch this
# Mac's own install, keychain or settings: they run in a temporary home.
#
# A test that hangs (a socket nobody answers, a run loop nobody turns) would hang the whole run. XCTest's own
# `executionTimeAllowance` is not enforced by `swift test` (measured: a test that sleeps 6 s with an allowance of 1 s
# passes), so this watches the run itself: a test case that has been running for ANODE_TEST_LIMIT seconds (default 240;
# the slowest honest one takes about a minute) ends the run, and the failure names it. Ending a run is TERM to the
# whole process tree, then KILL to what is still there 5 seconds later: tests in this package set TERM to ignored
# (HelperSignals.routeToStop), and a main thread that hangs never handles it. test.sh does not wait for anything that
# can no longer exit.
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
  -h|--help) sed -n 2,23p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
trap '[ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null; [ -n "$OVERALL_PID" ] && kill_tree "$OVERALL_PID"; [ -n "$BUILD_PID" ] && kill_tree "$BUILD_PID"; [ -n "$TEST_PID" ] && kill_tree "$TEST_PID"; rm -f "$LOG" "$STALLED" "$TIMED_OUT" "$BUILD_LOG"' EXIT

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
    local last where="No test case had reported yet."
    last="$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" 2>/dev/null | grep -E "^Test Case '.*' (started|passed|failed|skipped)" \
      | tail -n 1 || true)"
    [ -n "$last" ] && where="The last test case XCTest reported: $last"
    echo "✗ the run was still going after $(cat "$TIMED_OUT") s (ANODE_TEST_TOTAL_LIMIT), so it was stopped. No single" \
      "test case ran past its own limit, so what hung is outside one: the build, or a test class's set-up or tear-down." \
      "$where" >&2
  fi
  WATCH_PID=""; OVERALL_PID=""; TEST_PID=""; BUILD_PID=""
  exit 1
}

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
# watch PID LOG LIMIT OUT: while PID runs, note which test case XCTest last said it started; one that has been
# running for LIMIT seconds is written to OUT and the whole run is stopped. XCTest says "started" and "passed" or
# "failed" for each test case as it goes (NSUnbufferedIO below keeps those lines from sitting in a buffer).
watch() {
  local pid="$1" log="$2" limit="$3" out="$4" current="" since=$SECONDS line
  while kill -0 "$pid" 2>/dev/null; do
    sleep 2
    line="$(tail -n 100 "$log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' \
      | grep -E "^Test Case '.*' (started|passed|failed|skipped)" | tail -n 1 || true)"
    case "$line" in
      *" started.")
        if [ "$line" != "$current" ]; then
          current="$line"; since=$SECONDS
        elif [ $((SECONDS - since)) -ge "$limit" ]; then
          printf '%s' "$line" | sed -E "s/^Test Case '(.*)' started\.$/\1/" > "$out"
          kill_tree "$pid"
          return 0
        fi ;;
      *) current="" ;;
    esac
  done
}

# One process, not `--parallel`: FanHelperLaunchTests writes the real start-fan-helper.command in Application
# Support, and two test processes racing over that one file fail at random. Serial is about 25 s slower and does not.
FILTER=()
[ -n "${ANODE_TEST_FILTER:-}" ] && FILTER=(--filter "$ANODE_TEST_FILTER")
NSUnbufferedIO=YES swift test ${FILTER[@]+"${FILTER[@]}"} > "$LOG" 2>&1 &
TEST_PID=$!
watch "$TEST_PID" "$LOG" "$LIMIT" "$STALLED" &
WATCH_PID=$!
await "$TEST_PID" || ended_by_a_watchdog
TEST_STATUS="$AWAITED"
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
{ kill_tree "$OVERALL_PID"; wait "$OVERALL_PID"; } 2>/dev/null || true   # (the shell's "Terminated" notice is not news)
WATCH_PID=""; TEST_PID=""; OVERALL_PID=""
if [ "$TEST_STATUS" -eq 0 ]; then
  grep -E "Executed [0-9]+ tests" "$LOG" | tail -1 | sed 's/^[[:space:]]*//'
else
  # Only what failed, not several thousand lines of passes.
  sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -E "error:|failed|Fatal|Executed [0-9]+ tests" | grep -v "^\[" | tail -25 >&2
  echo "✗ tests failed (full output: $LOG is removed on exit; re-run \`swift test\` for it)" >&2
  exit 1
fi

if [ "$MODE" = "--full" ]; then
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
