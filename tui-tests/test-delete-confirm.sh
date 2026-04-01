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

    # Open rule 1 detail
    tui_send "1" ""; sleep 0.5
    tui_assert_screen "setup: rule detail open" "modify"

    # D shows the confirmation dialog; ctrl line replaces normal detail controls
    tui_send D ""; sleep 0.3
    tui_assert_screen     "D: confirm dialog visible"         "Delete"
    tui_assert_screen     "D: y/n hint shown"                 "confirm"
    tui_assert_ctrl_not   "D: [m] modify not in ctrl line"   "\[m\]"

    # n cancels — dialog dismissed, normal controls return
    tui_send n ""; sleep 0.3
    tui_assert_not_screen "n: dialog gone"    "Delete"
    tui_assert_screen     "n: controls back"  "modify"

    # D again, then Esc cancels
    tui_send D ""; sleep 0.3
    tui_assert_screen "D again: dialog visible" "Delete"
    tui_send Escape ""; sleep 0.3
    tui_assert_not_screen "Esc: dialog gone"   "Delete"
    tui_assert_screen     "Esc: controls back" "modify"

    # D again, then Space (any non-y key) cancels
    tui_send D ""; sleep 0.3
    tui_assert_screen "D third time: dialog visible" "Delete"
    tui_send " " ""; sleep 0.3
    tui_assert_not_screen "Space: dialog gone"   "Delete"
    tui_assert_screen     "Space: controls back" "modify"

    tui_stop
}

tui_main "$@"
