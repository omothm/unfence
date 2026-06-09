#!/usr/bin/env bash
# tui-tests/test-modify-wrap.sh — Verify the modify-prompt input viewport scrolls.
#
# The detail-view modify prompt ([m] key) is a single-line widget that must
# keep the cursor visible by horizontal scrolling when input exceeds the
# available terminal width. This test verifies scrolling activates for long
# inputs and that the viewport is stable across cursor movement.
#
# Uses a fixed 80-col terminal (avail nominally 40 chars).
# The exact visible count is measured from first stable reading to tolerate
# minor terminal-width variation under parallel test load.

source "$(dirname "$0")/helper.sh"

run() {
    echo "--- test: modify prompt viewport scrolling ---"
    tui_start_sized 80 24

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

    # Type 60 a's and poll until the visible count reaches the expected avail.
    # avail = cols - 1 - len(prefix=10) - len(hint=29); measure actual cols from
    # the tmux session to tolerate minor sizing variation under parallel load.
    local actual_cols
    actual_cols=$(tmux display-message -t "$SESSION" -p "#{window_width}" 2>/dev/null || echo 80)
    local EXPECTED_AVAIL=$(( actual_cols - 1 - 10 - 29 ))
    tui_type_n 60 a
    tui_wait_for "Modify: a"
    local _cur _count
    for _ in $(seq 1 100); do
        sleep 0.1
        _cur=$(tui_grep "Modify:.*")
        _count=$(echo "$_cur" | sed 's/^Modify: //' | grep -o '^a*' | tr -d '\n' | wc -c | tr -d ' ')
        [[ "$_count" -eq "$EXPECTED_AVAIL" ]] && break
    done

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

    # Move cursor to start; voff should become 0, revealing inp[0:40] = 40 a's.
    # Poll for stability: repeat the 60-Left batch until the visible count is
    # unchanged for 3 consecutive 100ms checks (handles slow parallel test load).
    tui_type_n 60 Left
    local _prev="-1" _stable=0
    for _ in $(seq 1 80); do
        sleep 0.1
        _cur=$(tui_grep "Modify:.*")
        _count=$(echo "$_cur" | sed 's/^Modify: //' | grep -o '^a*' | tr -d '\n' | wc -c | tr -d ' ')
        if [[ "$_count" -eq "$_prev" ]]; then
            (( _stable++ )) || true
            [[ $_stable -ge 3 ]] && break
        else
            _stable=0
            _prev="$_count"
        fi
    done

    local start_line vis_start
    start_line=$(tui_grep "Modify:.*")
    vis_start=$(echo "$start_line" | sed 's/^Modify: //' | grep -o '^a*' | tr -d '\n' | wc -c | tr -d ' ')
    echo "  Cursor at start:          $vis_start visible"

    if [[ "$vis_start" -le 0 ]]; then
        tui_fail "no chars visible at cursor-start (line: $start_line)"
        tui_stop; return
    fi
    if [[ "$vis_start" -ne "$EXPECTED_AVAIL" ]]; then
        tui_fail "visible count changed with cursor movement ($vis_end at end, $vis_start at start) — voff unstable"
        tui_stop; return
    fi

    tui_pass "viewport stable at avail=$EXPECTED_AVAIL chars (end=$vis_end, start=$vis_start)"
    tui_stop
}

tui_main "$@"
