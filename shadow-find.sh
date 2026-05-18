#!/usr/bin/env bash
# shadow-find.sh: Deterministic shadow detection using test-suite commands.
# Usage: shadow-find.sh <rules_dir>
# Output: JSON {"confirmed": [...], "pairs": [[A, B], ...]}
#
# Algorithm:
#  1. Source each *.test.sh with a stub run_test to extract test commands.
#  2. Run every test command through every rule (in parallel, one process per rule).
#  3. For each pair (A, B) where A sorts before B:
#     - Find a test command where both fire non-defer and return DIFFERENT verdicts.
#     - If found → confirmed shadow.
#  4. Output confirmed shadows and the full pair list so the caller can reason
#     about any pairs not confirmed from tests.

set -uo pipefail
[[ "${BASH_VERSINFO[0]}" -lt 4 ]] && { echo "bash 4+ required" >&2; exit 1; }

RULES_DIR="${1:?Usage: shadow-find.sh <rules_dir>}"
RULES_DIR="${RULES_DIR%/}"

# ── Collect rule files ────────────────────────────────────────────────────────

mapfile -t RULES < <(
    find "$RULES_DIR" -maxdepth 1 -name "*.sh" ! -name "*.test.sh" | sort
)
N="${#RULES[@]}"

if [[ "$N" -eq 0 ]]; then
    echo '{"confirmed":[],"pairs":[]}'
    exit 0
fi

# ── Extract test commands ─────────────────────────────────────────────────────

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

CMDS_FILE="$WORK_DIR/cmds"

# Source each test file with stub helpers that print NUL-terminated commands.
extract_commands() {
    local f="$1"
    (
        run_test()             { printf '%s\0' "$2"; }
        run_test_with_config() { printf '%s\0' "$2"; }
        run_test_with_cwd()    { printf '%s\0' "$2"; }
        # shellcheck disable=SC1090
        source "$f" 2>/dev/null || true
    )
}

for rule in "${RULES[@]}"; do
    test_f="${rule%.sh}.test.sh"
    [[ -f "$test_f" ]] && extract_commands "$test_f"
done > "$CMDS_FILE"

# Deduplicate NUL-separated commands into a sorted unique set.
mapfile -d '' -t ALL_CMDS < <(
    tr '\0' '\n' < "$CMDS_FILE" | sort -u | grep -v '^$' | tr '\n' '\0'
)
M="${#ALL_CMDS[@]}"

if [[ "$M" -eq 0 ]]; then
    echo '{"confirmed":[],"pairs":[]}'
    exit 0
fi

# ── Precompute verdicts (parallel, one process per rule) ──────────────────────
# Each rule produces a file with M lines: one verdict per test command.

for (( r=0; r<N; r++ )); do
    rule="${RULES[$r]}"
    outf="$WORK_DIR/v${r}"
    (
        for (( c=0; c<M; c++ )); do
            cmd="${ALL_CMDS[$c]}"
            v=$(COMMAND="$cmd" bash "$rule" 2>/dev/null)
            printf '%s\n' "$v"
        done
    ) > "$outf" &
done
wait

# Load verdict arrays: _V0, _V1, ..., _V(N-1)
for (( r=0; r<N; r++ )); do
    mapfile -t "_V${r}" < "$WORK_DIR/v${r}"
done

# ── Find shadow pairs ─────────────────────────────────────────────────────────

is_terminal() {
    local v="$1"
    [[ -n "$v" && "$v" != "defer" && "$v" != recurse:* ]]
}

CONFIRMED_FILE="$WORK_DIR/confirmed.ndjson"
PAIRS_FILE="$WORK_DIR/pairs.ndjson"
touch "$CONFIRMED_FILE" "$PAIRS_FILE"

for (( i=0; i<N; i++ )); do
    declare -n vi_arr="_V${i}"
    A_name="$(basename "${RULES[$i]}")"

    for (( j=i+1; j<N; j++ )); do
        declare -n vj_arr="_V${j}"
        B_name="$(basename "${RULES[$j]}")"

        jq -n --arg a "$A_name" --arg b "$B_name" '[$a,$b]' >> "$PAIRS_FILE"

        for (( c=0; c<M; c++ )); do
            va="${vi_arr[$c]:-}"
            vb="${vj_arr[$c]:-}"
            is_terminal "$va" || continue
            is_terminal "$vb" || continue
            [[ "$va" == "$vb" ]] && continue  # same verdict = harmless overlap

            cmd="${ALL_CMDS[$c]}"
            jq -n \
               --arg shadower "$A_name" \
               --arg shadowed "$B_name" \
               --arg example  "$cmd" \
               '{shadower:$shadower,shadowed:$shadowed,example:$example}' \
               >> "$CONFIRMED_FILE"
            break  # one example per pair is enough
        done
    done
done

# ── Output final JSON ─────────────────────────────────────────────────────────

jq -n \
    --slurpfile confirmed "$CONFIRMED_FILE" \
    --slurpfile pairs     "$PAIRS_FILE" \
    '{confirmed: $confirmed, pairs: $pairs}'
