run_test "rm --version → allow" \
  '/bin/rm --version 2>&1 || true' "allow"
run_test "python3 --version" \
  'python3 --version' "allow"
run_test "unknown-tool --version" \
  'sometool --version' "allow"
run_test "ffprobe --version" \
  'ffprobe --version' "allow"
run_test "claude --help" \
  'claude --help' "allow"
run_test "unknown-tool --help" \
  'sometool --help' "allow"
