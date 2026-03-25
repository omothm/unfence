# Tests for 0-unwrap.sh
# The recurse: verdict re-runs the pipeline, so the final result depends on
# what other rules are loaded. These tests assume a 1-lists.sh is also present
# that covers "git status" → allow and "rm -rf" → deny.

run_test "xargs git status → allow (via recurse)"  "xargs git status"     "allow"
run_test "xargs -I{} git show → allow"             "xargs -I{} git show"  "allow"
run_test "xargs rm -rf → deny (via recurse)"       "xargs rm -rf /tmp"    "deny"
run_test "non-xargs command → defer"               "git status"           "defer"
