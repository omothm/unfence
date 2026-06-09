#!/usr/bin/env bash
# tui-tests/test-bgtasks.sh — Verify the Background Tasks view.
#
# Behavioral contracts:
#  1. [b] opens the Background Tasks view (header shows "Background Tasks")
#  2. With no running tasks the view shows "No tasks currently running."
#  3. [b] closes the view; main list is restored
#  4. [esc] in the view also closes it
#  5. The header-line [b] indicator is NOT shown when no tasks are running

source "$(dirname "$0")/helper.sh"

run() {
    echo "--- test: background tasks view ---"
    tui_start

    # 1. Verify the [b] indicator is NOT in the header on startup (no tasks)
    tui_wait_for_not "running \[b\]" 30 || true  # wait for any transient indicator to settle
    tui_assert_not_screen "startup: no [b] indicator when idle" "running \[b\]"

    # 2. Press [b] — should open the Background Tasks view
    tui_send "b" ""
    tui_wait_for "No tasks currently running" 50 \
        || { tui_fail "[b]: Background Tasks view did not open"; tui_stop; return; }
    tui_assert_screen "view opened: header visible" "Background Tasks"

    # 3. Empty state: view should show the no-tasks message
    tui_assert_screen "empty state: no-tasks message visible" "No tasks currently running"

    # 4. Press [b] again — should close the view and return to main list
    tui_send "b" ""
    tui_wait_for_not "Background Tasks" 50 \
        || { tui_fail "[b]: main view did not restore after close"; tui_stop; return; }
    tui_assert_not_screen "after [b] close: Background Tasks header gone" "Background Tasks"

    # 5. Re-open and close with Esc
    tui_send "b" ""
    tui_wait_for "No tasks currently running" 50 \
        || { tui_fail "[b] reopen: Background Tasks view did not open"; tui_stop; return; }
    tui_send "Escape" ""
    tui_wait_for_not "Background Tasks" 50 \
        || { tui_fail "[esc]: main view did not restore after Escape"; tui_stop; return; }
    tui_assert_not_screen "after [esc] close: Background Tasks header gone" "Background Tasks"

    tui_stop
}

tui_main "$@"
