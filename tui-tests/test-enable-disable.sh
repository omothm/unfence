#!/usr/bin/env bash
# tui-tests/test-enable-disable.sh — Verify enable/disable toggle.
#
# Behavioral contracts:
#  1. TUI shows ENABLED in the header by default (no .disabled flag file)
#  2. [t] toggles to DISABLED (shown in header)
#  3. [t] again toggles back to ENABLED

source "$(dirname "$0")/helper.sh"

run() {
    echo "--- test: enable/disable toggle ---"
    tui_start

    # 1. Default state: ENABLED shown in header
    tui_assert_screen "startup: ENABLED in header" "ENABLED"

    # 2. Press [t] — should transition to DISABLED
    tui_send "t" ""; tui_wait_for "DISABLED"
    tui_assert_screen "after [t]: DISABLED in header" "DISABLED"

    # 3. Press [t] again — should transition back to ENABLED
    tui_send "t" ""; tui_wait_for "ENABLED"
    tui_assert_screen "after second [t]: ENABLED in header" "ENABLED"

    tui_stop
}

tui_main "$@"
