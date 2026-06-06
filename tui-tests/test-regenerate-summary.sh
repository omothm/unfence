#!/usr/bin/env bash
# tui-tests/test-regenerate-summary.sh — Verify [x] in detail view re-generates a summary.
#
# Behavioral contracts:
#  1. A rule whose cache file contains non-JSON is treated as stale on startup;
#     after the startup summarization attempt fails, the detail view shows
#     "Summarization failed." with a "Press [x] to retry" hint — not the generic
#     "no description" prompt.
#  2. Pressing [x] clears the failed state and triggers a new summarization attempt:
#     "Summarizing, please wait…" appears.
#  3. After that attempt also fails, the error message is shown again.
#
# Uses a stub "claude" binary on PATH that returns a non-JSON string instantly,
# so summarization fails fast and deterministically regardless of auth state.

source "$(dirname "$0")/helper.sh"

run() {
    echo "--- test: [x] regenerate summary ---"
    _tui_fixture_setup

    # Create a stub claude that always returns non-JSON (simulates auth failure).
    local stub_dir="$_TUI_FIXTURE_DIR/stub-bin"
    mkdir -p "$stub_dir"
    # Sleep 0.5s so the "Summarizing, please wait…" state is observable even under
    # parallel test load (the default poll interval is 0.1s, giving 5 polling windows).
    printf '#!/usr/bin/env bash\nsleep 0.5\necho "Not logged in · Please run /login"\n' \
        > "$stub_dir/claude"
    chmod +x "$stub_dir/claude"

    # Corrupt rule-2's cache and make it older than the rule so is_stale() = True
    # on startup, triggering an immediate summarize attempt that will fast-fail.
    printf 'Not logged in · Please run /login\n' \
        > "$_TUI_FIXTURE_DIR/cache/rule-2.sh"
    touch -t "$(date -v -1M '+%Y%m%d%H%M.%S')" "$_TUI_FIXTURE_DIR/cache/rule-2.sh" 2>/dev/null \
        || touch -d "1 minute ago" "$_TUI_FIXTURE_DIR/cache/rule-2.sh" 2>/dev/null \
        || true
    touch "$_TUI_FIXTURE_DIR/rules/rule-2.sh"  # rule newer → is_stale = True

    tmux new-session -d -s "$SESSION" \
        "env PATH='$stub_dir:$PATH' UNFENCE_RULES_DIR='$_TUI_FIXTURE_DIR/rules' UNFENCE_CACHE_DIR='$_TUI_FIXTURE_DIR/cache' python3 $TUI_SCRIPT" 2>/dev/null \
        || { echo "ERROR: could not create tmux session" >&2; exit 1; }
    tui_wait_for "navigate" 50 \
        || { echo "ERROR: TUI did not render initial view within 5s" >&2; exit 1; }

    # Wait for startup-triggered summarization to finish (stub fails instantly)
    tui_wait_for_not "Summarizing" 30 || true

    # 1. Open rule 2 detail — startup attempt failed, error state should be shown
    tui_send "2" ""; tui_wait_for_ctrl "\[m\]"
    tui_assert_screen "rule 2: summarization failed message shown" "Summarization failed"
    tui_assert_screen "rule 2: retry hint shown" "Press \[x\] to retry"
    tui_assert_not_screen "rule 2: no generic 'no description' prompt" "no description"

    # 2. Press [x] — clears failed state, triggers new summarization
    tui_send "x" ""
    tui_wait_for "Summarizing" 30 \
        || { tui_fail "[x]: 'Summarizing, please wait...' did not appear"; tui_stop; return; }
    tui_pass "[x]: summarizing state triggered"

    # 3. After that attempt also fails, error message is shown again
    tui_wait_for_not "Summarizing" 30 || true
    tui_assert_screen "after retry: summarization failed message shown again" "Summarization failed"

    tui_stop
}

tui_main "$@"
