#!/usr/bin/env bash
# tui-tests/test-eval-pane.sh — Verify the eval pane opens, accepts input, and closes.
#
# Behavioral contracts:
#  1. e from the main list opens the eval pane ("Evaluate" header visible)
#  2. Typed characters appear in the input area
#  3. Esc closes the pane and returns to the main list
#  4. Re-opening with e clears the previous input (fresh state)
#  5. Enter submits the command; a verdict line appears in the result

source "$(dirname "$0")/helper.sh"

run() {
    echo "--- test: eval pane ---"
    tui_start

    tui_assert_screen "startup: main list" "navigate"

    # 1. e opens the eval pane
    tui_send e ""; tui_wait_for "Evaluate"
    tui_assert_screen     "e: eval pane opened"   "Evaluate"
    tui_assert_not_screen "e: main list hidden"   "navigate"

    # 2. Typed characters appear in the input
    tui_type_n 5 g   # type "ggggg" (batched into one send-keys call)
    tui_wait_for "ggggg"
    tui_assert_screen "typing: input visible" "ggggg"

    # 3. Esc closes the pane
    tui_send Escape ""; tui_wait_for_ctrl "navigate"
    tui_assert_not_screen "Esc: eval pane gone"    "Evaluate"
    tui_assert_screen     "Esc: main list back"    "navigate"

    # 4. Re-opening clears previous input ("ggggg" should not be visible)
    tui_send e ""; tui_wait_for "Evaluate"
    tui_assert_screen     "reopen: eval pane"       "Evaluate"
    tui_assert_not_screen "reopen: old input cleared" "ggggg"

    # 5. Enter submits; wait for the engine to return a verdict.
    #    Send "git status" as a single string — cleaner and faster than a loop.
    tui_send "git status" ""
    tui_send Enter ""; tui_wait_for "allow\|deny\|defer" 60

    # Result should show one of the known verdicts
    local screen
    screen=$(tui_capture)
    if echo "$screen" | grep -qE "allow|deny|defer"; then
        tui_pass "Enter: verdict returned (allow/deny/defer visible)"
    else
        tui_fail "Enter: no verdict visible after eval (screen: $(echo "$screen" | tail -5))"
    fi

    tui_stop
}

tui_main "$@"
