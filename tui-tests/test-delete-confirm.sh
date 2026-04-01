#!/usr/bin/env bash
# tui-tests/test-delete-confirm.sh — Verify the delete-confirmation dialog flow.
#
# Behavioral contracts:
#  1. Pressing D in detail view shows the confirmation dialog
#  2. Any non-y key (n, Esc, Space…) cancels without deleting
#  3. After cancellation the ctrl line returns to normal detail controls
#
# NOTE: This test never presses 'y', so no rule files are actually deleted.

source "$(dirname "$0")/helper.sh"

run() {
    echo "--- test: delete confirmation dialog ---"
    tui_start

    # Open rule 1 detail. Use "\[m\]" — "modify" would falsely match "modified".
    tui_send "1" ""; tui_wait_for_ctrl "\[m\]"
    tui_assert_ctrl "setup: rule detail open" "\[m\]"

    # D shows the confirmation dialog; ctrl line replaces normal detail controls
    tui_send D ""; tui_wait_for "Delete"
    tui_assert_screen     "D: confirm dialog visible"         "Delete"
    tui_assert_screen     "D: y/n hint shown"                 "confirm"
    tui_assert_ctrl_not   "D: [m] modify not in ctrl line"   "\[m\]"

    # n cancels — dialog dismissed, normal controls return
    tui_send n ""; tui_wait_for_ctrl "\[m\]"
    tui_assert_not_screen "n: dialog gone"   "Delete"
    tui_assert_ctrl       "n: controls back" "\[m\]"

    # D again, then Esc cancels
    tui_send D ""; tui_wait_for "Delete"
    tui_assert_screen "D again: dialog visible" "Delete"
    tui_send Escape ""; tui_wait_for_ctrl "\[m\]"
    tui_assert_not_screen "Esc: dialog gone"  "Delete"
    tui_assert_ctrl       "Esc: controls back" "\[m\]"

    # D again, then Space (any non-y key) cancels
    tui_send D ""; tui_wait_for "Delete"
    tui_assert_screen "D third time: dialog visible" "Delete"
    tui_send " " ""; tui_wait_for_ctrl "\[m\]"
    tui_assert_not_screen "Space: dialog gone"  "Delete"
    tui_assert_ctrl       "Space: controls back" "\[m\]"

    tui_stop
}

tui_main "$@"
