You are implementing accepted unfence rule recommendations autonomously. Do NOT ask for confirmation, approval, or review before making any edits — proceed immediately with all changes. These are bash command patterns that have been identified as safe to auto-approve.

Read the file at `.claude/cache/.accepted-recs.json` (relative to the unfence directory `~/.claude/unfence/`). It contains a JSON array of recommendations, each with:
- `pattern`: the command prefix pattern (e.g. "npm install")
- `examples`: actual commands seen in the log
- `count`: how many times it occurred
- `rationale`: why it was assessed as safe

For each recommendation:
1. Look at the existing rule files (*.sh, not *.test.sh) to find the best place to add the pattern
2. For simple command prefixes, add to the ALLOW array in `1-lists.sh`
3. For command families that already have a dedicated checker (e.g. `2-check-aws.sh`), add to the appropriate file
4. Add a corresponding test to the matching `*.test.sh` file
5. Run the full test suite: `bash ~/.claude/unfence/run-tests.sh`
6. Only if all tests pass, remove the implemented recommendation from `.claude/cache/.accepted-recs.json`
7. If tests fail, revert your changes and leave the recommendation in the file

Be conservative: if unsure about placement, prefer `1-lists.sh` ALLOW array with an entry that is as specific as possible (prefer "cmd subcommand" over just "cmd").

After processing all recommendations (whether successful or not), run `./summary.py` would normally auto-reload, but just ensure `.claude/cache/.accepted-recs.json` reflects the final state.
