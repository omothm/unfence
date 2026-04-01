---
name: promote-generic-rules
description: Scan local rules/ against sample-rules/ and promote generic improvements to sample-rules/, updating existing tests so they pass.
user-invocable: true
---

# Promote Generic Rules

You are promoting generic improvements from the local `rules/` directory into the
shared `sample-rules/` directory. The goal is to keep the sample rules up to date
with battle-tested patterns from the production ruleset — **without** leaking
project-specific logic.

All paths are relative to `~/.claude/unfence/` unless otherwise specified.

## What "generic" means

A change qualifies as generic if it:
- Applies to a widely-used command family (curl, gh api, rm, xargs, git, aws, docker-compose, etc.)
- Improves correctness or safety for **any** user of the rule, not just this project
- Does not depend on project-specific config (`PROJECT_CONFIG`, `safe-orgs`, `safe-projects`, etc.)
- Is not specific to a single org, tool stack, or workflow (e.g. Salesforce CLI, gh project item-add)

A change is **not** generic if it:
- References project-specific allow-lists or config keys
- Adds commands that only make sense in this specific repo's context
- Introduces a new rule file with no counterpart in `sample-rules/`
  (new rule files are out of scope — only modifications to existing ones)

## Steps

### 1. Read both rule sets

List all `*.sh` files (non-test) in each directory:
```bash
ls rules/*.sh | grep -v '\.test\.sh'
ls sample-rules/*.sh | grep -v '\.test\.sh'
```

Read every file in both directories (including their `*.test.sh` counterparts).

### 2. Identify corresponding pairs

Find rule files that exist **in both** directories with the same filename (e.g.
`0-unwrap.sh`, `1-lists.sh`, `2-check-gh-api.sh`). These are the candidates.
Rules that exist only in `rules/` (no counterpart in `sample-rules/`) are
out of scope — do not create new sample-rule files.

### 3. Diff each pair and classify changes

For each corresponding pair, compare the local version to the sample version and
enumerate every behavioral difference (added patterns, changed verdicts, new
command families handled, etc.).

For each difference, decide: **generic** or **project-specific**?

Use the criteria above. When in doubt, err toward **not promoting** — it is
better to miss a generic improvement than to pollute the sample rules with
project-specific logic.

### 4. Apply generic improvements to sample-rules/

For each change you classified as generic:
- Edit the appropriate `sample-rules/<file>.sh` with the minimal diff that
  captures the improvement.
- Preserve the sample-rules file's existing structure, comments, and ordering.
- Do not reformat or rename variables.
- Do not copy wholesale — transplant only the generic delta.

### 5. Update corresponding sample-rules tests

After each rule change, update `sample-rules/<file>.test.sh`:
- **Do not add new test files.** Only edit existing test files.
- For each behavioral change you applied, review whether existing tests still
  correctly reflect the updated behavior.
  - If a test was written with an expected verdict that is now wrong (e.g. a
    previously-`defer` mutation that now correctly returns `ask`), update the
    expected value.
  - If a new pattern was added (e.g. a new command family now handled), add a
    minimal test case — a positive (matching) and a negative (non-matching) — to
    the existing test file, grouped near the related existing tests.
- Never remove passing tests.
- Follow the existing `run_test` call format exactly.

### 6. Run the sample test suite

```bash
RULES_SUITE=sample-rules bash ~/.claude/unfence/run-tests.sh
```

- If all tests pass → proceed.
- If any test fails → diagnose, fix the rule or test, re-run. Do not proceed
  until the suite is green.

Do **not** run the main `run-tests.sh` (without `RULES_SUITE=sample-rules`) —
local rule tests are not your concern here.

### 7. Report what was promoted

Print a concise summary:
- Which rule files were changed and why each change qualifies as generic.
- Which test files were updated and what was changed (expected verdicts flipped,
  new cases added).
- Which differences were evaluated but skipped as project-specific, and why.

### 8. Commit and push

```bash
git add sample-rules/
git diff --cached --stat
git commit -m "..."
git push
```

Write a commit message in the imperative that names the rule files changed.
Example: `feat(sample-rules): promote ask-for-mutations to curl and gh-api checkers`

Follow the Commit and Push Policy in CLAUDE.md: stash any unrelated uncommitted
changes before committing, then pop after.
