#!/usr/bin/env bash
# tui-tests.sh — Run the TUI test suite from tui-tests/.
#
# Usage:
#   bash tui-tests.sh                        # run all tests
#   bash tui-tests.sh tui-tests/test-modify* # run specific test(s)
#
# Each file in tui-tests/test-*.sh is an independent test script.
# To add a new test, create tui-tests/test-<name>.sh using tui-tests/helper.sh.
# Exit code: 0 = all pass, 1 = any fail.
#
# Tests run in parallel (each has a unique tmux session and fixture dir).
# Output is printed in discovery order after all tests complete.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0

if [[ $# -gt 0 ]]; then
    TEST_FILES=("$@")
else
    mapfile -t TEST_FILES < <(ls "$SCRIPT_DIR"/tui-tests/test-*.sh 2>/dev/null || true)
fi

if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
    echo "No TUI tests found in $SCRIPT_DIR/tui-tests/"
    exit 0
fi

# Launch all tests in parallel; each gets a unique PID-based tmux session name
# and an isolated mktemp fixture dir, so they never share state.
PIDS=()
OUTPUT_FILES=()
TEST_NAMES=()

for test_file in "${TEST_FILES[@]}"; do
    outfile=$(mktemp)
    OUTPUT_FILES+=("$outfile")
    TEST_NAMES+=("$(basename "$test_file")")
    bash "$test_file" > "$outfile" 2>&1 &
    PIDS+=("$!")
done

# Collect results in discovery order (wait for each in turn)
for i in "${!PIDS[@]}"; do
    wait "${PIDS[$i]}" || true
    echo "=== Running: ${TEST_NAMES[$i]} ==="
    cat "${OUTPUT_FILES[$i]}"
    passes=$(grep -c "^PASS:" "${OUTPUT_FILES[$i]}" || true)
    fails=$(grep -c  "^FAIL:" "${OUTPUT_FILES[$i]}" || true)
    TOTAL_PASS=$(( TOTAL_PASS + passes ))
    TOTAL_FAIL=$(( TOTAL_FAIL + fails ))
    rm -f "${OUTPUT_FILES[$i]}"
    echo ""
done

echo "=== Summary: $TOTAL_PASS passed, $TOTAL_FAIL failed ==="
[[ "$TOTAL_FAIL" -eq 0 ]]
