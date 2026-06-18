#!/usr/bin/env bash
# tui-tests/test-task-finished-date.sh — Verify the Finished timestamp includes the date.
#
# Strategy: trigger a real background task through the TUI (shadow re-analysis)
# using a stub claude that exits immediately, then open the Background Tasks view
# and assert the Finished field contains a YYYY-MM-DD date prefix.
#
# This exercises the actual code path (time.strftime in _spawn_claude_task's poll
# thread) rather than asserting a hardcoded string in a fixture.
#
# Behavioral contract:
#   After a background task completes, the Background Tasks view shows
#   "Finished: YYYY-MM-DD HH:MM:SS" (not just "HH:MM:SS").

source "$(dirname "$0")/helper.sh"

run() {
    echo "--- test: Finished timestamp includes date ---"
    _tui_fixture_setup

    # Stub claude that immediately outputs an empty shadows array and exits 0.
    local stub_dir="$_TUI_FIXTURE_DIR/stub-bin"
    mkdir -p "$stub_dir"
    printf '#!/usr/bin/env bash\necho "[]"\n' > "$stub_dir/claude"
    chmod +x "$stub_dir/claude"

    # Delete the pre-populated shadow cache so re-analysis actually runs.
    rm -f "$_TUI_FIXTURE_DIR/cache/.shadowing.json"

    tmux new-session -d -s "$SESSION" \
        "env PATH='$stub_dir:$PATH' \
             UNFENCE_RULES_DIR='$_TUI_FIXTURE_DIR/rules' \
             UNFENCE_CACHE_DIR='$_TUI_FIXTURE_DIR/cache' \
             python3 $TUI_SCRIPT" 2>/dev/null \
        || { echo "ERROR: could not create tmux session" >&2; exit 1; }
    tui_wait_for "navigate" 50 \
        || { echo "ERROR: TUI did not render initial view" >&2; tui_stop; return; }

    # Open shadow panel (s), then re-run analysis (r). This triggers
    # _spawn_claude_task → stub claude exits → poll() writes finished_str.
    tui_send "s" ""
    tui_wait_for "shadow" 30 \
        || { tui_fail "shadow panel did not open"; tui_stop; return; }
    tui_send "r" ""

    # Wait for the shadow-analysis task to complete (shadow panel closes on re-run,
    # then the background task finishes quickly since stub exits instantly).
    # Poll the Background Tasks view for the completed entry.
    tui_send "b" ""
    tui_wait_for "shadow-analysis" 50 \
        || { tui_fail "[b]: shadow-analysis entry not visible in tasks view"; tui_stop; return; }

    # Wait for the task to finish (Finished: line appears).
    tui_wait_for "Finished:" 50 \
        || { tui_fail "Finished: line did not appear"; tui_stop; return; }

    # Assert the Finished field contains a YYYY-MM-DD date (4 digits, dash, 2, dash, 2).
    local screen
    screen=$(tmux capture-pane -t "$SESSION" -p 2>/dev/null)
    if echo "$screen" | grep -qE "Finished: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}"; then
        tui_pass "Finished: timestamp includes YYYY-MM-DD date"
    else
        tui_fail "Finished: timestamp missing date — got: $(echo "$screen" | grep 'Finished:' | head -1)"
    fi

    tui_stop
}

tui_main "$@"
