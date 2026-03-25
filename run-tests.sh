#!/bin/bash
#
# Test runner for unfence.sh
# Loads *.test.sh files from rules/ and runs them.
# Run: bash run-tests.sh  (from the project root)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ENGINE="$SCRIPT_DIR/hooks/unfence.sh"
RULES_DIR="$SCRIPT_DIR/rules"
export NO_LOG=1   # suppress engine log writes during tests; unset to debug

export PASS=0
export FAIL=0
export TOTAL=0

# Colors
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export NC='\033[0m'

# run_test is sourced into each test file's scope.
# Usage: run_test "description" "command string" "allow|deny|defer"
run_test() {
  local description="$1" command="$2" expected="$3"
  (( TOTAL++ ))

  local json output actual
  json=$(jq -n --arg cmd "$command" '{"tool_input":{"command":$cmd}}')
  output=$(bash "$ENGINE" <<< "$json" 2>/dev/null)

  if echo "$output" | jq -e '.hookSpecificOutput.permissionDecision' &>/dev/null; then
    actual=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision')
  else
    actual="defer"
  fi

  if [[ "$actual" == "$expected" ]]; then
    (( PASS++ ))
    printf "${GREEN}PASS${NC}  %-60s  [%s]\n" "$description" "$expected"
  else
    (( FAIL++ ))
    printf "${RED}FAIL${NC}  %-60s  expected=${YELLOW}%s${NC}  actual=${RED}%s${NC}\n" \
      "$description" "$expected" "$actual"
  fi
}
export -f run_test

# run_test_with_config "desc" "cmd" "expected" '{"key":...}'
# Writes a real .claude/unfence.json in a temp dir and passes it as cwd.
run_test_with_config() {
  local description="$1" command="$2" expected="$3" config_json="$4"
  (( TOTAL++ ))

  local tmpdir json output actual
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/.claude"
  printf '%s' "$config_json" > "$tmpdir/.claude/unfence.json"

  json=$(jq -n --arg cmd "$command" --arg cwd "$tmpdir" \
    '{"tool_input":{"command":$cmd},"cwd":$cwd}')
  output=$(bash "$ENGINE" <<< "$json" 2>/dev/null)
  rm -rf "$tmpdir"

  if echo "$output" | jq -e '.hookSpecificOutput.permissionDecision' &>/dev/null; then
    actual=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision')
  else
    actual="defer"
  fi

  if [[ "$actual" == "$expected" ]]; then
    (( PASS++ ))
    printf "${GREEN}PASS${NC}  %-60s  [%s]\n" "$description" "$expected"
  else
    (( FAIL++ ))
    printf "${RED}FAIL${NC}  %-60s  expected=${YELLOW}%s${NC}  actual=${RED}%s${NC}\n" \
      "$description" "$expected" "$actual"
  fi
}
export -f run_test_with_config

echo "═══════════════════════════════════════════════════════════════════"
echo " unfence test suite"
echo "═══════════════════════════════════════════════════════════════════"

for test_file in $(ls "$RULES_DIR"/*.test.sh 2>/dev/null | sort); do
  [[ -f "$test_file" ]] || continue
  echo ""
  echo "── $(basename "$test_file" .test.sh) ──"
  # shellcheck disable=SC1090
  source "$test_file"
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
if (( FAIL == 0 )); then
  printf "${GREEN}All %d tests passed.${NC}\n" "$TOTAL"
else
  printf "${RED}%d/%d tests failed.${NC}\n" "$FAIL" "$TOTAL"
fi
echo "═══════════════════════════════════════════════════════════════════"
exit $FAIL
