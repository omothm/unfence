#!/usr/bin/env bash
# tui-tests/test-auto-allow.sh — Verify the Auto-Allow status section in the
# deferlog view renders correctly for each possible state.
#
# T1: Auto-Allow section header appears in deferlog view.
# T2: Default fixture (result=null, no entry_subs) shows "Analysis not run yet".
# T3: Entry with empty added list shows "Evaluated `curl`. Allowed: none".
# T4: Entry with added command shows "Allowed: `grep`".

source "$(dirname "$0")/helper.sh"

run() {
    # ── T1: Auto-Allow section header is present ──────────────────────────────
    echo "--- test: Auto-Allow section header appears in deferlog view ---"
    tui_start
    tui_send "d" ""
    tui_wait_for "Deferred Log" 20 \
        || { tui_fail "T1: deferlog view did not open"; tui_stop; return; }
    tui_assert_screen "T1: Auto-Allow section header" "Auto-Allow:"
    tui_stop

    # ── T2: Default fixture shows "Analysis not run yet" ──────────────────────
    echo "--- test: default fixture shows 'Analysis not run yet' ---"
    tui_start
    tui_send "d" ""
    tui_wait_for "Deferred Log" 20 \
        || { tui_fail "T2: deferlog view did not open"; tui_stop; return; }
    tui_assert_screen "T2: initial state shows 'Analysis not run yet'" "Analysis not run yet"
    tui_stop

    # ── T3: Entry analyzed, nothing allowed → "Evaluated … Allowed: none" ────
    echo "--- test: entry with empty added list shows 'Allowed: none' ---"
    local t3_cmd="curl https://api.example.com"
    local t3_hash; t3_hash=$(_cmd_hash "$t3_cmd")
    tui_start_with_aa_state \
        '{"added":[],"skipped":["curl"]}' \
        "{\"$t3_hash\":[\"curl\"]}" \
        "$t3_cmd"
    tui_send "d" ""
    tui_wait_for "Deferred Log" 20 \
        || { tui_fail "T3: deferlog view did not open"; tui_stop; return; }
    tui_assert_screen "T3: entry analyzed, nothing allowed" "Allowed: none"
    tui_stop

    # ── T4: Entry analyzed, one command allowed → "Allowed: `grep`" ──────────
    echo "--- test: entry with allowed command shows 'Allowed: \`grep\`' ---"
    local t4_cmd="grep -rn foo /tmp"
    local t4_hash; t4_hash=$(_cmd_hash "$t4_cmd")
    tui_start_with_aa_state \
        '{"added":["grep"],"skipped":["pkill"]}' \
        "{\"$t4_hash\":[\"grep\",\"pkill\"]}" \
        "$t4_cmd"
    tui_send "d" ""
    tui_wait_for "Deferred Log" 20 \
        || { tui_fail "T4: deferlog view did not open"; tui_stop; return; }
    tui_assert_screen "T4: added command shown" "Allowed: \`grep\`"
    tui_stop
}

tui_main "$@"
