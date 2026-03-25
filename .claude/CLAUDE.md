# unfence

This directory contains the rule files for the unfence engine.

## How the Engine Works

The engine (`~/.claude/unfence/hooks/unfence.sh`) is a PreToolUse hook for Claude Code. When Claude Code is about to run a Bash command, the engine:

1. Parses the command from the hook's JSON input.
2. Splits compound commands (`&&`, `||`, `;`, `|`, newlines) while respecting quotes and heredocs.
3. For each sub-command, normalizes it (strips redirections, `VAR=` prefixes, transparent flags like `-C <path>`).
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

### Requirements

- **Every change to a rule file MUST be accompanied by corresponding test changes.** Adding a new pattern requires at least one positive and one negative test. Modifying behavior requires updating affected tests.
- **Always run the full test suite after any change:**
  ```bash
  bash ~/.claude/unfence/run-tests.sh
  ```
- **Never proceed with further work if tests are failing.** Fix the issue first.

## Modifying Rules

## Rule File Agnosticism

Nothing in the engine or the TUI should hardcode knowledge about specific rule file names, internal structures, or arrays (e.g. do not assume `1-lists.sh` exists or has an ALLOW array). When adding UI features that create or modify rules, use Claude as the agent (via `--dangerously-skip-permissions`) to read the existing rule files, understand the conventions, and decide where and how to make changes. Never hardcode "append to ALLOW array in `1-lists.sh`" or similar assumptions.

## Rule Count Discipline

When a user requests a modification or addition of a rule, **first evaluate whether an existing rule is a better fit** for expansion or contraction. Suggest expanding an existing rule if it covers the same domain or command family — keep the total rule count lean. Only create a new rule file if the modification is genuinely distinct in logic or domain. After any change, automatically run `./summary.py` to show the updated state, highlighting what changed.
