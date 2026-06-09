#!/usr/bin/env python3
"""Annotate ANSI SGR attributes in tmux capture-pane -e output.

Reads raw escape-sequence output from stdin and prints each line with
attribute tags injected: [B]=bold [D]=dim [B+D]=bold+dim [grn]=green etc.

Usage:
    tmux capture-pane -t SESSION -e -p | python3 attr_parse.py

Output example:
    3: │[D]  ## [B+grn]Results                                              │
"""
import re
import sys

COLORS = {0: 'blk', 1: 'red', 2: 'grn', 3: 'yel',
          4: 'blu', 5: 'mag', 6: 'cyn', 7: 'wht'}


def parse_state(codes, state):
    i = 0
    while i < len(codes):
        c = codes[i]
        if c == 0:
            state.clear()
        elif c == 1:
            state['bold'] = True
        elif c == 2:
            state['dim'] = True
        elif c == 22:
            state.pop('bold', None)
            state.pop('dim', None)
        elif 30 <= c <= 37:
            state['fg'] = COLORS[c - 30]
        elif c == 39:
            state.pop('fg', None)
        elif c == 38 and i + 2 < len(codes) and codes[i + 1] == 5:
            state['fg'] = f'c{codes[i + 2]}'
            i += 2
        i += 1


def fmt(state):
    if not state:
        return ''
    parts = []
    if state.get('bold'):
        parts.append('B')
    if state.get('dim'):
        parts.append('D')
    if 'fg' in state:
        parts.append(state['fg'])
    return '+'.join(parts)


SGR_RE = re.compile(r'\x1b\[([0-9;]*)m')
ESC_RE = re.compile(r'\x1b[\x20-\x2f]*[\x40-\x7e]|\x1b\[[^a-zA-Z]*[a-zA-Z]')

for lineno, line in enumerate(sys.stdin.read().split('\n')):
    pos = 0
    state = {}
    out = []
    while pos < len(line):
        ch = line[pos]
        if ch in '\x0e\x0f':
            pos += 1
            continue
        m = SGR_RE.match(line, pos)
        if m:
            codes = [int(x) if x else 0 for x in m.group(1).split(';')]
            parse_state(codes, state)
            pos = m.end()
            continue
        m = ESC_RE.match(line, pos)
        if m:
            pos = m.end()
            continue
        out.append((fmt(state), ch))
        pos += 1

    result = ''
    prev_tag = None
    run = ''
    for tag, ch in out:
        if tag == prev_tag:
            run += ch
        else:
            if run:
                result += (f'[{prev_tag}]{run}' if prev_tag else run)
            prev_tag = tag
            run = ch
    if run:
        result += (f'[{prev_tag}]{run}' if prev_tag else run)

    print(f'{lineno:2}: {result.rstrip()}')
