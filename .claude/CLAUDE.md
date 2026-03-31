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
| `ask` | Defer to Claude Code's built-in permission prompt |
| `defer` | This rule has no opinion — pass to the next rule |
| `recurse:<cmd>` | Restart the rule pipeline with `<cmd>` (e.g. after unwrapping `xargs`) |

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
2. For each part, trace through each rule file in order and check whether it matches.
3. Only conclude a part is unhandled after verifying it against all rule files.

## Modifying Rules

## Rule File Agnosticism

Nothing in the engine or the TUI should hardcode knowledge about specific rule file names, internal structures, or arrays (e.g. do not assume `1-lists.sh` exists or has an ALLOW array). When adding UI features that create or modify rules, use Claude as the agent (via `--dangerously-skip-permissions`) to read the existing rule files, understand the conventions, and decide where and how to make changes. Never hardcode "append to ALLOW array in `1-lists.sh`" or similar assumptions.

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

## TUI Safe Rendering Patterns

Font glyph width bugs are invisible in tmux captures but visible in the user's terminal.
When writing line-drawing or fill code in `summary.py`:

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

## Commit and Push Policy

For simple, self-contained fixes (e.g. a single-file change with an obvious, low-risk purpose), **automatically commit and push without asking for confirmation**. Use a concise commit message that describes the change. Do not ask "should I commit this?" — just do it.

**Before committing, always check `git diff` for pre-existing uncommitted changes that belong to other agents.** Commit only your own changes. If unrelated changes are present, stash them first (`git stash`), commit your change, then restore the stash (`git stash pop`).

## Rule Count Discipline

When a user requests a modification or addition of a rule, **first evaluate whether an existing rule is a better fit** for expansion or contraction. Suggest expanding an existing rule if it covers the same domain or command family — keep the total rule count lean. Only create a new rule file if the modification is genuinely distinct in logic or domain. After any change, automatically run `./summary.py` to show the updated state, highlighting what changed.
