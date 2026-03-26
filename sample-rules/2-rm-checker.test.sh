# Tests for 3-rm-checker.sh
# Verifies that all rm recursive+force flag combinations are denied,
# regardless of flag order, style, or casing.

run_test "rm -rf (combined flags)"                    "rm -rf /tmp/foo"        "deny"
run_test "rm -r -f (split flags)"                     "rm -r -f ./some-dir"    "deny"
run_test "rm -fr (reversed combined)"                 "rm -fr ./some-dir"      "deny"
run_test "rm -R -f (uppercase recursive)"             "rm -R -f ./some-dir"    "deny"
run_test "rm --recursive --force (long flags)"        "rm --recursive --force ./dir" "deny"
run_test "rm --force --recursive (long flags, reversed)" "rm --force --recursive ./dir" "deny"
run_test "rm -rRf (mixed)"                            "rm -rRf ./some-dir"     "deny"

run_test "rm -r only (no force) → defer"              "rm -r ./some-dir"       "defer"
run_test "rm -f only (no recursive) → defer"          "rm -f ./file"           "defer"
run_test "rm plain → defer"                           "rm ./file"              "defer"
run_test "non-rm command → defer"                     "make build"             "defer"
