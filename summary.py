#!/usr/bin/env python3
"""Auto-accept rules TUI.  ↑/↓ PgUp/PgDn Home/End  r=reload  e=evaluate  q=quit"""

import curses
import json
import os
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

PROJECT_DIR     = Path(__file__).parent
RULES_DIR       = PROJECT_DIR / "rules"
CACHE_DIR       = PROJECT_DIR / ".claude" / "cache"
SHADOW_CACHE    = CACHE_DIR / ".shadowing.json"
LOG_STATS_CACHE = CACHE_DIR / ".log-stats.json"
LOG_FILE        = PROJECT_DIR / "logs" / "unfence.log"
CHANGE_LOG      = PROJECT_DIR / "logs" / "changes.log"
REC_CACHE       = CACHE_DIR / ".recs.json"
ACCEPTED_REC    = CACHE_DIR / ".accepted-recs.json"
SKILL_FILE      = PROJECT_DIR / ".claude" / "skills" / "implement-recommendations.md"


# ── Data helpers ──────────────────────────────────────────────────────────────

def get_rules():
    return sorted(
        r for r in RULES_DIR.glob("*.sh")
        if not r.name.endswith(".test.sh")
    )

def is_stale(rule: Path) -> bool:
    cache = CACHE_DIR / rule.name
    return not cache.exists() or rule.stat().st_mtime > cache.stat().st_mtime

def load_cache(rule: Path):
    cache = CACHE_DIR / rule.name
    if cache.exists():
        try:
            return json.loads(cache.read_text())
        except Exception:
            pass
    return None

def check_auto_created(rule: Path) -> bool:
    try:
        for line in rule.read_text().splitlines()[:3]:
            if line.strip() == "# auto-created":
                return True
    except Exception:
        pass
    return False

def summarize_rule(rule: Path):
    content = rule.read_text()
    prompt = (
        "Output a JSON object (no markdown) for this shell permission rule "
        "with three keys:\n"
        '- "title": 1-3 words capturing the rule purpose\n'
        '- "summary": one sentence, max 20 words, describing what commands '
        "it matches and what verdict it returns\n"
        '- "description": a thorough reference description for administrators. '
        "If the rule defines named arrays or lists (e.g. DENY, ASK, ALLOW), describe each array's "
        "purpose and enumerate its major command categories with representative examples from the actual list. "
        "Describe the matching algorithm (positional words, required flags, specificity scoring, tie-breaking). "
        "Cover any special logic (transparent flag stripping, recursion, sub-command checks). "
        "Be complete — do not truncate or summarise away details. Aim for 8-15 sentences. "
        "Organize into logical paragraphs separated by blank lines (\\n\\n). "
        "Use **bold** for key terms and `backticks` for command names, flags, and code.\n\n"
        + content
    )
    result = subprocess.run(
        ["claude", "-p", prompt, "--model", "haiku",
         "--output-format", "text", "--setting-sources", "project,local"],
        capture_output=True, text=True,
    )
    output = "\n".join(
        line for line in result.stdout.splitlines()
        if not line.startswith("```")
    ).strip()
    if output:
        (CACHE_DIR / rule.name).write_text(output)

def relative_time(mtime: float) -> str:
    diff = time.time() - mtime
    if diff < 60:        return "just now"
    if diff < 3600:      return f"{int(diff // 60)}m ago"
    if diff < 86400:     return f"{int(diff // 3600)}h ago"
    if diff < 7*86400:   return f"{int(diff // 86400)}d ago"
    if diff < 30*86400:  return f"{int(diff // (7*86400))}w ago"
    if diff < 365*86400: return f"{int(diff // (30*86400))}mo ago"
    return f"{int(diff // (365*86400))}y ago"

def _log_size():
    """Current byte size of the log file, or 0 if absent."""
    try:
        return LOG_FILE.stat().st_size
    except Exception:
        return 0


def _log_cache_key():
    """(mtime, size) of the log file, or (0, 0) if absent."""
    try:
        st = LOG_FILE.stat()
        return st.st_mtime, st.st_size
    except Exception:
        return 0, 0


def append_change_log(source: str, rule: str, msg: str):
    """Append a change entry to the rule change log (JSON-lines)."""
    import datetime
    entry = {
        "ts":     datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
        "source": source,
        "rule":   rule,
        "msg":    msg,
    }
    try:
        CHANGE_LOG.parent.mkdir(parents=True, exist_ok=True)
        with CHANGE_LOG.open("a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception:
        pass


def load_change_log(rule_name=None) -> list:
    """Load change log entries, optionally filtered by rule name.
    Returns list of dicts, newest first."""
    entries = []
    try:
        for line in CHANGE_LOG.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
                if rule_name is None or entry.get("rule") == rule_name:
                    entries.append(entry)
            except Exception:
                pass
    except Exception:
        pass
    return list(reversed(entries))


def _ts_of(line: str):
    """Extract the timestamp string from a log line, or None."""
    import re
    m = re.match(r'\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]', line)
    return m.group(1) if m else None


def _parse_deferred_commands(after_ts: str = ""):
    """Parse log for commands that fully deferred (no rule matched).
    Only processes lines with timestamp > after_ts (lexicographic compare is
    correct because the format is fixed-width ISO-like).
    Returns (dict, last_ts):
      dict: {pattern: {"count": N, "examples": [...]}}
      last_ts: timestamp string of the last line examined, or after_ts if none.
    """
    import re
    result = {}
    last_ts = after_ts
    try:
        all_lines = LOG_FILE.read_text(errors="replace").splitlines()
    except Exception:
        return result, last_ts

    # Find the first line index whose timestamp is strictly after after_ts.
    # Scan backward from the end for efficiency on large, mostly-old logs.
    start_idx = 0
    if after_ts:
        for k in range(len(all_lines) - 1, -1, -1):
            ts = _ts_of(all_lines[k])
            if ts and ts <= after_ts:
                start_idx = k + 1
                break

    lines = all_lines[start_idx:]

    def session_of(line):
        m = re.match(r'\[.*?\] \[([^\]]+)\]', line)
        return m.group(1) if m else None

    for i, line in enumerate(lines):
        ts = _ts_of(line)
        if ts and (last_ts is None or ts > last_ts):
            last_ts = ts
        if '=> defer (some parts had no matching rule)' not in line:
            continue
        sess = session_of(line)
        if not sess:
            continue
        # Look back within the new slice first, then into the preceding context.
        search_lines = all_lines[max(0, start_idx + i - 20): start_idx + i]
        for prev in reversed(search_lines):
            if '] INPUT ' not in prev:
                continue
            if session_of(prev) != sess:
                continue
            m = re.match(r'\[.*?\] \[.*?\] INPUT (.*)', prev)
            if not m:
                continue
            raw = m.group(1).strip()
            tokens = raw.split()
            pattern = ' '.join(tokens[:2]) if len(tokens) >= 2 else tokens[0] if tokens else raw
            if pattern not in result:
                result[pattern] = {"count": 0, "examples": []}
            result[pattern]["count"] += 1
            if raw not in result[pattern]["examples"]:
                result[pattern]["examples"].append(raw)
                if len(result[pattern]["examples"]) > 5:
                    result[pattern]["examples"] = result[pattern]["examples"][-5:]
            break
    return result, last_ts


def _engine_verdict(pattern: str) -> str:
    """Run a command pattern through the unfence engine eval mode."""
    try:
        engine = PROJECT_DIR / "hooks" / "unfence.sh"
        result = subprocess.run(
            ["bash", str(engine)],
            capture_output=True, text=True,
            env={**os.environ, "EVAL_MODE": "1", "CMD": pattern, "NO_LOG": "1"},
            timeout=5,
        )
        data = json.loads(result.stdout.strip())
        return data.get("verdict", "defer")
    except Exception:
        return "defer"


def analyze_recommendations(deferred: dict, dismissed: set, on_proc=None) -> list:
    """AI analysis of deferred commands. Returns list of safe rec dicts.
    Each dict: {pattern, examples, count, rationale}
    dismissed: set of patterns to skip.
    on_proc: optional callback(proc) when subprocess starts.
    """
    # Filter out patterns already handled by the engine (false positives from
    # compound commands where only a *different* sub-command deferred).
    def _already_covered(pattern: str, info: dict) -> bool:
        """True if the pattern or any of its example commands is already allowed."""
        if _engine_verdict(pattern) == "allow":
            return True
        return any(_engine_verdict(ex) == "allow" for ex in info.get("examples", []))

    already_allowed = [p for p, v in deferred.items()
                       if p not in dismissed and _already_covered(p, v)]
    candidates = {p: v for p, v in deferred.items()
                  if p not in dismissed and not _already_covered(p, v)}

    rec_log = CACHE_DIR / "rec-analysis.log"
    def _log(msg: str):
        try:
            with rec_log.open("a") as f:
                f.write(msg + "\n")
        except Exception:
            pass

    import datetime
    _log(f"\n{'='*60}")
    _log(f"[{datetime.datetime.now():%Y-%m-%d %H:%M:%S}] FILTER")
    _log(f"  deferred patterns: {sorted(deferred.keys())}")
    _log(f"  already allowed (filtered): {sorted(already_allowed)}")
    _log(f"  candidates for haiku: {sorted(candidates.keys())}")

    if not candidates:
        return []

    lines = []
    for pattern, info in sorted(candidates.items(), key=lambda x: -x[1]["count"]):
        exs = "  |  ".join(info["examples"][:3])
        lines.append(f'  {info["count"]}x  {pattern}  e.g. "{exs}"')

    # Build a compact view of current rule files so the model knows what is
    # already handled and does not re-recommend those patterns.
    rule_sections = []
    for rule_path in sorted(RULES_DIR.glob("*.sh")):
        if rule_path.name.endswith(".test.sh"):
            continue
        try:
            rule_sections.append(f"### {rule_path.name}\n{rule_path.read_text()}")
        except Exception:
            pass
    rules_block = (
        "Current rule files (already handled — do NOT recommend any pattern "
        "already covered by these rules):\n\n"
        + "\n\n".join(rule_sections)
        + "\n\n"
    ) if rule_sections else ""

    prompt = (
        "You are analyzing bash commands that were deferred to a human prompt because no "
        "unfence rule matched them. Assess which patterns are safe to auto-approve.\n\n"
        "Rules for SAFE: read-only introspection (status, list, show, describe, query), "
        "syntax/compile checks, running well-known test/build tools in a repo, "
        "standard help/version flags.\n"
        "Rules for NOT SAFE: anything that mutates files, pushes code, modifies system "
        "state, makes network requests beyond read-only fetches, has irreversible effects, "
        "spawns or wraps other programs (e.g. script, watch, xargs, nohup, eval), "
        "or monitors/reacts to filesystem events (e.g. fswatch, inotifywait).\n\n"
        "IMPORTANT: assess every pattern regardless of how many times it occurred. "
        "A pattern seen only once may still be worth whitelisting if it is clearly safe. "
        "When in doubt, exclude — only recommend patterns that are unambiguously read-only "
        "or widely-used build/test tooling with no meaningful side effects.\n\n"
        "Before finalising your output, do a safety pass over each candidate you intend to "
        "recommend: ask yourself 'if this prefix were auto-allowed with no further checks, "
        "what is the worst a malicious or mistaken command matching it could do?' "
        "If the answer is anything beyond harmless read-only introspection, drop it.\n\n"
        + rules_block
        + "Commands (count × pattern  e.g. example):\n"
        + "\n".join(lines) + "\n\n"
        "PATTERN SPECIFICITY: Choose the most specific safe prefix — use the examples to "
        "determine the right depth. If all examples share the same subcommand (e.g. 'sf config get'), "
        "use that full subcommand as the pattern. Only use a short 1-2 token prefix when the "
        "examples vary in subcommand and all variants are safe. Never return a shorter prefix "
        "than what the examples justify.\n\n"
        "Return a JSON array of safe patterns only:\n"
        '[{"pattern": "most specific safe prefix", "examples": ["ex1", "ex2"], "count": N, "rationale": "one sentence why safe"}]\n'
        "Return [] if nothing is clearly safe. No markdown fences."
    )

    try:
        _log(f"[{datetime.datetime.now():%Y-%m-%d %H:%M:%S}] PROMPT")
        _log(prompt)

        env = {**os.environ}
        proc = subprocess.Popen(
            ["claude", "-p", prompt, "--model", "claude-haiku-4-5-20251001",
             "--output-format", "text", "--setting-sources", "project,local",
             "-n", "unfence: shadow analysis"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=env,
        )
        if on_proc:
            on_proc(proc)
        stdout, stderr = proc.communicate(timeout=60)
        _log(f"[{datetime.datetime.now():%Y-%m-%d %H:%M:%S}] RESPONSE")
        _log(stdout)
        if stderr.strip():
            _log(f"STDERR: {stderr.strip()}")

        output = "\n".join(
            line for line in stdout.splitlines()
            if not line.startswith("```")
        )
        candidates_ai = json.loads(output.strip())
        if not isinstance(candidates_ai, list):
            candidates_ai = []
        # Validate and enrich with actual counts/examples from deferred dict
        result = []
        for item in candidates_ai:
            p = item.get("pattern", "")
            if not p:
                continue
            # Find actual data for this pattern. The AI may return a more specific
            # prefix than the 2-token grouping keys in deferred (e.g. "gh auth status"
            # vs key "gh auth"), so match both directions.
            matching = {k: v for k, v in deferred.items()
                        if k == p or k.startswith(p) or p.startswith(k)}
            total = sum(v["count"] for v in matching.values())
            all_exs = []
            for v in matching.values():
                all_exs.extend(v["examples"])
            # Prefer examples that actually start with the recommended pattern.
            # Fall back to all examples only if none match (e.g. pattern is more
            # specific than the deferred grouping key).
            exs = [e for e in all_exs if e.startswith(p)] or all_exs
            result.append({
                "pattern": p,
                "examples": exs[:5],
                "count": total or item.get("count", 0),
                "rationale": item.get("rationale", ""),
            })
        _log(f"RESULT: {len(result)} recs: {[r['pattern'] for r in result]}")
        return result
    except Exception:
        return []


def load_rec_cache():
    """Load recommendations from cache.
    Returns (recs, dismissed_set, last_ts).
    """
    try:
        data = json.loads(REC_CACHE.read_text())
        recs      = data.get("recs", [])
        dismissed = set(data.get("dismissed", []))
        last_ts   = data.get("last_ts", "")
        return recs, dismissed, last_ts
    except Exception:
        return [], set(), ""


def save_rec_cache(recs: list, dismissed: set, last_ts: str):
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        REC_CACHE.write_text(json.dumps({
            "last_ts":   last_ts,
            "log_size":  _log_size(),   # staleness sentinel
            "recs":      recs,
            "dismissed": list(dismissed),
        }))
    except Exception:
        pass


def rec_cache_stale() -> bool:
    """True if cache doesn't exist or log size has changed since last analysis."""
    try:
        data = json.loads(REC_CACHE.read_text())
        return data.get("log_size", 0) != _log_size()
    except Exception:
        return True




def load_deferred_commands() -> list[tuple[str, str]]:
    """Parse the unfence log and return (timestamp, command) for deferred sessions
    from the last 30 days, newest first."""
    import datetime
    log_file = PROJECT_DIR / "logs" / "unfence.log"
    if not log_file.exists():
        return []
    cutoff = datetime.datetime.now() - datetime.timedelta(days=30)
    LOG_RE = re.compile(r'^\[([^\]]+)\] \[(\d+)\] (.+)$')
    TS_FMT = "%Y-%m-%d %H:%M:%S"
    pid_input: dict[str, tuple[str, str]] = {}   # pid -> (ts, command)
    results: list[tuple[str, str]] = []
    cur_pid: str | None = None
    cur_ts:  str        = ""
    cur_lines: list[str] = []

    def _flush():
        if cur_pid and cur_lines:
            msg = "\n".join(cur_lines)
            if msg.startswith("INPUT "):
                pid_input[cur_pid] = (cur_ts, msg[6:])
            elif msg == "=> defer (some parts had no matching rule)":
                if cur_pid in pid_input:
                    results.append(pid_input[cur_pid])

    try:
        with open(log_file, "r", errors="replace") as fh:
            for raw in fh:
                line = raw.rstrip("\n")
                m = LOG_RE.match(line)
                if m:
                    _flush()
                    cur_ts, cur_pid, cur_lines = m.group(1), m.group(2), [m.group(3)]
                    try:
                        if datetime.datetime.strptime(cur_ts, TS_FMT) < cutoff:
                            cur_pid = None  # skip entries older than 30 days
                    except ValueError:
                        pass
                else:
                    cur_lines.append(line)
        _flush()
    except OSError:
        pass
    results.reverse()
    return results


def load_log_stats() -> dict:
    """Count allow/deny/defer verdicts from the last 30 days of the engine log.
    Cached by log (mtime, size).
    """
    import datetime

    mtime, size = _log_cache_key()
    try:
        cached = json.loads(LOG_STATS_CACHE.read_text())
        if cached.get("mtime") == mtime and cached.get("size") == size:
            return cached["counts"]
    except Exception:
        pass

    cutoff = (datetime.date.today() - datetime.timedelta(days=30)).isoformat()
    counts = {"allow": 0, "deny": 0, "defer": 0, "per_rule": {}}
    # Track which rules fired per PID within a compound command (to count once per compound)
    pid_rule_allow: dict = {}  # pid -> set of rule filenames that fired allow
    pid_rule_deny:  dict = {}  # pid -> set of rule filenames that fired deny

    try:
        with LOG_FILE.open() as fh:
            for line in fh:
                if len(line) < 12 or line[1:11] < cutoff:
                    continue
                b = line.find('[', 1)
                if b < 0:
                    continue
                e = line.find(']', b)
                if e < 0:
                    continue
                pid  = line[b + 1:e]
                rest = line[e + 1:]

                if ' => ' in rest:
                    for v in ('allow', 'deny', 'defer'):
                        if f' => {v}' in rest:
                            counts[v] += 1
                            break
                    # Credit each rule that contributed, once per compound command
                    for fname in pid_rule_allow.pop(pid, set()):
                        counts["per_rule"].setdefault(fname, {"allow": 0, "deny": 0})["allow"] += 1
                    for fname in pid_rule_deny.pop(pid, set()):
                        counts["per_rule"].setdefault(fname, {"allow": 0, "deny": 0})["deny"] += 1
                elif '-> allow' in rest or '-> deny' in rest:
                    ob = rest.find('(')
                    cb = rest.find(')', ob) if ob >= 0 else -1
                    if ob >= 0 and cb > ob:
                        fname = rest[ob + 1:cb]
                        if '-> allow' in rest:
                            pid_rule_allow.setdefault(pid, set()).add(fname)
                        else:
                            pid_rule_deny.setdefault(pid, set()).add(fname)
    except Exception:
        pass

    try:
        LOG_STATS_CACHE.write_text(
            json.dumps({"mtime": mtime, "size": size, "counts": counts})
        )
    except Exception:
        pass

    return counts


def load_recent_rule_matches(rule_name: str, limit: int = 3) -> list[tuple[str, str, str]]:
    """Return up to `limit` (timestamp, command, verdict) tuples for commands
    matched by `rule_name` with a final allow or deny compound verdict, newest first."""
    import datetime
    log_file = PROJECT_DIR / "logs" / "unfence.log"
    if not log_file.exists():
        return []

    LOG_RE = re.compile(r'^\[([^\]]+)\] \[(\d+)\] (.+)$')
    cutoff  = (datetime.date.today() - datetime.timedelta(days=30)).isoformat()

    pid_ts:      dict[str, str] = {}   # pid -> timestamp of INPUT
    pid_cmd:     dict[str, str] = {}   # pid -> command string
    pid_subcmd:  dict[str, str] = {}   # pid -> last classify[0] sub-command seen
    pid_matched: dict[str, str] = {}   # pid -> matched sub-command for this rule
    results: list[tuple[str, str, str]] = []

    try:
        with log_file.open(errors="replace") as fh:
            for raw in fh:
                line = raw.rstrip("\n")
                if len(line) < 12 or line[1:11] < cutoff:
                    continue
                m = LOG_RE.match(line)
                if not m:
                    continue
                ts, pid, rest = m.group(1), m.group(2), m.group(3)

                if rest.startswith("INPUT "):
                    pid_ts[pid]  = ts
                    pid_cmd[pid] = rest[6:]
                    pid_subcmd.pop(pid, None)
                    pid_matched.pop(pid, None)
                elif rest.startswith("  classify[0]: "):
                    pid_subcmd[pid] = rest[len("  classify[0]: "):]
                elif '-> allow' in rest or '-> deny' in rest:
                    ob = rest.find('(')
                    cb = rest.find(')', ob) if ob >= 0 else -1
                    if ob >= 0 and cb > ob and rest[ob + 1:cb] == rule_name:
                        # Store the sub-command that actually matched, not the full compound input
                        pid_matched[pid] = "allow" if '-> allow' in rest else "deny"
                        pid_cmd[pid] = pid_subcmd.get(pid, pid_cmd.get(pid, ""))
                elif rest.startswith('=> ') and pid in pid_matched and pid in pid_cmd:
                    for v in ('allow', 'deny'):
                        if f'=> {v}' in rest:
                            results.append((pid_ts.get(pid, ts), pid_cmd[pid], v))
                            break
                    pid_cmd.pop(pid, None)
                    pid_subcmd.pop(pid, None)
                    pid_matched.pop(pid, None)
                    pid_ts.pop(pid, None)
    except OSError:
        pass

    results.reverse()
    return results[:limit]


def word_wrap(text: str, width: int):
    words = text.split()
    current = ""
    for word in words:
        if not current:
            current = word
        elif len(current) + 1 + len(word) <= width:
            current += " " + word
        else:
            yield current
            current = word
    if current:
        yield current


def parse_md(text: str, normal, bold_attr, code_attr):
    """Parse **bold** and `code` spans; return list of (attr, str) segments."""
    import re
    segments = []
    last = 0
    for m in re.finditer(r'\*\*(.+?)\*\*|`([^`]+)`', text):
        if m.start() > last:
            segments.append((normal, text[last:m.start()]))
        if m.group(1) is not None:
            segments.append((bold_attr, m.group(1)))
        else:
            segments.append((code_attr, m.group(2)))
        last = m.end()
    if last < len(text):
        segments.append((normal, text[last:]))
    return segments or [(normal, text)]


# ── Deferlog syntax highlighting ──────────────────────────────────────────────
# Self-contained; used only in _draw_deferlog_view.
# To remove: delete this block and revert the sections marked [SH] below.

_SH_PATTERNS = [
    # name          regex                                   colour key
    ("comment",     re.compile(r'(#.*)'),                              "dim"),
    ("string_dq",   re.compile(r'("(?:[^"\\]|\\.)*")'),               "yellow"),
    ("string_sq",   re.compile(r"('(?:[^'\\]|\\.)*')"),               "yellow"),
    ("variable",    re.compile(r'(\$\{[^}]+\}|\$[A-Za-z_]\w*)'),      "green"),
    ("operator",    re.compile(r'(&&|\|\||[|;&]|>>?|<(?:<|&\d+)?)'),  "cyan"),
    ("flag",        re.compile(r'((?<!\w)--?[A-Za-z][\w-]*)'),        "dim"),
]
_SH_COMBINED = re.compile(
    "|".join(f"(?P<{name}>{pat.pattern})" for name, pat, _ in _SH_PATTERNS)
)
_SH_COLOUR = {name: col for name, _, col in _SH_PATTERNS}

def _sh_attr(key: str):
    if key == "yellow":  return curses.color_pair(1)
    if key == "green":   return curses.color_pair(6)
    if key == "cyan":    return curses.color_pair(4)
    if key == "dim":     return curses.A_DIM
    return curses.A_NORMAL

def highlight_shell(line: str) -> list:
    """
    Tokenise a full logical shell line into [(attr, text), …].
    The first plain word is bolded as the command name.
    Falls back to [(A_NORMAL, line)] on any error.
    """
    try:
        segs = []
        first_word_done = False
        pos = 0
        for m in _SH_COMBINED.finditer(line):
            if m.start() > pos:
                plain = line[pos:m.start()]
                if not first_word_done and plain.split():
                    word = plain.split()[0]
                    idx  = plain.index(word)
                    if idx:
                        segs.append((curses.A_NORMAL, plain[:idx]))
                    segs.append((curses.A_BOLD, word))
                    rest = plain[idx + len(word):]
                    if rest:
                        segs.append((curses.A_NORMAL, rest))
                    first_word_done = True
                else:
                    segs.append((curses.A_NORMAL, plain))
            segs.append((_sh_attr(_SH_COLOUR[m.lastgroup]), m.group()))
            first_word_done = True
            pos = m.end()
        if pos < len(line):
            tail = line[pos:]
            if not first_word_done and tail.split():
                word = tail.split()[0]
                idx  = tail.index(word)
                if idx:
                    segs.append((curses.A_NORMAL, tail[:idx]))
                segs.append((curses.A_BOLD, word))
                rest = tail[idx + len(word):]
                if rest:
                    segs.append((curses.A_NORMAL, rest))
            else:
                segs.append((curses.A_NORMAL, tail))
        return segs if segs else [(curses.A_NORMAL, line)]
    except Exception:
        return [(curses.A_NORMAL, line)]

def wrap_token_line(segs: list, width: int) -> list:
    """
    Wrap [(attr, text), …] to *width* chars, returning a list of display lines.
    Splits only at spaces within A_NORMAL segments; all other tokens are atomic.
    Falls back to [segs] on any error.
    """
    try:
        # Build words: each is a list of (attr, text), separated by space runs
        words, pending = [], []
        for attr, text in segs:
            if attr == curses.A_NORMAL:
                for part in re.split(r'( +)', text):
                    if not part:
                        continue
                    if ' ' in part:          # space run — flush current word
                        if pending:
                            words.append(pending)
                            pending = []
                    else:
                        pending.append((attr, part))
            else:
                pending.append((attr, text))  # atomic token — never split
        if pending:
            words.append(pending)
        if not words:
            return [[]]
        # Greedy line-fill
        lines, cur, cur_len = [], [], 0
        for word in words:
            wlen = sum(len(t) for _, t in word)
            if not cur:
                cur, cur_len = list(word), wlen
            elif cur_len + 1 + wlen <= width:
                cur.append((curses.A_NORMAL, ' '))
                cur.extend(word)
                cur_len += 1 + wlen
            else:
                lines.append(cur)
                cur, cur_len = list(word), wlen
        if cur:
            lines.append(cur)
        return lines if lines else [[]]
    except Exception:
        return [segs]

def scan_multiline_string_lines(cmd: str) -> tuple:
    """
    Return (body, closings) where:
    - body: set of line indices (0-based) that are entirely inside a
      multi-line quoted string (single or double).
    - closings: dict mapping line_idx → column of the closing quote on
      lines that terminate a multi-line string.  The prefix up to and
      including that column is string content; everything after is shell.
    The opening line (which starts the unclosed quote) is in neither set.
    """
    lines     = cmd.split("\n")
    body: set  = set()
    closings: dict = {}
    in_string = None   # '"' or "'" when inside an unclosed string
    for i, line in enumerate(lines):
        if in_string:
            # Scan for the closing quote, honouring backslash escapes
            j, closed, close_col = 0, False, -1
            while j < len(line):
                c = line[j]
                if c == '\\':
                    j += 2
                    continue
                if c == in_string:
                    closed     = True
                    close_col  = j
                    in_string  = None
                    break
                j += 1
            if closed:
                closings[i] = close_col
            else:
                body.add(i)
        else:
            # Look for an unclosed opening quote on this line
            j = 0
            while j < len(line):
                c = line[j]
                if c == '\\':
                    j += 2
                    continue
                if c in ('"', "'"):
                    quote = c
                    j += 1
                    closed = False
                    while j < len(line):
                        c2 = line[j]
                        if c2 == '\\':
                            j += 2
                            continue
                        if c2 == quote:
                            closed = True
                            break
                        j += 1
                    if not closed:
                        in_string = quote
                        break
                j += 1
    return body, closings


def scan_heredoc_body_lines(cmd: str) -> set:
    """
    Return set of line indices (0-based) that are heredoc body lines.
    Handles <<DELIM, <<'DELIM', <<"DELIM", <<-DELIM.
    Stacked heredocs (multiple << on one line) are processed FIFO.
    """
    lines   = cmd.split("\n")
    body    = set()
    pending = []   # queue of raw delimiter strings
    for i, line in enumerate(lines):
        if pending:
            if line.strip() == pending[0]:
                pending.pop(0)
            else:
                body.add(i)
        # Always scan for new << markers (handles stacked heredocs)
        if not (pending and line.strip() == pending[0]):  # skip if just closed
            for m in re.finditer(r'<<-?\s*["\']?(\w+)["\']?', line):
                pending.append(m.group(1))
    return body

# ── End deferlog syntax highlighting ──────────────────────────────────────────


def delete_rule(rule: Path):
    """Delete a rule file, its companion test file, and its cache entry."""
    test = rule.parent / rule.name.replace(".sh", ".test.sh")
    for p in (rule, test, CACHE_DIR / rule.name):
        try:
            p.unlink()
        except Exception:
            pass


# ── Shadow detection ──────────────────────────────────────────────────────────

def _shadow_cache_key(rules):
    if not rules:
        return 0.0, 0
    return max(r.stat().st_mtime for r in rules), len(rules)

def load_shadow_cache(rules):
    if not SHADOW_CACHE.exists():
        return None
    try:
        data = json.loads(SHADOW_CACHE.read_text())
        mtime, count = _shadow_cache_key(rules)
        if data.get("count") != count:
            return None
        if abs(data.get("mtime", 0) - mtime) > 0.001:
            return None
        return data.get("shadows", [])
    except Exception:
        return None

def _verify_shadow(shadower: Path, shadowed: Path, example: str) -> bool:
    """Dynamically confirm both rules return non-defer for the example command."""
    env = {**os.environ, "COMMAND": example}
    for rule in (shadower, shadowed):
        try:
            r = subprocess.run(
                ["bash", str(rule)], env=env,
                capture_output=True, text=True, timeout=5,
            )
            verdict = r.stdout.strip()
        except Exception:
            return False
        if verdict in ("", "defer") or verdict.startswith("recurse:"):
            return False
    return True

def analyze_shadows(rules, on_proc=None):
    if not rules:
        return []
    rule_map = {r.name: r for r in rules}
    sections = []
    for i, rule in enumerate(rules, 1):
        try:
            content = rule.read_text()
        except Exception:
            content = "(unreadable)"
        sections.append(f"--- Rule {i}: {rule.name} ---\n{content}")
    prompt = (
        "Analyze these shell permission rules, run in order by a permission engine. "
        "Each rule reads $COMMAND and outputs: allow, deny, ask, defer, or recurse:<cmd>. "
        "'defer' means pass to the next rule; any other output is final.\n\n"
        "A rule SHADOWS a later rule when it returns a non-defer verdict for commands "
        "that the later rule would also match — preventing that later rule from ever running.\n\n"
        "Instructions:\n"
        "- Trace each rule's code carefully for your example command before reporting.\n"
        "- Verify the shadower actually returns non-defer for the example "
        "(check arrays, conditions, and logic precisely — do not assume).\n"
        "- Verify the shadowed rule would also return non-defer for the same example.\n"
        "- Only report a shadow if BOTH rules would fire for the same command.\n"
        "- Ignore overlaps where both rules agree on the verdict and the overlap is harmless.\n\n"
        "Output a JSON array (no markdown). Each element:\n"
        '  {"shadower": "filename", "shadowed": "filename", "example": "example command"}\n'
        "If none, output: []\n\n"
        + "\n\n".join(sections)
    )
    proc = subprocess.Popen(
        ["claude", "-p", prompt, "--model", "sonnet",
         "-n", "unfence: recommendations"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    if on_proc:
        on_proc(proc)
    stdout, _ = proc.communicate()
    output = "\n".join(
        line for line in stdout.splitlines()
        if not line.startswith("```")
    )
    try:
        candidates = json.loads(output.strip())
        if not isinstance(candidates, list):
            candidates = []
    except Exception:
        candidates = []

    # Dynamically verify each candidate — discard any where either rule defers
    shadows = []
    for s in candidates:
        shr_name = s.get("shadower", "")
        shd_name = s.get("shadowed", "")
        example  = s.get("example", "")
        if not (shr_name and shd_name and example):
            continue
        shr = rule_map.get(shr_name)
        shd = rule_map.get(shd_name)
        if shr and shd and _verify_shadow(shr, shd, example):
            shadows.append(s)

    mtime, count = _shadow_cache_key(rules)
    SHADOW_CACHE.write_text(json.dumps({"mtime": mtime, "count": count, "shadows": shadows}))
    return shadows


# ── Live evaluation ───────────────────────────────────────────────────────────

ENGINE = PROJECT_DIR / "hooks" / "unfence.sh"

def evaluate_command(cmd: str):
    """Run cmd through the full engine pipeline. Returns (verdict, rule_name | None, deferred_parts)."""
    env = {**os.environ, "EVAL_MODE": "1", "CMD": cmd, "NO_LOG": "1"}
    try:
        r = subprocess.run(
            ["bash", str(ENGINE)], env=env,
            capture_output=True, text=True, timeout=15,
        )
        data = json.loads(r.stdout.strip())
        return data.get("verdict", "defer"), data.get("rule") or None, data.get("parts") or []
    except Exception:
        return "defer", None, []


# ── Layout objects ────────────────────────────────────────────────────────────

class HLine:
    __slots__ = ("lch", "rch")
    def __init__(self, lch, rch):
        self.lch = lch
        self.rch = rch

class ContentLine:
    __slots__ = ("segs", "bordered", "border_attr")
    def __init__(self, segs, bordered=True, border_attr=None):
        self.segs        = segs
        self.bordered    = bordered
        self.border_attr = border_attr  # if set, overrides default attr for │ chars

class SecLine:
    """Section header: '  ── {label} ' followed by ACS_HLINE fill to right border."""
    __slots__ = ("label", "attr")
    def __init__(self, label: str, attr: int):
        self.label = label
        self.attr  = attr


# ── Terminal protocol helpers ─────────────────────────────────────────────────

def _write_tty(s: str):
    try:
        sys.stdout.write(s)
        sys.stdout.flush()
    except Exception:
        pass

def enable_terminal_protocols():
    _write_tty("\033[?2004h")                        # bracketed paste mode
    _write_tty("\033[>1u")                           # kitty keyboard protocol
    _write_tty("\033]0;unfence\007")  # terminal title

def disable_terminal_protocols():
    _write_tty("\033[?2004l")   # disable bracketed paste
    _write_tty("\033[<u")       # pop kitty keyboard protocol


# ── TUI ───────────────────────────────────────────────────────────────────────

class TUI:
    HEADER_ROWS   = 3    # title + stats + body-top-border (no top border of its own)
    CTRL_ROWS     = 2    # fixed rows at bottom: controls sep + controls content
    MAX_INPUT_ROWS = 5   # cap on how tall the input area can grow

    def __init__(self, stdscr):
        self.stdscr   = stdscr
        self.scroll   = 0
        self.dirty    = True

        self._lock        = threading.Lock()
        self.rules        = []
        self.caches       = {}
        self.synced       = {}
        self.active       = set()
        self.last_refresh = ""

        self.shadows       = {}
        self.shadow_active = False
        self.shadow_open   = False
        self._shadow_gen   = 0    # incremented each time analysis starts
        self._shadow_proc  = None # Popen handle of the running analysis
        self._header_rows  = 4   # updated each render()

        self.log_stats = load_log_stats()

        self._body       = []
        self._body_inner = -1

        # Eval state
        self.eval_open    = False
        self.eval_input   = ""    # may contain \n for multi-line
        self.eval_cursor  = 0    # char offset into eval_input
        self.eval_result  = None
        self._eval_scroll = 0    # first logical line shown in the input area
        self.highlighted  = None
        self.hi_verdict   = None
        self._in_paste    = False
        self._pending_ev  = None   # replayed on next loop iteration

        # Recommendations state
        self.recs             = []     # list of rec dicts (pending)
        self._rec_dismissed   = set()  # dismissed fingerprints (patterns)
        self._rec_last_ts     = ""     # timestamp of last log line analyzed
        self.rec_open         = False
        self.rec_cursor     = 0
        self._rec_scroll    = 0
        self._rec_accepted  = set()  # patterns accepted in current session
        self.rec_analyzing  = False
        self.rec_processing = False
        self._rec_proc      = None   # Popen handle for running skill
        self._rec_gen       = 0

        # Change log view state
        self.log_open   = False
        self.log_scroll = 0

        # Deferred log view state
        self.deferlog_open     = False
        self.deferlog_entries  = []   # list of (timestamp_str, command_str), newest first
        self.deferlog_cursor   = 0    # index into deferlog_entries
        self.deferlog_scroll   = 0    # scroll offset for command body
        self.deferlog_evaling  = False
        self._deferlog_eval_proc = None
        self.deferlog_eval_result = None  # same dict shape as eval_result

        # Rule detail pane state
        self.detail_open            = False
        self.detail_rule_idx        = 0
        self.detail_scroll          = 0
        self._detail_confirm_delete = False

        # Detail modify state (Claude rewrites the rule)
        self.detail_modify_mode   = False   # in prompt-edit mode
        self.detail_modify_input  = ""
        self.detail_modify_cursor = 0
        self.detail_modifying     = False   # Claude subprocess running
        self.detail_modify_result = None    # None | "ok" | "fail: ..."
        self._detail_modify_proc  = None

        # Eval allow-rule state (Claude adds a new allow rule)
        self.eval_allowing     = False   # Claude subprocess running
        self._eval_allow_proc  = None
        self.eval_allow_result = None    # None | dict from Claude JSON output

        # Body cursor (selected rule index in main list)
        self.body_cursor            = 0
        self._body_cursor_cached    = -1

        # Terminal cursor target: None = hidden, (row, col) = visible at that position
        # Set during drawing; applied just before stdscr.refresh() via _apply_cursor().
        self._cursor_target: tuple[int, int] | None = None

        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_YELLOW,  -1)
        curses.init_pair(2, curses.COLOR_RED,     -1)
        curses.init_pair(3, curses.COLOR_BLACK,   curses.COLOR_MAGENTA)
        curses.init_pair(4, curses.COLOR_CYAN,    -1)
        curses.init_pair(5, curses.COLOR_WHITE,   curses.COLOR_RED)
        curses.init_pair(6, curses.COLOR_GREEN,   -1)
        curses.init_pair(7, curses.COLOR_BLACK,   curses.COLOR_GREEN)
        curses.init_pair(8, curses.COLOR_CYAN,    -1)   # pane chrome

        try:
            curses.set_escdelay(25)
        except AttributeError:
            pass  # Python < 3.9

        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        self._load_rules()
        self._trigger_stale()
        self._load_shadows()
        self.recs, self._rec_dismissed, self._rec_last_ts = load_rec_cache()
        if rec_cache_stale():
            self._load_recs()

    # ── Key reading ───────────────────────────────────────────────────────────

    def _read_event(self):
        """Read one event. Returns int key code, a string constant, or None."""
        ch = self.stdscr.getch()
        if ch == -1:
            return None

        if ch != 27:
            # In paste mode, newlines are literal
            if self._in_paste and ch in (10, 13):
                return "PASTE_NL"
            return ch

        # ESC received — collect escape sequence with short timeout
        seq = []
        self.stdscr.timeout(20)
        try:
            while len(seq) < 20:
                nch = self.stdscr.getch()
                if nch == -1:
                    break
                seq.append(chr(nch))
                s = "".join(seq)
                if s == "[200~":    return "PASTE_START"
                if s == "[201~":    return "PASTE_END"
                if s == "[27u":    return 27              # ESC (kitty)
                if s == "[13;2u":  return "SHIFT_ENTER"
                if s == "[114;5u": return 18              # Ctrl+R (kitty)
                # ANSI cursor/nav keys (may arrive split from ESC with nodelay)
                if s == "[A":  return curses.KEY_UP
                if s == "[B":  return curses.KEY_DOWN
                if s == "[C":  return curses.KEY_RIGHT
                if s == "[D":  return curses.KEY_LEFT
                if s == "[H":  return curses.KEY_HOME
                if s == "[F":  return curses.KEY_END
                if s == "[5~": return curses.KEY_PPAGE
                if s == "[6~": return curses.KEY_NPAGE
                if s == "[3~": return curses.KEY_DC
                # Stop at sequence terminator
                if s and (s[-1].isalpha() or s[-1] in "~$"):
                    return None  # unrecognised sequence, discard
        finally:
            self.stdscr.nodelay(True)

        return 27 if not seq else None  # standalone ESC or unrecognised

    # ── Eval cursor helpers ───────────────────────────────────────────────────

    def _cursor_line_col(self):
        """Return (line_idx, col) of the cursor within eval_input."""
        before = self.eval_input[:self.eval_cursor]
        parts  = before.split("\n")
        return len(parts) - 1, len(parts[-1])

    def _move_to_line_col(self, line_idx: int, col: int):
        lines     = self.eval_input.split("\n")
        line_idx  = max(0, min(line_idx, len(lines) - 1))
        col       = max(0, min(col, len(lines[line_idx])))
        self.eval_cursor = sum(len(lines[i]) + 1 for i in range(line_idx)) + col

    # ── Data ──────────────────────────────────────────────────────────────────

    def _load_rules(self):
        rules  = get_rules()
        caches = {r.name: load_cache(r) for r in rules}
        synced = {r.name: check_auto_created(r) for r in rules}
        with self._lock:
            self.rules  = rules
            self.caches = {k: v for k, v in caches.items() if v}
            self.synced = synced

    def _trigger_stale(self):
        self.log_stats = load_log_stats()
        with self._lock:
            stale = [r for r in self.rules if is_stale(r)]
            self.last_refresh = time.strftime("%H:%M:%S")
            if stale:
                self.active = {r.name for r in stale}
        if stale:
            self._invalidate()
            def work():
                threads = [
                    threading.Thread(target=self._summarize_one, args=(r,), daemon=True)
                    for r in stale
                ]
                for t in threads: t.start()
                for t in threads: t.join()
                LOG_STATS_CACHE.unlink(missing_ok=True)
                self.log_stats = load_log_stats()
                self._invalidate()
            threading.Thread(target=work, daemon=True).start()

    def _summarize_one(self, rule: Path):
        try:
            summarize_rule(rule)
            data = load_cache(rule)
        except Exception:
            data = None
        with self._lock:
            if data:
                self.caches[rule.name] = data
            self.active.discard(rule.name)
        self._invalidate()

    def _load_shadows(self):
        with self._lock:
            rules = list(self.rules)
        cached = load_shadow_cache(rules)
        if cached is not None:
            with self._lock:
                self.shadows = self._parse_shadows(cached)
            self._invalidate()
        else:
            with self._lock:
                self._shadow_gen  += 1
                gen                = self._shadow_gen
                self.shadow_active = True
            self._invalidate()
            def work(gen=gen):
                with self._lock:
                    r = list(self.rules)
                def on_proc(p):
                    with self._lock:
                        if self._shadow_gen == gen:
                            self._shadow_proc = p
                result = analyze_shadows(r, on_proc=on_proc)
                with self._lock:
                    if self._shadow_gen != gen:
                        return          # superseded — discard results
                    self._shadow_proc  = None
                    self.shadows       = self._parse_shadows(result)
                    self.shadow_active = False
                self._invalidate()
            threading.Thread(target=work, daemon=True).start()

    @staticmethod
    def _parse_shadows(shadow_list):
        out  = {}
        seen = set()
        for s in shadow_list:
            shr = s.get("shadower", "")
            shd = s.get("shadowed", "")
            ex  = s.get("example", "")
            if shr and shd and (shr, shd) not in seen:
                seen.add((shr, shd))
                out.setdefault(shr, []).append((shd, ex))
        return out

    def _load_recs(self):
        if not rec_cache_stale():
            return  # nothing new in the log; keep existing self.recs

        with self._lock:
            self._rec_gen += 1
            gen       = self._rec_gen
            last_ts   = self._rec_last_ts
            prev_recs = list(self.recs)
            dismissed = set(self._rec_dismissed)
            self.rec_analyzing = True
        self._invalidate()

        def work(gen=gen, last_ts=last_ts, prev_recs=prev_recs, dismissed=dismissed):
            new_deferred, new_ts = _parse_deferred_commands(after_ts=last_ts)

            def on_proc(p):
                with self._lock:
                    if self._rec_gen == gen:
                        self._rec_proc = p

            new_recs = analyze_recommendations(new_deferred, dismissed, on_proc=on_proc)

            # Merge: update counts/examples for existing patterns, append new ones.
            # Drop prev_recs that the engine now allows (i.e. were just implemented).
            merged = {r["pattern"]: r for r in prev_recs
                      if _engine_verdict(r["pattern"]) != "allow"}
            for r in new_recs:
                p = r["pattern"]
                if p in merged:
                    merged[p]["count"] += r["count"]
                    for ex in r["examples"]:
                        if ex not in merged[p]["examples"]:
                            merged[p]["examples"].append(ex)
                    merged[p]["examples"] = merged[p]["examples"][-5:]
                else:
                    merged[p] = r
            recs = list(merged.values())

            with self._lock:
                if self._rec_gen != gen:
                    return
                self.recs           = recs
                self._rec_last_ts   = new_ts
                self.rec_analyzing  = False

            save_rec_cache(recs, dismissed, new_ts)
            self._invalidate()

        threading.Thread(target=work, daemon=True).start()

    def _process_recs(self):
        with self._lock:
            accepted = set(self._rec_accepted)
            recs = list(self.recs)

        to_implement = [r for r in recs if r["pattern"] in accepted]
        if not to_implement:
            return

        try:
            CACHE_DIR.mkdir(parents=True, exist_ok=True)
            ACCEPTED_REC.write_text(json.dumps(to_implement, indent=2))
        except Exception:
            return

        if not SKILL_FILE.exists():
            return

        prompt = SKILL_FILE.read_text()
        log_path = CACHE_DIR / "implement-recommendations.log"

        def on_done():
            with self._lock:
                recs      = list(self.recs)
                dismissed = set(self._rec_dismissed)
                last_ts   = self._rec_last_ts
            recs = [r for r in recs if _engine_verdict(r["pattern"]) != "allow"]
            with self._lock:
                self.recs = recs
            save_rec_cache(recs, dismissed, last_ts)
            for pat in accepted:
                append_change_log("REC", "", f"Implemented recommendation: {pat}")

        if not self._spawn_claude_task(
            log_path, prompt,
            name="unfence: implement recommendations",
            proc_attr='_rec_proc', active_attr='rec_processing',
            on_start=lambda: self._rec_accepted.clear(),
            on_done=on_done,
        ):
            return

    def refresh(self):
        self._load_rules()
        self._trigger_stale()
        self._load_shadows()
        self._load_recs()
        self._invalidate()

    def hard_reload(self):
        """Wipe all caches and re-summarize everything from scratch."""
        try:
            for f in CACHE_DIR.iterdir():
                f.unlink(missing_ok=True)
        except Exception:
            pass
        self.refresh()

    def _invalidate(self):
        self._body_inner         = -1
        self._body_cursor_cached = -1
        self.dirty               = True

    # ── Small helpers ─────────────────────────────────────────────────────────

    @property
    def _rules(self) -> list:
        """Thread-safe snapshot of the current rule list."""
        with self._lock:
            return list(self.rules)

    def _cap_pane_rows(self, rows: int, total: int) -> int:
        """Cap pane height to at most half the available area."""
        return min(total, max(2, rows // 2))

    def _size_pane(self, rows: int, inner: int, content: int, description: str) -> int:
        """Return pane height for given content rows + chrome overhead, capped to half screen."""
        overhead = self._pane_overhead(description, inner)
        return self._cap_pane_rows(rows - self.CTRL_ROWS, content + overhead)

    def _main_ctrl_tokens(self) -> list[str]:
        """Build the key-token list for the main view controls row."""
        with self._lock:
            shadow_active  = self.shadow_active
            shadow_count   = sum(len(v) for v in self.shadows.values())
            rec_analyzing  = self.rec_analyzing
            rec_pending    = len([r for r in self.recs if r["pattern"] not in self._rec_dismissed])
            rec_processing = self.rec_processing
        shd_key = (
            "[analyzing shadows…]" if shadow_active else
            f"[s] {shadow_count} shadow{'s' if shadow_count != 1 else ''}" if shadow_count else
            "[s] no shadows"
        )
        rec_key = (
            "[implementing…]" if rec_processing else
            "[analyzing recs…]" if rec_analyzing else
            f"[p] {rec_pending} rec{'s' if rec_pending != 1 else ''}" if rec_pending else
            "[p] no recs"
        )
        return ["[r] reload", "[ctrl+r] hard reload", "[e] eval",
                "[↑↓] navigate  [enter/→/1-9] detail",
                shd_key, rec_key, "[c] changelog", "[d] deferlog", "[q] quit"]

    def _wrap_ctrl_tokens(self, tokens: list[str], inner: int) -> list[str]:
        """Greedily pack tokens into lines that fit within inner width (2-char indent)."""
        SEP = "  "
        lines: list[str] = []
        current = ""
        for tok in tokens:
            candidate = (current + SEP + tok) if current else tok
            if current and (2 + len(candidate)) > inner:
                lines.append(current)
                current = tok
            else:
                current = candidate
        if current:
            lines.append(current)
        return lines or [""]

    def _detail_ctrl_tokens(self) -> list[str]:
        """Token list for the detail view's normal navigation controls."""
        with self._lock:
            rules = list(self.rules)
        tokens = (["[←] prev", "[→] next"] if len(rules) > 1 else [])
        return tokens + ["[x] (re-)generate", "[m] modify", "[D] delete", "[enter/esc] back"]

    def _eval_ctrl_lines(self, cols: int) -> list[list[tuple]]:
        """Eval controls as a list of segs-lists (one entry per content row)."""
        A_DIM    = curses.A_DIM
        A_NORMAL = curses.A_NORMAL
        CP1 = curses.color_pair(1)
        CP2 = curses.color_pair(2)
        CP4 = curses.color_pair(4)
        CP6 = curses.color_pair(6)

        r = self.eval_allow_result
        if r is not None:
            if r.get("success"):
                rule = r.get("rule", "a rule file")
                pat  = r.get("pattern", "")
                return [[(CP6 | curses.A_BOLD, f"  Added to {rule}: {pat}   [any key] dismiss")]]
            elif r.get("engine_issue"):
                return [[(CP1, f"  Engine issue (not a missing rule): {r.get('error', '')}   [any key] dismiss")]]
            else:
                return [[(CP2, f"  Failed: {r.get('error', '')}   [any key] dismiss")]]
        if self.eval_allowing:
            return [[(CP4, "  Analyzing and adding rule, please wait…   [esc] cancel")]]
        res = self.eval_result
        if res is None:
            return [[(A_DIM, "   [shift+enter] newline  ·  [enter] run  ·  [esc] close")]]
        if res.get("running"):
            return [[(A_DIM, "   running…")]]
        verdict = res["verdict"]
        # Use shared helper for verdict + unmatched rendering
        result_lines = self._eval_result_lines(res, cols)
        # Append navigation hint to the first line
        allow_hint = "   [A] add to allow  ·  " if verdict == "defer" else "   "
        hint_segs  = [(A_DIM, allow_hint + "[enter] edit  ·  [n] new  ·  [esc] close")]
        if result_lines:
            first_line = result_lines[0]
            prefix_len = sum(len(t) for _, t in first_line)
            hint_len   = sum(len(t) for _, t in hint_segs)
            if prefix_len + hint_len <= cols:
                result_lines[0] = first_line + hint_segs
            else:
                result_lines.insert(1, hint_segs)
        return result_lines

    def _ctrl_rows(self, inner: int) -> int:
        """Number of rows for the bottom controls strip in the current context."""
        if self.detail_open:
            with self._lock:
                rules  = list(self.rules)
                active = set(self.active)
            idx = min(self.detail_rule_idx, max(0, len(rules) - 1))
            summarizing = bool(rules) and rules[idx].name in active
            # Locked states always fit on one content line
            if (summarizing or self.detail_modifying
                    or self.detail_modify_result is not None
                    or self._detail_confirm_delete or self.detail_modify_mode):
                return self.CTRL_ROWS
            return 1 + len(self._wrap_ctrl_tokens(self._detail_ctrl_tokens(), inner))
        if self.eval_open:
            return 1 + len(self._eval_ctrl_lines(inner + 2))  # +2: unbordered uses full cols
        if self.shadow_open or self.rec_open or self.log_open:
            return self.CTRL_ROWS  # 2: sep + 1 content line
        return 1 + len(self._wrap_ctrl_tokens(self._main_ctrl_tokens(), inner))

    def _draw_scroll_indicators(self, row: int, cols: int, can_up: bool, can_down: bool):
        """Draw ↑↓ scroll indicators near the right edge of a separator row."""
        if not can_up and not can_down:
            return
        ind_attr = curses.color_pair(4) | curses.A_BOLD
        up_ch   = "↑" if can_up   else " "
        down_ch = "↓" if can_down else " "
        for off, ch, attr in [(-5, " ", curses.A_NORMAL), (-4, up_ch, ind_attr),
                               (-3, down_ch, ind_attr), (-2, " ", curses.A_NORMAL)]:
            try: self.stdscr.addstr(row, cols + off, ch, attr)
            except curses.error: pass

    def _hide_cursor(self):
        """Record that the cursor should be hidden (applied at refresh time)."""
        self._cursor_target = None

    def _show_cursor(self, row: int, col: int):
        """Record cursor position to display (applied at refresh time)."""
        self._cursor_target = (row, col)

    def _apply_cursor(self):
        """Apply the recorded cursor state. Call as the last step before refresh()."""
        if self._cursor_target is None:
            try: curses.curs_set(0)
            except curses.error: pass
        else:
            row, col = self._cursor_target
            try:
                curses.curs_set(1)
                self.stdscr.move(row, min(col, self.stdscr.getmaxyx()[1] - 2))
            except curses.error:
                pass

    @staticmethod
    def _source_attr(source: str) -> int:
        """Return curses attribute for a change log source badge."""
        return {
            "USER": curses.color_pair(6),    # green — user-initiated
            "SYNC": curses.color_pair(3),    # black on magenta — auto-synced
            "REC":  curses.color_pair(1),    # yellow — recommendation
            "EVAL": curses.color_pair(4),    # cyan — eval pane
            "DEL":  curses.color_pair(2),    # red — deletion
        }.get(source, curses.A_NORMAL)

    def _open_detail(self, idx: int):
        """Open the rule detail view for the given rule index."""
        self.detail_rule_idx        = idx
        self.body_cursor            = idx
        self.detail_open            = True
        self.detail_scroll          = 0
        self._detail_confirm_delete = False
        self._invalidate()

    def _clear_eval_input(self):
        """Reset eval input/result fields to blank state (caller must _invalidate)."""
        self.eval_input   = ""
        self.eval_cursor  = 0
        self.eval_result  = None
        self.highlighted  = None
        self.hi_verdict   = None
        self._eval_scroll = 0

    def _handle_basic_edit(self, ev, text_attr: str, cursor_attr: str) -> bool:
        """Handle backspace / left / right / printable-char insert for a single-line field.
        Returns True if the event was consumed (caller should not process it further)."""
        text   = getattr(self, text_attr)
        cursor = getattr(self, cursor_attr)
        if ev in (curses.KEY_BACKSPACE, 127, 8):
            if cursor > 0:
                setattr(self, text_attr,   text[:cursor - 1] + text[cursor:])
                setattr(self, cursor_attr, cursor - 1)
                self._invalidate()
            return True
        elif ev == curses.KEY_LEFT:
            setattr(self, cursor_attr, max(0, cursor - 1))
            self.dirty = True
            return True
        elif ev == curses.KEY_RIGHT:
            setattr(self, cursor_attr, min(len(text), cursor + 1))
            self.dirty = True
            return True
        elif isinstance(ev, int) and 32 <= ev <= 126:
            ch = chr(ev)
            setattr(self, text_attr,   text[:cursor] + ch + text[cursor:])
            setattr(self, cursor_attr, cursor + 1)
            self._invalidate()
            return True
        return False

    def _cancel_proc(self, proc_attr: str, active_attr: str):
        """Terminate a running background Claude process and clear its state."""
        with self._lock:
            proc = getattr(self, proc_attr)
        if proc:
            try: proc.terminate()
            except Exception: pass
        with self._lock:
            setattr(self, proc_attr, None)
            setattr(self, active_attr, False)
        self._invalidate()

    def _spawn_claude_task(
        self,
        log_path: Path,
        prompt: str,
        *,
        name: str,
        proc_attr: str,
        active_attr: str,
        result_attr: str | None = None,
        on_start=None,
        parse_result=None,
        on_done=None,
    ) -> bool:
        """Spawn a Claude subprocess and poll it in a background thread.

        Args:
            log_path:     Path to write Claude's output log.
            prompt:       The -p prompt string.
            proc_attr:    Name of the self._ attribute holding the Popen handle.
            active_attr:  Name of the self. flag set True while running.
            result_attr:  Name of the self. attribute to store parsed result (optional).
            on_start:     Callable invoked inside self._lock after proc starts.
            parse_result: Callable(lines: list[str]) -> result value.
                          Default: last JSON line parsed as dict.
            on_done:      Callable() run after state is cleared, before _invalidate().

        Returns True if the process was successfully spawned.
        """
        try:
            proc = subprocess.Popen(
                ["claude", "--model", "claude-sonnet-4-6",
                 "--setting-sources", "user,project,local",
                 "--dangerously-skip-permissions",
                 "-n", name,
                 "-p", prompt],
                stdout=open(log_path, "w"), stderr=subprocess.STDOUT,
                cwd=str(PROJECT_DIR),
            )
        except Exception:
            return False

        with self._lock:
            setattr(self, proc_attr, proc)
            setattr(self, active_attr, True)
            if result_attr:
                setattr(self, result_attr, None)
            if on_start:
                on_start()
        self.dirty = True

        def _default_parse(lines):
            for line in reversed(lines):
                line = line.strip()
                if line.startswith("{"):
                    try:
                        return json.loads(line)
                    except Exception:
                        pass
            return {"success": False, "error": "no output from Claude"}

        _parse = parse_result if parse_result is not None else _default_parse

        def poll():
            proc.wait()
            with self._lock:
                setattr(self, proc_attr, None)
                setattr(self, active_attr, False)
                if result_attr is not None:
                    try:
                        lines = log_path.read_text().splitlines()
                    except Exception:
                        lines = []
                    setattr(self, result_attr, _parse(lines))
            if on_done:
                on_done()
            self._invalidate()

        threading.Thread(target=poll, daemon=True).start()
        return True

    # ── Evaluation ────────────────────────────────────────────────────────────

    def _eval_result_lines(self, res: dict, cols: int) -> list[list[tuple]]:
        """Convert an eval result dict into a list of segs-lists (one per display row).
        Returns [] if res is None or running."""
        if res is None or res.get("running"):
            return []
        A_DIM    = curses.A_DIM
        A_NORMAL = curses.A_NORMAL
        A_BOLD   = curses.A_BOLD
        CP1 = curses.color_pair(1)
        CP2 = curses.color_pair(2)
        CP6 = curses.color_pair(6)
        verdict   = res["verdict"]
        rule_name = res.get("rule_name")
        rule_num  = res.get("rule_num")
        v_attr = {"allow": CP6 | A_BOLD, "deny": CP2 | A_BOLD,
                  "ask":   CP1 | A_BOLD, "defer": A_DIM}.get(verdict, A_NORMAL)
        verdict_segs = [(A_NORMAL, "   → "), (v_attr, verdict.upper())]
        if rule_name and rule_num:
            verdict_segs += [(A_DIM, f"  ·  #{rule_num} {rule_name}")]
        else:
            verdict_segs += [(A_DIM, "  ·  no rule matched")]
        lines = [verdict_segs]
        if verdict == "defer":
            deferred = res.get("deferred_parts") or []
            if deferred:
                MAX_PART = 50
                SEP      = "  ·  "
                prefix   = "   unmatched: "
                indent   = " " * len(prefix)
                formatted = [p[:MAX_PART] + "…" if len(p) > MAX_PART else p for p in deferred]
                current = prefix
                for i, part in enumerate(formatted):
                    chunk = (SEP if i > 0 else "") + part
                    if i > 0 and len(current) + len(chunk) > cols:
                        lines.append([(A_DIM, current)])
                        current = indent + part
                    else:
                        current += chunk
                lines.append([(A_DIM, current)])
        return lines

    def _run_eval_async(self, cmd: str, result_attr: str, highlight: bool = True):
        """Run cmd through the engine in a background thread, storing result in self.<result_attr>."""
        with self._lock:
            setattr(self, result_attr, {"running": True, "verdict": "…",
                                        "rule_name": None, "rule_num": None,
                                        "deferred_parts": []})
        self.dirty = True

        def work():
            verdict, rule_name, deferred_parts = evaluate_command(cmd)
            with self._lock:
                rules = list(self.rules)
            # rule_name may be a chain like "0-unwrap.sh → 1-lists.sh"
            rule_chain = [r.strip() for r in rule_name.split("→")] if rule_name else []
            last_rule  = rule_chain[-1] if rule_chain else None
            rule_num   = next((i + 1 for i, r in enumerate(rules) if r.name == last_rule), None)
            with self._lock:
                setattr(self, result_attr, {"running": False, "verdict": verdict,
                                            "rule_name": rule_name, "rule_num": rule_num,
                                            "deferred_parts": deferred_parts})
                if highlight:
                    self.highlighted = frozenset(rule_chain)
                    self.hi_verdict  = verdict
            if highlight and rule_num is not None:
                self._scroll_to_rule(rule_num - 1)
            self._invalidate()

        threading.Thread(target=work, daemon=True).start()

    def _run_eval(self):
        cmd = self.eval_input.strip()
        if not cmd:
            return
        self._run_eval_async(cmd, 'eval_result', highlight=True)

    def _add_allow_rule(self, cmd: str):
        """Spawn Claude to identify the deferring sub-command and add an allow rule."""
        engine = PROJECT_DIR / "hooks" / "unfence.sh"
        with self._lock:
            deferred_parts = (self.eval_result or {}).get("deferred_parts") or []
        if deferred_parts:
            parts_bullet = "\n".join(f"  - {p}" for p in deferred_parts)
            step1 = (
                f"The engine already identified these unmatched sub-command(s):\n{parts_bullet}\n\n"
                "Skip step 1 and proceed directly to step 2.\n"
            )
        else:
            step1 = (
                f"1. Run the engine in eval mode to identify which sub-command(s) caused the deferral:\n"
                f"   EVAL_MODE=1 CMD='...' NO_LOG=1 bash {engine}\n"
                "   (substitute the actual sub-commands to isolate which one defers)\n"
            )
        prompt = (
            "You are adding an allow rule to the unfence engine.\n\n"
            f"The user evaluated this command and the engine returned 'defer':\n"
            f"  Command: {cmd}\n\n"
            f"{step1}\n"
            "Steps:\n"
            "2. Determine whether the deferral is caused by:\n"
            "   a) A missing rule — no rule file matches the sub-command\n"
            "   b) An engine issue — the engine's tokenizer/parser incorrectly handles the command\n"
            "3. CRITICAL: Do NOT modify the engine file "
            f"({engine}) under any circumstances.\n"
            "   If the cause is (b), output on the last line:\n"
            '   {"success": false, "engine_issue": true, "error": "<brief description>"}\n'
            "   and stop.\n"
            "4. If the cause is (a):\n"
            "   a. Read the existing rule files (*.sh, not *.test.sh) to understand conventions\n"
            "   b. Choose the most appropriate file and location to add an allow entry\n"
            "   c. Add a test to the corresponding *.test.sh file\n"
            "   d. Run the full test suite: bash ~/.claude/unfence/run-tests.sh\n"
            "   e. If all tests pass, output on the last line:\n"
            '      {"success": true, "rule": "<filename>", "pattern": "<what was added>"}\n'
            "   f. If tests fail, revert all changes and output on the last line:\n"
            '      {"success": false, "error": "<brief reason>"}'
        )
        log_path = CACHE_DIR / "add-allow-rule.log"

        def on_done():
            self._load_rules()
            self._trigger_stale()
            r = self.eval_allow_result
            if r and r.get("success"):
                rule_name = r.get("rule", "unknown")
                pattern   = r.get("pattern", cmd[:60])
                append_change_log("EVAL", rule_name, f"Added allow: {pattern}")

        self._spawn_claude_task(
            log_path, prompt,
            name="unfence: add allow rule",
            proc_attr='_eval_allow_proc', active_attr='eval_allowing',
            result_attr='eval_allow_result',
            on_done=on_done,
        )

    def _modify_detail_rule(self, rule: Path, modify_prompt: str):
        """Spawn Claude to modify a rule file, run tests, and revert on failure."""
        test = rule.parent / rule.name.replace(".sh", ".test.sh")
        prompt = (
            f"You are modifying an unfence rule file.\n\n"
            f"Rule file: {rule.name}\n"
            f"Modification request: {modify_prompt}\n\n"
            "Instructions:\n"
            f"1. Read the rule file at {rule} and its companion test file at {test}\n"
            "2. Apply the requested modification\n"
            "3. Update or add tests in the test file as needed\n"
            "4. Run the full test suite: bash ~/.claude/unfence/run-tests.sh\n"
            "5. If all tests pass, keep the changes and output on the last line: "
            '{"success": true}\n'
            "6. If tests fail, revert both files to their original content and output on the last line: "
            '{"success": false, "error": "<brief reason>"}'
        )
        log_path = CACHE_DIR / f"modify-{rule.name}.log"

        def parse_modify(lines):
            for line in reversed(lines):
                line = line.strip()
                if line.startswith("{"):
                    try:
                        data = json.loads(line)
                        if not data.get("success"):
                            return f"fail: {data.get('error', 'unknown error')}"
                        return "ok"
                    except Exception:
                        pass
            return "ok"

        def on_done():
            rules = self._rules
            if self.detail_rule_idx < len(rules):
                (CACHE_DIR / rules[self.detail_rule_idx].name).unlink(missing_ok=True)
            self._load_rules()
            self._trigger_stale()
            if self.detail_modify_result == "ok":
                append_change_log("USER", rule.name, modify_prompt[:120])

        self._spawn_claude_task(
            log_path, prompt,
            name=f"unfence: modify {rule.name}",
            proc_attr='_detail_modify_proc', active_attr='detail_modifying',
            result_attr='detail_modify_result',
            parse_result=parse_modify,
            on_done=on_done,
        )

    def _scroll_to_rule(self, rule_idx: int):
        rows, cols = self.stdscr.getmaxyx()
        inner      = cols - 2
        body       = self._get_body(inner, self.body_cursor)
        rule_count = -1
        start_line = 0
        for i, item in enumerate(body):
            if isinstance(item, ContentLine) and (i == 0 or isinstance(body[i - 1], HLine)):
                rule_count += 1
                if rule_count == rule_idx:
                    start_line = i
                    break
        eval_rows   = self._eval_pane_rows(inner)
        shadow_rows = self._shadow_pane_rows(rows, inner)
        rec_rows    = self._rec_pane_rows(rows, inner)
        ctrl_rows   = self._ctrl_rows(inner)
        body_rows   = max(1, rows - self._header_rows - eval_rows - shadow_rows - rec_rows - ctrl_rows)
        max_scroll  = max(0, len(body) - body_rows)
        self.scroll = max(0, min(start_line, max_scroll))

    # ── Eval pane sizing ──────────────────────────────────────────────────────

    def _desc_rows(self, description: str, inner: int) -> int:
        """Rows consumed by a pane description: wrapped lines + divider."""
        return len(list(word_wrap(description, max(1, inner - 4)))) + 1

    def _pane_overhead(self, description: str | None, inner: int) -> int:
        """Fixed rows consumed by pane chrome: gap + title + optional desc + divider.
        Note: _desc_rows already includes the divider row, so no extra +1 needed."""
        overhead = 2  # gap row + title border row
        if description:
            overhead += self._desc_rows(description, inner)
        return overhead

    def _eval_pane_rows(self, inner: int) -> int:
        """Dynamic height: separator + description + input lines (capped)."""
        if not self.eval_open:
            return 0
        input_width = max(1, inner - 4)  # " › " prefix = 3 chars + 1 border
        logical_lines = self.eval_input.split("\n")
        visual_rows = sum(
            max(1, (len(line) + input_width - 1) // input_width) if line else 1
            for line in logical_lines
        )
        overhead = self._pane_overhead("Test a command against the engine to see which rule fires.", inner)
        return overhead + min(visual_rows, self.MAX_INPUT_ROWS)

    def _shadow_pane_rows(self, rows: int, inner: int) -> int:
        if not self.shadow_open:
            return 0
        with self._lock:
            shadows = dict(self.shadows)
        fix_w = max(1, inner - 4)
        content = 0
        for shadower, pairs in shadows.items():
            for shadowed, example in pairs:
                content += 1  # relationship line
                fix = (f"example: {example}  ·  "
                       f"add exception in {shadower} to defer, or reorder rules")
                content += max(1, len(list(word_wrap(fix, fix_w))))
        if not content:
            content = 1  # "No shadows detected."
        return self._size_pane(rows, inner, content, "Rules where an earlier rule already matches the same commands.")

    def _draw_shadow_pane(self, rows, cols, inner, shadow_rows):
        A_NORMAL = curses.A_NORMAL
        A_DIM    = curses.A_DIM
        CP2      = curses.color_pair(2)
        CP5      = curses.color_pair(5)

        sep_row, content_start = self._begin_pane(
            rows, cols, inner, shadow_rows, " Shadow Analysis ",
            description="Rules where an earlier rule already matches the same commands.")

        with self._lock:
            shadows   = dict(self.shadows)
            rules     = list(self.rules)
        rule_nums = {r.name: i + 1 for i, r in enumerate(rules)}

        CP8  = curses.color_pair(8)
        battr = CP8
        row = content_start
        if not shadows:
            self._draw_item(row, ContentLine([(A_DIM, "  No shadows detected.")]), cols, inner, border_attr=battr)
        else:
            for shadower, pairs in shadows.items():
                shr_num = rule_nums.get(shadower, "?")
                for shadowed, example in pairs:
                    if row >= rows:
                        break
                    shd_num = rule_nums.get(shadowed, "?")
                    self._draw_item(row, ContentLine([
                        (A_NORMAL, "  "),
                        (CP2,      f"#{shr_num} {shadower}"),
                        (A_DIM,    "  shadows  "),
                        (CP5,      f"#{shd_num} {shadowed}"),
                    ]), cols, inner, border_attr=battr)
                    row += 1
                    if row < rows:
                        fix = (f"example: {example}  ·  "
                               f"add exception in {shadower} to defer, or reorder rules")
                        for seg in word_wrap(fix, max(1, inner - 4)):
                            if row >= rows:
                                break
                            self._draw_item(row, ContentLine([(A_DIM, f"  {seg}")]), cols, inner, border_attr=battr)
                            row += 1

    def _rec_item_rows(self, rec: dict, wrap_w: int) -> int:
        """Rows consumed by one rec: 1 (pattern) + 1 (examples) + wrapped rationale lines."""
        import textwrap
        rat = rec.get("rationale", "") or "(no rationale)"
        return 1 + 1 + max(1, len(textwrap.wrap(rat, wrap_w)))

    def _rec_pane_rows(self, rows: int, inner: int) -> int:
        if not self.rec_open:
            return 0
        with self._lock:
            recs = list(self.recs)
            dismissed = set(self._rec_dismissed)
        visible = [r for r in recs if r["pattern"] not in dismissed]
        wrap_w = max(1, inner - 6)
        if not visible:
            content = 1
        else:
            content = sum(self._rec_item_rows(r, wrap_w) for r in visible)
        return self._size_pane(rows, inner, content, "Commands seen in logs that may be safe to auto-allow.")

    def _draw_rec_pane(self, rows, cols, inner, rec_rows):
        A_NORMAL = curses.A_NORMAL
        A_DIM    = curses.A_DIM
        A_BOLD   = curses.A_BOLD
        CP6      = curses.color_pair(6)

        _rec_desc = "Commands seen in logs that may be safe to auto-allow."
        sep_row, content_start = self._begin_pane(
            rows, cols, inner, rec_rows, " Recommendations ",
            description=_rec_desc)

        with self._lock:
            recs      = list(self.recs)
            dismissed = set(self._rec_dismissed)
            accepted  = set(self._rec_accepted)
            cursor    = self.rec_cursor

        visible = [r for r in recs if r["pattern"] not in dismissed]

        scroll = self._rec_scroll  # row offset, already clamped by render()
        wrap_w = max(1, inner - 6)

        _overhead     = self._pane_overhead(_rec_desc, inner)
        _content_rows = max(1, rec_rows - _overhead)
        _total        = sum(self._rec_item_rows(r, wrap_w) for r in visible) if visible else 0
        self._draw_scroll_indicators(
            content_start - 1, cols,
            scroll > 0,
            scroll + _content_rows < _total,
        )

        CP8   = curses.color_pair(8)
        battr = CP8
        row = content_start
        logical_row = 0  # tracks cumulative rows consumed by recs before current
        if not visible:
            self._draw_item(row, ContentLine([(A_DIM, "  No recommendations yet.")]), cols, inner, border_attr=battr)
        else:
            for idx, rec in enumerate(visible):
                import textwrap
                item_h = self._rec_item_rows(rec, wrap_w)
                if logical_row + item_h <= scroll:
                    logical_row += item_h
                    continue
                logical_row += item_h
                if row >= rows:
                    break
                is_cursor   = (idx == cursor)
                is_accepted = rec["pattern"] in accepted
                line_attr   = A_BOLD if is_cursor else A_NORMAL
                check       = "✓ " if is_accepted else "  "
                badge       = f"  ({rec['count']}×)"
                segs = [
                    (A_DIM if not is_cursor else A_BOLD, f"  {check}"),
                    (CP6 | A_BOLD if is_accepted else line_attr, rec["pattern"]),
                    (A_DIM, badge),
                ]
                if is_cursor:
                    # Highlight entire line
                    try:
                        self.stdscr.addstr(row, 0, " " * cols, curses.A_REVERSE)
                    except curses.error:
                        pass
                self._draw_item(row, ContentLine(segs), cols, inner, border_attr=battr)
                row += 1

                # Examples — show actual commands seen, truncated to fit.
                # If an example doesn't start with the pattern, find the first
                # token position where the pattern begins and prefix with "…".
                if row < rows:
                    pat = rec.get("pattern", "")
                    exs = rec.get("examples", [])
                    def _fmt_example(ex: str) -> str:
                        if ex.startswith(pat):
                            return ex
                        # Find where the pattern starts within the example tokens
                        toks = ex.split()
                        pat_toks = pat.split()
                        for i in range(len(toks)):
                            if toks[i:i + len(pat_toks)] == pat_toks:
                                return "… " + " ".join(toks[i:])
                        return ex  # no match found, show as-is
                    formatted = [_fmt_example(e) for e in exs[:2]]
                    ex_str = "  e.g. " + "  |  ".join(formatted) if formatted else ""
                    max_ex = max(1, inner - 6)
                    if len(ex_str) > max_ex:
                        ex_str = ex_str[:max_ex - 1] + "…"
                    self._draw_item(row, ContentLine([(A_DIM, f"     {ex_str}")]), cols, inner, border_attr=battr)
                    row += 1

                # Rationale — wrapped across as many rows as needed
                import textwrap
                rationale = rec.get("rationale", "") or "(no rationale)"
                wrap_w = max(1, inner - 6)
                for rat_line in textwrap.wrap(rationale, wrap_w) or ["(no rationale)"]:
                    if row >= rows:
                        break
                    self._draw_item(row, ContentLine([(A_DIM, f"     {rat_line}")]), cols, inner, border_attr=battr)
                    row += 1

        # Fill any remaining content rows with bordered blank lines so the pane
        # box is visually complete when fewer items are rendered than available rows.
        while row < rows:
            self._draw_item(row, ContentLine([], border_attr=battr), cols, inner, border_attr=battr)
            row += 1

    # ── Pane helper ───────────────────────────────────────────────────────────

    def _begin_pane(self, rows: int, cols: int, inner: int,
                    pane_rows: int, label: str,
                    description: str | None = None) -> tuple[int, int]:
        """Draw pane header and optional description, return (sep_row, content_start).

        Reserves a blank gap row above the title, then:
        Without description: draws ┌─ Label ─┐, content starts at sep_row + 1.
        With description:    draws ┌─ Label ─┐ / │ description │ / ├─────────┤,
                             content starts after divider.
        All border chars are drawn in the pane chrome color (CP8).
        """
        CP8  = curses.color_pair(8)
        battr = CP8

        sep_row = rows - pane_rows
        # Blank gap row — just draw the two side chars so it visually separates
        # from the rule body above without leaving a raw empty line
        try: self.stdscr.addch(sep_row, 0,        ' ')
        except curses.error: pass
        try: self.stdscr.addch(sep_row, cols - 1, ' ')
        except curses.error: pass

        title_row = sep_row + 1
        self._draw_item(title_row, HLine(curses.ACS_ULCORNER, curses.ACS_URCORNER),
                        cols, inner, border_attr=battr)
        try:
            self.stdscr.addstr(title_row, (cols - len(label)) // 2, label,
                               curses.A_BOLD | CP8)
        except curses.error:
            pass
        if description:
            desc_lines = list(word_wrap(description, max(1, inner - 4)))
            for i, dline in enumerate(desc_lines):
                self._draw_item(title_row + 1 + i,
                                ContentLine([(curses.A_DIM, f"  {dline}")],
                                            border_attr=battr),
                                cols, inner, border_attr=battr)
            divider_row = title_row + 1 + len(desc_lines)
            self._draw_item(divider_row, HLine(curses.ACS_LTEE, curses.ACS_RTEE),
                            cols, inner, border_attr=battr)
            return sep_row, divider_row + 1
        return sep_row, title_row + 1

    # ── Layout builder ────────────────────────────────────────────────────────

    def _build_header(self, inner, refresh_ts):
        A_NORMAL = curses.A_NORMAL
        A_DIM    = curses.A_DIM
        A_BOLD   = curses.A_BOLD
        CP2 = curses.color_pair(2)
        CP4 = curses.color_pair(4)
        CP6 = curses.color_pair(6)

        hdr = "unfence"
        ref = f"  ↻ Updated: {refresh_ts}" if refresh_ts else ""
        title_row = ContentLine([(A_NORMAL, " "), (A_BOLD, hdr), (A_DIM, ref)],
                                bordered=False)

        st = self.log_stats
        total = st['allow'] + st['deny'] + st['defer']
        non_prompted = st['allow'] + st['deny']
        autonomy_str = f"  {100 * non_prompted / total:.1f}% autonomous" if total else ""
        stats_row = ContentLine([
            (A_DIM,          " 30d: "),
            (CP6 | A_BOLD,   f"{st['allow']:,}"),
            (A_DIM,          " allowed   "),
            (CP2 | A_BOLD,   f"{st['deny']:,}"),
            (A_DIM,          " denied   "),
            (CP4,            f"{st['defer']:,}"),
            (A_DIM,          " prompted"),
            (A_DIM,          autonomy_str),
        ], bordered=False)

        return [
            title_row,
            stats_row,
            HLine(curses.ACS_ULCORNER, curses.ACS_URCORNER),  # body box top
        ]

    def _build_body(self, inner: int, cursor: int = -1):
        A_NORMAL = curses.A_NORMAL
        A_DIM    = curses.A_DIM
        A_BOLD   = curses.A_BOLD
        CP1 = curses.color_pair(1)
        CP2 = curses.color_pair(2)
        CP3 = curses.color_pair(3)
        CP5 = curses.color_pair(5)
        CP6 = curses.color_pair(6)
        CP7 = curses.color_pair(7)
        DIV = HLine(curses.ACS_LTEE,     curses.ACS_RTEE)
        BOT = HLine(curses.ACS_LLCORNER, curses.ACS_LRCORNER)

        with self._lock:
            rules      = list(self.rules)
            caches     = dict(self.caches)
            synced     = dict(self.synced)
            active     = set(self.active)
            shadows    = dict(self.shadows)
            highlighted = self.highlighted
            hi_verdict  = self.hi_verdict

        rule_nums = {r.name: i + 1 for i, r in enumerate(rules)}
        per_rule  = self.log_stats.get("per_rule", {})

        def match_badge_attr(v):
            if v == "allow": return CP7
            if v == "deny":  return CP5
            if v == "ask":   return CP1 | curses.A_BOLD
            return curses.A_DIM

        body = []
        for idx, rule in enumerate(rules):
            name       = rule.name
            cache      = caches.get(name)
            is_active  = name in active
            is_synced  = synced.get(name, False)
            n          = idx + 1
            is_last    = idx == len(rules) - 1
            is_match   = name in highlighted if highlighted else False
            is_cursor  = (idx == cursor)

            title      = (cache or {}).get("title") or name
            if is_cursor:
                title_attr = curses.A_REVERSE | A_BOLD
            else:
                title_attr = (CP2 if is_active else CP1) | A_BOLD
            rel        = relative_time(rule.stat().st_mtime)

            badge_segs = []
            if is_active:
                badge_segs += [(A_NORMAL, " "), (CP2, "[summarizing...]")]
            if is_synced:
                badge_segs += [(A_NORMAL, " "), (CP3, "[auto-created]")]
            for shd_name, _ in shadows.get(name, []):
                num = rule_nums.get(shd_name, "?")
                badge_segs += [(A_NORMAL, " "), (CP5, f"[shadows #{num}]")]
            if is_match:
                badge_segs += [(A_NORMAL, " "), (match_badge_attr(hi_verdict), f"[▶ {hi_verdict}]")]
            rule_pr = per_rule.get(name)
            if rule_pr is not None:
                a, d = rule_pr["allow"], rule_pr["deny"]
                badge_segs += [
                    (A_NORMAL, " "),
                    (A_DIM, "["),
                    (CP6, str(a)) if a else (A_DIM, "0"),
                    (A_DIM, "|"),
                    (CP2, str(d)) if d else (A_DIM, "0"),
                    (A_DIM, "]"),
                ]
            elif not is_active:
                # Rule exists but was never hit in the last 30 days
                badge_segs += [(A_NORMAL, " "), (A_DIM, "[0|0]")]

            body.append(ContentLine(
                [(A_NORMAL, " "), (title_attr, f"{n}. {title}"),
                 (A_NORMAL, " "), (A_DIM, f"[{name}]"), (A_DIM, f"  {rel}")]
                + badge_segs
            ))

            if cache and (summary := cache.get("summary")):
                for sline in word_wrap(summary, inner - 5):
                    body.append(ContentLine([(A_NORMAL, "    "), (A_NORMAL, sline)]))
            else:
                body.append(ContentLine([(A_NORMAL, "    "), (A_DIM, "(no summary)")]))

            if not is_last:
                body.append(DIV)

        body.append(BOT)

        tip_text = "Tip: run claude in ~/.claude/unfence/ to add complex rules or modify existing ones"
        tip_width = max(1, inner - 3)
        for line in word_wrap(tip_text, tip_width):
            body.append(ContentLine([(A_DIM, "  " + line)], bordered=False))

        return body

    def _get_body(self, inner: int, cursor: int = -1):
        if self._body_inner != inner or self._body_cursor_cached != cursor:
            self._body               = self._build_body(inner, cursor)
            self._body_inner         = inner
            self._body_cursor_cached = cursor
        return self._body

    # ── Rule detail view ──────────────────────────────────────────────────────

    def _render_detail(self):
        rows, cols = self.stdscr.getmaxyx()
        inner      = cols - 2
        ctrl_rows  = self._ctrl_rows(inner)
        self.stdscr.clear()
        self._draw_detail_view(rows, cols, inner, ctrl_rows)
        self._draw_controls(rows, cols, inner, ctrl_rows)
        self._apply_cursor()
        self.stdscr.refresh()
        self.dirty = False

    def _draw_detail_view(self, rows, cols, inner, ctrl_rows=None):
        A_NORMAL = curses.A_NORMAL
        A_DIM    = curses.A_DIM
        A_BOLD   = curses.A_BOLD
        CP1 = curses.color_pair(1)
        CP2 = curses.color_pair(2)
        CP4 = curses.color_pair(4)
        CP6 = curses.color_pair(6)

        with self._lock:
            rules             = list(self.rules)
            caches            = dict(self.caches)
            active            = set(self.active)
            per_rule          = self.log_stats.get("per_rule", {})
            detail_modifying  = self.detail_modifying
            detail_mod_result = self.detail_modify_result

        idx = min(self.detail_rule_idx, max(0, len(rules) - 1))
        if not rules:
            return
        rule         = rules[idx]
        name         = rule.name
        n            = idx + 1
        summarizing  = name in active

        cache   = caches.get(name) or {}
        title   = cache.get("title") or name
        summary = cache.get("summary") or ""
        desc    = cache.get("description") or ""

        try:
            rel = relative_time(rule.stat().st_mtime)
        except Exception:
            rel = "unknown"

        rule_pr = per_rule.get(name)
        if rule_pr:
            a, d = rule_pr["allow"], rule_pr["deny"]
            stats_segs = [
                (A_DIM,        "  30d: "),
                (CP6 | A_BOLD, str(a)),
                (A_DIM,        " allowed   "),
                (CP2 | A_BOLD, str(d)),
                (A_DIM,        " denied"),
            ]
        else:
            stats_segs = [(A_DIM, "  30d: no activity recorded")]

        # ── Fixed header: top border + single info row + divider ─────────────
        label = f" #{n}. {title} — {name} "
        self._draw_item(0, HLine(curses.ACS_ULCORNER, curses.ACS_URCORNER), cols, inner)
        try:
            self.stdscr.addstr(0, max(1, (cols - len(label)) // 2),
                               label[:inner], A_BOLD)
        except curses.error:
            pass

        # Combine stats + mtime on one line
        mtime_segs = [(A_DIM, f"   ·   Last modified: {rel}")]
        self._draw_item(1, ContentLine(stats_segs + mtime_segs), cols, inner)
        self._draw_item(2, HLine(curses.ACS_LTEE, curses.ACS_RTEE), cols, inner)

        # ── Scrollable content area (rows 3 .. rows-ctrl_rows-1) ────────────
        if ctrl_rows is None:
            ctrl_rows = self.CTRL_ROWS
        wrap_w       = max(1, inner - 4)
        content_top  = 3
        content_rows = rows - ctrl_rows - content_top
        if content_rows <= 0:
            return

        # Build content lines — description only, fall back to summary if none
        lines: list[list] = []
        if detail_modifying:
            lines.append([(CP4 | A_BOLD, "  Modifying, please wait…")])
        elif summarizing:
            lines.append([(CP4 | A_BOLD, "  Summarizing, please wait…")])
        elif desc:
            for i, para in enumerate(desc.split("\n\n")):
                if i:
                    lines.append([])
                for wl in word_wrap(para, wrap_w):
                    segs = parse_md(wl, A_NORMAL, CP1 | A_BOLD, CP4)
                    lines.append([(segs[0][0], "  " + segs[0][1])] + segs[1:])
        elif summary:
            lines.append([(A_DIM, "  (no long description — press [x] to generate)")])
            lines.append([])
            for wl in word_wrap(summary, wrap_w):
                lines.append([(A_NORMAL, f"  {wl}")])
        else:
            lines.append([(A_DIM, "  (no description — press [x] to generate)")])

        # ── Recent commands + change log ─────────────────────────────────────────
        if not detail_modifying and not summarizing:
            def _sec(label: str) -> SecLine:
                return SecLine(label, A_DIM | A_BOLD)

            recent = load_recent_rule_matches(name)
            lines.append([])
            lines.append(_sec("Recent Commands"))
            if recent:
                lines.append([])
                import textwrap as _tw
                _prefix_w = 29  # len("  YYYY-MM-DD HH:MM  ▶ verb   ")
                for r_ts, r_cmd, r_verdict in recent:
                    r_date   = r_ts[:10] if len(r_ts) >= 10 else r_ts
                    r_time   = r_ts[11:16] if len(r_ts) >= 16 else ""
                    v_attr   = CP6 | A_BOLD if r_verdict == "allow" else CP2 | A_BOLD
                    cmd_text = " ".join(r_cmd.split())
                    cmd_w    = max(10, wrap_w - _prefix_w)
                    cmd_lines = (_tw.wrap(cmd_text, cmd_w) or [cmd_text])[:3]
                    lines.append([
                        (A_DIM,    f"  {r_date} {r_time}  "),
                        (v_attr,   f"▶ {r_verdict:<5}"),
                        (A_NORMAL, "  "),
                    ] + highlight_shell(cmd_lines[0]))
                    for cl in cmd_lines[1:]:
                        lines.append([(A_NORMAL, " " * _prefix_w)] + highlight_shell(cl))
            else:
                lines.append([])
                lines.append([(A_DIM, "  No recent commands recorded.")])

            changes = load_change_log(name)
            lines.append([])
            lines.append(_sec("Changes"))
            if changes:
                lines.append([])
                for entry in changes[:30]:
                    ts       = entry.get("ts", "")
                    src      = entry.get("source", "?")
                    msg      = entry.get("msg", "")
                    time_str = ts[11:16] if len(ts) >= 16 else ts[:10] if ts else "?"
                    date_str = ts[:10]   if len(ts) >= 10 else "?"
                    src_attr = self._source_attr(src)
                    max_msg  = max(1, wrap_w - 25)
                    if len(msg) > max_msg:
                        msg = msg[:max_msg - 1] + "…"
                    lines.append([
                        (A_DIM,              f"  {date_str} {time_str}  "),
                        (src_attr | A_BOLD,  f"[{src:<4}]"),
                        (A_NORMAL,           f"  {msg}"),
                    ])
            else:
                lines.append([])
                lines.append([(A_DIM, "  No changes recorded.")])

        # Scroll clamping
        max_scroll = max(0, len(lines) - content_rows)
        self.detail_scroll = max(0, min(self.detail_scroll, max_scroll))

        # Scroll indicator on the divider
        if max_scroll > 0:
            ind_attr = CP4 | A_BOLD
            up_ch   = "↑" if self.detail_scroll > 0          else " "
            down_ch = "↓" if self.detail_scroll < max_scroll else " "
            for off, ch in [(-4, up_ch), (-3, down_ch)]:
                try:
                    self.stdscr.addstr(2, cols + off, ch, ind_attr)
                except curses.error:
                    pass

        EMPTY = ContentLine([])
        visible = lines[self.detail_scroll: self.detail_scroll + content_rows]
        for i in range(content_rows):
            if i >= len(visible):
                row_item = EMPTY
            elif isinstance(visible[i], SecLine):
                row_item = visible[i]
            else:
                row_item = ContentLine(visible[i])
            self._draw_item(content_top + i, row_item, cols, inner)

    # ── Change log view ───────────────────────────────────────────────────────

    def _render_log(self):
        rows, cols = self.stdscr.getmaxyx()
        inner      = cols - 2
        ctrl_rows  = self.CTRL_ROWS
        self.stdscr.erase()
        self._draw_log_view(rows, cols, inner, ctrl_rows)
        self._draw_controls(rows, cols, inner, ctrl_rows)
        self._hide_cursor()
        self._apply_cursor()
        self.stdscr.refresh()
        self.dirty = False

    def _build_log_display(self, inner: int) -> list:
        """Build ContentLine items for the change log view (newest first, day-grouped)."""
        import datetime
        A_DIM    = curses.A_DIM
        A_NORMAL = curses.A_NORMAL
        A_BOLD   = curses.A_BOLD

        entries = load_change_log()
        if not entries:
            return [ContentLine([(A_DIM, "  No changes recorded yet.")])]

        today     = datetime.date.today().isoformat()
        yesterday = (datetime.date.today() - datetime.timedelta(days=1)).isoformat()
        last_date = None
        # Reserve space for:  "  HH:MM  [SRC ]  rule-name                msg"
        #                       2+5+2+7+2+22+2 = 42 prefix → msg gets inner-44
        msg_width = max(20, inner - 44)

        lines = []
        for entry in entries:
            ts    = entry.get("ts", "")
            src   = entry.get("source", "?")
            rule  = entry.get("rule", "")
            msg   = entry.get("msg", "")
            date_str = ts[:10]   if len(ts) >= 10 else "?"
            time_str = ts[11:16] if len(ts) >= 16 else ts

            # Day header on date change
            if date_str != last_date:
                last_date = date_str
                if date_str == today:
                    day_label = f"Today  {date_str}"
                elif date_str == yesterday:
                    day_label = f"Yesterday  {date_str}"
                else:
                    day_label = date_str
                lines.append(ContentLine([(A_DIM | A_BOLD, f"  {day_label}")], bordered=False))

            src_attr  = self._source_attr(src)
            rule_disp = (rule[:19] + "…") if len(rule) > 20 else rule
            msg_disp  = (msg[:msg_width - 1] + "…") if len(msg) > msg_width else msg
            lines.append(ContentLine([
                (A_DIM,              f"  {time_str}  "),
                (src_attr | A_BOLD,  f"[{src:<4}]"),
                (A_DIM,              "  "),
                (A_NORMAL,           f"{rule_disp:<22}"),
                (A_NORMAL,           msg_disp),
            ]))

        return lines

    def _draw_log_view(self, rows, cols, inner, ctrl_rows):
        A_DIM  = curses.A_DIM
        A_BOLD = curses.A_BOLD

        # Header: title border + description + divider
        label = " Change Log "
        self._draw_item(0, HLine(curses.ACS_ULCORNER, curses.ACS_URCORNER), cols, inner)
        try:
            self.stdscr.addstr(0, max(1, (cols - len(label)) // 2), label, A_BOLD)
        except curses.error:
            pass
        self._draw_item(1, ContentLine([(A_DIM, "  Rule changes recorded across sessions.")]), cols, inner)
        self._draw_item(2, HLine(curses.ACS_LTEE, curses.ACS_RTEE), cols, inner)

        content_top  = 3
        content_rows = rows - ctrl_rows - content_top
        if content_rows <= 0:
            return

        lines = self._build_log_display(inner)

        # Clamp scroll
        max_scroll      = max(0, len(lines) - content_rows)
        self.log_scroll = max(0, min(self.log_scroll, max_scroll))

        # Scroll indicators on the divider
        self._draw_scroll_indicators(2, cols, self.log_scroll > 0, self.log_scroll < max_scroll)

        EMPTY   = ContentLine([])
        visible = lines[self.log_scroll: self.log_scroll + content_rows]
        for i in range(content_rows):
            item = visible[i] if i < len(visible) else EMPTY
            self._draw_item(content_top + i, item, cols, inner)

    # ── Deferred log view ─────────────────────────────────────────────────────

    def _render_deferlog(self):
        rows, cols = self.stdscr.getmaxyx()
        inner      = cols - 2
        self.stdscr.erase()
        self._draw_deferlog_view(rows, cols, inner)
        self._hide_cursor()
        self._apply_cursor()
        self.stdscr.refresh()
        self.dirty = False

    def _draw_deferlog_view(self, rows, cols, inner):
        A_DIM    = curses.A_DIM
        A_NORMAL = curses.A_NORMAL
        A_BOLD   = curses.A_BOLD

        entries = self.deferlog_entries
        n       = len(entries)
        cursor  = self.deferlog_cursor

        # ── Header: title + description + divider ─────────────────────────────
        left_arrow  = "← " if cursor > 0     else ""
        right_arrow = " →" if n > 0 and cursor < n - 1 else ""
        count_str   = f" {left_arrow}{cursor + 1}/{n}{right_arrow} " if n else " 0/0 "
        label       = " Deferred Log "
        self._draw_item(0, HLine(curses.ACS_ULCORNER, curses.ACS_URCORNER), cols, inner)
        try:
            self.stdscr.addstr(0, max(1, (cols - len(label)) // 2), label, A_BOLD)
            self.stdscr.addstr(0, max(1, cols - len(count_str) - 1), count_str, A_DIM)
        except curses.error:
            pass
        self._draw_item(1, ContentLine([(A_DIM, "  Commands with no matching rule (true gaps) — last 30 days, newest first.")]), cols, inner)
        self._draw_item(2, HLine(curses.ACS_LTEE, curses.ACS_RTEE), cols, inner)

        # ── Ctrl rows at bottom ────────────────────────────────────────────────
        ctrl_lines = self._deferlog_ctrl_lines(cols)
        ctrl_rows  = 1 + len(ctrl_lines)   # sep + content lines

        content_top  = 3
        content_rows = rows - ctrl_rows - content_top
        if content_rows <= 0:
            return

        # ── Timestamp row ──────────────────────────────────────────────────────
        if not entries:
            self._draw_item(content_top, ContentLine([(A_DIM, "  No deferred commands in log.")]), cols, inner)
            # draw ctrl
            ctrl_sep = rows - ctrl_rows
            self._draw_item(ctrl_sep, HLine(curses.ACS_LLCORNER, curses.ACS_LRCORNER), cols, inner)
            for i, segs in enumerate(ctrl_lines):
                self._draw_item(ctrl_sep + 1 + i, ContentLine(segs, bordered=False), cols, inner)
            return

        ts, cmd = entries[cursor]

        # Timestamp on first content row
        self._draw_item(content_top, ContentLine([(A_DIM, f"  {ts}")]), cols, inner)
        body_top  = content_top + 1
        body_rows = content_rows - 1
        if body_rows <= 0:
            return

        # ── Command body (tokenize → wrap → scroll) ────────────────────────  [SH]
        cmd_width      = max(1, inner - 4)   # 2 spaces indent each side
        body_lines: list = []                # list of list[(attr, text)]   [SH]
        heredoc_bodies                = scan_heredoc_body_lines(cmd)        # [SH]
        string_bodies, str_closings   = scan_multiline_string_lines(cmd)   # [SH]
        for line_idx, logical in enumerate(cmd.split("\n")):                # [SH]
            if not logical.strip():
                body_lines.append([])
                continue
            if line_idx in heredoc_bodies or line_idx in string_bodies:     # [SH]
                # String body line — render as yellow content               [SH]
                segs = []                                                   # [SH]
                for w in logical.split():                                   # [SH]
                    if segs: segs.append((curses.A_NORMAL, ' '))            # [SH]
                    segs.append((_sh_attr("yellow"), w))                    # [SH]
                wrapped = wrap_token_line(                                  # [SH]
                    segs or [(curses.A_NORMAL, logical)], cmd_width)        # [SH]
            elif line_idx in str_closings:                                  # [SH]
                # Closing line: yellow prefix (up to+incl closing quote),  # [SH]
                # then highlight_shell on the remainder so shell code after # [SH]
                # the quote is not mistakenly coloured as string content.   # [SH]
                close_col = str_closings[line_idx]                          # [SH]
                prefix    = logical[:close_col + 1]                         # [SH]
                suffix    = logical[close_col + 1:]                         # [SH]
                segs      = [(_sh_attr("yellow"), prefix)] if prefix else []# [SH]
                if suffix:                                                  # [SH]
                    segs.extend(highlight_shell(suffix))                    # [SH]
                wrapped = wrap_token_line(                                  # [SH]
                    segs or [(curses.A_NORMAL, logical)], cmd_width)        # [SH]
            else:
                wrapped = wrap_token_line(highlight_shell(logical), cmd_width)
            body_lines.extend(wrapped if wrapped else [[]])

        max_scroll        = max(0, len(body_lines) - body_rows)
        self.deferlog_scroll = max(0, min(self.deferlog_scroll, max_scroll))
        scroll = self.deferlog_scroll

        self._draw_scroll_indicators(2, cols, scroll > 0, scroll < max_scroll)

        EMPTY = ContentLine([])
        visible = body_lines[scroll: scroll + body_rows]
        for i in range(body_rows):
            line = visible[i] if i < len(visible) else None
            item = ContentLine([(A_NORMAL, "  ")] + line) if line is not None else EMPTY  # [SH]
            self._draw_item(body_top + i, item, cols, inner)

        # ── Controls ───────────────────────────────────────────────────────────
        ctrl_sep = rows - ctrl_rows
        self._draw_item(ctrl_sep, HLine(curses.ACS_LLCORNER, curses.ACS_LRCORNER), cols, inner)
        for i, segs in enumerate(ctrl_lines):
            self._draw_item(ctrl_sep + 1 + i, ContentLine(segs, bordered=False), cols, inner)

    def _deferlog_ctrl_lines(self, cols: int) -> list[list[tuple]]:
        A_DIM = curses.A_DIM

        res = self.deferlog_eval_result
        lines = []

        if res and res.get("running"):
            lines.append([(A_DIM, "  evaluating…")])
        elif res and not res.get("running"):
            lines.extend(self._eval_result_lines(res, cols))

        n = len(self.deferlog_entries)
        nav = "  ·  [←/→] navigate" if n > 1 else ""
        hint = f"  [e] eval  ·  [c] copy  ·  [r] reload{nav}  ·  [esc] close"
        lines.append([(A_DIM, hint)])
        return lines

    # ── Rendering ─────────────────────────────────────────────────────────────

    def _draw_controls(self, rows: int, cols: int, inner: int, ctrl_rows: int | None = None):
        """Draw the unified bottom controls strip (ctrl_sep: sep, then content lines)."""
        A_DIM    = curses.A_DIM
        A_NORMAL = curses.A_NORMAL
        A_BOLD   = curses.A_BOLD
        CP1 = curses.color_pair(1)
        CP2 = curses.color_pair(2)
        CP4 = curses.color_pair(4)
        CP6 = curses.color_pair(6)

        CP8 = curses.color_pair(8)
        if ctrl_rows is None:
            ctrl_rows = self.CTRL_ROWS
        ctrl_sep  = rows - ctrl_rows
        pane_open = self.eval_open or self.shadow_open or self.rec_open
        ctrl_battr = CP8 if pane_open else None
        box_open = pane_open or self.detail_open or self.log_open
        sep_lch = curses.ACS_LLCORNER if box_open else curses.ACS_HLINE
        sep_rch = curses.ACS_LRCORNER if box_open else curses.ACS_HLINE
        self._draw_item(ctrl_sep, HLine(sep_lch, sep_rch),
                        cols, inner, border_attr=ctrl_battr if ctrl_battr is not None else curses.A_DIM)

        if self.detail_open:
            with self._lock:
                rules  = list(self.rules)
                active = set(self.active)
            idx = min(self.detail_rule_idx, max(0, len(rules) - 1))
            summarizing       = bool(rules) and rules[idx].name in active
            detail_modifying  = self.detail_modifying
            detail_mod_result = self.detail_modify_result

            if summarizing or detail_modifying:
                segs = [(CP4, "  Modifying, please wait…   [esc] cancel"
                         if detail_modifying else "  Summarizing…   [←/esc] go back")]
            elif detail_mod_result is not None:
                if detail_mod_result == "ok":
                    segs = [(CP6 | A_BOLD, "  Rule modified and tests passed.   [any key] dismiss")]
                else:
                    segs = [(CP2, f"  {detail_mod_result[:inner - 4]}   [any key] dismiss")]
            elif self._detail_confirm_delete:
                name = rules[idx].name if rules else "?"
                segs = [(A_NORMAL, f"  Delete {name} and its test file?   [y] confirm   [n/esc] cancel")]
            elif self.detail_modify_mode:
                segs = [(A_NORMAL, f"  Modify: {self.detail_modify_input}   [enter] send  [esc] cancel")]
                self._draw_item(ctrl_sep + 1, ContentLine(segs, bordered=False), cols, inner)
                prefix = "  Modify: "
                self._show_cursor(ctrl_sep + 1, len(prefix) + self.detail_modify_cursor)
                return
            else:
                lines = self._wrap_ctrl_tokens(self._detail_ctrl_tokens(), inner)
                for i, line in enumerate(lines):
                    self._draw_item(ctrl_sep + 1 + i,
                                    ContentLine([(A_DIM, "  " + line)], bordered=False),
                                    cols, inner)
                self._hide_cursor()
                return
            self._hide_cursor()

        elif self.eval_open:
            for i, line_segs in enumerate(self._eval_ctrl_lines(cols)):
                self._draw_item(ctrl_sep + 1 + i, ContentLine(line_segs, bordered=False), cols, inner)
            return

        elif self.rec_open:
            if self.rec_processing:
                segs = [(CP4, "  Implementing recommendations, please wait…")]
            elif self.rec_analyzing:
                segs = [(A_DIM, "  Analyzing recommendations…   [esc/p] close")]
            else:
                with self._lock:
                    accepted_count = len(self._rec_accepted)
                proc_hint = f"[enter] process {accepted_count}  ·  " if accepted_count else ""
                segs = [(A_DIM, f"  ↑↓ navigate  [a] accept  [d] dismiss  [r] re-run  {proc_hint}[esc/p] close")]

        elif self.log_open:
            segs = [(A_DIM, "  [↑↓] scroll  ·  [esc/c] close")]

        elif self.shadow_open:
            if self.shadow_active:
                segs = [(A_DIM, "  Analyzing shadows…   [esc/s] close")]
            else:
                segs = [(A_DIM, "  [esc/s] close  ·  [r] re-run analysis")]

        else:
            # Main view — wrap tokens across as many rows as needed
            lines = self._wrap_ctrl_tokens(self._main_ctrl_tokens(), inner)
            for i, line in enumerate(lines):
                self._draw_item(ctrl_sep + 1 + i,
                                ContentLine([(A_DIM, "  " + line)], bordered=False),
                                cols, inner)
            return

        self._draw_item(ctrl_sep + 1, ContentLine(segs, bordered=False), cols, inner)

    def _draw_item(self, srow, item, cols, inner, border_attr=None):
        def safe_addch(y, x, ch, attr=curses.A_NORMAL):
            try: self.stdscr.addch(y, x, ch, attr)
            except curses.error: pass

        if isinstance(item, HLine):
            battr = border_attr if border_attr is not None else curses.A_NORMAL
            safe_addch(srow, 0, item.lch, battr)
            try: self.stdscr.hline(srow, 1, curses.ACS_HLINE, inner, battr)
            except curses.error: pass
            safe_addch(srow, cols - 1, item.rch, battr)
        elif isinstance(item, SecLine):
            # Section header: "  ── {label} " + ACS_HLINE fill + border
            # Use hline for all line-drawing to avoid double-width char issues
            safe_addch(srow, 0, curses.ACS_VLINE, curses.A_NORMAL)
            safe_addch(srow, cols - 1, curses.ACS_VLINE, curses.A_NORMAL)
            # "  " indent
            try: self.stdscr.addstr(srow, 1, "  ", item.attr)
            except curses.error: pass
            # leading "──" via hline (2 ACS_HLINE chars, guaranteed 1-col each)
            try: self.stdscr.hline(srow, 3, curses.ACS_HLINE, 2, item.attr)
            except curses.error: pass
            # " {label} " — pure ASCII
            label_str = f" {item.label} "
            label_start = 5
            try: self.stdscr.addstr(srow, label_start, label_str, item.attr)
            except curses.error: pass
            # fill from end of label to right border
            fill_start = label_start + len(label_str)
            fill_cols  = max(0, (cols - 1) - fill_start)
            if fill_cols > 0:
                try: self.stdscr.hline(srow, fill_start, curses.ACS_HLINE, fill_cols, item.attr)
                except curses.error: pass
        else:
            battr = (item.border_attr if item.border_attr is not None
                     else border_attr if border_attr is not None
                     else curses.A_NORMAL)
            if item.bordered:
                safe_addch(srow, 0, curses.ACS_VLINE, battr)
            col_start = 1 if item.bordered else 0
            col_end   = (cols - 1) if item.bordered else cols
            col = col_start
            for attr, text in item.segs:
                if col >= col_end:
                    break
                avail = col_end - col
                try: self.stdscr.addstr(srow, col, text[:avail], attr)
                except curses.error: pass
                col += len(text)
            if item.bordered:
                safe_addch(srow, cols - 1, curses.ACS_VLINE, battr)

    def _draw_eval_pane(self, rows, cols, inner, eval_rows):
        A_NORMAL = curses.A_NORMAL
        A_DIM    = curses.A_DIM

        sep_row, content_start = self._begin_pane(
            rows, cols, inner, eval_rows, " Evaluate ",
            description="Test a command against the engine to see which rule fires.")

        # Multi-line input
        logical_lines = self.eval_input.split("\n")
        cur_line, cur_col_in_line = self._cursor_line_col()
        scroll        = self._eval_scroll  # already clamped by render()
        visible_rows  = max(1, rows - content_start)

        # Scroll indicators on separator
        self._draw_scroll_indicators(sep_row, cols,
                                     scroll > 0, scroll + visible_rows < len(logical_lines))

        input_row_start = content_start
        display_row = input_row_start
        cursor_screen_row = input_row_start
        cursor_screen_col = 1 + 3  # after " › "

        CP8   = curses.color_pair(8)
        battr = CP8
        for li, line in enumerate(logical_lines):
            if li < scroll:
                continue
            if display_row >= rows:
                break
            prefix      = " › " if li == 0 else "   "
            prefix_attr = A_DIM if li == 0 else A_NORMAL
            self._draw_item(display_row, ContentLine([
                (prefix_attr, prefix),
                (A_NORMAL,    line),
            ]), cols, inner, border_attr=battr)
            if li == cur_line:
                cursor_screen_row = display_row
                cursor_screen_col = 1 + len(prefix) + cur_col_in_line
            display_row += 1

        # Cursor (hint content is drawn by _draw_controls)
        res = self.eval_result
        if not self.eval_allowing and res is None and self.eval_allow_result is None:
            self._show_cursor(cursor_screen_row, cursor_screen_col)
        else:
            self._hide_cursor()

    def render(self):
        if self.deferlog_open:
            self._render_deferlog()
            return
        if self.log_open:
            self._render_log()
            return
        if self.detail_open:
            self._render_detail()
            return

        rows, cols   = self.stdscr.getmaxyx()
        inner        = cols - 2
        eval_rows    = self._eval_pane_rows(inner)
        shadow_rows  = self._shadow_pane_rows(rows, inner)
        rec_rows     = self._rec_pane_rows(rows, inner)

        with self._lock:
            refresh_ts = self.last_refresh

        header = self._build_header(inner, refresh_ts)
        HR     = len(header)
        self._header_rows = HR
        body   = self._get_body(inner, self.body_cursor)

        ctrl_rows  = self._ctrl_rows(inner)
        pane_rows  = eval_rows + shadow_rows + rec_rows
        body_rows  = max(0, rows - HR - pane_rows - ctrl_rows)
        max_scroll = max(0, len(body) - body_rows)
        self.scroll = max(0, min(self.scroll, max_scroll))

        # Clamp rec scroll so cursor stays visible
        if rec_rows > 1:
            with self._lock:
                recs      = list(self.recs)
                dismissed = set(self._rec_dismissed)
                cursor    = self.rec_cursor
            visible = [r for r in recs if r["pattern"] not in dismissed]
            wrap_w  = max(1, inner - 6)
            _rec_desc = "Commands seen in logs that may be safe to auto-allow."
            content_rows = max(1, rec_rows - self._pane_overhead(_rec_desc, inner))
            # Build cumulative row offsets per rec index
            offsets = []
            acc = 0
            for r in visible:
                offsets.append(acc)
                acc += self._rec_item_rows(r, wrap_w)
            # Scroll so the entire cursor item is within [_rec_scroll, _rec_scroll+content_rows)
            if visible and cursor < len(offsets):
                cur_off  = offsets[cursor]
                cur_end  = cur_off + self._rec_item_rows(visible[cursor], wrap_w)
                if cur_off < self._rec_scroll:
                    self._rec_scroll = cur_off
                elif cur_end > self._rec_scroll + content_rows:
                    # Find first item boundary >= (cur_end - content_rows) so the
                    # cursor item ends at or before the bottom of the visible area.
                    target = max(0, cur_end - content_rows)
                    new_scroll = 0
                    for off in offsets:
                        if off >= target:
                            new_scroll = off
                            break
                    self._rec_scroll = new_scroll
            self._rec_scroll = max(0, self._rec_scroll)

        # Clamp eval scroll so cursor stays visible
        if eval_rows > 0:
            _eval_overhead = self._pane_overhead(
                "Test a command against the engine to see which rule fires.", inner)
            visible_input_rows = max(1, eval_rows - _eval_overhead)
            cur_line, _ = self._cursor_line_col()
            if cur_line < self._eval_scroll:
                self._eval_scroll = cur_line
            elif cur_line >= self._eval_scroll + visible_input_rows:
                self._eval_scroll = cur_line - visible_input_rows + 1
            self._eval_scroll = max(0, self._eval_scroll)

        pane_bot = rows - ctrl_rows  # row just above controls sep

        self.stdscr.erase()

        for srow, item in enumerate(header):
            self._draw_item(srow, item, cols, inner)

        div_row  = HR - 1
        self._draw_scroll_indicators(div_row, cols, self.scroll > 0, self.scroll < max_scroll)

        visible_body = body[self.scroll : self.scroll + body_rows]
        for i, item in enumerate(visible_body):
            self._draw_item(HR + i, item, cols, inner)

        if shadow_rows:
            self._draw_shadow_pane(pane_bot - eval_rows, cols, inner, shadow_rows)

        if rec_rows:
            self._draw_rec_pane(pane_bot - eval_rows - shadow_rows, cols, inner, rec_rows)

        if eval_rows:
            self._draw_eval_pane(pane_bot, cols, inner, eval_rows)
        else:
            self._hide_cursor()

        self._draw_controls(rows, cols, inner, ctrl_rows)
        self._apply_cursor()
        self.stdscr.refresh()
        self.dirty = False

    # ── Main loop ─────────────────────────────────────────────────────────────

    def run(self):
        self.stdscr.nodelay(True)
        self.stdscr.keypad(True)
        curses.curs_set(0)

        while True:
            if self.dirty:
                self.render()

            if self._pending_ev is not None:
                ev, self._pending_ev = self._pending_ev, None
            else:
                ev = self._read_event()
            if ev is None:
                time.sleep(0.05)
                continue

            # Handle paste bracketing globally
            if ev == "PASTE_START":
                self._in_paste = True
                continue
            if ev == "PASTE_END":
                self._in_paste = False
                continue

            rows, cols    = self.stdscr.getmaxyx()
            inner         = cols - 2

            # ── Change log view ───────────────────────────────────────────────
            if self.log_open:
                if ev in (27, ord('c'), ord('C')):
                    self.log_open = False
                    self._invalidate()
                elif ev in (curses.KEY_UP, ord('k')):
                    self.log_scroll = max(0, self.log_scroll - 1)
                    self.dirty = True
                elif ev in (curses.KEY_DOWN, ord('j')):
                    self.log_scroll += 1  # clamped in _draw_log_view
                    self.dirty = True
                elif ev == curses.KEY_PPAGE:
                    self.log_scroll = max(0, self.log_scroll - max(1, (rows - 4) // 2))
                    self.dirty = True
                elif ev == curses.KEY_NPAGE:
                    self.log_scroll += max(1, (rows - 4) // 2)  # clamped in _draw_log_view
                    self.dirty = True
                elif ev == curses.KEY_HOME:
                    self.log_scroll = 0
                    self.dirty = True
                elif ev == curses.KEY_END:
                    self.log_scroll = 999999  # clamped in _draw_log_view
                    self.dirty = True
                continue

            # ── Deferlog view ─────────────────────────────────────────────────
            if self.deferlog_open:
                if ev == 27 or ev in (ord('q'), ord('Q')):
                    self.deferlog_open = False
                    self.deferlog_eval_result = None
                    self._invalidate()
                elif ev in (curses.KEY_UP, ord('k')):
                    self.deferlog_scroll = max(0, self.deferlog_scroll - 1)
                    self.dirty = True
                elif ev in (curses.KEY_DOWN, ord('j')):
                    self.deferlog_scroll += 1   # clamped in render
                    self.dirty = True
                elif ev == curses.KEY_PPAGE:
                    self.deferlog_scroll = max(0, self.deferlog_scroll - max(1, (rows - 4) // 2))
                    self.dirty = True
                elif ev == curses.KEY_NPAGE:
                    self.deferlog_scroll += max(1, (rows - 4) // 2)
                    self.dirty = True
                elif ev in (curses.KEY_LEFT, ord('h'), ord('p')) and self.deferlog_entries:
                    # Previous = newer (lower index)
                    if self.deferlog_cursor > 0:
                        self.deferlog_cursor -= 1
                        self.deferlog_scroll = 0
                        self.deferlog_eval_result = None
                        self._invalidate()
                elif ev in (curses.KEY_RIGHT, ord('l'), ord('n')) and self.deferlog_entries:
                    # Next = older (higher index)
                    if self.deferlog_cursor < len(self.deferlog_entries) - 1:
                        self.deferlog_cursor += 1
                        self.deferlog_scroll = 0
                        self.deferlog_eval_result = None
                        self._invalidate()
                elif ev in (ord('e'), ord('E')) and self.deferlog_entries:
                    if not (self.deferlog_eval_result or {}).get("running"):
                        _, cmd = self.deferlog_entries[self.deferlog_cursor]
                        self._run_eval_async(cmd, 'deferlog_eval_result', highlight=False)
                elif ev in (ord('c'), ord('C')) and self.deferlog_entries:
                    _, cmd = self.deferlog_entries[self.deferlog_cursor]
                    try:
                        subprocess.run(["pbcopy"], input=cmd, text=True, timeout=3)
                    except Exception:
                        pass
                elif ev in (ord('r'), ord('R')):
                    self.deferlog_entries  = load_deferred_commands()
                    self.deferlog_cursor   = min(self.deferlog_cursor,
                                                 max(0, len(self.deferlog_entries) - 1))
                    self.deferlog_scroll   = 0
                    self.deferlog_eval_result = None
                    self._invalidate()
                continue

            # ── Rule detail view ──────────────────────────────────────────────
            if self.detail_open:
                with self._lock:
                    rules      = list(self.rules)
                    active     = set(self.active)
                summarizing = (self.detail_rule_idx < len(rules) and
                               rules[self.detail_rule_idx].name in active)

                if summarizing:
                    # Only allow going back; all other keys are no-ops
                    if ev in (27, curses.KEY_ENTER, 10, 13):
                        self.detail_open = False
                        self._invalidate()
                    continue

                if self.detail_modifying:
                    if ev == 27:
                        self._cancel_proc('_detail_modify_proc', 'detail_modifying')
                    continue

                if self.detail_modify_result is not None:
                    self.detail_modify_result = None
                    self._invalidate()
                    continue

                if self.detail_modify_mode:
                    if self._handle_basic_edit(ev, 'detail_modify_input', 'detail_modify_cursor'):
                        pass
                    elif ev == 27:
                        self.detail_modify_mode = False
                        self._invalidate()
                    elif ev in (curses.KEY_ENTER, 10, 13):
                        text = self.detail_modify_input.strip()
                        if text and self.detail_rule_idx < len(rules):
                            self.detail_modify_mode = False
                            self._modify_detail_rule(rules[self.detail_rule_idx], text)
                        self._invalidate()
                    continue

                if self._detail_confirm_delete:
                    if ev in (ord('y'), ord('Y')):
                        rule = rules[self.detail_rule_idx] if self.detail_rule_idx < len(rules) else None
                        if rule:
                            append_change_log("DEL", rule.name, "Rule deleted by user")
                            delete_rule(rule)
                            with self._lock:
                                self.rules  = [r for r in self.rules if r != rule]
                                self.caches.pop(rule.name, None)
                                self.synced.pop(rule.name, None)
                                self.active.discard(rule.name)
                            n_left = len(self.rules)
                            self.body_cursor     = min(self.body_cursor, max(0, n_left - 1))
                            self.detail_rule_idx = min(self.detail_rule_idx, max(0, n_left - 1))
                        self.detail_open = False
                        self._detail_confirm_delete = False
                        self.refresh()
                    else:
                        self._detail_confirm_delete = False
                        self._invalidate()
                    continue

                # Normal detail navigation
                if ev in (27, curses.KEY_ENTER, 10, 13):
                    self.detail_open = False
                    self._invalidate()
                elif ev in (curses.KEY_LEFT, curses.KEY_RIGHT):
                    delta = -1 if ev == curses.KEY_LEFT else 1
                    self.detail_rule_idx = max(0, min(len(rules) - 1, self.detail_rule_idx + delta))
                    self.body_cursor     = self.detail_rule_idx
                    self.detail_scroll   = 0
                    self._invalidate()
                elif ev == curses.KEY_UP:
                    self.detail_scroll = max(0, self.detail_scroll - 1)
                    self.dirty = True
                elif ev == curses.KEY_DOWN:
                    self.detail_scroll += 1   # clamped in _draw_detail_view
                    self.dirty = True
                elif ev in (ord('x'), ord('X')):
                    # Invalidate this rule's cache so the standard summarizer re-runs it
                    if self.detail_rule_idx < len(rules):
                        rule = rules[self.detail_rule_idx]
                        (CACHE_DIR / rule.name).unlink(missing_ok=True)
                        self._trigger_stale()
                elif ev in (ord('m'), ord('M')):
                    self.detail_modify_mode   = True
                    self.detail_modify_input  = ""
                    self.detail_modify_cursor = 0
                    self._invalidate()
                elif ev in (ord('D'),):
                    self._detail_confirm_delete = True
                    self._invalidate()
                continue  # swallow all other keys

            eval_typing   = self.eval_open and self.eval_result is None
            eval_result   = self.eval_open and self.eval_result is not None
            eval_running  = eval_result and (self.eval_result or {}).get("running")

            # ── Eval typing mode ──────────────────────────────────────────────
            if eval_typing:
                if ev in ("SHIFT_ENTER", "PASTE_NL"):
                    # Insert newline at cursor
                    self.eval_input  = (self.eval_input[:self.eval_cursor]
                                        + "\n" + self.eval_input[self.eval_cursor:])
                    self.eval_cursor += 1
                    self._invalidate()
                elif ev == 27:  # ESC
                    self.eval_open    = False
                    self.highlighted  = None
                    self._eval_scroll = 0
                    self._invalidate()
                elif ev in (curses.KEY_ENTER, 10, 13):
                    self._run_eval()
                elif ev == curses.KEY_DC:
                    if self.eval_cursor < len(self.eval_input):
                        self.eval_input = (self.eval_input[:self.eval_cursor]
                                           + self.eval_input[self.eval_cursor + 1:])
                        self._invalidate()
                elif ev == curses.KEY_UP:
                    line, col = self._cursor_line_col()
                    if line > 0:
                        self._move_to_line_col(line - 1, col)
                        self.dirty = True
                elif ev == curses.KEY_DOWN:
                    line, col = self._cursor_line_col()
                    lines = self.eval_input.split("\n")
                    if line < len(lines) - 1:
                        self._move_to_line_col(line + 1, col)
                        self.dirty = True
                elif ev == curses.KEY_HOME:
                    _, _ = self._cursor_line_col()
                    line, _ = self._cursor_line_col()
                    self._move_to_line_col(line, 0)
                    self.dirty = True
                elif ev == curses.KEY_END:
                    line, _ = self._cursor_line_col()
                    lines = self.eval_input.split("\n")
                    self._move_to_line_col(line, len(lines[line]))
                    self.dirty = True
                elif self._handle_basic_edit(ev, 'eval_input', 'eval_cursor'):
                    pass  # backspace, left, right, printable insert
                continue  # all keys consumed in typing mode

            # ── Eval allow result (dismiss on any key) ────────────────────────
            if self.eval_allow_result is not None:
                self.eval_allow_result = None
                self._invalidate()
                continue

            # ── Eval allowing (Claude running in background) ───────────────────
            if self.eval_allowing:
                if ev == 27:
                    self._cancel_proc('_eval_allow_proc', 'eval_allowing')
                continue

            # ── Shadow panel: ESC or s to close, r to re-run ─────────────────
            if self.shadow_open:
                if ev in (27, ord('s'), ord('S')):
                    self.shadow_open = False
                    self._invalidate()
                    continue
                if ev in (ord('r'), ord('R')):
                    self.shadow_open = False
                    SHADOW_CACHE.unlink(missing_ok=True)
                    self._load_shadows()
                    self._invalidate()
                    continue

            # ── Recommendations panel ─────────────────────────────────────────
            if self.rec_open:
                with self._lock:
                    recs      = list(self.recs)
                    dismissed = set(self._rec_dismissed)
                    cursor    = self.rec_cursor
                visible = [r for r in recs if r["pattern"] not in dismissed]

                if ev in (27, ord('p'), ord('P')):  # ESC or p closes
                    self.rec_open = False
                    self._invalidate()
                    continue
                if ev == curses.KEY_UP:
                    self.rec_cursor = max(0, cursor - 1)
                    self.dirty = True
                    continue
                if ev == curses.KEY_DOWN:
                    self.rec_cursor = min(len(visible) - 1, cursor + 1) if visible else 0
                    self.dirty = True
                    continue
                if ev in (ord('a'), ord('A')) and visible and cursor < len(visible):
                    pattern = visible[cursor]["pattern"]
                    with self._lock:
                        if pattern in self._rec_accepted:
                            self._rec_accepted.discard(pattern)
                        else:
                            self._rec_accepted.add(pattern)
                    self._invalidate()
                    continue
                if ev in (ord('d'), ord('D')) and visible and cursor < len(visible):
                    pattern = visible[cursor]["pattern"]
                    with self._lock:
                        self._rec_dismissed.add(pattern)
                        self._rec_accepted.discard(pattern)
                        recs_now      = list(self.recs)
                        dismissed_now = set(self._rec_dismissed)
                        last_ts_now   = self._rec_last_ts
                    save_rec_cache(recs_now, dismissed_now, last_ts_now)
                    # Adjust cursor
                    new_visible = [r for r in recs_now if r["pattern"] not in dismissed_now]
                    self.rec_cursor = min(cursor, max(0, len(new_visible) - 1))
                    self._invalidate()
                    continue
                if ev in (curses.KEY_ENTER, 10, 13):
                    with self._lock:
                        has_accepted = bool(self._rec_accepted)
                    if has_accepted:
                        self.rec_open = False
                        self._process_recs()
                    continue
                if ev in (ord('r'), ord('R')) and not self.rec_analyzing and not self.rec_processing:
                    REC_CACHE.unlink(missing_ok=True)
                    with self._lock:
                        self.recs = []
                        self._rec_last_ts = None
                    self._load_recs()
                    self._invalidate()
                    continue
                continue  # swallow all other keys

            # ── Eval result mode ──────────────────────────────────────────────
            if eval_result and not eval_running:
                if ev in (curses.KEY_ENTER, 10, 13):
                    # Edit: return to typing with same input
                    self.eval_result  = None
                    self.highlighted  = None
                    self.hi_verdict   = None
                    self._invalidate()
                elif ev in (ord('n'), ord('N')):
                    # New: clear input and start fresh
                    self._clear_eval_input()
                    self._invalidate()
                elif ev in (ord('a'), ord('A')):
                    if (self.eval_result or {}).get('verdict') == 'defer':
                        self._add_allow_rule(self.eval_input.strip())
                        self._invalidate()
                elif ev == 27:  # ESC: close panel
                    self.eval_open = False
                    self._clear_eval_input()
                    self._invalidate()
                elif ev in (ord('q'), ord('Q')):  # q: close and quit
                    self.eval_open = False
                    self._clear_eval_input()
                    self._invalidate()
                    break
                else:
                    # Any other key (cursor movement, printable, etc.): re-enter typing mode
                    # and replay the key so it's processed by the typing handler.
                    self.eval_result  = None
                    self.highlighted  = None
                    self.hi_verdict   = None
                    self._pending_ev  = ev
                    self._invalidate()
                continue

            # ── Normal mode ───────────────────────────────────────────────────
            body_rows = max(0, rows - self._header_rows - self._ctrl_rows(inner))

            if ev in (ord('q'), ord('Q')):
                break
            elif ev in (ord('e'), ord('E')):
                self.eval_open   = True
                self.shadow_open = False
                self.rec_open    = False
                self._clear_eval_input()
                self._invalidate()
            elif ev in (curses.KEY_RIGHT, curses.KEY_ENTER, 10, 13):
                # Open rule detail for current body cursor
                if self._rules:
                    self._open_detail(self.body_cursor)
            elif isinstance(ev, int) and ord('1') <= ev <= ord('9'):
                # Quick-open rule by number
                n = ev - ord('0')
                rules = self._rules
                if 1 <= n <= len(rules):
                    self._open_detail(n - 1)
            elif ev in (ord('s'), ord('S')):
                with self._lock:
                    analyzing = self.shadow_active
                if not analyzing:
                    self.shadow_open = not self.shadow_open
                    self.eval_open   = False
                    self.rec_open    = False
                    self._invalidate()
            elif ev in (ord('d'), ord('D')):
                self.deferlog_entries  = load_deferred_commands()
                self.deferlog_cursor   = 0
                self.deferlog_scroll   = 0
                self.deferlog_eval_result = None
                self.deferlog_open     = True
                self._invalidate()
            elif ev in (ord('c'), ord('C')):
                self.log_open    = True
                self.log_scroll  = 0
                self.eval_open   = False
                self.shadow_open = False
                self.rec_open    = False
                self._invalidate()
            elif ev in (ord('p'), ord('P')):
                with self._lock:
                    processing = self.rec_processing
                if not processing:
                    if not self.rec_open:
                        self.rec_open    = True
                        self.shadow_open = False
                        self.eval_open   = False
                        self.rec_cursor  = 0
                        self._rec_scroll = 0
                        if rec_cache_stale():
                            self._load_recs()
                    else:
                        self.rec_open = False
                    self._invalidate()
            elif ev in (ord('r'), ord('R')):
                self.refresh()
            elif ev == 18:  # Ctrl+R
                self.hard_reload()
            elif ev in (curses.KEY_UP, ord('k')):
                rules = self._rules
                self.body_cursor = max(0, self.body_cursor - 1)
                self._scroll_to_rule(self.body_cursor)
                self._invalidate()
            elif ev in (curses.KEY_DOWN, ord('j')):
                rules = self._rules
                self.body_cursor = min(len(rules) - 1, self.body_cursor + 1)
                self._scroll_to_rule(self.body_cursor)
                self._invalidate()
            elif ev == curses.KEY_PPAGE:
                rules = self._rules
                self.body_cursor = max(0, self.body_cursor - max(1, body_rows // 3))
                self._scroll_to_rule(self.body_cursor)
                self._invalidate()
            elif ev == curses.KEY_NPAGE:
                rules = self._rules
                self.body_cursor = min(len(rules) - 1,
                                       self.body_cursor + max(1, body_rows // 3))
                self._scroll_to_rule(self.body_cursor)
                self._invalidate()
            elif ev == curses.KEY_HOME:
                self.body_cursor = 0
                self.scroll      = 0
                self._invalidate()
            elif ev == curses.KEY_END:
                rules = self._rules
                self.body_cursor = max(0, len(rules) - 1)
                self._scroll_to_rule(self.body_cursor)
                self._invalidate()
            elif ev == curses.KEY_RESIZE:
                self._invalidate()


def main(stdscr):
    enable_terminal_protocols()
    tui = TUI(stdscr)
    try:
        tui.run()
    finally:
        disable_terminal_protocols()
        with tui._lock:
            shadow_proc  = tui._shadow_proc
            rec_proc     = tui._rec_proc
            allow_proc   = tui._eval_allow_proc
            modify_proc  = tui._detail_modify_proc
        for proc in (shadow_proc, rec_proc, allow_proc, modify_proc):
            if proc is not None:
                try:
                    proc.terminate()
                except Exception:
                    pass


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--log":
        # Write a change log entry: summary.py --log SOURCE RULE MESSAGE...
        if len(sys.argv) >= 5:
            append_change_log(sys.argv[2], sys.argv[3], " ".join(sys.argv[4:]))
        sys.exit(0)
    os.environ.setdefault("ESCDELAY", "25")
    curses.wrapper(main)
