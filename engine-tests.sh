# Tests for engine-level normalization (behaviors in unfence.sh, not in any rule file).
# Only rule-independent cases belong here so this file can be committed to the repo.
# Tests that depend on user-defined ALLOW/DENY lists live in the appropriate *.test.sh files.

# --- inline comment stripping ---
# A ; followed by # comment should not produce a deferred part — the comment is stripped.
# Both emitted parts are empty (whitespace-only) → engine allows unconditionally.
run_test "semicolon then inline comment → allow"    '; # this is a comment'                    "allow"
run_test "inline comment at start of command → allow" '# standalone comment'                   "allow"
run_test "two semis then inline comment → allow"    '; ; # trailing comment'                   "allow"
run_test "inline comment with preceding tab → allow" $';\t# tabbed comment'                    "allow"

# --- brace group normalization ---
# split_commands splits "{ cmd; } > file" on ; yielding "{ cmd" and "} > file".
# The engine strips the leading { (recursing on the remainder) and allows the bare }.
# Lone { and } are unconditional engine allows — no rule involvement.
run_test "lone { → allow"           '{'                   "allow"
run_test "bare } → allow"           '}'                   "allow"
run_test "} with redirect → allow"  '} > /tmp/out.xml'    "allow"
