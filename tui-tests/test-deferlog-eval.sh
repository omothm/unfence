#!/usr/bin/env bash
# tui-tests/test-deferlog-eval.sh — Verify pressing [e] in the deferlog view
# runs the engine and shows a verdict.
#
# Behavioral contracts:
#  1. d opens the deferlog view
#  2. A pre-populated entry is visible
#  3. [e] triggers eval and a verdict line (allow/deny/defer) appears
#  4. The eval result persists (doesn't flash away immediately)

source "$(dirname "$0")/helper.sh"

run() {
    echo "--- test: deferlog eval ---"
    # Start with a single deferred entry so [e] has something to evaluate.
    tui_start_with_aa_state 'null' '{}' 'git status'

    # 1. Open deferlog
    tui_send "d" ""
    tui_wait_for "Deferred Log" 50 \
        || { tui_fail "deferlog view did not open"; tui_stop; return; }
    tui_assert_screen "deferlog open: header visible" "Deferred Log"

    # 2. Entry should be visible (git status)
    tui_assert_screen "deferlog entry visible" "git status"

    # 3. Press [e] to evaluate; wait for a verdict (displayed as ALLOW/DENY/DEFER uppercase)
    tui_send "e" ""
    tui_wait_for "ALLOW\|DENY\|DEFER" 60 \
        || { tui_fail "[e]: no verdict appeared after eval"; tui_stop; return; }

    local screen
    screen=$(tui_capture)
    if echo "$screen" | grep -qE "ALLOW|DENY|DEFER"; then
        tui_pass "[e]: verdict returned (ALLOW/DENY/DEFER visible)"
    else
        tui_fail "[e]: verdict text not found (screen: $(echo "$screen" | tail -5))"
    fi

    tui_stop
}

tui_main "$@"
