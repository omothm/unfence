# unfence

Increase Claude's autonomy without losing control.

Claude Code's built-in permission system errs far on the side of caution: it prompts you to approve commands that are obviously safe — `git status`, `curl -s`, `jq` — breaking your agent's flow dozens of times per session. The only escape valve it offers is a coarse allow-list in `settings.json`, with no logic, no conditions, and no way to say "allow this, but not that variant."

This project replaces that with a **rule-file engine**: small shell scripts that encode exactly which commands are safe, which are dangerous, and which warrant a prompt. Rules are precise (flag-aware, specificity-ranked, composable), tested, and git-tracked. An agent writes and maintains them automatically as you work — you stay in control without being interrupted. It is the [PreToolUse hook](https://code.claude.com/docs/en/permissions#:~:text=Use%20PreToolUse%20hooks) that Claude's own docs recommend for reliable command filtering.

## How it works

`hooks/unfence.sh` is a `PreToolUse` hook. When Claude Code is about to run a Bash command, the engine:

1. Splits compound commands (`&&`, `||`, `;`, `|`, newlines) while respecting quotes and heredocs.
2. Normalizes each part (strips redirections, `VAR=` prefixes).
3. Runs each part through every rule file in `rules/` in filename-sorted order.
4. Combines verdicts: `deny` beats `ask` beats `allow`; any unmatched part defers to Claude Code's built-in prompt.

Each rule reads `$COMMAND` (already normalized) and outputs one of: `allow` `deny` `deny:<message>` `ask` `defer` `recurse:<new_cmd>`. The `deny:<message>` form blocks the command and surfaces the message to Claude as `permissionDecisionReason`, so it understands why and can choose an alternative.

## Getting started

**Prerequisites:** Claude Code, `bash` 4+ (macOS ships bash 3.2 — install a modern version via `brew install bash`), `jq`.

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

The runner sources every `*.test.sh` in `rules/`, reports pass/fail, then runs the TUI test suite (`tui-tests/`). Always run after changing a rule or `summary.py`. Never proceed if any test is failing.

To run only the TUI tests:

```bash
bash tui-tests.sh
```

## Writing rules

Rules are normally written by agents (see [Recommended workflow](#recommended-workflow)), but understanding the patterns helps when you want to review or manually tune them. `sample-rules/` contains annotated templates covering the main patterns:

**`0-unwrap.sh` — `recurse:` (preprocessing layer)**
Strips a wrapper command and re-runs the full pipeline on the inner command. Handles `xargs`, `eval`, and `bash`/`sh`/`zsh -c` out of the box. This means every other rule you write automatically extends to those wrapper forms for free. The `recurse:` return value is unique to this engine.

**`0-strip-flags.sh` — transparent flag stripping**
Some flags modify execution context (e.g. `git -C /path`) without changing the semantic identity of the command. This rule strips known flag-value pairs per tool and recurses on the clean command, so all downstream rules see `git log` instead of `git -C /repo log`. The pattern is always tool-specific: only strip flags you know consume a value for a particular command — global stripping would silently corrupt flags that are meaningful for other tools.

**`1-lists.sh` — specificity-based ALLOW / DENY / ASK lists**
The main workhorse. Define three arrays of command prefixes. The most-specific match wins, with `deny > ask > allow` on ties. This lets you block `git push --force` while still allowing `git push` — a more-specific rule always beats a less-specific one. Flags like `--force` can appear anywhere in the command and still be matched.

**`2-checker.sh` — flag-inspection checker (curl)**
For tools where prefix matching isn't precise enough. Parses the actual flags to distinguish safe from unsafe operations — here, curl GET/HEAD requests are allowed while anything with `-d`, `-F`, `-X POST`, etc. is deferred. Apply this pattern to any tool with a mix of read-only and mutating subcommands.

**`2-rm-checker.sh` — semantic rm checker**
Extends the checker pattern to destructive operations. Denies any `rm` invocation that combines a recursive flag (`-r`, `-R`, `--recursive`) with a force flag (`-f`, `--force`), regardless of order, casing, or whether they appear combined (`-rf`) or split (`-r -f`). Prefix matching in `1-lists.sh` would only catch the exact string `rm -rf`; this checker catches all variants.

**Cross-cutting flag rule (e.g. `2-check-info-flags.sh`)**
Some rules apply across all commands based purely on flags, not the command name. Any invocation with `--help` or `--version` is safe regardless of what command it is — a single 5-line rule auto-approves all informational queries across every CLI tool you'll ever use. Write one such rule and it applies everywhere for free.

**Naming-convention matching (e.g. `2-check-aws.sh`)**
When a tool's CLI follows a consistent naming convention, match the pattern instead of enumerating every subcommand. AWS read-only operations are all prefixed `describe-*`, `list-*`, `get-*` — a single `case` match covers hundreds of subcommands. More robust than maintaining an exhaustive list, and automatically correct for new subcommands as the tool evolves.

**Environment-aware / project-config rules (e.g. `1-check-sf.sh`)**
Rules can read environment variables and external JSON config, not just the command string. If a file named `.claude/unfence.json` exists in the project root, the engine loads it and exports its contents as `$PROJECT_CONFIG`. Rules can then use `jq` to extract project-specific values and make context-sensitive decisions. This is the pattern to reach for when "always allow" is too coarse but "always ask" is too noisy.

A few examples of what this unlocks:

- **Salesforce:** allow `sf project deploy start` only when `--target-org` matches an org listed in `.salesforce.safe-orgs` — so Claude can deploy freely to scratch orgs but must ask for production.
- **AWS — safe profiles:** allow any `aws` command when `--profile` matches a read-only or sandbox profile listed in `.aws.safe-profiles` — Claude gets full autonomy within the sandbox, zero autonomy outside it.
- **AWS — safe resource IDs:** go further and list specific instance IDs, bucket names, or cluster ARNs in `.aws.safe-resources`; the rule checks whether every resource argument in the command is on that list. Claude can operate freely on the resources it created for this task and nothing else.

The possibilities scale with the task. For a focused refactoring session you might allow all `git` operations on a single branch. For a data pipeline run you might allow `aws s3` reads from one specific bucket. The config file is project-local and git-tracked, so the scope of Claude's autonomy is explicit, reviewable, and easy to tighten or widen per task.

**Filename prefix conventions:**
- `0-*` — Unwrappers / preprocessors (run first)
- `1-*` — List-based matching
- `2-*` — Command-specific checkers (run last; multiple checkers sort alphabetically)

Every rule file must have a `*.test.sh` counterpart with at least one positive (`allow`) and one negative (`defer`) test.

## The TUI (`./summary.py`)

`summary.py` is an interactive terminal dashboard for managing and understanding your rules. Run it from the project directory:

```bash
./summary.py
```

**What you see:**
- A scrollable list of all loaded rule files, each with its verdict counts (allow/deny/ask entries) and a one-line summary generated by Claude.
- A shadow analysis pane (`s`) that detects when an earlier rule always matches a command before a later rule can — flagging unreachable rules.
- A recommendations pane (`p`) that analyzes frequently-deferred commands and suggests new rules to add.
- An **ENABLED / DISABLED** badge in the header. Press `t` to toggle: when disabled, the hook exits silently and Claude Code falls back to its built-in prompts. Useful when you want to temporarily bypass all rules without unregistering the hook.

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

> git -C /some/repo status
  ✓ allow  (0-strip-flags.sh → recurse → 1-lists.sh)
```

The eval pane shows which rule fired and scrolls the rule list to highlight it — a fast way to understand why a command was allowed or blocked and to verify changes before committing them.
