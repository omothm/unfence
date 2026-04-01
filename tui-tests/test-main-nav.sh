#!/usr/bin/env bash
# tui-tests/test-main-nav.sh — Verify main list navigation and detail view entry/exit.
#
# Behavioral contracts:
#  1. TUI opens on the main list (ctrl line contains "navigate")
#  2. Number key N opens detail for the Nth rule
#  3. Esc / Enter in detail closes it and returns to the main list
#  4. j / ↓ moves the cursor down; Enter then opens that rule's detail
#  5. k / ↑ moves the cursor up
#  6. ← / → in detail view navigate to the prev/next rule (not close the view)

source "$(dirname "$0")/helper.sh"

run() {
    echo "--- test: main list navigation ---"
    tui_start

    # 1. Main list is shown on startup
    tui_assert_screen "startup: main list ctrl line" "navigate"

    # 2. Number key '1' opens rule 1 detail; ctrl line changes to detail controls.
    # Use "\[m\]" to wait — "modify" would falsely match "modified" in the main list.
    tui_send "1" ""; tui_wait_for_ctrl "\[m\]"
    tui_assert_ctrl     "key '1': detail view opened" "\[m\]"
    tui_assert_ctrl_not "key '1': not on main list"   "navigate"

    # 3a. Esc closes detail → back to main list
    tui_send Escape ""; tui_wait_for_ctrl "navigate"
    tui_assert_ctrl     "Esc: ctrl line has 'navigate'" "navigate"
    tui_assert_ctrl_not "Esc: ctrl line no 'modify'"    "\[m\]"

    # 3b. Enter also closes detail → back to main list
    tui_send "1" ""; tui_wait_for_ctrl "\[m\]"
    tui_assert_ctrl "Enter-to-close setup: in detail" "\[m\]"
    tui_send Enter ""; tui_wait_for_ctrl "navigate"
    tui_assert_screen "Enter: back to main list" "navigate"

    # 4. j moves cursor down; subsequent Enter opens the next rule's detail
    #    After the two round-trips above body_cursor=0 (rule 1).
    #    After j → body_cursor=1 (rule 2).
    tui_send j ""; sleep 0.1
    tui_send Enter ""; tui_wait_for_ctrl "\[m\]"
    tui_assert_ctrl     "j+Enter: detail opened"         "\[m\]"
    tui_assert_ctrl_not "j+Enter: not on main list"      "navigate"

    # 5. k moves cursor up (back to rule 1); Esc first to return to list
    tui_send Escape ""; tui_wait_for_ctrl "navigate"
    tui_send k ""; sleep 0.1
    tui_send Enter ""; tui_wait_for_ctrl "\[m\]"
    # Should be at rule 1 again (body_cursor=0 after k)
    tui_assert_ctrl "k+Enter: detail opened" "\[m\]"
    tui_send Escape ""; tui_wait_for_ctrl "navigate"

    # 6. ← / → in detail navigate between rules without closing the view
    tui_send "2" ""; tui_wait_for_ctrl "\[m\]"   # open rule 2
    tui_assert_ctrl "rule 2 detail" "\[m\]"

    tui_send Right ""; sleep 0.1   # → → rule 3
    tui_assert_ctrl "→: still in detail (rule 3)" "\[m\]"

    tui_send Left ""; sleep 0.1    # ← → rule 2
    tui_assert_ctrl "←: still in detail (rule 2)" "\[m\]"

    # ← at rule 1 (idx=0) is clamped — must still be in detail, not main list
    tui_send Left ""; sleep 0.1    # → rule 1
    tui_send Left ""; sleep 0.1    # ← at rule 0: clamped, stays in detail
    tui_assert_ctrl     "← at rule 0: still in detail"   "\[m\]"
    tui_assert_ctrl_not "← at rule 0: not on main list"  "navigate"

    tui_stop
}

tui_main "$@"
