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

    # 2. Number key '1' opens rule 1 detail; ctrl line changes to detail controls
    tui_send "1" ""; sleep 0.5
    tui_assert_screen     "key '1': detail view opened" "modify"
    tui_assert_not_screen "key '1': not on main list"   "navigate"

    # 3a. Esc closes detail → back to main list (check ctrl line, not full screen:
    #     body content may contain the word "modify" in change log entries)
    tui_send Escape ""; sleep 0.3
    tui_assert_ctrl     "Esc: ctrl line has 'navigate'" "navigate"
    tui_assert_ctrl_not "Esc: ctrl line no 'modify'"    "\[m\]"

    # 3b. Enter also closes detail → back to main list
    tui_send "1" ""; sleep 0.5
    tui_assert_screen "Enter-to-close setup: in detail" "modify"
    tui_send Enter ""; sleep 0.3
    tui_assert_screen "Enter: back to main list" "navigate"

    # 4. j moves cursor down; subsequent Enter opens the next rule's detail
    #    After the two round-trips above body_cursor=0 (rule 1).
    #    After j → body_cursor=1 (rule 2).
    tui_send j ""; sleep 0.2
    tui_send Enter ""; sleep 0.5
    tui_assert_screen     "j+Enter: detail opened"         "modify"
    tui_assert_not_screen "j+Enter: not on main list"      "navigate"

    # 5. k moves cursor up (back to rule 1); Esc first to return to list
    tui_send Escape ""; sleep 0.3
    tui_send k ""; sleep 0.2
    tui_send Enter ""; sleep 0.5
    # Should be at rule 1 again (body_cursor=0 after k)
    tui_assert_screen "k+Enter: detail opened" "modify"
    tui_send Escape ""; sleep 0.3

    # 6. ← / → in detail navigate between rules without closing the view
    tui_send "2" ""; sleep 0.5   # open rule 2
    tui_assert_screen "rule 2 detail" "modify"

    tui_send Right ""; sleep 0.3   # → → rule 3
    tui_assert_screen "→: still in detail (rule 3)" "modify"

    tui_send Left ""; sleep 0.3    # ← → rule 2
    tui_assert_screen "←: still in detail (rule 2)" "modify"

    # ← at rule 1 (idx=0) is clamped — must still be in detail, not main list
    tui_send Left ""; sleep 0.3    # → rule 1
    tui_send Left ""; sleep 0.3    # ← at rule 0: clamped, stays in detail
    tui_assert_screen     "← at rule 0: still in detail" "modify"
    tui_assert_not_screen "← at rule 0: not on main list" "navigate"

    tui_stop
}

tui_main "$@"
