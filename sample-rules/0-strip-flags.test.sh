# Tests for 0-strip-flags.sh
# After stripping, recurse: re-runs the full pipeline, so expected verdicts
# reflect what downstream rules (1-lists.sh, 2-rm-checker.sh, etc.) produce.

run_test "git -C path log → allow"           'git -C /some/repo log'               "allow"
run_test "git -C path status → allow"        'git -C /some/repo status'            "allow"
run_test "git -C path push --force → deny"   'git -C /some/repo push --force'      "deny"
run_test "git --prefix path status → allow"  'git --prefix /some/repo status'      "allow"
run_test "git -C= form → allow"              'git -C=/some/repo log'               "allow"
run_test "plain git log → allow (no strip)"  'git log --oneline'                   "allow"
run_test "non-git command → defer"           'make -C /some/dir build'             "defer"
