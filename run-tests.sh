#!/usr/bin/env bash
#
# Master test runner for unfence.sh
# Runs rule tests (engine + rules/) then TUI tests (tui-tests/).
# Run: bash run-tests.sh  (from the project root)
#

if (( BASH_VERSINFO[0] < 4 )); then
  printf 'run-tests.sh requires bash 4+; found %s. Install via Homebrew: brew install bash\n' "$BASH_VERSION" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ENGINE="$SCRIPT_DIR/hooks/unfence.sh"
# RULES_SUITE selects which rules directory to test (default: rules).
# Export the resolved absolute path so the engine subprocess uses the same dir.
RULES_DIR="$SCRIPT_DIR/${RULES_SUITE:-rules}"
export UNFENCE_RULES_DIR="$RULES_DIR"
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
#
# Rule test files (rules/*.test.sh) are sourced directly into this script's
# process, so these exported functions are available to them without any
# explicit import.  This differs from TUI tests, which run as subprocesses
# and therefore source tui-tests/helper.sh themselves.
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
    actual=$(jq -r '(.hookSpecificOutput.ruleVerdict // .hookSpecificOutput.permissionDecision) // empty' <<< "$output" 2>/dev/null)
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

    actual=$(jq -r '(.hookSpecificOutput.ruleVerdict // .hookSpecificOutput.permissionDecision) // empty' <<< "$output" 2>/dev/null)
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

# run_test_with_cwd "desc" "cmd" "expected" "/path/to/cwd"
# Like run_test but passes an explicit cwd to the engine (no config file needed).
run_test_with_cwd() {
  local description="$1" command="$2" expected="$3" cwd="$4"
  local seq=$(( ++_SEQ ))
  (( TOTAL++ ))

  if (( _ACTIVE >= _MAX_PARALLEL )); then
    wait -n 2>/dev/null
    (( _ACTIVE-- ))
  fi

  local result_file="$_TMPDIR/$seq"
  (
    local json output actual
    json=$(jq -n --arg cmd "$command" --arg cwd "$cwd" \
      '{"tool_input":{"command":$cmd},"cwd":$cwd}')
    output=$(bash "$ENGINE" <<< "$json" 2>/dev/null)
    actual=$(jq -r '(.hookSpecificOutput.ruleVerdict // .hookSpecificOutput.permissionDecision) // empty' <<< "$output" 2>/dev/null)
    [[ -z "$actual" ]] && actual="defer"

    if [[ "$actual" == "$expected" ]]; then
      printf 'P\t%s\t%s\n' "$description" "$expected" > "$result_file"
    else
      printf 'F\t%s\t%s\t%s\n' "$description" "$expected" "$actual" > "$result_file"
    fi
  ) &
  (( _ACTIVE++ ))
}
export -f run_test_with_cwd

# run_test_config_walkup "desc" "cmd" "expected" "config_json" [depth]
# Places config at a temp project root under $HOME/Documents, sets cwd to a
# subdirectory at the given depth (default 2), and runs the engine.
# Verifies that config loading walks up from a drifted CWD.
run_test_config_walkup() {
  local description="$1" command="$2" expected="$3" config_json="$4" depth="${5:-2}"
  local seq=$(( ++_SEQ ))
  (( TOTAL++ ))

  if (( _ACTIVE >= _MAX_PARALLEL )); then
    wait -n 2>/dev/null
    (( _ACTIVE-- ))
  fi

  local result_file="$_TMPDIR/$seq"
  (
    local tmpdir subdir json output actual
    tmpdir=$(mktemp -d "$HOME/Documents/.unfence-walkup.XXXXXX")
    mkdir -p "$tmpdir/.claude"
    printf '%s' "$config_json" > "$tmpdir/.claude/unfence.json"
    subdir="$tmpdir"
    for (( i=0; i<depth; i++ )); do subdir="$subdir/sub$i"; done
    mkdir -p "$subdir"

    json=$(jq -n --arg cmd "$command" --arg cwd "$subdir" \
      '{"tool_input":{"command":$cmd},"cwd":$cwd}')
    output=$(bash "$ENGINE" <<< "$json" 2>/dev/null)
    rm -rf "$tmpdir"

    actual=$(jq -r '(.hookSpecificOutput.ruleVerdict // .hookSpecificOutput.permissionDecision) // empty' <<< "$output" 2>/dev/null)
    [[ -z "$actual" ]] && actual="defer"

    if [[ "$actual" == "$expected" ]]; then
      printf 'P\t%s\t%s\n' "$description" "$expected" > "$result_file"
    else
      printf 'F\t%s\t%s\t%s\n' "$description" "$expected" "$actual" > "$result_file"
    fi
  ) &
  (( _ACTIVE++ ))
}
export -f run_test_config_walkup

# run_test_deny_reason "desc" "cmd" "expected_reason_substr"
# Asserts verdict=deny AND permissionDecisionReason contains the given substring.
run_test_deny_reason() {
  local description="$1" command="$2" expected_substr="$3"
  local seq=$(( ++_SEQ ))
  (( TOTAL++ ))

  if (( _ACTIVE >= _MAX_PARALLEL )); then
    wait -n 2>/dev/null
    (( _ACTIVE-- ))
  fi

  local result_file="$_TMPDIR/$seq"
  (
    local json output verdict reason
    json=$(jq -n --arg cmd "$command" '{"tool_input":{"command":$cmd}}')
    output=$(bash "$ENGINE" <<< "$json" 2>/dev/null)
    verdict=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<< "$output" 2>/dev/null)
    reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<< "$output" 2>/dev/null)

    if [[ "$verdict" == "deny" && "$reason" == *"$expected_substr"* ]]; then
      printf 'P\t%s\t%s\n' "$description" "deny+reason" > "$result_file"
    else
      local actual="verdict=${verdict:-none} reason=${reason:-(empty)}"
      printf 'F\t%s\t%s\t%s\n' "$description" "deny+\"$expected_substr\"" "$actual" > "$result_file"
    fi
  ) &
  (( _ACTIVE++ ))
}
export -f run_test_deny_reason

echo "═══════════════════════════════════════════════════════════════════"
echo " unfence test suite — rules"
echo "═══════════════════════════════════════════════════════════════════"

# Engine tests are rule-suite-independent — always run them first.
if [[ -f "$SCRIPT_DIR/engine-tests.sh" ]]; then
  _SECTIONS+=("${_SEQ}:engine")
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/engine-tests.sh"
fi

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
  printf "${GREEN}All %d rule tests passed.${NC}\n" "$TOTAL"
else
  printf "${RED}%d/%d rule tests failed.${NC}\n" "$FAIL" "$TOTAL"
fi
echo "═══════════════════════════════════════════════════════════════════"

# Highlighter tests (Python)
echo ""
HIGHLIGHT_EXIT=0
python3 "$SCRIPT_DIR/highlighter-tests.py" || HIGHLIGHT_EXIT=$?

# Parse-entry-subs tests (Python)
echo ""
PARSE_SUBS_EXIT=0
python3 "$SCRIPT_DIR/parse-entry-subs-tests.py" || PARSE_SUBS_EXIT=$?

# unfence-config tests (standalone script)
echo ""
CONFIG_EXIT=0
bash "$SCRIPT_DIR/unfence-config-tests.sh" || CONFIG_EXIT=$?

# TUI tests
echo ""
TUI_EXIT=0
bash "$SCRIPT_DIR/tui-tests.sh" || TUI_EXIT=$?

exit $(( FAIL + HIGHLIGHT_EXIT + PARSE_SUBS_EXIT + CONFIG_EXIT + TUI_EXIT ))
