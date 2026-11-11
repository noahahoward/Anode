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
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
case "$MODE" in
  ""|--quick|--full) ;;
  --install-hook)
    git config core.hooksPath .githooks
    echo "✓ git will run ./test.sh --quick before every push (git push --no-verify skips it once)"
    exit 0 ;;
  -h|--help) sed -n 2,14p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
trap 'rm -f "$LOG"' EXIT
# One process, not `--parallel`: FanHelperLaunchTests writes the real start-fan-helper.command in Application
# Support, and two test processes racing over that one file fail at random. Serial is about 25 s slower and does not.
if swift test > "$LOG" 2>&1; then
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
