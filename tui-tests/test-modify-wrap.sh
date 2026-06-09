#!/usr/bin/env bash
# tui-tests/test-modify-wrap.sh — Verify the modify-prompt input viewport scrolls.
#
# The detail-view modify prompt ([m] key) is a single-line widget that must
# keep the cursor visible by horizontal scrolling when input exceeds the
# available terminal width. This test verifies scrolling activates for long
# inputs and that the viewport is stable across cursor movement.
#
# Uses a fixed 80-col terminal so avail is deterministic (40 chars).
# prefix="  Modify: " (10) + hint="   [enter] send  [esc] cancel" (29) + 1 = 40 chars
# consumed, leaving avail = 80 - 1 - 10 - 29 = 40.

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

    # Type 60 a's. At 80 cols, avail=40, so the cursor ends at position 60 and
    # voff = 60 - 40 + 1 = 21, showing inp[21:61] = 40 a's.
    # Poll until exactly 40 a's are visible — this is the deterministic condition
    # that proves both scrolling activated AND all 60 keystrokes were processed.
    local EXPECTED_AVAIL=40
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
    if [[ "$vis_end" -ne "$EXPECTED_AVAIL" ]]; then
        tui_fail "expected $EXPECTED_AVAIL visible at cursor-end, got $vis_end (line: $end_line)"
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
