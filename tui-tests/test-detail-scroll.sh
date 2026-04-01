#!/usr/bin/env bash
# tui-tests/test-detail-scroll.sh — Verify detail view content scrolls with ↓/↑.
#
# Behavioral contracts:
#  1. A rule with enough content shows a ↓ scroll indicator when at the top
#  2. Pressing ↓ scrolls down; ↑ indicator appears confirming displacement
#  3. Pressing ↑ scrolls back up; ↑ indicator disappears at top
#  4. ← / → (prev/next rule) resets scroll to 0 (↑ indicator disappears)
#
# Uses a small terminal (80×12) to guarantee overflow.
# With 12 rows: HEADER_ROWS=3, CTRL_ROWS=2, content_rows = 12-3-2 = 7 rows.
# Rule 1's pre-populated 24-sentence description overflows 7 rows reliably.

source "$(dirname "$0")/helper.sh"

# Scroll indicators are drawn near the right edge of the ctrl_sep (bottom border) row.
has_down_indicator() { tui_capture | grep -q "↓"; }
has_up_indicator()   { tui_capture | grep -q "↑"; }

run() {
    echo "--- test: detail view scrolling ---"
    tui_start_sized 80 12

    # Open rule 1 — pre-populated 24-sentence cache entry guarantees overflow at 80×12
    # Wait for both the detail view and the ↓ scroll indicator to appear.
    # Use "\[m\]" — "modify" would falsely match "modified" in the main list.
    tui_send "1" ""; tui_wait_for_ctrl "\[m\]"

    tui_assert_screen "rule 1 detail open" "modify"

    # 1. At top: ↓ indicator should be visible (content overflows downward)
    if ! has_down_indicator; then
        tui_fail "scroll/top: ↓ indicator not shown — content may not overflow at 80×12"
        tui_stop; return
    fi
    tui_pass "scroll/top: ↓ indicator visible (content overflows)"

    # Confirm no ↑ at top (nothing above)
    if has_up_indicator; then
        tui_fail "scroll/top: unexpected ↑ indicator at scroll position 0"
    else
        tui_pass "scroll/top: no ↑ indicator at top (correct)"
    fi

    # 2. ↓ scrolls down; ↑ indicator should now appear
    tui_send Down ""; tui_wait_for "↑"
    if has_up_indicator; then
        tui_pass "scroll/down: ↑ indicator appeared after scrolling down"
    else
        tui_fail "scroll/down: ↑ indicator not shown after pressing ↓"
    fi

    # 3. ↑ scrolls back to top; ↑ indicator should disappear
    tui_send Up ""; tui_wait_for_not "↑"
    if has_up_indicator; then
        tui_fail "scroll/up: ↑ indicator still showing after scrolling back to top"
    else
        tui_pass "scroll/up: ↑ indicator gone after returning to top"
    fi

    # 4. → (next rule) resets scroll: scroll down first, then switch rule
    tui_send Down ""; sleep 0.1
    tui_send Down ""; sleep 0.1
    tui_send Right ""; tui_wait_for_not "↑"   # navigate to next rule — scroll resets to 0
    if has_up_indicator; then
        tui_fail "scroll/rule-change: ↑ indicator persisted after ← / → rule switch"
    else
        tui_pass "scroll/rule-change: scroll reset to 0 on rule switch (no ↑)"
    fi

    tui_stop
}

tui_main "$@"
