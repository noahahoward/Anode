#!/bin/bash
# test.sh's limits, tried with a stand-in `swift` (so nothing here builds or runs the real suite): a test case that
# starts and never ends must stop the run and be named, also when it ignores TERM; a run that hangs outside any test
# case must be stopped by the limit on the whole run; honest and failing runs must be left alone.
#
#   Tests/watchdog-tests.sh        also run by `swift test` (TestRunnerWatchdogTests)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(mktemp -d)"
trap 'for p in $(cat "$T"/stub-pid-* 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done; rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '    ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '    FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/          | /'; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

mkdir -p "$T/bin"
# The stand-in: what it prints, and whether it then hangs, is chosen by $STUB_MODE.
cat > "$T/bin/swift" <<STUB
#!/bin/sh
echo \$\$ > "$T/stub-pid-\$\$"
echo "Test Case '-[PowerKitTests.FakeTests testQuick]' started."
echo "Test Case '-[PowerKitTests.FakeTests testQuick]' passed (0.001 seconds)."
case "\$STUB_MODE" in
  hang)
    echo "Test Case '-[PowerKitTests.FakeTests testHangs]' started."
    exec sleep 120 ;;
  deaf)
    # What the package's own tests do to the test process (TERM ignored), and a hung main thread never handles it.
    echo "Test Case '-[PowerKitTests.FakeTests testIgnoresTerm]' started."
    trap '' TERM
    while :; do sleep 1; done ;;
  outside)
    # Hung with no test case running: between cases, in a class's set-up or tear-down, or building.
    trap '' TERM
    while :; do sleep 1; done ;;
  fail)
    echo "/x/FakeTests.swift:1: error: -[PowerKitTests.FakeTests testBroken] : XCTAssertTrue failed"
    echo "Test Case '-[PowerKitTests.FakeTests testBroken]' failed (0.002 seconds)."
    echo "     Executed 2 tests, with 1 failure (0 unexpected) in 0.003 (0.004) seconds"
    exit 1 ;;
  *)
    echo "     Executed 2 tests, with 0 failures (0 unexpected) in 0.003 (0.004) seconds" ;;
esac
STUB
chmod +x "$T/bin/swift"

run() {  # run MODE LIMIT [TOTAL]: test.sh --quick against the stand-in, given at most 40 s; sets OUT, STATUS, SECS
  local start=$SECONDS
  STUB_MODE="$1" ANODE_TEST_LIMIT="$2" ANODE_TEST_TOTAL_LIMIT="${3:-1800}" PATH="$T/bin:$PATH" "$ROOT/test.sh" --quick > "$T/out" 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 40 ]; do sleep 1; waited=$((waited + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; STATUS=124; else wait "$pid"; STATUS=$?; fi
  OUT="$(cat "$T/out")"; SECS=$((SECONDS - start))
}
has() { printf '%s' "$OUT" | grep -qF -- "$1"; }
hasnt() { ! has "$1"; }

echo "1. A test case that starts and never ends"
run hang 4
check "stops the run, with a failing status"                 [ "$STATUS" = 1 ]
check "names the test that was running"                      has "-[PowerKitTests.FakeTests testHangs]"
check "and not the one that finished"                        hasnt "testQuick] was still"
check "and says how long it waited"                          has "still running after 4 s"
check "in a few seconds, not the stand-in's two minutes"     [ "$SECS" -lt 25 ]
gone() { local p; for p in $(cat "$T"/stub-pid-*); do kill -0 "$p" 2>/dev/null && return 1; done; return 0; }
check "and leaves nothing of the run behind"                 gone

echo "2. An honest run"
rm -f "$T"/stub-pid-*
run ok 4
check "passes"                                               [ "$STATUS" = 0 ]
check "prints the count"                                     has "Executed 2 tests, with 0 failures"
check "and says nothing about a test running too long"       hasnt "still running"

echo "3. A failing run"
run fail 4
check "fails"                                                [ "$STATUS" = 1 ]
check "says what failed"                                     has "testBroken"
check "and is not blamed on a test running too long"         hasnt "still running"

echo "4. A test case that ignores TERM"
rm -f "$T"/stub-pid-*
run deaf 4
check "stops the run, with a failing status"                 [ "$STATUS" = 1 ]
check "names the test that was running"                      has "-[PowerKitTests.FakeTests testIgnoresTerm]"
check "and says how long it waited"                          has "still running after 4 s"
check "in well under the stand-in's patience (KILL follows TERM)" [ "$SECS" -lt 30 ]
check "and leaves nothing of the run behind"                 gone

echo "5. A hang outside any test case, stopped by the limit on the whole run"
rm -f "$T"/stub-pid-*
run outside 1000 4
check "stops the run, with a failing status"                 [ "$STATUS" = 1 ]
check "says the whole run went on too long, and how long"    has "still going after 4 s"
check "says it is outside a test case"                       has "outside one"
check "and does not blame a test case"                       hasnt "was still running after"
check "in a few seconds"                                     [ "$SECS" -lt 30 ]
check "and leaves nothing of the run behind"                 gone
rm -f "$T"/stub-pid-*
run hang 1000 4
check "a case that has not passed its own limit yet still ends with the run's" has "still going after 4 s"
check "and names the last test case that was reported"       has "testHangs]' started"
check "leaving nothing behind"                               gone

echo "6. The limit on the whole run does not touch an honest run"
rm -f "$T"/stub-pid-*
run ok 4 600
check "passes"                                               [ "$STATUS" = 0 ]
check "and says nothing about the run going on too long"     hasnt "still going"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
