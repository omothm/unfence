#!/usr/bin/env bash
# validate-tui.sh — Run the TUI test suite from tui-tests/.
#
# Usage:
#   bash validate-tui.sh [test-file-glob]
#
# Examples:
#   bash validate-tui.sh                        # run all tests
#   bash validate-tui.sh tui-tests/test-modify* # run specific test(s)
#
# Each file in tui-tests/test-*.sh is an independent test script.
# To add a new test, create tui-tests/test-<name>.sh using helper.sh.
# Exit code: 0 = all pass, 1 = any fail.

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

for test_file in "${TEST_FILES[@]}"; do
    echo "=== Running: $(basename "$test_file") ==="
    if output=$(bash "$test_file" 2>&1); then
        echo "$output"
        passes=$(echo "$output" | grep -c "^PASS:" || true)
        TOTAL_PASS=$((TOTAL_PASS + passes))
    else
        echo "$output"
        fails=$(echo "$output" | grep -c "^FAIL:" || true)
        TOTAL_FAIL=$((TOTAL_FAIL + fails))
    fi
    echo ""
done

echo "=== Summary: $TOTAL_PASS passed, $TOTAL_FAIL failed ==="
[[ "$TOTAL_FAIL" -eq 0 ]]
