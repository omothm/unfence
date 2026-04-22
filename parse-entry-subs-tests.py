#!/usr/bin/env python3
"""
Regression tests for _parse_entry_subs_from_log and load_auto_allow_state.

These tests were added to prevent a specific regression: when the state file
lacks 'last_entry_subs_ts' (old format or poisoned state), the backfill scan
must start from after_ts="" so historical deferred entries are captured.

Run directly:  python3 parse-entry-subs-tests.py
Or via:        bash run-tests.sh
"""
import sys
import json
import tempfile
import os
from pathlib import Path

# ── Bootstrap: redirect LOG_FILE to a temp file we control ────────────────────

_tmp_log = tempfile.NamedTemporaryFile(mode="w", suffix=".log", delete=False)
_tmp_state = tempfile.NamedTemporaryFile(
    mode="w", suffix=".json", delete=False
)
_tmp_state.close()

# Patch environment so summary.py uses our tmp files
os.environ["UNFENCE_CACHE_DIR"] = str(Path(_tmp_state.name).parent)

import importlib.util, types

# We import only the functions we need by exec-ing the module with patched paths.
_spec = importlib.util.spec_from_file_location(
    "summary_mod",
    Path(__file__).parent / "summary.py",
)
_mod = importlib.util.module_from_spec(_spec)

# Patch LOG_FILE and AUTO_ALLOW_STATE before exec
_orig_log = None


def _patch_module(mod):
    mod.LOG_FILE = Path(_tmp_log.name)
    mod.AUTO_ALLOW_STATE = Path(_tmp_state.name)


_spec.loader.exec_module(_mod)
_patch_module(_mod)

_parse_entry_subs_from_log = _mod._parse_entry_subs_from_log
_load_aa = _mod.load_auto_allow_state
_save_aa = _mod.save_auto_allow_state
_cmd_hash = _mod._cmd_hash

# ── Helpers ───────────────────────────────────────────────────────────────────

PASS = 0
FAIL = 0


def ok(name):
    global PASS
    PASS += 1
    print(f"PASS: {name}")


def fail(name, msg=""):
    global FAIL
    FAIL += 1
    print(f"FAIL: {name}" + (f" — {msg}" if msg else ""))


def write_log(lines):
    Path(_tmp_log.name).write_text("\n".join(lines) + "\n")


def write_state(d):
    Path(_tmp_state.name).write_text(json.dumps(d))


# ── Tests: _parse_entry_subs_from_log ─────────────────────────────────────────


def test_basic_defer_entry():
    """Single INPUT with two sub-commands, one defers — entry_subs populated."""
    write_log([
        "[2026-04-21 10:00:01] [99] INPUT pkill -f myapp; grep foo /tmp/bar",
        "[2026-04-21 10:00:01] [99]   classify[0]: pkill -f myapp",
        "[2026-04-21 10:00:01] [99]   -> defer (no rule decided)",
        "[2026-04-21 10:00:01] [99]   classify[0]: grep foo /tmp/bar",
        "[2026-04-21 10:00:01] [99]   -> allow  (1-lists.sh)",
        "[2026-04-21 10:00:01] [99] => defer (some parts had no matching rule)",
    ])
    result, last_ts = _parse_entry_subs_from_log("")
    cmd = "pkill -f myapp; grep foo /tmp/bar"
    h = _cmd_hash(cmd)
    if h not in result:
        fail("basic_defer_entry", f"hash {h} not in result {list(result.keys())}")
        return
    if result[h] != ["pkill"]:
        fail("basic_defer_entry", f"expected ['pkill'], got {result[h]}")
        return
    if last_ts != "2026-04-21 10:00:01":
        fail("basic_defer_entry", f"unexpected last_ts {last_ts}")
        return
    ok("basic_defer_entry")


def test_allow_entry_excluded():
    """INPUT where all sub-commands allow — should NOT appear in entry_subs."""
    write_log([
        "[2026-04-21 10:00:02] [99] INPUT ls -la",
        "[2026-04-21 10:00:02] [99]   classify[0]: ls -la",
        "[2026-04-21 10:00:02] [99]   -> allow  (1-lists.sh)",
        "[2026-04-21 10:00:02] [99] => allow  All command parts match ALLOW rules",
    ])
    result, _ = _parse_entry_subs_from_log("")
    if result:
        fail("allow_entry_excluded", f"expected empty, got {result}")
    else:
        ok("allow_entry_excluded")


def test_multiple_deferred_bases():
    """Multiple sub-commands defer — all bases collected."""
    write_log([
        "[2026-04-21 10:00:03] [99] INPUT type aws; hash -r",
        "[2026-04-21 10:00:03] [99]   classify[0]: type aws",
        "[2026-04-21 10:00:03] [99]   -> defer (no rule decided)",
        "[2026-04-21 10:00:03] [99]   classify[0]: hash -r",
        "[2026-04-21 10:00:03] [99]   -> defer (no rule decided)",
        "[2026-04-21 10:00:03] [99] => defer (some parts had no matching rule)",
    ])
    result, _ = _parse_entry_subs_from_log("")
    cmd = "type aws; hash -r"
    h = _cmd_hash(cmd)
    if h not in result:
        fail("multiple_deferred_bases", f"hash not in result")
        return
    if sorted(result[h]) != ["hash", "type"]:
        fail("multiple_deferred_bases", f"expected ['hash','type'], got {sorted(result[h])}")
        return
    ok("multiple_deferred_bases")


def test_after_ts_filters_old_entries():
    """after_ts set to just before second entry — only second entry returned."""
    write_log([
        "[2026-04-21 10:00:01] [99] INPUT old-cmd --flag",
        "[2026-04-21 10:00:01] [99]   classify[0]: old-cmd --flag",
        "[2026-04-21 10:00:01] [99]   -> defer (no rule decided)",
        "[2026-04-21 10:00:01] [99] => defer (some parts had no matching rule)",
        "[2026-04-21 10:00:05] [99] INPUT new-cmd --flag",
        "[2026-04-21 10:00:05] [99]   classify[0]: new-cmd --flag",
        "[2026-04-21 10:00:05] [99]   -> defer (no rule decided)",
        "[2026-04-21 10:00:05] [99] => defer (some parts had no matching rule)",
    ])
    result, last_ts = _parse_entry_subs_from_log("2026-04-21 10:00:01")
    old_h = _cmd_hash("old-cmd --flag")
    new_h = _cmd_hash("new-cmd --flag")
    if old_h in result:
        fail("after_ts_filters_old", "old entry should have been filtered")
        return
    if new_h not in result:
        fail("after_ts_filters_old", "new entry missing")
        return
    if result[new_h] != ["new-cmd"]:
        fail("after_ts_filters_old", f"expected ['new-cmd'], got {result[new_h]}")
        return
    ok("after_ts_filters_old")


def test_empty_log():
    """Empty log returns empty result."""
    write_log([])
    result, last_ts = _parse_entry_subs_from_log("")
    if result or last_ts:
        fail("empty_log", f"expected empty, got result={result} last_ts={last_ts!r}")
    else:
        ok("empty_log")


def test_interleaved_pids():
    """Two concurrent PIDs — each tracked independently."""
    write_log([
        "[2026-04-21 10:00:01] [11] INPUT cmd-a; other",
        "[2026-04-21 10:00:01] [22] INPUT safe-b",
        "[2026-04-21 10:00:01] [11]   classify[0]: cmd-a",
        "[2026-04-21 10:00:01] [22]   classify[0]: safe-b",
        "[2026-04-21 10:00:01] [11]   -> defer (no rule decided)",
        "[2026-04-21 10:00:01] [22]   -> allow  (1-lists.sh)",
        "[2026-04-21 10:00:01] [11]   classify[0]: other",
        "[2026-04-21 10:00:01] [11]   -> allow  (1-lists.sh)",
        "[2026-04-21 10:00:01] [22] => allow  All command parts match ALLOW rules",
        "[2026-04-21 10:00:01] [11] => defer (some parts had no matching rule)",
    ])
    result, _ = _parse_entry_subs_from_log("")
    ha = _cmd_hash("cmd-a; other")
    hb = _cmd_hash("safe-b")
    if ha not in result:
        fail("interleaved_pids", "PID 11 entry missing")
        return
    if hb in result:
        fail("interleaved_pids", "PID 22 allowed entry should not appear")
        return
    if result[ha] != ["cmd-a"]:
        fail("interleaved_pids", f"expected ['cmd-a'], got {result[ha]}")
        return
    ok("interleaved_pids")


def test_multiline_input_command():
    """INPUT spanning multiple log lines — full command hash must match."""
    # The log function writes `printf '[ts] [pid] %s\n' "INPUT $cmd"` in one call.
    # When cmd contains newlines, the result is:
    #   [ts] [pid] INPUT first line
    #   second line
    #   third line
    #   [ts] [pid]   classify[0]: ...
    # The continuation lines have no [ts][pid] prefix.
    cmd = "type aws 2>&1; echo ---\necho PATH\necho done"
    write_log([
        f"[2026-04-21 10:00:01] [99] INPUT {cmd.splitlines()[0]}",
        cmd.splitlines()[1],
        cmd.splitlines()[2],
        "[2026-04-21 10:00:01] [99]   classify[0]: type aws",
        "[2026-04-21 10:00:01] [99]   -> defer (no rule decided)",
        "[2026-04-21 10:00:01] [99]   classify[0]: echo ---",
        "[2026-04-21 10:00:01] [99]   -> allow  (1-lists.sh)",
        "[2026-04-21 10:00:01] [99]   classify[0]: echo PATH",
        "[2026-04-21 10:00:01] [99]   -> allow  (1-lists.sh)",
        "[2026-04-21 10:00:01] [99]   classify[0]: echo done",
        "[2026-04-21 10:00:01] [99]   -> allow  (1-lists.sh)",
        "[2026-04-21 10:00:01] [99] => defer (some parts had no matching rule)",
    ])
    result, _ = _parse_entry_subs_from_log("")
    h = _cmd_hash(cmd)
    if not result:
        fail("multiline_input_command", "result is empty — continuation lines not collected")
        return
    if h not in result:
        found = list(result.keys())
        fail("multiline_input_command",
             f"full-command hash {h} not in result; found hashes: {found}")
        return
    if result[h] != ["type"]:
        fail("multiline_input_command", f"expected ['type'], got {result[h]}")
        return
    ok("multiline_input_command")


def test_recurse_deferred_sub():
    """Sub-command that goes through recurse: and then defers must be captured.

    When the engine emits 'classify[0]: git -C <path> worktree list' followed by
    '-> recurse: git worktree list', then 'classify[1]: git worktree list' followed
    by '-> defer', the original classify[0] sub must be recorded as deferred.
    Previously the parser cleared pid_cur_sub on the recurse: verdict and missed
    the subsequent defer.
    """
    write_log([
        "[2026-04-21 10:00:01] [99] INPUT git -C /some/path worktree list 2>&1 | head -5",
        "[2026-04-21 10:00:01] [99]   classify[0]: git -C /some/path worktree list",
        "[2026-04-21 10:00:01] [99]   -> recurse: git worktree list  (0-strip-flags.sh)",
        "[2026-04-21 10:00:01] [99]   classify[1]: git worktree list",
        "[2026-04-21 10:00:01] [99]   -> defer (no rule decided)",
        "[2026-04-21 10:00:01] [99]   classify[0]: head -5",
        "[2026-04-21 10:00:01] [99]   -> allow  (1-lists.sh)",
        "[2026-04-21 10:00:01] [99] => defer (some parts had no matching rule)",
    ])
    result, _ = _parse_entry_subs_from_log("")
    cmd = "git -C /some/path worktree list 2>&1 | head -5"
    h = _cmd_hash(cmd)
    if h not in result:
        fail("recurse_deferred_sub", f"hash {h} not in result {list(result.keys())}")
        return
    if result[h] != ["git"]:
        fail("recurse_deferred_sub", f"expected ['git'], got {result[h]}")
        return
    ok("recurse_deferred_sub")


def test_recurse_allowed_sub_excluded():
    """Sub-command that goes through recurse: and then allows must NOT appear as deferred."""
    write_log([
        "[2026-04-21 10:00:02] [99] INPUT git -C /some/path status 2>&1",
        "[2026-04-21 10:00:02] [99]   classify[0]: git -C /some/path status",
        "[2026-04-21 10:00:02] [99]   -> recurse: git status  (0-strip-flags.sh)",
        "[2026-04-21 10:00:02] [99]   classify[1]: git status",
        "[2026-04-21 10:00:02] [99]   -> allow  (1-lists.sh)",
        "[2026-04-21 10:00:02] [99]   -> allow  (0-strip-flags.sh)  [via recurse]",
        "[2026-04-21 10:00:02] [99] => allow  All command parts match ALLOW rules",
    ])
    result, _ = _parse_entry_subs_from_log("")
    if result:
        fail("recurse_allowed_sub_excluded", f"expected empty result, got {result}")
    else:
        ok("recurse_allowed_sub_excluded")


# ── Tests: load_auto_allow_state backfill detection ───────────────────────────


def test_missing_last_entry_subs_ts_resets_to_empty():
    """State file without last_entry_subs_ts → last_ts returned as "" (full backfill)."""
    write_state({
        "last_ts": "2026-04-21 22:48:12",
        "last_log_size": 99999,
        "result": {"added": [], "skipped": ["curl"]},
        "entry_subs": {},
    })
    last_ts, result, entry_subs, no_more = _load_aa()
    if last_ts != "":
        fail("missing_last_entry_subs_ts_resets", f"expected '', got {last_ts!r}")
        return
    ok("missing_last_entry_subs_ts_resets")


def test_no_entry_subs_key_resets_to_empty():
    """Old state file without entry_subs key → last_ts reset to "" and entry_subs={}."""
    write_state({
        "last_ts": "2026-04-21 22:48:12",
        "last_log_size": 99999,
        "result": {"added": ["grep"], "skipped": []},
    })
    last_ts, result, entry_subs, no_more = _load_aa()
    if last_ts != "":
        fail("no_entry_subs_key_resets", f"expected '', got {last_ts!r}")
        return
    if entry_subs != {}:
        fail("no_entry_subs_key_resets", f"expected {{}}, got {entry_subs}")
        return
    ok("no_entry_subs_key_resets")


def test_valid_state_uses_last_entry_subs_ts():
    """Valid new-format state uses last_entry_subs_ts, not last_ts."""
    write_state({
        "last_ts": "2026-04-21 22:48:12",
        "last_entry_subs_ts": "2026-04-21 22:50:00",
        "last_log_size": 99999,
        "result": None,
        "entry_subs": {"abc123": ["curl"]},
    })
    last_ts, result, entry_subs, no_more = _load_aa()
    if last_ts != "2026-04-21 22:50:00":
        fail("valid_state_uses_last_entry_subs_ts", f"expected 22:50:00, got {last_ts!r}")
        return
    if entry_subs != {"abc123": ["curl"]}:
        fail("valid_state_uses_last_entry_subs_ts", f"entry_subs mismatch: {entry_subs}")
        return
    ok("valid_state_uses_last_entry_subs_ts")


def test_save_writes_last_entry_subs_ts():
    """save_auto_allow_state writes last_entry_subs_ts so next load uses it."""
    _save_aa("2026-04-21 23:00:00", {"added": ["ls"]}, {"h1": ["ls"]})
    d = json.loads(Path(_tmp_state.name).read_text())
    if "last_entry_subs_ts" not in d:
        fail("save_writes_last_entry_subs_ts", "last_entry_subs_ts missing from saved state")
        return
    if d["last_entry_subs_ts"] != "2026-04-21 23:00:00":
        fail("save_writes_last_entry_subs_ts", f"unexpected value: {d['last_entry_subs_ts']!r}")
        return
    ok("save_writes_last_entry_subs_ts")


def test_entry_no_more_defers_round_trip():
    """save/load round-trip for entry_no_more_defers set."""
    _save_aa("2026-04-21 23:00:00", {"added": []}, {"h1": ["git"]},
             entry_no_more_defers={"abc", "def"})
    _, _, _, no_more = _load_aa()
    if no_more != {"abc", "def"}:
        fail("entry_no_more_defers_round_trip", f"expected {{'abc','def'}}, got {no_more}")
        return
    ok("entry_no_more_defers_round_trip")


def test_entry_no_more_defers_missing_defaults_empty():
    """State without entry_no_more_defers key → empty set on load."""
    write_state({
        "last_ts": "2026-04-21 22:48:12",
        "last_entry_subs_ts": "2026-04-21 22:48:12",
        "last_log_size": 99999,
        "result": None,
        "entry_subs": {},
    })
    _, _, _, no_more = _load_aa()
    if no_more != set():
        fail("entry_no_more_defers_missing_defaults_empty", f"expected empty set, got {no_more}")
        return
    ok("entry_no_more_defers_missing_defaults_empty")


# ── Run all tests ─────────────────────────────────────────────────────────────

test_basic_defer_entry()
test_allow_entry_excluded()
test_multiple_deferred_bases()
test_after_ts_filters_old_entries()
test_empty_log()
test_interleaved_pids()
test_multiline_input_command()
test_recurse_deferred_sub()
test_recurse_allowed_sub_excluded()
test_missing_last_entry_subs_ts_resets_to_empty()
test_no_entry_subs_key_resets_to_empty()
test_valid_state_uses_last_entry_subs_ts()
test_save_writes_last_entry_subs_ts()
test_entry_no_more_defers_round_trip()
test_entry_no_more_defers_missing_defaults_empty()

# Cleanup
os.unlink(_tmp_log.name)
os.unlink(_tmp_state.name)

print(f"\n{'All' if FAIL == 0 else FAIL} parse-entry-subs test(s) {'passed' if FAIL == 0 else 'failed'} ({PASS} passed, {FAIL} failed).")
sys.exit(0 if FAIL == 0 else 1)
