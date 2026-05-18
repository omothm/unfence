#!/usr/bin/env bash
# Tests for shadow-find.sh
# Each test creates a minimal fixture rules dir and verifies the output.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHADOW_FIND="$SCRIPT_DIR/shadow-find.sh"

PASS=0
FAIL=0

_tmpdir=$(mktemp -d)
trap 'rm -rf "$_tmpdir"' EXIT

pass() { printf '\033[0;32mPASS\033[0m  %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '\033[0;31mFAIL\033[0m  %s — %s\n' "$1" "$2"; FAIL=$(( FAIL + 1 )); }

# ── Fixture helpers ───────────────────────────────────────────────────────────

new_rules_dir() {
    local d; d=$(mktemp -d "$_tmpdir/rules.XXXXXX")
    printf '%s' "$d"
}

write_rule() {
    # write_rule <dir> <name> <verdict-for-match> <match-prefix>
    local d="$1" name="$2" verdict="$3" prefix="$4"
    cat > "$d/$name" << EOF
#!/usr/bin/env bash
if [[ "\$COMMAND" == ${prefix}* ]]; then echo $verdict; else echo defer; fi
EOF
}

write_test() {
    # write_test <dir> <rule-name> <command>
    local d="$1" rule="$2" cmd="$3"
    local tname="${rule%.sh}.test.sh"
    printf 'run_test "test" '"'"'%s'"'"' "allow"\n' "$cmd" >> "$d/$tname"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# T1: Two rules overlap on same command, different verdicts → shadow found.
t1() {
    local d; d=$(new_rules_dir)
    write_rule "$d" "1-aaa.sh" "allow" "safe-cmd"
    write_rule "$d" "2-bbb.sh" "deny"  "safe-cmd"
    write_test "$d" "1-aaa.sh" "safe-cmd foo"
    write_test "$d" "2-bbb.sh" "safe-cmd foo"

    local out; out=$(bash "$SHADOW_FIND" "$d")
    local count; count=$(jq '.confirmed | length' <<< "$out" 2>/dev/null)
    local shadower; shadower=$(jq -r '.confirmed[0].shadower' <<< "$out" 2>/dev/null)
    local shadowed; shadowed=$(jq -r '.confirmed[0].shadowed' <<< "$out" 2>/dev/null)

    [[ "$count" == "1" && "$shadower" == "1-aaa.sh" && "$shadowed" == "2-bbb.sh" ]] \
        && pass "T1: overlapping rules with different verdicts → shadow found" \
        || fail "T1: overlapping rules with different verdicts → shadow found" \
                "confirmed=$count shadower=$shadower shadowed=$shadowed"
}

# T2: Two rules overlap on same command, SAME verdict → no shadow (harmless).
t2() {
    local d; d=$(new_rules_dir)
    write_rule "$d" "1-aaa.sh" "allow" "safe-cmd"
    write_rule "$d" "2-bbb.sh" "allow" "safe-cmd"
    write_test "$d" "1-aaa.sh" "safe-cmd foo"
    write_test "$d" "2-bbb.sh" "safe-cmd foo"

    local out; out=$(bash "$SHADOW_FIND" "$d")
    local count; count=$(jq '.confirmed | length' <<< "$out" 2>/dev/null)

    [[ "$count" == "0" ]] \
        && pass "T2: same-verdict overlap → not a shadow" \
        || fail "T2: same-verdict overlap → not a shadow" "confirmed=$count (expected 0)"
}

# T3: Two rules with non-overlapping command domains → no shadow.
t3() {
    local d; d=$(new_rules_dir)
    write_rule "$d" "1-aaa.sh" "allow" "foo-cmd"
    write_rule "$d" "2-bbb.sh" "deny"  "bar-cmd"
    write_test "$d" "1-aaa.sh" "foo-cmd arg"
    write_test "$d" "2-bbb.sh" "bar-cmd arg"

    local out; out=$(bash "$SHADOW_FIND" "$d")
    local count; count=$(jq '.confirmed | length' <<< "$out" 2>/dev/null)

    [[ "$count" == "0" ]] \
        && pass "T3: non-overlapping domains → no shadow" \
        || fail "T3: non-overlapping domains → no shadow" "confirmed=$count (expected 0)"
}

# T4: No rules at all → empty output with valid JSON.
t4() {
    local d; d=$(new_rules_dir)

    local out; out=$(bash "$SHADOW_FIND" "$d")
    local valid; valid=$(jq 'type == "object"' <<< "$out" 2>/dev/null)

    [[ "$valid" == "true" ]] \
        && pass "T4: empty rules dir → valid JSON output" \
        || fail "T4: empty rules dir → valid JSON output" "output: $out"
}

# T5: No test files → no confirmed shadows (can't prove shadow without test commands).
t5() {
    local d; d=$(new_rules_dir)
    write_rule "$d" "1-aaa.sh" "allow" "safe-cmd"
    write_rule "$d" "2-bbb.sh" "deny"  "safe-cmd"
    # No *.test.sh files

    local out; out=$(bash "$SHADOW_FIND" "$d")
    local count; count=$(jq '.confirmed | length' <<< "$out" 2>/dev/null)

    [[ "$count" == "0" ]] \
        && pass "T5: no test files → no confirmed shadows" \
        || fail "T5: no test files → no confirmed shadows" "confirmed=$count (expected 0)"
}

# T6: pairs list contains all (A,B) pairs where A sorts before B.
t6() {
    local d; d=$(new_rules_dir)
    write_rule "$d" "1-aaa.sh" "allow" "x"
    write_rule "$d" "2-bbb.sh" "allow" "x"
    write_rule "$d" "3-ccc.sh" "allow" "x"
    # Need at least one test command so the script doesn't exit early.
    write_test "$d" "1-aaa.sh" "x foo"

    local out; out=$(bash "$SHADOW_FIND" "$d")
    local pairs; pairs=$(jq '.pairs | length' <<< "$out" 2>/dev/null)
    # 3 rules → C(3,2) = 3 pairs
    [[ "$pairs" == "3" ]] \
        && pass "T6: pairs list has C(n,2) entries" \
        || fail "T6: pairs list has C(n,2) entries" "pairs=$pairs (expected 3)"
}

# T7: shadower always sorts before shadowed in confirmed output.
t7() {
    local d; d=$(new_rules_dir)
    # 2-bbb comes AFTER 1-aaa, so 1-aaa should be shadower, 2-bbb should be shadowed
    write_rule "$d" "1-aaa.sh" "allow" "q"
    write_rule "$d" "2-bbb.sh" "deny"  "q"
    write_test "$d" "1-aaa.sh" "q arg"
    write_test "$d" "2-bbb.sh" "q arg"

    local out; out=$(bash "$SHADOW_FIND" "$d")
    local shadower; shadower=$(jq -r '.confirmed[0].shadower' <<< "$out" 2>/dev/null)
    local shadowed; shadowed=$(jq -r '.confirmed[0].shadowed' <<< "$out" 2>/dev/null)

    [[ "$shadower" == "1-aaa.sh" && "$shadowed" == "2-bbb.sh" ]] \
        && pass "T7: shadower sorts before shadowed" \
        || fail "T7: shadower sorts before shadowed" "shadower=$shadower shadowed=$shadowed"
}

# T8: output is idempotent — two runs produce identical results.
t8() {
    local d; d=$(new_rules_dir)
    write_rule "$d" "1-aaa.sh" "allow" "cmd"
    write_rule "$d" "2-bbb.sh" "deny"  "cmd"
    write_test "$d" "1-aaa.sh" "cmd foo"
    write_test "$d" "2-bbb.sh" "cmd foo"

    local out1 out2
    out1=$(bash "$SHADOW_FIND" "$d")
    out2=$(bash "$SHADOW_FIND" "$d")

    [[ "$out1" == "$out2" ]] \
        && pass "T8: output is idempotent across runs" \
        || fail "T8: output is idempotent across runs" "runs differ"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

echo "═══════════════════════════════════════════════════════════════════"
echo " shadow-find tests"
echo "═══════════════════════════════════════════════════════════════════"

t1; t2; t3; t4; t5; t6; t7; t8

echo ""
echo "═══════════════════════════════════════════════════════════════════"
TOTAL=$(( PASS + FAIL ))
if (( FAIL == 0 )); then
    printf '\033[0;32mAll %d shadow-find tests passed.\033[0m\n' "$TOTAL"
else
    printf '\033[0;31m%d/%d shadow-find tests failed.\033[0m\n' "$FAIL" "$TOTAL"
fi
echo "═══════════════════════════════════════════════════════════════════"

exit "$FAIL"
