#!/bin/bash
# test.sh's limits, tried with a stand-in `swift` (so nothing here builds or runs the real suite): a test case that
# starts and never ends must stop the run and be named, also when it ignores TERM; a run that hangs outside any test
# case must be stopped by the limit on the whole run; honest and failing runs must be left alone.
#
# The scenarios do not depend on each other, and each spends its time waiting for a limit to run out, so they run at the
# same time, each in a folder of its own (its stand-in, its output, its process ids), and their results are printed in order.
#
#   Tests/watchdog-tests.sh        also run by `swift test` (TestRunnerWatchdogTests)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(mktemp -d)"
JOBS_PIDS=()
trap 'for p in ${JOBS_PIDS[@]+"${JOBS_PIDS[@]}"}; do kill "$p" 2>/dev/null; done; for p in $(cat "$T"/*/stub-pid-* 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done; rm -rf "$T"' EXIT

# What a scenario prints: one line a check, in the form the totals below count.
ok()  { printf '    ok    %s\n' "$1"; }
bad() { printf '    FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/          | /'; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

# scenario_dir NAME: this scenario's own folder, with the stand-in in it. What the stand-in prints, and whether it then
# hangs, is chosen by $STUB_MODE.
scenario_dir() {
  D="$T/$1"; mkdir -p "$D/bin"
  # `swift test --parallel` prints a line a test case as it finishes, and runs each in a process of its own,
  # `xctest -XCTest Module.Class/test <bundle>`: the stand-in's hung test case is such a process (a script of that name, so
  # that ps shows the same arguments), which is how test.sh finds a test case that has run too long.
  cat > "$D/bin/xctest" <<XCTEST
#!/bin/sh
echo \$\$ > "$D/stub-pid-\$\$"
case "\$STUB_MODE" in
  deaf) trap '' TERM; while :; do sleep 1; done ;;   # what the package's own tests do to the test process (TERM ignored)
  *) sleep 120 ;;
esac
XCTEST
  cat > "$D/bin/swift" <<STUB
#!/bin/sh
echo \$\$ > "$D/stub-pid-\$\$"
echo "[1/2] Testing PowerKitTests.FakeTests/testQuick"
case "\$STUB_MODE" in
  hang)
    "$D/bin/xctest" -XCTest PowerKitTests.FakeTests/testHangs /x/PowerKitTests.xctest ;;
  deaf)
    # A hung main thread never handles TERM either: the one that waits for the test case is deaf as well.
    trap '' TERM
    "$D/bin/xctest" -XCTest PowerKitTests.FakeTests/testIgnoresTerm /x/PowerKitTests.xctest ;;
  outside)
    # Hung with no test case running: between cases, in a class's set-up or tear-down, or building.
    trap '' TERM
    while :; do sleep 1; done ;;
  fail)
    echo "/x/FakeTests.swift:1: error: -[PowerKitTests.FakeTests testBroken] : XCTAssertTrue failed"
    echo "Test Case '-[PowerKitTests.FakeTests testBroken]' failed (0.002 seconds)."
    echo "     Executed 1 test, with 1 failure (0 unexpected) in 0.003 (0.004) seconds"
    exit 1 ;;
  *)
    echo "[2/2] Testing PowerKitTests.FakeTests/testOther" ;;
esac
STUB
  chmod +x "$D/bin/swift" "$D/bin/xctest"
}

run() {  # run MODE LIMIT [TOTAL]: test.sh --quick against the stand-in, given at most 40 s; sets OUT, STATUS, SECS
  local start=$SECONDS
  # ANODE_SHELL_SUITES: test.sh would otherwise start the shell suites (this one among them) beside the stand-in's run.
  STUB_MODE="$1" ANODE_TEST_LIMIT="$2" ANODE_TEST_TOTAL_LIMIT="${3:-1800}" ANODE_SHELL_SUITES=stand-in PATH="$D/bin:$PATH" "$ROOT/test.sh" --quick > "$D/out" 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 40 ]; do sleep 1; waited=$((waited + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; STATUS=124; else wait "$pid"; STATUS=$?; fi
  OUT="$(cat "$D/out")"; SECS=$((SECONDS - start))
}
has() { printf '%s' "$OUT" | grep -qF -- "$1"; }
hasnt() { ! has "$1"; }
gone() { local p; for p in $(cat "$D"/stub-pid-* 2>/dev/null); do kill -0 "$p" 2>/dev/null && return 1; done; return 0; }

# ── The scenarios, one function each ────────────────────────────────────────
s1() {
  scenario_dir s1
  run hang 4
  check "stops the run, with a failing status"                 [ "$STATUS" = 1 ]
  check "names the test that was running"                      has "-[PowerKitTests.FakeTests testHangs]"
  check "and not the one that finished"                        hasnt "testQuick] was still"
  check "and says how long it waited"                          has "still running after 4 s"
  check "in a few seconds, not the stand-in's two minutes"     [ "$SECS" -lt 25 ]
  check "and leaves nothing of the run behind"                 gone
}
s2() {
  scenario_dir s2
  run ok 4
  check "passes"                                               [ "$STATUS" = 0 ]
  check "prints the count"                                     has "2 tests passed"
  check "and says nothing about a test running too long"       hasnt "still running"
}
s3() {
  scenario_dir s3
  run fail 4
  check "fails"                                                [ "$STATUS" = 1 ]
  check "says what failed"                                     has "testBroken"
  check "and is not blamed on a test running too long"         hasnt "still running"
}
s4() {
  scenario_dir s4
  run deaf 4
  check "stops the run, with a failing status"                 [ "$STATUS" = 1 ]
  check "names the test that was running"                      has "-[PowerKitTests.FakeTests testIgnoresTerm]"
  check "and says how long it waited"                          has "still running after 4 s"
  check "in well under the stand-in's patience (KILL follows TERM)" [ "$SECS" -lt 30 ]
  check "and leaves nothing of the run behind"                 gone
}
s5a() {
  scenario_dir s5a
  run outside 1000 4
  check "stops the run, with a failing status"                 [ "$STATUS" = 1 ]
  check "says the whole run went on too long, and how long"    has "still going after 4 s"
  check "says it is outside a test case"                       has "outside one"
  check "and does not blame a test case"                       hasnt "was still running after"
  check "in a few seconds"                                     [ "$SECS" -lt 30 ]
  check "and leaves nothing of the run behind"                 gone
}
s5b() {
  scenario_dir s5b
  run hang 1000 4
  check "a case that has not passed its own limit yet still ends with the run's" has "still going after 4 s"
  check "and names the last test case that finished"           has "FakeTests/testQuick"
  check "leaving nothing behind"                               gone
}
s6() {
  scenario_dir s6
  run ok 4 600
  check "passes"                                               [ "$STATUS" = 0 ]
  check "and says nothing about the run going on too long"     hasnt "still going"
}

# Each scenario's lines go to a file of its own; they are printed below in the order they were written here.
NAMES=(s1 s2 s3 s4 s5a s5b s6)
for n in "${NAMES[@]}"; do
  "$n" > "$T/$n.result" 2>&1 &
  JOBS_PIDS+=("$!")
done
for p in "${JOBS_PIDS[@]}"; do wait "$p" 2>/dev/null; done

echo "1. A test case that starts and never ends";                                          cat "$T/s1.result"
echo "2. An honest run";                                                                   cat "$T/s2.result"
echo "3. A failing run";                                                                   cat "$T/s3.result"
echo "4. A test case that ignores TERM";                                                   cat "$T/s4.result"
echo "5. A hang outside any test case, stopped by the limit on the whole run";             cat "$T/s5a.result" "$T/s5b.result"
echo "6. The limit on the whole run does not touch an honest run";                         cat "$T/s6.result"

PASS="$(cat "$T"/s*.result | grep -c '^    ok ')"
FAIL="$(cat "$T"/s*.result | grep -c '^    FAIL ')"
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
