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
# the slowest honest one takes about a minute) ends the run, and the failure names it.
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
  -h|--help) sed -n 2,22p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown option: $MODE (try --help)" >&2; exit 2 ;;
esac

step() { printf '\n› %s\n' "$1"; }
START=$SECONDS

if [ "$MODE" != "--quick" ]; then
  step "building every product (release)"
  for product in AnodeApp AnodeHelper anode; do
    swift build -c release --product "$product" 2>&1 | grep -E "error:|Compiling|Build complete" | grep -vE "^\[" | tail -1
    [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "✗ $product did not build" >&2; exit 1; }
  done
fi

step "running the test suite"
LOG="$(mktemp)"
STALLED="$(mktemp)"
LIMIT="${ANODE_TEST_LIMIT:-240}"
TEST_PID=""; WATCH_PID=""
trap '[ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null; [ -n "$TEST_PID" ] && kill_tree "$TEST_PID"; rm -f "$LOG" "$STALLED"' EXIT

kill_tree() {  # kill_tree PID: the process and everything it started
  local child
  for child in $(pgrep -P "$1" 2>/dev/null || true); do kill_tree "$child"; done
  kill -TERM "$1" 2>/dev/null || true
}
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
TEST_STATUS=0
wait "$TEST_PID" || TEST_STATUS=$?
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""; TEST_PID=""
if [ -s "$STALLED" ]; then
  echo "✗ $(cat "$STALLED") was still running after ${LIMIT} s, so the run was stopped. A test that waits for a socket," \
    "a timer or a run loop that never comes hangs the whole suite; this is the one." >&2
  exit 1
fi
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
