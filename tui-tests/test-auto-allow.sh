#!/usr/bin/env bash
# tui-tests/test-auto-allow.sh — Verify the Auto-Allow status section in the
# deferlog view renders correctly for each possible state.
#
# T1: Auto-Allow section header appears in deferlog view.
# T2: Default fixture (result=null) shows "Analysis not run".
# T3: Empty added list shows "no safe commands to add".
# T4: Non-empty added list displays the first added command.

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

    # ── T2: Default fixture shows "Analysis not run" ──────────────────────────
    echo "--- test: default fixture shows 'Analysis not run' ---"
    tui_start
    tui_send "d" ""
    tui_wait_for "Deferred Log" 20 \
        || { tui_fail "T2: deferlog view did not open"; tui_stop; return; }
    tui_assert_screen "T2: initial state shows 'Analysis not run'" "Analysis not run"
    tui_stop

    # ── T3: Empty added list shows "no safe commands to add" ──────────────────
    echo "--- test: empty added list shows 'no safe commands to add' ---"
    tui_start_with_aa_state '{"added":[],"skipped":["curl https://api.example.com"]}'
    tui_send "d" ""
    tui_wait_for "Deferred Log" 20 \
        || { tui_fail "T3: deferlog view did not open"; tui_stop; return; }
    tui_assert_screen "T3: empty added → 'no safe commands to add'" "no safe commands to add"
    tui_stop

    # ── T4: Non-empty added list displays the first command ───────────────────
    echo "--- test: added commands are displayed ---"
    tui_start_with_aa_state '{"added":["git status","ls -la"],"skipped":[]}'
    tui_send "d" ""
    tui_wait_for "Deferred Log" 20 \
        || { tui_fail "T4: deferlog view did not open"; tui_stop; return; }
    tui_assert_screen "T4: added commands shown" "Added: git status"
    tui_stop
}

tui_main "$@"
