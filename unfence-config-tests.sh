#!/usr/bin/env bash
# unfence-config-tests.sh — Unit tests for the unfence-config script.
# Run standalone: bash unfence-config-tests.sh
# Also sourced by run-tests.sh for inclusion in the full test suite.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNFENCE_CONFIG="$SCRIPT_DIR/unfence-config"

PASS=0
FAIL=0

_pass() { echo "PASS: $1"; ((PASS++)) || true; }
_fail() { echo "FAIL: $1 — $2"; ((FAIL++)) || true; }

# Run a test in an isolated temp dir. The callable receives the tmpdir as $1.
_in_tmpdir() {
    local tmpdir; tmpdir=$(mktemp -d)
    (cd "$tmpdir" && "$@")
    rm -rf "$tmpdir"
}

# Assert that a jq expression evaluates to the expected string.
_assert_jq() {
    local label="$1" file="$2" expr="$3" expected="$4"
    local actual
    actual=$(jq -r "$expr" "$file" 2>/dev/null) || actual="(jq error)"
    if [[ "$actual" == "$expected" ]]; then
        _pass "$label"
    else
        _fail "$label" "expected $(printf '%q' "$expected"), got $(printf '%q' "$actual")"
    fi
}

echo ""
echo "── unfence-config ──"

# ── Test 1: --add creates a new config file and appends to an array ─────────
_in_tmpdir bash -c "
    python3 '$UNFENCE_CONFIG' --add my-rule.safe-list=hello >/dev/null
    jq -r '.\"my-rule\".\"safe-list\"[0]' .claude/unfence.json
" | grep -q "hello" \
    && _pass "--add: creates new file and adds value to array" \
    || _fail "--add: creates new file and adds value to array" "output did not contain 'hello'"

# ── Test 2: --add to an existing array appends without duplicates ────────────
_in_tmpdir bash -c "
    python3 '$UNFENCE_CONFIG' --add my-rule.list=first >/dev/null
    python3 '$UNFENCE_CONFIG' --add my-rule.list=second >/dev/null
    python3 '$UNFENCE_CONFIG' --add my-rule.list=first >/dev/null   # duplicate, must not be added
    count=\$(jq '.\"my-rule\".list | length' .claude/unfence.json)
    [[ \"\$count\" == '2' ]] && echo ok || echo \"WRONG count: \$count\"
" | grep -q "^ok$" \
    && _pass "--add: deduplicates entries in array" \
    || _fail "--add: deduplicates entries in array" "duplicate was added or count wrong"

# ── Test 3: --set stores a scalar string ────────────────────────────────────
_in_tmpdir bash -c "
    python3 '$UNFENCE_CONFIG' --set my-rule.token=abc123 >/dev/null
    jq -r '.\"my-rule\".token' .claude/unfence.json
" | grep -q "^abc123$" \
    && _pass "--set: stores string value" \
    || _fail "--set: stores string value" "value not stored correctly"

# ── Test 4: --set with a numeric value stores as number (not string) ─────────
_in_tmpdir bash -c "
    python3 '$UNFENCE_CONFIG' --set my-rule.max-count=42 >/dev/null
    jq -r '.\"my-rule\".\"max-count\" | type' .claude/unfence.json
" | grep -q "^number$" \
    && _pass "--set: integer value stored as JSON number" \
    || _fail "--set: integer value stored as JSON number" "type was not 'number'"

# ── Test 5: --set with a float value stores as number ────────────────────────
_in_tmpdir bash -c "
    python3 '$UNFENCE_CONFIG' --set my-rule.ratio=1.5 >/dev/null
    jq -r '.\"my-rule\".ratio | type' .claude/unfence.json
" | grep -q "^number$" \
    && _pass "--set: float value stored as JSON number" \
    || _fail "--set: float value stored as JSON number" "type was not 'number'"

# ── Test 6: running the command preserves all other properties ───────────────
_in_tmpdir bash -c "
    python3 '$UNFENCE_CONFIG' --set rule-a.key1=value1 >/dev/null
    python3 '$UNFENCE_CONFIG' --set rule-b.key2=value2 >/dev/null
    python3 '$UNFENCE_CONFIG' --add rule-a.list=item >/dev/null   # modify rule-a only
    # rule-b must still have key2=value2
    jq -r '.\"rule-b\".key2' .claude/unfence.json
" | grep -q "^value2$" \
    && _pass "--add: preserves unrelated properties" \
    || _fail "--add: preserves unrelated properties" "other property was lost"

# ── Test 7: --set replaces unrelated sibling key is preserved ────────────────
_in_tmpdir bash -c "
    python3 '$UNFENCE_CONFIG' --set sf.safe-orgs=[org1,org2] >/dev/null
    python3 '$UNFENCE_CONFIG' --set sf.max-retries=3 >/dev/null
    # both keys must exist under sf
    k1=\$(jq -r '.sf.\"safe-orgs\"[0]' .claude/unfence.json)
    k2=\$(jq -r '.sf.\"max-retries\"' .claude/unfence.json)
    echo \"\$k1 \$k2\"
" | grep -q "^org1 3$" \
    && _pass "--set: preserves sibling keys in same rule section" \
    || _fail "--set: preserves sibling keys in same rule section" "sibling key was lost"

# ── Test 8: --add with [a,b,c] array syntax ──────────────────────────────────
_in_tmpdir bash -c "
    python3 '$UNFENCE_CONFIG' --add my-rule.hosts='[alpha,beta,gamma]' >/dev/null
    count=\$(jq '.\"my-rule\".hosts | length' .claude/unfence.json)
    echo \"\$count\"
" | grep -q "^3$" \
    && _pass "--add: [a,b,c] syntax adds all items" \
    || _fail "--add: [a,b,c] syntax adds all items" "item count wrong"

# ── Test 9: --set replaces an existing array entirely ────────────────────────
_in_tmpdir bash -c "
    python3 '$UNFENCE_CONFIG' --add my-rule.list=old1 >/dev/null
    python3 '$UNFENCE_CONFIG' --add my-rule.list=old2 >/dev/null
    python3 '$UNFENCE_CONFIG' --set my-rule.list='[new1,new2]' >/dev/null
    count=\$(jq '.\"my-rule\".list | length' .claude/unfence.json)
    first=\$(jq -r '.\"my-rule\".list[0]' .claude/unfence.json)
    echo \"\$count \$first\"
" | grep -q "^2 new1$" \
    && _pass "--set: replaces array entirely" \
    || _fail "--set: replaces array entirely" "array was not replaced"

# ── Test 10: existing config with extra top-level keys is preserved ───────────
_in_tmpdir bash -c "
    mkdir -p .claude
    printf '{\"other-tool\":{\"setting\":\"preserved\"},\"my-rule\":{}}' > .claude/unfence.json
    python3 '$UNFENCE_CONFIG' --set my-rule.key=val >/dev/null
    jq -r '.\"other-tool\".setting' .claude/unfence.json
" | grep -q "^preserved$" \
    && _pass "--set: preserves unrelated top-level keys" \
    || _fail "--set: preserves unrelated top-level keys" "other-tool.setting was lost"

# ── Test 11: number 0 is stored as number, not string ────────────────────────
_in_tmpdir bash -c "
    python3 '$UNFENCE_CONFIG' --set my-rule.zero=0 >/dev/null
    jq -r '.\"my-rule\".zero | type' .claude/unfence.json
" | grep -q "^number$" \
    && _pass "--set: zero stored as JSON number" \
    || _fail "--set: zero stored as JSON number" "type was not 'number'"

# ── Test 12: --add merges into existing array from pre-existing config ────────
_in_tmpdir bash -c "
    mkdir -p .claude
    printf '{\"sf\":{\"safe-orgs\":[\"existing-org\"]}}' > .claude/unfence.json
    python3 '$UNFENCE_CONFIG' --add sf.safe-orgs=new-org >/dev/null
    count=\$(jq '.sf.\"safe-orgs\" | length' .claude/unfence.json)
    has_existing=\$(jq '.sf.\"safe-orgs\" | contains([\"existing-org\"])' .claude/unfence.json)
    has_new=\$(jq '.sf.\"safe-orgs\" | contains([\"new-org\"])' .claude/unfence.json)
    echo \"\$count \$has_existing \$has_new\"
" | grep -q "^2 true true$" \
    && _pass "--add: merges with existing array in pre-existing config" \
    || _fail "--add: merges with existing array in pre-existing config" "merge failed"

echo ""
echo "── unfence-config results: $PASS passed, $FAIL failed ──"
[[ "$FAIL" -eq 0 ]]
