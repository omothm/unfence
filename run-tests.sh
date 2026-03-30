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

# Parallel execution state
_TMPDIR=$(mktemp -d)
_SEQ=0
_ACTIVE=0
_MAX_PARALLEL=$(( $(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4) * 2 ))
# Section boundaries: "seq_before:label" — print header before test (seq_before+1)
_SECTIONS=()

_cleanup() { rm -rf "$_TMPDIR"; }
trap _cleanup EXIT

# run_test: launches the engine check as a background job, writes result to a
# temp file. Results are collected in order after all test files are sourced.
run_test() {
  local description="$1" command="$2" expected="$3"
  local seq=$(( ++_SEQ ))
  (( TOTAL++ ))

  # Throttle: wait for one slot to free up before spawning another job.
  # Uses a counter rather than `jobs -r | wc -l` to avoid forking per check.
  if (( _ACTIVE >= _MAX_PARALLEL )); then
    wait -n 2>/dev/null
    (( _ACTIVE-- ))
  fi

  local result_file="$_TMPDIR/$seq"
  (
    local json output actual
    json=$(jq -n --arg cmd "$command" '{"tool_input":{"command":$cmd}}')
    output=$(bash "$ENGINE" <<< "$json" 2>/dev/null)
    actual=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<< "$output" 2>/dev/null)
    [[ -z "$actual" ]] && actual="defer"

    if [[ "$actual" == "$expected" ]]; then
      printf 'P\t%s\t%s\n' "$description" "$expected" > "$result_file"
    else
      printf 'F\t%s\t%s\t%s\n' "$description" "$expected" "$actual" > "$result_file"
    fi
  ) &
  (( _ACTIVE++ ))
}
export -f run_test

# run_test_with_config "desc" "cmd" "expected" '{"key":...}'
# Writes a real .claude/unfence.json in a temp dir and passes it as cwd.
run_test_with_config() {
  local description="$1" command="$2" expected="$3" config_json="$4"
  local seq=$(( ++_SEQ ))
  (( TOTAL++ ))

  if (( _ACTIVE >= _MAX_PARALLEL )); then
    wait -n 2>/dev/null
    (( _ACTIVE-- ))
  fi

  local result_file="$_TMPDIR/$seq"
  (
    local tmpdir json output actual
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.claude"
    printf '%s' "$config_json" > "$tmpdir/.claude/unfence.json"

    json=$(jq -n --arg cmd "$command" --arg cwd "$tmpdir" \
      '{"tool_input":{"command":$cmd},"cwd":$cwd}')
    output=$(bash "$ENGINE" <<< "$json" 2>/dev/null)
    rm -rf "$tmpdir"

    actual=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<< "$output" 2>/dev/null)
    [[ -z "$actual" ]] && actual="defer"

    if [[ "$actual" == "$expected" ]]; then
      printf 'P\t%s\t%s\n' "$description" "$expected" > "$result_file"
    else
      printf 'F\t%s\t%s\t%s\n' "$description" "$expected" "$actual" > "$result_file"
    fi
  ) &
  (( _ACTIVE++ ))
}
export -f run_test_with_config

echo "═══════════════════════════════════════════════════════════════════"
echo " unfence test suite"
echo "═══════════════════════════════════════════════════════════════════"

for test_file in $(ls "$RULES_DIR"/*.test.sh 2>/dev/null | sort); do
  [[ -f "$test_file" ]] || continue
  # Record section boundary: print header before the first test of this file
  _SECTIONS+=("${_SEQ}:$(basename "$test_file" .test.sh)")
  # shellcheck disable=SC1090
  source "$test_file"
done

# Wait for all background engine calls to finish
wait

# Build a seq→section-label lookup (section prints before test seq+1)
declare -A _SECTION_AT
for entry in "${_SECTIONS[@]}"; do
  _SECTION_AT["${entry%%:*}"]="${entry#*:}"
done

# Print results in submission order, inserting section headers at the right spots
for i in $(seq 1 "$_SEQ"); do
  seq_before=$(( i - 1 ))
  if [[ -n "${_SECTION_AT[$seq_before]}" ]]; then
    echo ""
    echo "── ${_SECTION_AT[$seq_before]} ──"
  fi

  result_file="$_TMPDIR/$i"
  [[ -f "$result_file" ]] || continue

  IFS=$'\t' read -r verdict description expected actual < "$result_file"

  if [[ "$verdict" == "P" ]]; then
    (( PASS++ ))
    printf "${GREEN}PASS${NC}  %-60s  [%s]\n" "$description" "$expected"
  else
    (( FAIL++ ))
    printf "${RED}FAIL${NC}  %-60s  expected=${YELLOW}%s${NC}  actual=${RED}%s${NC}\n" \
      "$description" "$expected" "$actual"
  fi
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
