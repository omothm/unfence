---
name: unfence:allow-safe
description: >
  Analyze a command and add its safe variations to the unfence rules. ALWAYS use
  this skill when asked to "allow <cmd>", "add <cmd> to rules", "teach unfence about
  <cmd>", "make <cmd> auto-approved", or when about to add commands to allow/ask/deny
  lists in rule files.
argument-hint: <cmd>
user-invocable: true
---

# unfence:allow-safe

You are adding safe (and, where necessary, unsafe) variations of `$ARGUMENTS` to the
unfence rule files. All paths are relative to `~/.claude/unfence/` unless otherwise
specified.

## 1. Read the existing rules

Read every non-test rule file in `rules/` (sorted by name) so you understand what is
already covered:

```bash
ls rules/*.sh | grep -v '\.test\.sh' | sort
```

Read each file. Pay special attention to:
- Which rule families and commands already exist
- What patterns are used (prefix lists, flag checks, regex)
- What the DENY / ASK / ALLOW arrays contain (if using `1-lists.sh` conventions)

## 2. Classify the command

Research `$ARGUMENTS` and classify every invocation form into one of three buckets:

| Bucket | Meaning | Target list |
|--------|---------|-------------|
| **Always safe** | Read-only or fully reversible, no side effects on shared state | ALLOW |
| **Conditionally safe** | Safe only with specific subcommands, flags, or absence of flags | ALLOW (specific entry) |
| **Unsafe** | Mutates shared state, destroys data, sends network requests with side effects | ASK or DENY |

When classifying, consider:
- **Read-only**: does it only read or display data?
- **Scope**: local-only vs. affects remote systems, other users, or persistent shared state?
- **Reversibility**: can the effect be easily undone?
- **Blast radius**: how bad is the worst-case outcome?

### Classification heuristics by form

- `<cmd>` alone (no subcommand) → classify by what the bare command does
- `<cmd> <sub>` → classify each subcommand independently
- `<cmd> --flag` → a flag that restricts to read-only (e.g. `--dry-run`, `--list`,
  `--show`, `--status`) shifts toward ALLOW; a flag that amplifies impact shifts toward
  ASK/DENY
- `<cmd> <sub> --flag` → combine both

**If `<cmd>` has a base that is unsafe but safe subcommands exist**, you must add both:
the safe subcommands to ALLOW (specific prefixes) and the base command to ASK (so
unrecognized invocations still prompt rather than defer). Specificity in `1-lists.sh`
means longer/more-specific entries win over shorter ones — a `DENY`/`ASK` entry for
`<cmd>` will be beaten by a longer `ALLOW` entry for `<cmd> <safe-sub>`.

## 3. Choose the right rule file

Do not hardcode assumptions about rule file names — read the actual files first. Then:

1. **If a rule file already handles `$ARGUMENTS`** (e.g. a dedicated checker):
   - Prefer extending that file.
2. **If the command fits a list-matching pattern** (prefix matching is sufficient):
   - Add it to the appropriate array in the matching list rule (e.g. the DENY/ASK/ALLOW
     lists file).
3. **If the command requires flag or argument introspection** that prefix matching cannot
   capture:
   - Add it to an existing `2-*` checker if one covers the same domain, or create a new
     `2-check-<cmd>.sh` checker as a last resort.
4. **When creating a new `2-*` checker**, follow the transparent-flag-stripping and
   `recurse:` conventions documented in CLAUDE.md.

## 4. Draft the changes

Before writing, plan your edits:

- List every ALLOW entry you will add, with a one-line justification.
- List every ASK or DENY entry you will add, with a one-line justification.
- Note which rule file each entry goes into.
- If you are adding to both ALLOW and ASK (safe subcommands + unsafe base), explicitly
  confirm that the specificity logic will resolve correctly: the longer ALLOW prefix
  must beat the shorter ASK prefix on matching commands.

Show this plan as a short bullet list before making any edits.

## 5. Apply the changes

Edit the rule file(s). Follow the existing style:
- Group related entries with a comment if the file uses comment groupings.
- Keep entries alphabetically or logically ordered within their group.
- Do not reformat unrelated code.

## 6. Write / update tests

Every rule file change requires corresponding test changes in its `*.test.sh`:

- For each new ALLOW entry: add a positive test (`allow`) and at least one negative
  test that confirms a dangerous variant is NOT allowed (returns `ask`, `deny`, or
  `defer` as appropriate).
- For each new ASK/DENY entry: add a positive test and a negative test confirming a
  safe variant is not over-blocked.
- Follow the `run_test` / `run_test_with_config` format used in the existing test file.

## 7. Run the full test suite

```bash
bash ~/.claude/unfence/run-tests.sh
```

- All tests must pass before proceeding.
- If any test fails, diagnose and fix before continuing.

## 8. Show the updated rule summary

```bash
python3 -m py_compile summary.py && echo OK
./summary.py
```

Highlight (in your response) which entries were added and to which rule file.

## 9. Done

Rule files are git-ignored — no commit is needed. The changes take effect immediately
on disk. Report what was added and to which file(s).
