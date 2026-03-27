---
name: sync-permissions
description: Translate new permissions.allow entries from settings.local.json into unfence rule files with tests, then clean up the settings file.
user-invocable: false
---

# Sync Permissions

You are syncing new Claude Code permission approvals ("don't ask again" entries) into the
unfence engine so they are auto-approved in the future.

## Key Files

| File | Purpose |
|---|---|
| `~/.claude/unfence/hooks/unfence.sh` | Permission engine — loads rule files, handles normalization & compound splitting |
| `~/.claude/unfence/run-tests.sh` | Test runner — sources `*.test.sh` from the rules directory |
| `~/.claude/unfence/rules/*.sh` | Individual rule files (sorted by filename for execution order) |
| `~/.claude/unfence/rules/*.test.sh` | Co-located test files for each rule |
| `.claude/settings.local.json` (CWD) | Project-local permissions to process |
| `~/.claude/settings.local.json` | Global permissions to process |

## How the Engine Works

- Rule files in `~/.claude/unfence/rules/` are loaded in filename-sorted order (e.g. `0-unwrap-xargs.sh` before `1-lists.sh` before `2-check-aws.sh`).
- Each rule receives `COMMAND` as an env var and outputs one of: `allow`, `deny`, `ask`, `defer`, or `recurse:<new_command>`.
- The engine runs rules in order until one returns a definitive verdict (`allow`/`deny`/`ask`). `defer` passes to the next rule. `recurse:<cmd>` restarts the pipeline with a new command.

## Steps

### 1. Find settings files with permissions

Check both locations:
- `.claude/settings.local.json` relative to CWD
- `~/.claude/settings.local.json`

Read each file with `jq`. Collect all entries under `.permissions.allow[]`.

- Entries starting with `Bash(`: extract the command string from inside `Bash(...)` — these need rules (handled in Steps 2–5).
- All other entries (e.g. `WebFetch(...)`, `Write(...)`, `Read(...)`): these are legitimate Claude Code permissions that should live in the **global** settings file. Handle them in Step 6b.

### 2. Check coverage

For each extracted command, determine if it is **already covered** by the existing rules:
- Read the rule files in `~/.claude/unfence/rules/`
- Consider both the list-based rules (`1-lists.sh`) and the special-case checkers (`2-check-*.sh`)
- If already covered → skip (no rule needed, but still clean up the entry)

### 3. Design the rule

For each **uncovered** command, read all existing rule files in `~/.claude/unfence/rules/` and pick the **best-matching** destination:

- Understand each rule's purpose, scope, and structure.
- Choose the rule where this command most naturally belongs — by command family, matching logic, or domain.
- If no existing rule is a good fit, create a new `2-check-<name>.sh`.
- **Never add to DENY or ASK** — these entries are approvals.
- **Avoid over-broad rules.** `python3` alone would allow any Python script; prefer path-based restrictions if that fits.

### 4. Add rule + tests

Edit the appropriate rule file, or create a new one:
- Place the new entry in the most appropriate location within the file.
- Add a short inline comment if the rule's intent is not obvious.
- If **creating a new rule file**, add `# auto-created` as the second line (after the shebang) to mark it as machine-generated.

Edit the corresponding `*.test.sh` file:
- Add at least two test cases per new rule:
  1. A **positive** case: a representative command that should `allow`.
  2. A **negative** case: a similar command outside the allowed pattern that should `defer`.
- Follow the existing `run_test` format and group with nearby related tests.

### 5. Run the test suite

```bash
bash ~/.claude/unfence/run-tests.sh
```

- If all tests pass → proceed to cleanup.
- If any test fails → diagnose, fix the rule/test, re-run. Do not clean up until green.

### 5b. Log each change

For each rule file you created or modified (not for skipped/already-covered entries), log the change:

```bash
python3 ~/.claude/unfence/summary.py --log SYNC <rule_filename.sh> "One sentence: what was added or changed"
```

Example:
```bash
python3 ~/.claude/unfence/summary.py --log SYNC 1-lists.sh "Added curl https://example.com to ALLOW list"
python3 ~/.claude/unfence/summary.py --log SYNC 2-check-gh-api.sh "Created rule: allow gh api GET requests"
```

Run this for each rule touched, after tests pass.

### 6. Clean up settings.local.json

#### 6a. Remove Bash entries

For each processed settings file, remove all `Bash(...)` entries from `permissions.allow`
(both the ones you added rules for and any that were already covered — they are now
handled by the unfence hook and must not remain in settings).

#### 6b. Promote non-Bash entries to global

Any non-`Bash` entries (e.g. `WebFetch(...)`) found in the **project-local**
`.claude/settings.local.json` should be **moved** to `~/.claude/settings.local.json`
so they apply globally and don't sit in a project-specific file.

- Merge them into `~/.claude/settings.local.json` under `.permissions.allow` (create the file/key if absent).
- Then remove them from the project-local file.
- If the entry already exists in the global file, skip the duplicate.

Non-Bash entries already in `~/.claude/settings.local.json` are left untouched.

#### 6c. Prune empty structures

After the above changes, for each modified settings file:
- If `permissions.allow` is now empty, remove the `permissions` key entirely.
- If the file is now `{}` (or has no remaining keys), delete the file.

Use `jq` for all JSON manipulation (per global rules — never use python for JSON).

Example — remove empty `permissions` key:
```bash
jq 'if (.permissions.allow | length) == 0 then del(.permissions) else . end' file.json
```
