# Tests for 0-unwrap.sh
# The recurse: verdict re-runs the pipeline, so the final result depends on
# what other rules are loaded. These tests assume 1-lists.sh (git status →
# allow) and 2-rm-checker.sh (rm -rf → deny) are also present.

run_test "xargs git status → allow (via recurse)"          "xargs git status"                  "allow"
run_test "xargs -I{} git show → allow"                     "xargs -I{} git show"               "allow"
run_test "xargs rm -rf → deny (via recurse)"               "xargs rm -rf /tmp"                 "deny"
run_test "non-xargs command → defer"                       "make build"                        "defer"

run_test "eval double-quoted rm -rf → deny"                'eval "rm -rf ./some-dir"'          "deny"
run_test "eval single-quoted rm -rf → deny"                "eval 'rm -rf ./some-dir'"          "deny"
run_test "eval unquoted rm -rf → deny"                     "eval rm -rf ./some-dir"            "deny"
run_test "eval safe command → allow"                       'eval "git status"'                 "allow"

run_test "bash -c rm -rf → deny"                           'bash -c "rm -rf ./some-dir"'       "deny"
run_test "sh -c rm -rf → deny"                             'sh -c "rm -rf ./some-dir"'         "deny"
run_test "zsh -c rm -rf → deny"                            'zsh -c "rm -rf ./some-dir"'        "deny"
run_test "bash --norc -c rm -rf → deny"                    'bash --norc -c "rm -rf ./some-dir"' "deny"
run_test "bash -c safe command → allow"                    'bash -c "git status"'              "allow"

run_test "timeout safe command → allow"                    "timeout 30 git status"             "allow"
run_test "timeout rm -rf → deny"                           "timeout 30 rm -rf /tmp/foo"        "deny"
run_test "timeout with flags safe command → allow"         "timeout -k 5 30 git log"           "allow"
run_test "time safe command → allow"                       "time git status"                   "allow"
run_test "time rm -rf → deny"                              "time rm -rf /tmp/foo"              "deny"
