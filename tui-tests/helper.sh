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
_TUI_FIXTURE_DIR=""

# ── Fixture ────────────────────────────────────────────────────────────────────
# Tests must never depend on the real rules/ directory or its accumulated history.
# tui_fixture_setup creates an isolated temp directory with:
#   - 5 dummy rule files (echo defer) so all number-key and nav tests work
#   - Pre-populated cache entries so the TUI never spawns summarizer subprocesses
#   - Pre-populated shadow/rec/log-stats caches so background analyses don't start
#   - Rule 1 has a long description to guarantee scroll overflow in small terminals
# The TUI is launched with UNFENCE_RULES_DIR and UNFENCE_CACHE_DIR pointing here.

_tui_fixture_setup() {
    _TUI_FIXTURE_DIR=$(mktemp -d)
    local rules="$_TUI_FIXTURE_DIR/rules"
    local cache="$_TUI_FIXTURE_DIR/cache"
    local unfence_dir; unfence_dir="$(dirname "$TUI_SCRIPT")"
    mkdir -p "$rules" "$cache"

    # 5 minimal rule files (content irrelevant; just need to be valid .sh)
    for i in 1 2 3 4 5; do
        printf '#!/usr/bin/env bash\necho defer\n' > "$rules/rule-$i.sh"
        chmod +x "$rules/rule-$i.sh"
    done

    # Long description for rule 1: 24 sentences → overflows any small terminal
    local long_desc
    long_desc=$(python3 -c "
print(' '.join(
    'Sentence %d: this is a dummy rule used only for TUI testing and always defers.' % i
    for i in range(1, 25)
))")

    jq -n --arg d "$long_desc" \
       '{"title":"Test Rule 1","summary":"Dummy rule for TUI testing.","description":$d}' \
       > "$cache/rule-1.sh"

    # Short cache entries for rules 2–5 (prevent summarizer from running)
    for i in 2 3 4 5; do
        jq -n --arg i "$i" \
           '{"title":("Test Rule "+$i),"summary":"Dummy rule for TUI testing.","description":("Dummy rule "+$i+" used for TUI testing.")}' \
           > "$cache/rule-$i.sh"
    done

    # Pre-populate shadow cache (.shadowing.json) so _load_shadows() skips the
    # Claude API call. Cache key = (max_mtime_of_rules, rule_count). Using
    # python3 here because jq cannot read file mtimes — no shell equivalent.
    local mtime
    mtime=$(python3 -c "
import os, glob
files = glob.glob('$rules/*.sh')
print(max(os.stat(f).st_mtime for f in files) if files else 0)
")
    jq -n --argjson mtime "$mtime" --argjson count 5 \
       '{"mtime": $mtime, "count": $count, "shadows": []}' \
       > "$cache/.shadowing.json"

    # Pre-populate rec cache (.recs.json) so _load_recs() skips the Claude API
    # call. Cache key = byte size of unfence.log at the time of analysis.
    local log_size=0
    local log_file="$unfence_dir/logs/unfence.log"
    [[ -f "$log_file" ]] && log_size=$(wc -c < "$log_file" | tr -d ' ')
    jq -n --argjson log_size "$log_size" \
       '{"last_ts": "", "log_size": $log_size, "recs": [], "dismissed": []}' \
       > "$cache/.recs.json"

    # Pre-populate log-stats cache (.log-stats.json) so load_log_stats() skips
    # parsing the real log. Cache key = (mtime, size) of unfence.log.
    local log_mtime=0 log_sz=0
    if [[ -f "$log_file" ]]; then
        log_mtime=$(python3 -c "import os; print(os.stat('$log_file').st_mtime)")
        log_sz=$log_size
    fi
    jq -n --argjson mtime "$log_mtime" --argjson size "$log_sz" \
       '{"mtime": $mtime, "size": $size, "counts": {"allow":0,"deny":0,"defer":0,"per_rule":{}}}' \
       > "$cache/.log-stats.json"

    # Pre-populate auto-allow state so _load_auto_allow() skips analysis on start.
    # last_log_size = current log size, last_entry_subs_ts present → stale = False.
    jq -n --argjson sz "$log_size" \
       '{"last_ts": "", "last_entry_subs_ts": "", "last_log_size": $sz, "result": null, "entry_subs": {}, "entry_no_more_defers": [], "analyzed_cmds": []}' \
       > "$cache/.auto-allow-state.json"

    # Pre-populate deferred-commands cache (.deferred-commands.json) with empty
    # entries so the deferlog view shows nothing. Cache key = (mtime, size) of
    # unfence.log — must match the real log so the cache is not considered stale.
    jq -n --argjson mtime "$log_mtime" --argjson sz "$log_sz" \
       '{"mtime": $mtime, "size": $sz, "entries": []}' \
       > "$cache/.deferred-commands.json"
}

_tui_fixture_teardown() {
    [[ -n "$_TUI_FIXTURE_DIR" ]] && rm -rf "$_TUI_FIXTURE_DIR" || true
    _TUI_FIXTURE_DIR=""
}

# ── Lifecycle ──────────────────────────────────────────────────────────────────

tui_start() {
    # No explicit dimensions: uses the current terminal size.
    # Use tui_start_sized when a specific size is required (e.g. to force scroll overflow).
    _tui_fixture_setup
    tmux new-session -d -s "$SESSION" \
        "env UNFENCE_RULES_DIR='$_TUI_FIXTURE_DIR/rules' UNFENCE_CACHE_DIR='$_TUI_FIXTURE_DIR/cache' python3 $TUI_SCRIPT" 2>/dev/null \
        || { echo "ERROR: could not create tmux session" >&2; exit 1; }
    tui_wait_for "navigate" 50 \
        || { echo "ERROR: TUI did not render initial view within 5s" >&2; exit 1; }
}

# tui_start_sized W H — start TUI in a tmux pane of exactly W×H characters.
# Use when a test depends on terminal dimensions, e.g. to guarantee content
# overflows the viewport so scroll behavior can be exercised.
tui_start_sized() {
    local width="${1:-80}" height="${2:-24}"
    _tui_fixture_setup
    tmux new-session -d -s "$SESSION" -x "$width" -y "$height" \
        "env UNFENCE_RULES_DIR='$_TUI_FIXTURE_DIR/rules' UNFENCE_CACHE_DIR='$_TUI_FIXTURE_DIR/cache' python3 $TUI_SCRIPT" 2>/dev/null \
        || { echo "ERROR: could not create tmux session" >&2; exit 1; }
    # Use tui_wait_for (full screen) rather than tui_wait_for_ctrl (last 2 lines)
    # because at narrow widths the ctrl block can wrap to many rows, pushing
    # "navigate" above the last 2 lines that tui_ctrl_line captures.
    tui_wait_for "navigate" 50 \
        || { echo "ERROR: TUI did not render initial view within 5s" >&2; exit 1; }
}

# _cmd_hash CMD — compute the 16-hex-char MD5 used by summary.py to key per-entry
# auto-allow state. Must match _cmd_hash() in summary.py exactly.
_cmd_hash() {
    python3 -c "import hashlib,sys; print(hashlib.md5(sys.argv[1].encode()).hexdigest()[:16])" "$1"
}

# tui_start_with_aa_state RESULT_JSON [ENTRY_SUBS_JSON] [ENTRY_CMD]
#
# Start TUI with a pre-populated auto-allow state file.  Arguments:
#   RESULT_JSON      — the "result" field value (e.g. '{"added":[],"skipped":["curl"]}')
#   ENTRY_SUBS_JSON  — optional; the "entry_subs" field value (default: '{}')
#   ENTRY_CMD        — optional; if set, a single deferlog entry with this command is
#                      written to the deferred-commands cache so the TUI shows it.
#
# The last_log_size is set to the current log size so auto_allow_stale() returns
# False (suppressing real analysis).  Pass 'null' for RESULT_JSON to simulate the
# initial "Analysis not run" state.
tui_start_with_aa_state() {
    local result_json="$1"
    local entry_subs_json="${2:-{}}"
    local entry_cmd="${3:-}"
    local unfence_dir; unfence_dir="$(dirname "$TUI_SCRIPT")"
    local log_file="$unfence_dir/logs/unfence.log"
    local log_size=0 log_mtime=0
    if [[ -f "$log_file" ]]; then
        log_size=$(wc -c < "$log_file" | tr -d ' ')
        log_mtime=$(python3 -c "import os; print(os.stat('$log_file').st_mtime)")
    fi
    _tui_fixture_setup
    # Write state with entry_subs (overrides what _tui_fixture_setup wrote)
    jq -n --argjson result "$result_json" \
           --argjson subs "$entry_subs_json" \
           --argjson sz "$log_size" \
       '{"last_ts": "", "last_entry_subs_ts": "", "last_log_size": $sz, "result": $result, "entry_subs": $subs, "entry_no_more_defers": [], "analyzed_cmds": []}' \
       > "$_TUI_FIXTURE_DIR/cache/.auto-allow-state.json"
    # If a specific deferlog entry was requested, overwrite the empty cache
    if [[ -n "$entry_cmd" ]]; then
        jq -n --argjson mtime "$log_mtime" \
               --argjson sz "$log_size" \
               --arg cmd "$entry_cmd" \
           '{"mtime": $mtime, "size": $sz, "entries": [["2026-04-21 10:00:00", $cmd]]}' \
           > "$_TUI_FIXTURE_DIR/cache/.deferred-commands.json"
    fi
    tmux new-session -d -s "$SESSION" \
        "env UNFENCE_RULES_DIR='$_TUI_FIXTURE_DIR/rules' \
             UNFENCE_CACHE_DIR='$_TUI_FIXTURE_DIR/cache' python3 $TUI_SCRIPT" 2>/dev/null \
        || { echo "ERROR: could not create tmux session" >&2; exit 1; }
    tui_wait_for "navigate" 50 \
        || { echo "ERROR: TUI did not render initial view within 5s" >&2; exit 1; }
}

tui_stop() {
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    _tui_fixture_teardown
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

# tui_type_n N CHAR — type a single character or named key N times.
#
# Single chars (e.g. "a") are batched into one send-keys call using a
# repeated string, which is significantly faster than N individual calls.
# Named keys (e.g. "Left", "Right") are sent in chunks of 20 with 50ms
# inter-chunk pauses to avoid flooding curses's input queue.
tui_type_n() {
    local n="$1" ch="$2"
    if [[ ${#ch} -eq 1 ]]; then
        # Single char: build a string of N copies and send in one call
        local str; str=$(printf "%${n}s" | tr ' ' "$ch")
        tui_send "$str" ""
    else
        # Named key: send in batches of 20 to avoid flooding curses
        local sent=0 batch args
        while (( sent < n )); do
            batch=$(( n - sent > 20 ? 20 : n - sent ))
            args=()
            for _ in $(seq 1 "$batch"); do args+=("$ch"); done
            tui_send "${args[@]}" ""
            sleep 0.05
            sent=$(( sent + batch ))
        done
    fi
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

# tui_assert_ctrl LABEL PATTERN — assert PATTERN appears in the ctrl line(s) only.
# Prefer this over tui_assert_screen when a pattern could appear in body content.
# Retries up to 3 times with 50ms pauses to tolerate brief mid-render blips where
# a background-thread invalidation momentarily clears the ctrl line between the
# preceding tui_wait_for_ctrl and this assertion.
tui_assert_ctrl() {
    local label="$1" pattern="$2" i
    for i in 1 2 3; do
        tui_ctrl_line | grep -q "$pattern" && { tui_pass "$label"; return; }
        sleep 0.05
    done
    tui_fail "$label (pattern '$pattern' not in ctrl line: $(tui_ctrl_line | tr '\n' '|'))"
}

# tui_assert_ctrl_not LABEL PATTERN — assert PATTERN is absent from the ctrl line(s).
tui_assert_ctrl_not() {
    local label="$1" pattern="$2"
    if ! tui_ctrl_line | grep -q "$pattern"; then
        tui_pass "$label"
    else
        tui_fail "$label (pattern '$pattern' unexpectedly in ctrl line: $(tui_ctrl_line | tr '\n' '|'))"
    fi
}

# tui_grep PATTERN — grep the screen for PATTERN, empty string on no match
tui_grep() { tui_capture | grep -o "$1" || echo ""; }

# ── Wait helpers ───────────────────────────────────────────────────────────────

# tui_wait_for PATTERN [max_tries] — poll until PATTERN appears anywhere on screen.
# Polls every 100ms. Default timeout: 50 × 0.1s = 5s.
# Returns 0 if found, 1 if timed out.
# Use after tui_send when the UI must transition to a new state before asserting.
# CAUTION: patterns like "\[m\]" can produce false positives from body content
# (on BSD grep, "\[m\]" = char class "[m]", matching any "m"). For ctrl-line-only
# state transitions, use tui_wait_for_ctrl instead.
tui_wait_for() {
    local pattern="$1" max_tries="${2:-50}"
    local i
    for i in $(seq 1 "$max_tries"); do
        tui_capture | grep -q "$pattern" && return 0
        sleep 0.1
    done
    return 1
}

# tui_wait_for_not PATTERN [max_tries] — poll until PATTERN is absent from screen.
# Polls every 100ms. Default timeout: 30 × 0.1s = 3s.
# Returns 0 if absent, 1 if timed out.
tui_wait_for_not() {
    local pattern="$1" max_tries="${2:-30}"
    local i
    for i in $(seq 1 "$max_tries"); do
        tui_capture | grep -q "$pattern" || return 0
        sleep 0.1
    done
    return 1
}

# tui_wait_for_ctrl PATTERN [max_tries] — poll until PATTERN appears in the ctrl line.
# Polls every 100ms. Default timeout: 50 × 0.1s = 5s.
# Checks only the last 2 lines (ctrl line), not the full screen. Use this
# instead of tui_wait_for when the pattern could produce false positives in the
# body content — e.g. "\[m\]" matches body text with "m" on BSD grep.
tui_wait_for_ctrl() {
    local pattern="$1" max_tries="${2:-50}"
    local i
    for i in $(seq 1 "$max_tries"); do
        tui_ctrl_line | grep -q "$pattern" && return 0
        sleep 0.1
    done
    return 1
}

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
