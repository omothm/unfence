#!/usr/bin/env bash
# tui-tests/test-taskoutput.sh — Verify the task output overlay rendering.
#
# Strategy: inject a pre-written log file and a .task-history.json entry
# pointing to it into the fixture cache dir, then navigate to [b] → select
# the history entry → press [o] and assert rendering in a narrow terminal
# (80 cols) so that long fence lines must wrap.
#
# Behavioral contracts:
#  1. [b] → [o] on a history entry opens the Output overlay
#  2. Fence content wraps: a line longer than the content width is split
#  3. Heading hashes are shown (e.g. "## ") followed by green bold text
#  4. [esc] / [o] closes the overlay and returns to the tasks view

source "$(dirname "$0")/helper.sh"

run() {
    echo "--- test: task output overlay ---"

    # ── Fixture ───────────────────────────────────────────────────────────────
    _tui_fixture_setup

    # Write a log file with known markdown content into the fixture cache dir.
    # The fence line is intentionally long (90 chars) so it must wrap at 80 cols.
    local log_file="$_TUI_FIXTURE_DIR/cache/test-task.log"
    cat > "$log_file" << 'LOG'
## Results

Some introductory text before the fence.

```
This is a very long fence line that should wrap because it exceeds eighty columns of available space
```

Done.
LOG

    # Inject a task history entry pointing at the log file.
    jq -n --arg log "$log_file" '[{
        "name":         "test-task",
        "purpose":      "Test task for output overlay TUI test",
        "started_str":  "10:00:00",
        "finished_str": "10:00:05",
        "elapsed_secs": 5.0,
        "exit_code":    0,
        "log_path":     $log
    }]' > "$_TUI_FIXTURE_DIR/cache/.task-history.json"

    # Start TUI at 80×30 so fence lines have a predictable wrap width.
    tmux new-session -d -s "$SESSION" -x 80 -y 30 \
        "env UNFENCE_RULES_DIR='$_TUI_FIXTURE_DIR/rules' \
             UNFENCE_CACHE_DIR='$_TUI_FIXTURE_DIR/cache' python3 $TUI_SCRIPT" 2>/dev/null \
        || { echo "ERROR: could not create tmux session" >&2; tui_stop; return; }
    tui_wait_for "navigate" 50 \
        || { echo "ERROR: TUI did not render initial view" >&2; tui_stop; return; }

    # 1. Open the Background Tasks view and navigate to the history entry.
    tui_send "b" ""
    tui_wait_for "test-task" 50 \
        || { tui_fail "[b]: history entry not visible in tasks view"; tui_stop; return; }
    tui_pass "[b]: tasks view shows history entry"

    # The history entry is the only item; cursor is already on it.
    # Wait for the ctrl line to offer [o] before pressing it.
    tui_wait_for_ctrl "\[o\]" 50 \
        || { tui_fail "[o] hint not in ctrl line"; tui_stop; return; }
    tui_send "o" ""
    tui_wait_for "Output:" 50 \
        || { tui_fail "[o]: output overlay did not open"; tui_stop; return; }
    tui_pass "[o]: output overlay opened"

    # 2. Ctrl line should show the [esc/o] close hint.
    tui_assert_ctrl "ctrl: [esc/o] close hint visible" "esc/o"

    # 3. Heading: "## Results" should appear with hashes preserved.
    tui_wait_for "## Results" 30 \
        || { tui_fail "heading: ## Results not visible"; tui_stop; return; }
    tui_assert_screen "heading: ## prefix visible" "## Results"

    # 4. Heading is green bold — check with attribute capture.
    tui_assert_attr "heading: green bold rendering" '\[B+grn\].*Results'

    # 5. Fence content wraps: the log line is >80 chars, so "available space"
    #    (the end of the line) must appear on a separate row from the start.
    tui_assert_screen "fence wrap: trailing words on own line" "available space"

    # Confirm the start of the fence line also appears (not just cut off entirely).
    tui_assert_screen "fence wrap: leading words visible" "This is a very long"

    # 6. Close with [o] — overlay should disappear, tasks view returns.
    tui_send "o" ""
    tui_wait_for_not "Output:" 30 \
        || { tui_fail "[o] close: output overlay did not close"; tui_stop; return; }
    tui_assert_screen "[o] close: back in tasks view" "test-task"
    tui_pass "[o] close: overlay closed"

    # 7. Close with [esc] too — re-open then esc.
    tui_send "o" ""
    tui_wait_for "Output:" 30 \
        || { tui_fail "[o] reopen failed"; tui_stop; return; }
    tui_send "Escape" ""
    tui_wait_for_not "Output:" 30 \
        || { tui_fail "[esc]: overlay did not close"; tui_stop; return; }
    tui_pass "[esc]: overlay closed via Escape"

    tui_stop
}

tui_main "$@"
