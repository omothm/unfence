#!/usr/bin/env bash
# tui-tests/helper.sh — Shared functions for TUI smoke tests.
#
# Source this file from individual test scripts:
#   source "$(dirname "$0")/helper.sh"
#
# Each test script must define a run() function and call tui_main "$@".
# The helper manages a tmux session, provides send/capture primitives,
# and accumulates pass/fail counts.
#
# Why tmux (not `expect`):
#   `expect` sees only what the TUI *writes* (escape sequences). If curses's
#   differential refresh skips stale cells, `expect` sees nothing but the user
#   still sees old content. tmux `capture-pane` reads the terminal emulator's
#   rendered cell buffer, so stale/bleed-through artifacts are visible.
#
# Irreducible limitations — things no automated capture can detect:
#   1. Font glyph width: tmux has its own wcwidth table. If a Unicode char
#      (e.g. ACS box-drawing) renders wider in Ghostty than tmux expects,
#      tmux shows correct alignment while Ghostty does not. When layout looks
#      fine in tests but broken for the user, ask for a Ghostty screenshot.
#   2. Exact color rendering: we can see the ANSI code (e.g. color 2 = green)
#      but not the RGB Ghostty maps it to on the user's theme.
#   3. Terminal theme: dim ([D]) can be nearly invisible on some dark themes.
#      Use bold+dim ([B+D]) for text that must be readable but subdued.
#   4. Ligatures / kerning: not visible in the cell buffer.

set -euo pipefail

TUI_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/summary.py"
SESSION="unfence-tui-test-$$"
PASS=0
FAIL=0

# ── Lifecycle ──────────────────────────────────────────────────────────────────

tui_start() {
    # Use explicit dimensions (-x W -y H); without them tmux defaults to 80×24
    # which can truncate wide content. Omitting dimensions is a common gotcha.
    tmux new-session -d -s "$SESSION" \
        "python3 $TUI_SCRIPT" 2>/dev/null \
        || { echo "ERROR: could not create tmux session" >&2; exit 1; }
    sleep 2  # TUI renders asynchronously; wait for initial paint
}

tui_stop() {
    tmux kill-session -t "$SESSION" 2>/dev/null || true
}

# ── Interaction primitives ─────────────────────────────────────────────────────

# tui_send KEY [KEY...] — send one or more tmux key names or literal strings.
# Always include a trailing "" to flush: tui_send "j" ""
# Common keys: Enter, Escape, Left, Right, Up, Down, Space
#
# Navigation reference:
#   1–9        open detail view for rule N
#   j / k      navigate rule list (or ↓/↑)
#   Enter / →  open detail view for selected rule
#   Escape / ← back to list
#   m          modify prompt (in detail view)
#   x          re-generate summary (in detail view)
#   D          delete rule (in detail view)
#   e          eval pane (in list view)
#   c          changelog view
#   d          deferred-log view
#   q          quit
tui_send() { tmux send-keys -t "$SESSION" "$@"; }

# tui_type_n N CHAR — type a single character N times.
# One send-keys per char for reliable input; bulk send can race with curses rendering.
tui_type_n() {
    local n="$1" ch="$2"
    for _ in $(seq 1 "$n"); do tui_send "$ch" ""; done
}

# tui_capture — print the current full terminal contents (attributes stripped).
# Use for layout/structure checks: text content, borders, line counts.
#
# ACS chars in plain capture appear as raw alternate-charset letters:
#   q=─  x=│  l=┌  k=┐  m=└  j=┘  t=├  u=┤
tui_capture() { tmux capture-pane -t "$SESSION" -p; }

# tui_capture_attr — print terminal contents with ANSI SGR attributes annotated.
# Output format: [B]=bold [D]=dim [B+D]=bold+dim [grn]=green [red]=red [cyn]=cyan etc.
# Use for color/attribute assertions that tui_capture cannot express.
#
# Example output:
#   0: lqqq[B] #1. Strip Transparent Flags — 0-strip-flags.sh qqqk
#   1: x[D]  30d: [B+grn]22[D] allowed   [B+red]0[D] denied   ·   Last modified: 4d ago   x
#  16: x[B+D]  qq Recent Commands qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqx
tui_capture_attr() {
    tmux capture-pane -t "$SESSION" -e -p | python3 - <<'PYEOF'
import re, sys

COLORS = {0:'blk',1:'red',2:'grn',3:'yel',4:'blu',5:'mag',6:'cyn',7:'wht'}

def parse_state(codes, state):
    i = 0
    while i < len(codes):
        c = codes[i]
        if c == 0:    state.clear()
        elif c == 1:  state['bold'] = True
        elif c == 2:  state['dim']  = True
        elif c == 22: state.pop('bold', None); state.pop('dim', None)
        elif 30 <= c <= 37: state['fg'] = COLORS[c - 30]
        elif c == 39: state.pop('fg', None)
        elif c == 38 and i+2 < len(codes) and codes[i+1] == 5:
            state['fg'] = f'c{codes[i+2]}'
            i += 2
        i += 1

def fmt(state):
    if not state: return ''
    parts = []
    if state.get('bold'): parts.append('B')
    if state.get('dim'):  parts.append('D')
    if 'fg' in state:     parts.append(state['fg'])
    return '+'.join(parts)

SGR_RE = re.compile(r'\x1b\[([0-9;]*)m')
ESC_RE = re.compile(r'\x1b[\x20-\x2f]*[\x40-\x7e]|\x1b\[[^a-zA-Z]*[a-zA-Z]')

for lineno, line in enumerate(sys.stdin.read().split('\n')):
    pos = 0; state = {}; out = []
    while pos < len(line):
        ch = line[pos]
        if ch in '\x0e\x0f': pos += 1; continue
        m = SGR_RE.match(line, pos)
        if m:
            codes = [int(x) if x else 0 for x in m.group(1).split(';')]
            parse_state(codes, state); pos = m.end(); continue
        m = ESC_RE.match(line, pos)
        if m: pos = m.end(); continue
        out.append((fmt(state), ch)); pos += 1
    result = ""; prev_tag = None; run = ""
    for tag, ch in out:
        if tag == prev_tag: run += ch
        else:
            if run: result += (f'[{prev_tag}]{run}' if prev_tag else run)
            prev_tag = tag; run = ch
    if run: result += (f'[{prev_tag}]{run}' if prev_tag else run)
    print(f"{lineno:2}: {result.rstrip()}")
PYEOF
}

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

# tui_assert_attr LABEL PATTERN — assert the annotated attribute output matches PATTERN.
# Use when you need to verify color or bold/dim state, not just text content.
# Example: tui_assert_attr "allowed count is bold+green" "B+grn.*allowed"
tui_assert_attr() {
    local label="$1" pattern="$2"
    if tui_capture_attr | grep -qP "$pattern" 2>/dev/null \
        || tui_capture_attr | grep -q "$pattern"; then
        tui_pass "$label"
    else
        tui_fail "$label (attr pattern '$pattern' not found)"
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
