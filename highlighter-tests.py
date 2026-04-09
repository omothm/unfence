#!/usr/bin/env python3
"""
Tests for the deferlog syntax highlighting helpers in summary.py:
  - scan_heredoc_body_lines
  - scan_multiline_string_lines

Run directly:  python3 highlighter-tests.py
Or via:        bash run-tests.sh
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import summary

RED   = '\033[0;31m'
GREEN = '\033[0;32m'
NC    = '\033[0m'

_pass = 0
_fail = 0


def check(desc: str, actual, expected):
    global _pass, _fail
    if actual == expected:
        print(f"{GREEN}PASS{NC}  {desc}")
        _pass += 1
    else:
        print(f"{RED}FAIL{NC}  {desc}")
        print(f"      expected: {expected!r}")
        print(f"      actual:   {actual!r}")
        _fail += 1


# ── scan_heredoc_body_lines ───────────────────────────────────────────────────

def hd(cmd):
    return summary.scan_heredoc_body_lines(cmd)


check("hd: basic << EOF",
      hd("cat << EOF\nbody line\nEOF"),
      {1})

check("hd: single-quoted delimiter << 'EOF'",
      hd("cat << 'EOF'\nbody\nEOF"),
      {1})

check("hd: double-quoted delimiter << \"EOF\"",
      hd('cat << "EOF"\nbody\nEOF'),
      {1})

check("hd: <<- strips leading tabs from delimiter",
      hd("cat <<-EOF\nbody\nEOF"),
      {1})

check("hd: multiple body lines",
      hd("cat << EOF\nline1\nline2\nEOF"),
      {1, 2})

check("hd: empty heredoc (no body lines)",
      hd("cat << EOF\nEOF"),
      set())

check("hd: code after heredoc is not body",
      hd("cat << EOF\nbody\nEOF\necho done"),
      {1})

check("hd: code after heredoc — post-heredoc line index not in body",
      3 not in hd("cat << EOF\nbody\nEOF\necho done"),
      True)

check("hd: stacked heredocs on one line (FIFO)",
      hd("paste << A << B\nbody_a\nA\nbody_b\nB"),
      {1, 3})

check("hd: heredoc with surrounding shell commands",
      hd("echo start\ncat << EOF\nbody\nEOF\necho end"),
      {2})


# ── scan_multiline_string_lines ───────────────────────────────────────────────

def ml(cmd):
    return summary.scan_multiline_string_lines(cmd)


check("ml: all-closed double-quoted string",
      ml('echo "hello"'),
      (set(), {}))

check("ml: no quotes at all",
      ml("git push origin master"),
      (set(), {}))

check("ml: double-quoted multiline — body and closing line",
      ml('VAR="first line\nsecond line\nend"'),
      ({1}, {2: 3}))

check("ml: single-quoted multiline — body and closing line",
      ml("VAR='first line\nsecond line\nend'"),
      ({1}, {2: 3}))

check("ml: backslash-escaped quote does not open multiline",
      ml(r'echo "foo\"bar"'),
      (set(), {}))

# Bug case: apostrophe inside a heredoc body line (e.g. "don't") must not
# open a string context that bleeds into lines after the heredoc ends.
_body, _closings = ml("cat << 'DELIM'\ndon't stop\nDELIM\necho done")
check("ml: apostrophe in heredoc body does not bleed into post-heredoc lines",
      3 not in _body and 3 not in _closings,
      True)

# Realistic multi-apostrophe case: two apostrophes in body, code after heredoc
_body2, _close2 = ml(
    "cat << EOF\nOrg 4 couldn't be used\ndon't worry\nEOF\nBODY=$(cat /tmp/f)\ngh api"
)
check("ml: multiple apostrophes in heredoc body, post-heredoc lines clean",
      (4 not in _body2 and 5 not in _body2 and
       4 not in _close2 and 5 not in _close2),
      True)


# ── Summary ───────────────────────────────────────────────────────────────────

total = _pass + _fail
print()
print("═══════════════════════════════════════════════════════════════════")
if _fail == 0:
    print(f"{GREEN}All {total} highlighter tests passed.{NC}")
else:
    print(f"{RED}{_fail}/{total} highlighter tests failed.{NC}")
print("═══════════════════════════════════════════════════════════════════")

sys.exit(1 if _fail else 0)
