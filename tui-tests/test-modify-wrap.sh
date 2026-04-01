#!/usr/bin/env bash
# tui-tests/test-modify-wrap.sh — Verify the modify-prompt input viewport scrolls.
#
# The detail-view modify prompt ([m] key) is a single-line widget that must
# keep the cursor visible by horizontal scrolling when input exceeds the
# available terminal width. This test verifies scrolling activates for long
# inputs and that the viewport is stable across cursor movement.

source "$(dirname "$0")/helper.sh"

run() {
    echo "--- test: modify prompt viewport scrolling ---"
    tui_start

    # Navigate into the first rule's detail view
    tui_send Enter ""; sleep 0.8

    local ctrl
    ctrl=$(tui_ctrl_line)
    if [[ "$ctrl" != *"modify"* ]]; then
        tui_fail "detail view did not open (ctrl: $ctrl)"
        tui_stop; return
    fi

    # Enter modify mode
    tui_send m ""; sleep 0.5

    local init
    init=$(tui_grep "Modify:.*")
    if [[ "$init" != *"Modify:"* ]]; then
        tui_fail "modify mode did not activate (line: $init)"
        tui_stop; return
    fi

    # Type 60 a's one-at-a-time; sleep generously to let curses process them
    tui_type_n 60 a
    sleep 1.5

    # Count visible a's immediately after "Modify: " on screen
    local end_line vis_end
    end_line=$(tui_grep "Modify:.*")
    vis_end=$(echo "$end_line" | sed 's/^Modify: //' | grep -o '^a*' | tr -d '\n' | wc -c | tr -d ' ')
    echo "  Cursor at end (60 typed): $vis_end visible"

    if [[ "$vis_end" -le 0 ]]; then
        tui_fail "no chars visible at cursor-end (line: $end_line)"
        tui_stop; return
    fi
    if [[ "$vis_end" -ge 60 ]]; then
        tui_fail "all 60 chars visible — viewport scrolling did not activate (line: $end_line)"
        tui_stop; return
    fi

    local avail="$vis_end"

    # Move cursor to start; viewport should shift left revealing the first $avail chars
    tui_type_n 60 Left
    sleep 1.0

    local start_line vis_start
    start_line=$(tui_grep "Modify:.*")
    vis_start=$(echo "$start_line" | sed 's/^Modify: //' | grep -o '^a*' | tr -d '\n' | wc -c | tr -d ' ')
    echo "  Cursor at start:          $vis_start visible"

    if [[ "$vis_start" -le 0 ]]; then
        tui_fail "no chars visible at cursor-start (line: $start_line)"
        tui_stop; return
    fi
    if [[ "$vis_start" -ne "$avail" ]]; then
        tui_fail "visible count changed with cursor movement ($avail at end, $vis_start at start) — voff unstable"
        tui_stop; return
    fi

    tui_pass "viewport stable at avail=$avail chars (end=$vis_end, start=$vis_start)"
    tui_stop
}

tui_main "$@"
