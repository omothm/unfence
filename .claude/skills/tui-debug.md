---
name: tui-debug
description: >
  Techniques for launching the unfence TUI (summary.py) non-interactively, sending keypresses,
  and capturing rendered output for visual verification — including color and attribute state.
  Apply whenever you need to visually inspect how a TUI change renders — after modifying
  summary.py views, adding new sections, or debugging layout issues.
user-invocable: false
---

# TUI Debugging

`summary.py` requires an interactive terminal (curses). To inspect its rendered output
non-interactively, use tmux to drive a PTY session and capture the screen.

## Prerequisites

- `tmux` is installed (`brew install tmux`).
- `python3` available for capture parsing.

## Standard Capture (structure only)

`tmux capture-pane -p` returns the **rendered screen text** with attributes stripped.
Use this for layout/structure checks — verifying text content, borders, line counts.

```bash
tmux new-session -d -s unfence-tui -x 120 -y 40 \
  'env TERM=xterm-256color python3 /Users/omothm/.claude/unfence/summary.py'
sleep 1.5
tmux send-keys -t unfence-tui "1" ""   # open detail view for rule #1
sleep 0.5
tmux capture-pane -t unfence-tui -p    # plain text, attributes stripped
tmux kill-session -t unfence-tui
```

## Attribute-Aware Capture (colors + bold/dim)

Use `-e` to **preserve ANSI escape sequences** in the capture output.
Then run the parser below to annotate each text segment with its SGR state.

```bash
tmux capture-pane -t unfence-tui -e -p > /tmp/tui-e.txt
```

### SGR Annotation Parser

Paste this inline after capturing to get annotated output showing
`[B]` (bold), `[D]` (dim), `[B+D]`, `[grn]`, `[red]`, `[cyn]`, etc.:

```python
python3 - <<'PYEOF'
import re

COLORS = {0:'blk',1:'red',2:'grn',3:'yel',4:'blu',5:'mag',6:'cyn',7:'wht'}

def parse_state(codes, state):
    i = 0
    while i < len(codes):
        c = codes[i]
        if c == 0:   state.clear()
        elif c == 1: state['bold'] = True
        elif c == 2: state['dim']  = True
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

raw = open("/tmp/tui-e.txt").read()
for lineno, line in enumerate(raw.split('\n')):
    pos = 0; state = {}; out = []
    while pos < len(line):
        ch = line[pos]
        if ch in '\x0e\x0f': pos += 1; continue          # ACS charset switch
        m = SGR_RE.match(line, pos)
        if m:
            codes = [int(x) if x else 0 for x in m.group(1).split(';')]
            parse_state(codes, state)
            pos = m.end(); continue
        m = ESC_RE.match(line, pos)
        if m: pos = m.end(); continue
        out.append((fmt(state), ch))
        pos += 1
    result = ""; prev_tag = None; run = ""
    for tag, ch in out:
        if tag == prev_tag: run += ch
        else:
            if run: result += (f'[{prev_tag}]{run}' if prev_tag else run)
            prev_tag = tag; run = ch
    if run: result += (f'[{prev_tag}]{run}' if prev_tag else run)
    print(f"{lineno:2}: {result.rstrip()}")
PYEOF
```

**Example output:**
```
 0: lqqq[B] #1. Strip Transparent Flags — 0-strip-flags.sh qqqk
 1: x[D]  30d: [B+grn]22[D] allowed   [B+red]0[D] denied   ·   Last modified: 4d ago   x
16: x[B+D]  qq Recent Commands qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqx
18: x[D]  2026-03-31 14:53  [B+grn]▶ allow  [B]git [D]-C /Users/omothm/... status      x
22: x[B+D]  qq Changes qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqx
```

`qq` = ACS_HLINE (renders as `─` in Ghostty). `[B+grn]` = bold green. `[D]` = dim.

## Full Example: Attribute-Aware Detail View

```bash
tmux new-session -d -s unfence-tui -x 120 -y 40 \
  'env TERM=xterm-256color python3 /Users/omothm/.claude/unfence/summary.py'
sleep 1.5
tmux send-keys -t unfence-tui "1" ""
sleep 0.5
tmux capture-pane -t unfence-tui -e -p > /tmp/tui-e.txt
tmux kill-session -t unfence-tui
# Then run the SGR parser above
```

## `tmux send-keys` Syntax

`tmux send-keys -t SESSION "text" ""` — the trailing `""` sends Enter.
For single keypresses that don't need Enter, **still include** the trailing `""` to flush:

```bash
tmux send-keys -t unfence-tui "j" ""   # navigate down
tmux send-keys -t unfence-tui "1" ""   # open rule #1 detail
tmux send-keys -t unfence-tui "q" ""   # quit
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

## Safe Rendering Patterns for summary.py

Font glyph width bugs are **invisible in tmux but visible in Ghostty**. Follow these
rules when writing any line-drawing or fill code in `summary.py`:

| Task | ❌ Avoid | ✅ Use instead |
|------|----------|----------------|
| Horizontal fill / separator | `addstr("─" * n)` | `stdscr.hline(row, col, ACS_HLINE, n, attr)` |
| Box border drawing | `addstr("│")` / `addstr("─")` | `addch(ACS_VLINE)` / `addch(ACS_HLINE)` |
| Column tracking after addstr | `col += len(text)` (when text has Unicode line-drawing chars) | Track only pure-ASCII text with `len()`; use absolute column positions for fills |
| Section header fill | compute fill string, append as ContentLine seg | Use `SecLine` item type — drawn via `hline(ACS_HLINE)` in `_draw_item` |

**Why:** Python's `len()` counts Unicode code points. ncurses counts display columns via
`wcwidth`. For pure-ASCII text these agree. For box-drawing chars (U+2500–U+257F), they
may disagree if the terminal's font renders them wider than one column. When they
disagree, `addstr` clips or raises silently, and tmux (which has its own width model)
shows no problem. Use `hline`/`addch` with ACS constants — ncurses owns the column
accounting entirely and the terminal's own rendering is always in sync.

## Why tmux over `expect`

`expect` only sees what the TUI *writes* (escape sequences). If curses's differential
refresh skips stale cells, `expect` sees nothing — but the user still sees the old content.
tmux `capture-pane` reads the terminal emulator's **rendered cell buffer**, so stale/
bleed-through artifacts are visible.

## Irreducible Limitations

These issues **cannot** be detected from any automated capture:

1. **Font glyph width** — tmux uses its own internal wcwidth table. If a Unicode character
   (e.g. `─` U+2500) renders at a different display width in Ghostty's font than tmux
   expects, tmux's cell buffer looks correct while Ghostty shows misaligned content.
   This is exactly what caused the section-header fill bug: tmux showed the fill correctly,
   Ghostty did not. The fix was to use `curses.hline(ACS_HLINE)` instead of `addstr("─"*n)`.
   **Rule:** if layout looks fine in tmux but broken in Ghostty, suspect double-width char
   desync. Use `curses.hline(ACS_HLINE)` for any repeated line-drawing fill.

2. **Exact color rendering** — I can see the ANSI color code (`grn` = color 2) but not
   the exact RGB Ghostty maps it to. Whether `grn` looks good on Ghostty's dark theme
   requires a user screenshot.

3. **Terminal theme** — dim (`[D]`) is nearly invisible on some dark themes (e.g. Ghostty's
   default). Use `[B+D]` (bold+dim) for text that must be readable but subdued.

4. **Ligatures / kerning** — not visible in cell buffer.

When a visual issue only appears in Ghostty (not tmux), ask the user for a screenshot.

## Gotchas

- **Always set tmux dimensions explicitly** via `-x W -y H` — without them tmux defaults
  to 80×24 which truncates wide content.
- **`after 300` / `sleep 0.5`** before capturing: the TUI renders asynchronously
  (background threads for summarization, stats). Without a brief delay, the pane may be
  mid-render.
- **Syntax check before spawning:**
  ```bash
  python3 -m py_compile /Users/omothm/.claude/unfence/summary.py && echo OK
  ```
- **ACS chars in `-p` output** appear as `q x l k m j t u` — these are the raw alternate-
  charset letters. They map to: `q`=─, `x`=│, `l`=┌, `k`=┐, `m`=└, `j`=┘, `t`=├, `u`=┤.
  In the annotated `-e` output, they appear the same way — just read past them.
