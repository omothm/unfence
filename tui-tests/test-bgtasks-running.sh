#!/usr/bin/env bash
# tui-tests/test-bgtasks-running.sh — Verify the Background Tasks view when tasks are running.
#
# Strategy: start TUI with shadow cache absent (stale → triggers shadow analysis) and
# a mock claude binary that sleeps for 30 s.  This guarantees a running task is visible
# for the duration of the test without needing real Claude credentials.
#
# Behavioral contracts:
#  1. When a task is running, the header shows an "N running [b]" indicator
#  2. [b] opens the view and the task name is listed
#  3. The metadata line shows the PID (or "(preprocessing)")
#  4. [x] + [y] kills the task; header indicator goes away

source "$(dirname "$0")/helper.sh"

run() {
    echo "--- test: background tasks view (with running task) ---"

    # ── Set up isolated fixture with slow mock claude ─────────────────────────
    _tui_fixture_setup

    # Remove shadow cache so the TUI runs shadow analysis on startup
    rm -f "$_TUI_FIXTURE_DIR/cache/.shadowing.json"

    # Inject a mock claude that sleeps 30 s — long enough to observe the task
    local mock_dir="$_TUI_FIXTURE_DIR/bin"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/claude" << 'MOCK'
#!/usr/bin/env bash
# Mock claude: accept any args, sleep so we remain a running task
sleep 30
MOCK
    chmod +x "$mock_dir/claude"

    # Start TUI with mock claude first in PATH and no shadow cache
    tmux new-session -d -s "$SESSION" \
        "env PATH='$mock_dir:$PATH' \
             UNFENCE_RULES_DIR='$_TUI_FIXTURE_DIR/rules' \
             UNFENCE_CACHE_DIR='$_TUI_FIXTURE_DIR/cache' python3 $TUI_SCRIPT" 2>/dev/null \
        || { echo "ERROR: could not create tmux session" >&2; tui_stop; return; }
    tui_wait_for "navigate" 50 \
        || { echo "ERROR: TUI did not render initial view within 5s" >&2; tui_stop; return; }

    # 1. Header should show the running indicator once shadow analysis starts
    tui_wait_for "running \[b\]" 80 \
        || { tui_fail "header: running [b] indicator did not appear"; tui_stop; return; }
    tui_assert_screen "header: running indicator visible" "running \[b\]"

    # 2. Open background tasks view and verify the task is listed
    tui_send "b" ""
    tui_wait_for "Background Tasks" 50 \
        || { tui_fail "[b]: Background Tasks view did not open"; tui_stop; return; }
    tui_assert_screen "view: shadow-analysis task listed" "shadow-analysis"

    # 3. Metadata line shows PID or "(preprocessing)"
    local screen
    screen=$(tui_capture)
    if echo "$screen" | grep -qE "PID: [0-9]+|PID: \(preprocessing\)"; then
        tui_pass "metadata: PID or preprocessing label visible"
    else
        tui_fail "metadata: expected 'PID: <num>' or 'PID: (preprocessing)' (screen: $(echo "$screen" | tail -5))"
    fi

    # 4. Kill the task: press [x], confirm with [y], verify running indicator gone
    tui_send "x" ""
    tui_wait_for "confirm\|Kill" 20 \
        || { tui_fail "[x]: kill confirmation prompt did not appear"; tui_stop; return; }
    tui_send "y" ""
    # After kill, the running-task indicator in the header should disappear
    # (the task may appear in history but is no longer active)
    tui_wait_for_not "running \[b\]" 60 \
        || { tui_fail "[y]: task not removed after kill confirm"; tui_stop; return; }
    tui_pass "[y]: task removed; header indicator gone after kill"

    # Close view and verify header indicator is gone
    tui_send "b" ""
    tui_wait_for "navigate" 30 \
        || { tui_fail "[b] close: main view did not restore"; tui_stop; return; }
    tui_wait_for_not "running \[b\]" 30 \
        || { tui_fail "header: running indicator still visible after kill"; tui_stop; return; }
    tui_assert_not_screen "header: indicator gone after kill" "running \[b\]"

    tui_stop
}

tui_main "$@"
