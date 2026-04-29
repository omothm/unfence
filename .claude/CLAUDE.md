# unfence

This directory contains the rule files for the unfence engine.

## How the Engine Works

The engine (`~/.claude/unfence/hooks/unfence.sh`) is a PreToolUse hook for Claude Code. When Claude Code is about to run a Bash command, the engine:

1. Parses the command from the hook's JSON input.
2. Splits compound commands (`&&`, `||`, `;`, `|`, newlines) while respecting quotes and heredocs.
3. For each sub-command, normalizes it (strips redirections, `VAR=` prefixes).
4. Runs the normalized command through rule files in **filename-sorted order** until one returns a definitive verdict.
5. Combines verdicts across sub-commands: `deny` wins over `ask`, which wins over `allow`; any unknown part causes `defer`.

## Rule Files

Each `*.sh` file (excluding `*.test.sh`) in the `rules/` directory is a rule. Rules receive the normalized command in the `COMMAND` env var and must output exactly one of:

| Output | Meaning |
|---|---|
| `allow` | Auto-approve this command |
| `deny` | Block this command |
| `ask` | This rule explicitly wants the user to decide — stop the pipeline and prompt |
| `defer` | This rule has no opinion — pass to the next rule |
| `recurse:<cmd>` | Restart the rule pipeline with `<cmd>` (e.g. after unwrapping `xargs`) |

### `ask` vs `defer` — a critical distinction

These two verdicts both result in the user being prompted, but they are semantically very different:

- **`ask`** means a rule *recognized* the command and made an active decision to require human approval. The rule knows what the command is and deliberately flagged it. The engine emits `{"hookSpecificOutput":{"ruleVerdict":"ask"}}` so the outcome is observable.
- **`defer`** means no rule *claimed* the command at all — the engine ran out of rules with an opinion. The command falls back to Claude Code's default behavior (which is also to prompt, but for a different reason: *unknown*, not *flagged*).

Practical consequences:
- **Deferlog**: commands that `defer` all the way through appear in the TUI's deferred-commands log (so you can review what's unhandled). Commands that `ask` do **not** appear there — they were handled intentionally.
- **Tests**: `ask` and `defer` must be tested with distinct expected values (`"ask"` vs `"defer"`). Using `"defer"` as the expected value for a rule that returns `ask` hides the distinction and makes it impossible to verify the rule is actually firing.
- **Rule design**: use `ask` when you have recognized the command and want to require approval. Use `defer` when your rule simply doesn't apply to this command and you want the next rule to have a chance.

### Execution Order

Controlled by filename. Current ordering convention:
- `0-*` — Unwrapping / preprocessing rules (e.g. `xargs`)
- `1-*` — List-based matching (DENY/ASK/ALLOW arrays)
- `2-*` — Command-specific checkers (e.g. `aws`, `curl`, `gh api`)

### Creating a New Rule

1. Choose a filename that places it in the right execution order.
2. The script must read `$COMMAND` and echo a single verdict to stdout.
3. Default to `echo defer` when the rule doesn't apply.
4. Keep stderr silent (`2>/dev/null` is applied by the engine, but avoid noisy output).
5. **Handle both quote styles.** When a rule extracts a quoted argument value (e.g., `-c '...'` or `-c "..."`), it must accept both single and double quotes and behave identically for both. A rule that only handles one quote style will silently miss the other. Always test the same command with both quote styles.

## Tests

Every rule file **must** have a corresponding `*.test.sh` file. Test files are co-located in the `rules/` directory.

### Test File Format

Test files use the `run_test` function provided by the test runner:

```bash
run_test "description" 'command string' "expected_verdict"
```

Where `expected_verdict` is one of: `allow`, `deny`, `defer` (note: `ask` rules produce `defer` from the engine's perspective since no JSON output is emitted).

For rules that read `$PROJECT_CONFIG`, use `run_test_with_config` instead:

```bash
run_test_with_config "description" 'command string' "expected_verdict" '{"key": "value"}'
```

This writes the config JSON to a temp `.claude/unfence.json` and passes it as the `cwd` to the engine. Always include a `run_test` (no config) case to verify that missing config correctly produces `defer`.

**Why rule tests don't have a separate helper.sh:** Rule test files (`rules/*.test.sh`) are *sourced* directly into `run-tests.sh`, so they share its process and automatically have access to `run_test`, `run_test_with_config`, and `run_test_with_cwd` without any import. TUI tests run as *subprocesses*, so they must explicitly `source tui-tests/helper.sh` to get their helpers. This is an intentional architectural difference, not an oversight.

### Requirements

- **Every change to a rule file MUST be accompanied by corresponding test changes.** Adding a new pattern requires at least one positive and one negative test. Modifying behavior requires updating affected tests.
- **Always run the full test suite after any change:**
  ```bash
  bash ~/.claude/unfence/run-tests.sh
  ```
- **After any change to sample-rules/, also run the sample test suite:**
  ```bash
  RULES_SUITE=sample-rules bash ~/.claude/unfence/run-tests.sh
  ```
- **Never proceed with further work if tests are failing.** Fix the issue first.

## Diagnosing Why a Command Isn't Auto-Accepted

**Always read the rule files before diagnosing.** Do not assume a command or keyword is unhandled — check the actual rule files first. A confident diagnosis based on assumption (e.g. "no rule handles `for`") that contradicts the code wastes time and erodes trust.

Diagnostic checklist:
1. Split the command mentally (or via the engine) on `;`, `|`, `&&`, `||`, newlines.
2. For each part, trace through **every** rule file in filename order and note which verdict each would produce.
3. Only conclude a part is unhandled after verifying it against all rule files.
4. **Check all rules that sort after the one that fired.** A verdict from rule X doesn't mean X is correct — a later rule Y may have given a more specific or more appropriate verdict but never ran because X short-circuited the pipeline. If such a rule exists, the bug is an ordering bug: rename/reorder the later rule to run first. Do not patch rule X to paper over Y's absence.

## Modifying Rules

## Rule File Agnosticism

Nothing in the engine or the TUI should hardcode knowledge about specific rule file names, internal structures, or arrays (e.g. do not assume `1-lists.sh` exists or has an ALLOW array). When adding UI features that create or modify rules, use Claude as the agent (via `--dangerously-skip-permissions`) to read the existing rule files, understand the conventions, and decide where and how to make changes. Never hardcode "append to ALLOW array in `1-lists.sh`" or similar assumptions.

**CLAUDE.md additions must follow the same principle.** This file is a shared reference — additions must be generic (concepts, conventions, invariants) and must never reference specific filenames, array names, or patterns inside `rules/`. Rule files are untracked and evolve independently; any CLAUDE.md note tied to a specific rule file will become stale or misleading.

## Engine Normalization vs `0-*` Rules

When a command part needs to be "unwrapped" before rules can classify it, the fix belongs in one of two places. The deciding question is: **does the construct have a command name?**

**Shell syntax constructs → engine normalization (`classify_single`).**
Grouping constructs like `{ ... }`, `( ... )`, and `[[ ... ]]` are bash language syntax, not commands. They have no `TOKENS[0]` tool name. The engine is the right place to strip them because the alternative would require every rule to guard against syntax noise it should never see. Examples already handled in the engine: brace groups `{ cmd` / `}`, subshell groups `( cmd ) [&]`, variable assignments `VAR=$(cmd)`.

**Command wrappers and flag stripping → `0-*` preprocessing rules (`recurse:`).**
When `TOKENS[0]` is a recognizable tool name that wraps another command — `eval`, `bash -c`, `xargs`, `timeout`, `time`, or a tool with transparent context flags like `git -C` — the logic belongs in a `0-*` rule. The engine should not hardcode knowledge of specific tools. Using `recurse:` restarts the full pipeline so every downstream rule sees the clean inner command automatically.

**The wrong call:** if you find yourself writing a `0-*` rule that matches `TOKENS[0] == "("` or `TOKENS[0] == "{"`, that's a signal the fix belongs in the engine instead.

## Transparent Flag Stripping

Flags that modify execution context (e.g. `git -C <path>`) without changing the semantic identity of the command are "transparent". Stripping them is a normalization concern that belongs in a `0-*` preprocessing rule using `recurse:` — **not in the engine**.

Key principles:
- **Always tool-specific.** Only strip flags you know consume a value token for a particular command. Global stripping across all commands would silently corrupt flags that are meaningful for other tools.
- **Boolean flags are never transparent in this sense.** Only value-consuming flags qualify. A flag that takes no argument (e.g. `git -p` / `--paginate`) must not be treated as consuming the next token.
- **Use `recurse:` to restart the full pipeline.** This ensures all downstream rules (lists and checkers) see the clean command automatically.
- See `0-strip-flags.sh` (in both `rules/` and `sample-rules/`) for the canonical implementation.

## TUI Syntax Check

`summary.py` requires an interactive terminal and cannot be run non-interactively. To verify it still compiles after changes, use:

```bash
python3 -m py_compile summary.py && echo OK
```

## TUI Testing

`tui-tests/` contains a suite of interactive TUI smoke tests driven via tmux. They run automatically at the end of `run-tests.sh`, or you can run them directly:

```bash
bash ~/.claude/unfence/tui-tests.sh
```

Each `tui-tests/test-<name>.sh` is a standalone test script. To add a new test:
1. Create `tui-tests/test-<name>.sh` and `source "$(dirname "$0")/helper.sh"` at the top.
2. Define a `run()` function that uses the helper primitives (`tui_start`, `tui_stop`, `tui_send`, `tui_type_n`, `tui_capture`, `tui_grep`, `tui_pass`, `tui_fail`, etc.).
3. Call `tui_main "$@"` at the end.
4. `tui-tests.sh` auto-discovers all `tui-tests/test-*.sh` files.

**One test per behavioral contract** — if you add a new interactive widget (input field, confirmation dialog, scrollable pane) or change how an existing one renders, add a corresponding test.

**Tests must be self-contained** — never depend on real rule files in `rules/` or accumulated command history. Always use `tui_start` / `tui_start_sized` (which call `_tui_fixture_setup` automatically) so the TUI launches against an isolated fixture: 5 dummy rules with pre-populated cache entries (rule 1 has a 24-sentence description to guarantee scroll overflow at small terminal heights). The fixture also pre-populates shadow/rec/log-stats caches so shadow analysis and recommendation analysis do **not** start on launch. Tests must pass on a fresh checkout with an empty `rules/` directory.

### TUI test performance — wait for state, don't sleep fixed time

Tests run in **parallel** (each has a unique tmux session and fixture dir). Use polling instead of `sleep`:

- **`tui_wait_for_ctrl PATTERN`** — after `tui_send`, poll until PATTERN appears in the bottom ctrl line. Use this for transitions between main list and detail view.
- **`tui_wait_for PATTERN`** — poll until PATTERN appears anywhere on screen. Use for full-screen patterns like "Evaluate", "Delete", "navigate" (ctrl-only text), or verdict text.
- **`tui_wait_for_not PATTERN`** — poll until PATTERN disappears. Use when verifying a dialog or indicator went away.
- **`sleep 0.1`** — only for cursor movement keystrokes (`j`, `k`, `Left`, `Right`) that don't change visible text, where polling has nothing to trigger on.

**`tui_wait_for "\[m\]"` is a known false positive on macOS BSD grep** — `\[m\]` is interpreted as the character class `[m]` (matching any `m`), which hits "Dummy" in rule descriptions. Always use `tui_wait_for_ctrl "\[m\]"` to restrict the check to the ctrl line.

**`tui_type_n N CHAR` is batched**: single chars are sent as one string (all N at once); named keys (Left, Right) are sent in chunks of 20. For slow TUI widgets (curses event loop processes one keystroke per iteration at ~20 events/s), after batch-typing you may need to wait for the count to **stabilize** rather than sleep a fixed time. See `test-modify-wrap.sh` for a stability-polling example.

### Single-line input widgets

Single-line text inputs must implement horizontal viewport scrolling to keep the cursor visible. Key invariants:
- Available display width = `cols - 1 - len(fixed_prefix) - len(fixed_hint)` — the `-1` avoids writing to the last column of the last terminal row, which curses rejects.
- `voff = clamp(cursor - avail + 1, 0, max(0, len(text) - avail))` — cursor stays within the visible window.
- Visible count is the same at cursor-end and cursor-start (stable avail). Moving the cursor changes `voff`, not the number of visible chars.

## TUI Safe Rendering Patterns

Font glyph width bugs are **invisible in tmux captures but visible in the user's terminal** (Ghostty). When writing line-drawing or fill code in `summary.py`:

- **Never** use `addstr("─" * n)` or similar Unicode box-drawing char repetition for fills.
  Use `stdscr.hline(row, col, curses.ACS_HLINE, n, attr)` instead.
- **Never** use `addstr("│")` / `addstr("─")` for border characters.
  Use `addch(curses.ACS_VLINE)` / `addch(curses.ACS_HLINE)`.
- **Never** track display columns with `col += len(text)` when `text` contains
  Unicode line-drawing chars (U+2500–U+257F). Use absolute column positions or
  restrict `len()`-based tracking to pure-ASCII strings.
- For section headers with a labeled fill, use the `SecLine` layout object —
  `_draw_item` renders it entirely via `hline(ACS_HLINE)`, which is always correct.

**Rationale:** Python `len()` counts code points; ncurses counts display columns via
`wcwidth`. These diverge for box-drawing chars on some fonts, causing `addstr` to
silently clip or fail. ACS functions let ncurses own all column accounting.

**If layout looks correct in `tui-tests.sh` but broken for the user, ask for a Ghostty screenshot.** Automated captures cannot detect font glyph width mismatches — see `tui-tests/helper.sh` for the full list of irreducible limitations.

## PROJECT_CONFIG Schema Conventions

Rules that need project-specific configuration read `$PROJECT_CONFIG`, which is loaded from `.claude/unfence.json` in the project root. Follow these conventions when defining config keys:

- **Top-level key = tool name** (full name, e.g. `salesforce`, `github` — not the CLI alias).
- **Nested kebab-case** sub-keys, e.g. `salesforce["safe-orgs"]`, `github["safe-projects"]`.
- **Name keys after the data they hold**, not the command that uses them. A list of safe org aliases is `safe-orgs`; a list of project entries is `safe-projects`. Never name a key after a subcommand (e.g. not `item-edit`).
- **One entry, full identity.** Prefer a single array of richly-typed objects over parallel arrays keyed by lookup method. If a project can be identified by both a human-readable number and an opaque node ID, include both in the same object:
  ```json
  {
    "github": {
      "safe-projects": [
        {"owner": "trilogy-group", "num": 452, "node-id": "PVT_kwDOAVNSds4AsebT"}
      ]
    }
  }
  ```
  The rule then queries the same array differently depending on what the command exposes (`num`+`owner` for `item-add`, `node-id` for `item-edit`).

## Git Tracking

The `rules/` directory files are **not tracked by git** (only a `.gitkeep` is committed). Changes to rule files take effect immediately on disk — there is nothing to commit or push after editing them.

**Corollary for agents:** After adding or modifying rules, do **not** run `git add`, `git commit`, or `git push` for rule changes — there is nothing to commit. The only tracked files in this repo are engine code, TUI code, tests, and configuration (e.g. `.claude/`). If an agent workflow says "commit your changes", that applies only to those tracked files, not to `rules/`.

## Commit and Push Policy

**After completing any change to tracked files (`summary.py`, `tui-tests.sh`, `tui-tests/`, `run-tests.sh`, `engine-tests.sh`, `.claude/CLAUDE.md`, etc.), commit and push immediately — without asking, without waiting.** This is mandatory, not optional. Do not finish a task without committing. Do not ask "should I commit?" — just do it.

Steps every time:
1. `git diff` — confirm only your own changes are staged/unstaged.
2. If unrelated changes are present (from other agents), `git stash` them first, commit your change, then `git stash pop`.
3. Commit with a concise message and push: `git push`.

## README Sync

After any change that affects user-visible behavior (engine logic, TUI features, setup steps, sample-rule patterns), check `README.md` for stale descriptions and update them. Keep the README lean — fix outdated information, don't expand it. The README is the only user-facing doc; CLAUDE.md is internal.

## Bash Version Requirement

All shell scripts in this project require **bash 4.0 or later**. Features in active use that are unavailable in bash 3.x include `mapfile`, `${var^^}` case modifiers, and `declare -A` associative arrays. Backporting to bash 3.2 would require significant rewrites and is not a goal.

**Shebang convention**: All tracked `.sh` files use `#!/usr/bin/env bash` (not `#!/bin/bash`). On macOS, `/bin/bash` is frozen at 3.2 for licensing reasons; `#!/usr/bin/env bash` uses whichever `bash` is first in `PATH` instead. Install a modern bash via Homebrew (`brew install bash`) if needed.

**Consistency rule**: The PreToolUse hook, the TUI eval (`summary.py`), and the test runner must all resolve to the same `bash` binary. The hook is invoked via its shebang — `#!/usr/bin/env bash` ensures it picks up the same PATH bash that `summary.py` calls directly. Do not use `#!/bin/bash` in any new script.

**Version guard**: `hooks/unfence.sh` and `run-tests.sh` check `BASH_VERSINFO[0] < 4` at startup and exit with an error if the requirement is not met.

## Rule Count Discipline

When a user requests a modification or addition of a rule, **first evaluate whether an existing rule is a better fit** for expansion or contraction. Suggest expanding an existing rule if it covers the same domain or command family — keep the total rule count lean. Only create a new rule file if the modification is genuinely distinct in logic or domain. After any change, automatically run `./summary.py` to show the updated state, highlighting what changed.

## Claude Subprocess Logging

**Every** Claude subprocess spawned by the TUI — whether via `_spawn_claude_task` or directly via `subprocess.run`/`subprocess.Popen` — must write its full output (prompt, stdout, stderr) to a log file in `CACHE_DIR` (`.claude/cache/`). Use a meaningful name: `summarize-{rule.name}.log`, `shadow-analysis.log`, `modify-{rule.name}.log`, `add-allow-rule.log`, `implement-recommendations.log`, etc. These files persist between TUI runs.

**Rule:** When adding or editing any feature that spawns a Claude subprocess, always ensure the log path is meaningful and discoverable. Never use `stderr=subprocess.DEVNULL` or discard stdout without writing it to a log first. When debugging a failure that a user reports via screenshot, check the corresponding log file first — it contains the full Claude transcript including any error messages or JSON output.

## Claude Subprocess and Protected Paths

`_spawn_claude_task` spawns Claude with `--dangerously-skip-permissions` to bypass interactive permission prompts. However, Claude Code's **sensitive-file guard** operates independently and blocks writes to `~/.claude/**` regardless of that flag.

**Rule:** Always pass `--add-dir str(RULES_DIR)` (or the relevant directory) to every `_spawn_claude_task` call that needs to write files. Omitting it causes writes to be silently blocked with a "Permission denied: sensitive-file guard" error that surfaces as a failure in the TUI without any indication of why.

The current call in `_spawn_claude_task` already includes `--add-dir str(RULES_DIR)`. Any future subprocess that writes to a different directory must add its own `--add-dir` for that path.
