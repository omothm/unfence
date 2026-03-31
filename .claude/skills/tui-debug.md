---
name: tui-debug
description: >
  Techniques for launching the unfence TUI (summary.py) non-interactively, sending keypresses,
  and capturing rendered output for visual verification. Apply whenever you need to visually
  inspect how a TUI change renders — after modifying summary.py views, adding new sections,
  or debugging layout issues.
user-invocable: false
---

# TUI Debugging

`summary.py` requires an interactive terminal (curses). To inspect its rendered output
non-interactively, use `expect` to drive a PTY session and capture the screen.

## Prerequisites

- `expect` is available at `/usr/bin/expect` (pre-installed on macOS).
- `tmux` is installed (`brew install tmux`). **Prefer tmux for screen captures** — it gives
  the actual rendered screen state, not the raw byte stream.

## tmux — Preferred Approach

`tmux capture-pane -p` returns the **rendered screen** (what you actually see), not escape
sequences. Exact dimensions are set via `-x` / `-y` on session creation.

```bash
# Launch TUI at exact 120x40, open rule 1, capture, kill
tmux new-session -d -s unfence-tui -x 120 -y 40 \
  'env TERM=xterm-256color python3 /Users/omothm/.claude/unfence/summary.py'
sleep 1
tmux send-keys -t unfence-tui "1" ""   # press "1" to open detail view for rule #1
sleep 0.5
tmux capture-pane -t unfence-tui -p    # prints clean text of current screen
tmux kill-session -t unfence-tui
```

`tmux send-keys` syntax: `tmux send-keys -t SESSION "text" ""` — the trailing `""` sends Enter
(omit it for single keypresses that don't need Enter, like navigation keys).

For keypresses that need no Enter confirmation:
```bash
tmux send-keys -t unfence-tui "j" ""   # wrong — sends j then Enter
tmux send-keys -t unfence-tui "j"      # correct for bare keypress? No — "" IS needed
# Actually tmux send-keys always needs the trailing "" to flush; just include it.
```

**Why tmux over `expect`:** `expect` only sees what the TUI *writes* (escape sequences). If
curses's differential update skips stale cells (e.g., trailing spaces that match old content),
`expect` sees spaces — not the old terminal content that the user actually sees. tmux
`capture-pane` reads the terminal emulator's rendered cell buffer, so stale/bleed-through
artifacts are visible.

## Basic Pattern

```bash
expect -c '
  set timeout 4
  spawn env TERM=xterm COLUMNS=100 LINES=40 python3 /Users/omothm/.claude/unfence/summary.py
  expect -timeout 2 -re ".+"
  # send keypresses here
  send "q"
  expect eof
' > /tmp/tui-out.txt 2>/dev/null
```

**Key `expect` primitives:**
- `send "1"` — press the key `1` (opens detail view for rule #1)
- `send "q"` — quit
- `send " "` — scroll down one page in detail view
- `send [string repeat " " 8]` — scroll down 8 pages
- `send "\r"` — Enter
- `send "\033"` — Escape
- `after 300` — wait 300 ms (use when a view needs time to render before capturing)

## Stripping ANSI / Curses Escape Codes

The raw output contains curses escape sequences. Strip them with Python:

```python
import re

raw = open("/tmp/tui-out.txt", errors="replace").read()

# Strip ESC sequences
clean = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', raw)   # CSI sequences (colours, cursor)
clean = re.sub(r'\x1b[()][AB012]', '', clean)          # charset switches ESC(0 / ESC(B
clean = re.sub(r'\x1b[=>]', '', clean)
clean = re.sub(r'\x1b\][^\x07]*\x07', '', clean)       # OSC sequences

# Strip control characters (keep \n \t)
clean = re.sub(r'[\x00-\x08\x0b-\x1f\x7f]', '', clean)
```

**Residue after stripping:** `ESC(0` / `ESC(B` are alternate-charset switches for box-drawing
characters. After stripping the ESC, the literal chars `l q k x t u m j` remain — these are
the ACS box-drawing chars in alternate charset. They appear in borders and separators.
They're harmless noise; just read past them when inspecting output.

## Full Example: Capture Detail View

```bash
expect -c '
  set timeout 4
  spawn env TERM=xterm COLUMNS=100 LINES=40 python3 /Users/omothm/.claude/unfence/summary.py
  expect -timeout 2 -re ".+"
  send "1"           ;# open detail view for rule #1
  after 300
  send [string repeat " " 8]   ;# scroll down to see lower sections
  expect -timeout 2 -re ".+"
  send "q"
  expect eof
' > /tmp/tui-detail.txt 2>/dev/null

python3 - <<'PYEOF'
import re
raw = open("/tmp/tui-detail.txt", errors="replace").read()
clean = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', raw)
clean = re.sub(r'\x1b[()][AB012]', '', clean)
clean = re.sub(r'\x1b[=>]', '', clean)
clean = re.sub(r'\x1b\][^\x07]*\x07', '', clean)
clean = re.sub(r'[\x00-\x08\x0b-\x1f\x7f]', '', clean)
lines = [l.rstrip() for l in clean.split('\n') if l.strip()]
# Find and print from the detail pane onwards
start = next((i for i, l in enumerate(lines) if '30d:' in l and 'allowed' in l), 0)
for l in lines[max(0, start-1):start+50]:
    print(l)
PYEOF
```

## Navigating to Different Views

| Key | Action |
|-----|--------|
| `1`–`9` | Open detail view for rule N |
| `j` / `k` (or `↓`/`↑`) | Navigate rule list |
| `\r` or `→` | Open detail view for selected rule |
| `\033` or `←` | Back to list |
| `c` | Change log view |
| `d` | Deferred log view |
| `e` | Eval pane (in list view) |
| `q` | Quit |
| `" "` (space) | Scroll down in detail/deferlog view |

## Navigating Rules by Name

To open a specific rule, count its position in the rule list (sorted alphabetically by
filename) and send the corresponding number. Rules beyond 9 require navigating with
`j`/`k` and pressing Enter.

## Gotchas

- **Always set `COLUMNS` and `LINES`** in the `spawn` env — without explicit dimensions
  curses may use 80×24 defaults which truncates wide content.
- **`after 300`** before capturing: the TUI renders asynchronously (background threads for
  summarization, stats). Without a brief delay, the pane may be mid-render.
- **Syntax check before spawning:** always run
  `python3 -m py_compile /Users/omothm/.claude/unfence/summary.py && echo OK`
  first to avoid spawning a broken process.
- **`expect eof` can hang** if the process doesn't exit cleanly. Always send `q` before
  `expect eof`, or add a generous `set timeout`.
