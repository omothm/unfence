run_test "rm -f /tmp files" \
  'rm -f /tmp/foo.json /tmp/bar.json' "allow"
run_test "rm /tmp file (no flags)" \
  'rm /tmp/foo.json' "allow"
run_test "truncate -s 0 /tmp file" \
  'truncate -s 0 /tmp/sync-permissions.log' "allow"
run_test "truncate /tmp (no flags)" \
  'truncate /tmp/foo.txt' "allow"
run_test "rm -f mixed paths → defer" \
  'rm -f /tmp/foo.json /home/user/important.txt' "defer"
run_test "rm -f non-tmp path → defer" \
  'rm -f /var/data/file.txt' "defer"
run_test "truncate non-/tmp path → defer" \
  'truncate -s 0 /var/log/syslog' "defer"
run_test "rm -rf /tmp → still deny (DENY list wins)" \
  'rm -rf /tmp/foo' "deny"
run_test "rm ~/.claude/ file" \
  'rm ~/.claude/unfence/.claude/agents/summary.md' "allow"
run_test "rmdir ~/.claude/ dir" \
  'rmdir ~/.claude/unfence/.claude/agents' "allow"
run_test "rm ~/.claude/ file with -f flag" \
  'rm -f ~/.claude/foo.txt' "allow"
run_test "rmdir non-claude path → defer" \
  'rmdir /Users/omothm/Documents/foo' "defer"
run_test "rm ~/.claude/ recursive → defer (blocked before DENY)" \
  'rm -r ~/.claude/foo' "defer"
