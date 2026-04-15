#!/usr/bin/env bash
# tui-tests/test-error-wrap.sh — Verify that a long modify-error wraps across
# multiple lines instead of being silently truncated.
#
# At width=60 (inner=58), the full error text
#   "  fail: Permission denied: … [any key] dismiss"
# exceeds 60 chars. Without wrapping, the text is clipped and the "dismiss"
# hint is never visible. With wrapping, the hint appears on a continuation line.
#
# The test injects a mock `claude` binary that immediately returns a fake long
# error so no real API call is needed.

source "$(dirname "$0")/helper.sh"

run() {
    echo "--- test: long modify error wrapping (width=60) ---"

    # Set up isolated fixture (sets $_TUI_FIXTURE_DIR)
    _tui_fixture_setup

    # Create a mock `claude` that outputs a long error JSON and exits immediately
    local mock_dir="$_TUI_FIXTURE_DIR/bin"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/claude" << 'MOCK'
#!/usr/bin/env bash
echo '{"success": false, "error": "Permission denied: sensitive-file guard blocks all writes to protected paths; pass --add-dir to grant write access to the rules directory"}'
MOCK
    chmod +x "$mock_dir/claude"

    # Start TUI at width=60 with mock claude first in PATH
    tmux new-session -d -s "$SESSION" -x 60 -y 30 \
        "env PATH='$mock_dir:$PATH' UNFENCE_RULES_DIR='$_TUI_FIXTURE_DIR/rules' UNFENCE_CACHE_DIR='$_TUI_FIXTURE_DIR/cache' python3 $TUI_SCRIPT" 2>/dev/null \
        || { echo "ERROR: could not create tmux session" >&2; exit 1; }
    tui_wait_for "navigate" 50 \
        || { echo "ERROR: TUI did not render initial view within 5s" >&2; exit 1; }

    # Open detail view for rule 1
    tui_send Enter ""; tui_wait_for_ctrl "\[m\]"

    local ctrl
    ctrl=$(tui_ctrl_line)
    if [[ "$ctrl" != *"modify"* ]]; then
        tui_fail "detail view did not open (ctrl: $ctrl)"
        tui_stop; return
    fi

    # Enter modify mode and submit a prompt (triggers the mock claude subprocess)
    tui_send m ""; tui_wait_for "Modify:"
    tui_send "fix it" Enter ""

    # Wait for the error to appear (mock claude exits immediately so this is fast)
    tui_wait_for "fail:" 100 \
        || { tui_fail "error did not appear within 10s"; tui_stop; return; }

    # The "dismiss" hint must be visible somewhere on screen.
    # Without wrapping, it is clipped at col 60 and never shown.
    # With wrapping, it appears on a continuation line.
    tui_assert_screen "dismiss hint visible after wrap" "dismiss"

    tui_pass "long error wraps: dismiss hint visible at width=60"
    tui_stop
}

tui_main "$@"
