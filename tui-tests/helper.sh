#!/usr/bin/env bash
# tui-tests/helper.sh — Shared functions for TUI smoke tests.
#
# Source this file from individual test scripts:
#   source "$(dirname "$0")/helper.sh"
#
# Each test script must define a run() function and call tui_main "$@".
# The helper manages a tmux session, provides send/capture primitives,
# and accumulates pass/fail counts.

set -euo pipefail

TUI_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/summary.py"
SESSION="unfence-tui-test-$$"
PASS=0
FAIL=0

# ── Lifecycle ──────────────────────────────────────────────────────────────────

tui_start() {
    tmux new-session -d -s "$SESSION" \
        "python3 $TUI_SCRIPT" 2>/dev/null \
        || { echo "ERROR: could not create tmux session" >&2; exit 1; }
    sleep 2
}

tui_stop() {
    tmux kill-session -t "$SESSION" 2>/dev/null || true
}

# ── Interaction primitives ─────────────────────────────────────────────────────

# send KEY [KEY...]  — send one or more tmux key names or literal strings
tui_send() { tmux send-keys -t "$SESSION" "$@"; }

# tui_type N CHAR — type a single character N times (one send per char for
# reliable input; bulk send-keys can race with curses rendering)
tui_type_n() {
    local n="$1" ch="$2"
    for _ in $(seq 1 "$n"); do tui_send "$ch" ""; done
}

# tui_capture — print the current full terminal contents
tui_capture() { tmux capture-pane -t "$SESSION" -p; }

# tui_ctrl_line — print the bottom control/status line(s)
tui_ctrl_line() { tui_capture | tail -2; }

# tui_grep PATTERN — grep the screen for PATTERN, empty string on no match
tui_grep() { tui_capture | grep -o "$1" || echo ""; }

# ── Assertions ─────────────────────────────────────────────────────────────────

tui_pass() { echo "PASS: $*"; ((PASS++)) || true; }
tui_fail() { echo "FAIL: $*"; ((FAIL++)) || true; }

tui_assert_screen() {
    local label="$1" pattern="$2"
    if tui_capture | grep -q "$pattern"; then
        tui_pass "$label"
    else
        tui_fail "$label (pattern '$pattern' not found on screen)"
    fi
}

tui_assert_not_screen() {
    local label="$1" pattern="$2"
    if ! tui_capture | grep -q "$pattern"; then
        tui_pass "$label"
    else
        tui_fail "$label (pattern '$pattern' unexpectedly found on screen)"
    fi
}

# ── Main entry point ───────────────────────────────────────────────────────────

tui_main() {
    trap 'tui_stop' EXIT

    if ! command -v tmux &>/dev/null; then
        echo "ERROR: tmux not found — TUI tests require tmux" >&2; exit 1
    fi

    run "$@"

    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [[ "$FAIL" -eq 0 ]]
}
