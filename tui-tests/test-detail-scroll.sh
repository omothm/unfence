#!/usr/bin/env bash
# tui-tests/test-detail-scroll.sh — Verify detail view content scrolls with ↓/↑.
#
# Behavioral contracts:
#  1. A rule with enough content shows a ↓ scroll indicator when at the top
#  2. Pressing ↓ scrolls down; ↑ indicator appears confirming displacement
#  3. Pressing ↑ scrolls back up; ↑ indicator disappears at top
#  4. ← / → (prev/next rule) resets scroll to 0 (↑ indicator disappears)
#
# Uses a small terminal (80×16) to guarantee overflow even for short descriptions.
# With 16 rows: HEADER_ROWS=3, CTRL_ROWS=2, content_rows = 16-3-2 = 11 rows.
# Any rule with a cached summary + recent commands section overflows 11 rows.

source "$(dirname "$0")/helper.sh"

# Scroll indicators are drawn near the right edge of the ctrl_sep (bottom border) row.
has_down_indicator() { tui_capture | grep -q "↓"; }
has_up_indicator()   { tui_capture | grep -q "↑"; }

run() {
    echo "--- test: detail view scrolling ---"
    tui_start_sized 80 16

    # Open rule 4 (1-lists.sh) — high command count guarantees overflow
    tui_send "4" ""; sleep 1.0

    tui_assert_screen "rule 4 detail open" "modify"

    # 1. At top: ↓ indicator should be visible (content overflows downward)
    if ! has_down_indicator; then
        tui_fail "scroll/top: ↓ indicator not shown — content may not overflow at 80×16"
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
    tui_send Down ""; sleep 0.3
    if has_up_indicator; then
        tui_pass "scroll/down: ↑ indicator appeared after scrolling down"
    else
        tui_fail "scroll/down: ↑ indicator not shown after pressing ↓"
    fi

    # 3. ↑ scrolls back to top; ↑ indicator should disappear
    tui_send Up ""; sleep 0.3
    if has_up_indicator; then
        tui_fail "scroll/up: ↑ indicator still showing after scrolling back to top"
    else
        tui_pass "scroll/up: ↑ indicator gone after returning to top"
    fi

    # 4. → (next rule) resets scroll: scroll down first, then switch rule
    tui_send Down ""; sleep 0.2
    tui_send Down ""; sleep 0.2
    tui_send Right ""; sleep 0.5   # navigate to rule 5 — scroll resets to 0
    if has_up_indicator; then
        tui_fail "scroll/rule-change: ↑ indicator persisted after ← / → rule switch"
    else
        tui_pass "scroll/rule-change: scroll reset to 0 on rule switch (no ↑)"
    fi

    tui_stop
}

tui_main "$@"
