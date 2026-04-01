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

    # Navigate into the first rule's detail view.
    # Use "\[m\]" — "modify" would falsely match "modified" in the main list.
    tui_send Enter ""; tui_wait_for_ctrl "\[m\]"

    local ctrl
    ctrl=$(tui_ctrl_line)
    if [[ "$ctrl" != *"modify"* ]]; then
        tui_fail "detail view did not open (ctrl: $ctrl)"
        tui_stop; return
    fi

    # Enter modify mode
    tui_send m ""; tui_wait_for "Modify:"

    local init
    init=$(tui_grep "Modify:.*")
    if [[ "$init" != *"Modify:"* ]]; then
        tui_fail "modify mode did not activate (line: $init)"
        tui_stop; return
    fi

    # Type 60 a's in one batch (tui_type_n batches single chars into one send-keys call).
    # The TUI event loop processes one keystroke per iteration with ~50ms idle sleep,
    # so 60 chars can take ~3s to fully process. Poll until the visible char count
    # stabilizes (unchanged for 3 consecutive 100ms checks) rather than sleeping fixed.
    tui_type_n 60 a
    # "Modify: a" (one space then immediate 'a') is specific to typed input.
    # The empty-input hint "Modify:    [enter]..." has 3+ spaces, so no false positive.
    tui_wait_for "Modify: a"
    local _prev_count="-1" _stable=0 _cur _count
    for _ in $(seq 1 50); do
        sleep 0.1
        _cur=$(tui_grep "Modify:.*")
        _count=$(echo "$_cur" | sed 's/^Modify: //' | grep -o '^a*' | tr -d '\n' | wc -c | tr -d ' ')
        if [[ "$_count" -gt 0 && "$_count" -eq "$_prev_count" ]]; then
            (( _stable++ )) || true
            [[ $_stable -ge 3 ]] && break
        else
            _stable=0
            _prev_count="$_count"
        fi
    done

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

    # Move cursor to start; viewport should shift left revealing the first $avail chars.
    # tui_type_n batches named keys into chunks of 20 with 50ms inter-chunk pauses.
    tui_type_n 60 Left
    sleep 0.3   # wait for curses to settle after bulk cursor movement

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
