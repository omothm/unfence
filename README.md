# unfence

Claude Code's built-in permission system errs far on the side of caution: it prompts you to approve commands that are obviously safe — `git status`, `curl -s`, `jq` — breaking your agent's flow dozens of times per session. The only escape valve it offers is a coarse allow-list in `settings.json`, with no logic, no conditions, and no way to say "allow this, but not that variant."

This project replaces that with a **rule-file engine**: small shell scripts that encode exactly which commands are safe, which are dangerous, and which warrant a prompt. Rules are precise (flag-aware, specificity-ranked, composable), tested, and git-tracked. An agent writes and maintains them automatically as you work — you stay in control without being interrupted.

## How it works

`hooks/unfence.sh` is a `PreToolUse` hook. When Claude Code is about to run a Bash command, the engine:

1. Splits compound commands (`&&`, `||`, `;`, `|`) while respecting quotes and heredocs.
2. Normalizes each part (strips redirections, `VAR=` prefixes, transparent flags like `-C <path>`).
3. Runs each part through every rule file in `rules/` in filename-sorted order.
4. Combines verdicts: `deny` beats `ask` beats `allow`; any unmatched part defers to Claude Code's built-in prompt.

Each rule reads `$COMMAND` (already normalized) and outputs one of: `allow` `deny` `ask` `defer` `recurse:<new_cmd>`.

## Getting started

**Prerequisites:** Claude Code, `bash`, `jq`.

**1. Clone into your Claude config directory:**
```bash
git clone <repo-url> ~/.claude/unfence
cd ~/.claude/unfence
```

**2. Seed your rules directory from the samples:**
```bash
cp sample-rules/* rules/
```
This gives you a working starting point. The samples already cover common patterns — see [Writing rules](#writing-rules) below.

**3. Register the hooks in `~/.claude/settings.json`:**
```json
"PreToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command",
  "command": "~/.claude/unfence/hooks/unfence.sh", "timeout": 5 }] }],
"Stop": [{ "hooks": [{ "type": "command",
  "command": "~/.claude/unfence/hooks/sync-permissions-hook.sh" }] }]
```

**4. Verify:**
```bash
bash run-tests.sh
```

## Recommended workflow

You are not expected to write or edit rule files by hand. The intended flow is:

1. **Use Claude Code normally.** When it prompts you for a command you'd always allow, click "Allow" — this adds a `Bash(...)` entry to `settings.local.json`.
2. **The `sync-permissions-hook.sh` Stop hook fires automatically** at the end of each session. It spawns a Claude agent that reads those entries, decides where they best fit in your existing rules, writes the rule + test, runs the test suite, and removes the entry from `settings.local.json` once it's clean.
3. **Review the change** with `bash run-tests.sh` and spot-check the rule if you like.

Over time your `rules/` directory grows to reflect your actual workflow, fully automatically.

## Running tests

```bash
bash run-tests.sh
```

The runner sources every `*.test.sh` in `rules/` and reports pass/fail. Always run after changing a rule. Never proceed if any test is failing.

## Writing rules

Rules are normally written by agents (see [Recommended workflow](#recommended-workflow)), but understanding the patterns helps when you want to review or manually tune them. `sample-rules/` contains three annotated templates covering the main patterns:

**`0-unwrap.sh` — `recurse:` (preprocessing layer)**
Strips a wrapper command (e.g. `xargs`) and re-runs the full pipeline on the inner command. This means every other rule you write automatically extends to `xargs` invocations too, for free. The `recurse:` return value is unique to this engine.

**`1-lists.sh` — specificity-based ALLOW / DENY / ASK lists**
The main workhorse. Define three arrays of command prefixes. The most-specific match wins, with `deny > ask > allow` on ties. This lets you block `git push --force` while still allowing `git push` — a more-specific rule always beats a less-specific one. Flags like `--force` can appear anywhere in the command and still be matched.

**`2-checker.sh` — flag-inspection checker**
For tools where prefix matching isn't precise enough. Parses the actual flags to distinguish safe from unsafe operations — here, curl GET/HEAD requests are allowed while anything with `-d`, `-F`, `-X POST`, etc. is deferred. Apply this pattern to any tool with a mix of read-only and mutating subcommands.

**Filename prefix conventions:**
- `0-*` — Unwrappers / preprocessors (run first)
- `1-*` — List-based matching
- `2-*` — Command-specific checkers (run last)

Every rule file must have a `*.test.sh` counterpart with at least one positive (`allow`) and one negative (`defer`) test.

## The TUI (`./summary.py`)

`summary.py` is an interactive terminal dashboard for managing and understanding your rules. Run it from the project directory:

```bash
./summary.py
```

**What you see:**
- A scrollable list of all loaded rule files, each with its verdict counts (allow/deny/ask entries) and a one-line summary generated by Claude.
- A shadow analysis pane (bottom-left) that runs recent commands from the engine log through the current rules and flags any that would change verdict — useful after editing a rule.
- A recommendations pane (bottom-right) that analyzes frequently-deferred commands and suggests new rules to add.

### Try it right after setup

If you copied the sample rules in step 2, open the TUI and try the eval pane (`e`):

```
> git status
  ✓ allow  (1-lists.sh)

> git push --force
  ✗ deny   (1-lists.sh)

> git push origin main
  ~ defer  → Claude Code will prompt you

> curl https://api.example.com/health
  ✓ allow  (2-checker.sh)

> curl -X POST https://api.example.com/users -d '{}'
  ~ defer  → Claude Code will prompt you

> xargs git log
  ✓ allow  (0-unwrap.sh → recurse → 1-lists.sh)
```

The eval pane shows which rule fired and scrolls the rule list to highlight it — a fast way to understand why a command was allowed or blocked and to verify changes before committing them.
