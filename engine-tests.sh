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
# } is an engine-always-allow; with an inline comment after it the comment is stripped first.
run_test "} followed by inline comment → allow"     '} # comment after brace'                  "allow"

# --- hash is NOT a comment when inside quotes ---
# VAR=... is engine-always-allow regardless of rules.
# In split_commands the in_double / in_single guards prevent the # handler from firing.
run_test "hash in double-quoted assignment → allow"  'X="foo#bar"'                              "allow"
run_test "hash in single-quoted assignment → allow"  "X='foo#bar'"                              "allow"

# --- hash is NOT a comment when not preceded by whitespace ---
# The handler checks: last char of current must be whitespace (or current empty).
# ${#var}: { is before #.  foo#bar: letter is before #.  Both are rule-independent VAR=.
run_test "hash in parameter expansion → allow"       'X=${#var}'                                "allow"
run_test "hash immediately after word chars → allow" 'X=foo#bar'                                "allow"

# --- hash inside $() is NOT a comment (paren_depth > 0 guard) ---
# OUTER=$(...) strips the wrapper; inner becomes Y=${#z} — another VAR= — engine allows.
# If paren_depth guard were absent, the # inside $() would be treated as a comment,
# the ) would never close, and the subshell token would be malformed.
run_test "hash inside subshell (paren guard) → allow" 'OUTER=$(Y=${#z})'                       "allow"

# --- hash inside [[ ]] is NOT a comment (double_bracket_depth > 0 guard) ---
# [[ ... ]] commands always defer in the engine-test fixture (no rule handles them), so
# there is no rule-independent way to distinguish correct vs broken depth-guard behavior
# purely from the overall verdict.  The guard is verified by the rule-suite tests that
# exercise [[ ]] patterns where the verdict is known.  The code path is:
#   if (( double_bracket_depth == 0 && paren_depth == 0 )); then   ← guards the # handler
# ensuring # inside [[ ... ]] is never treated as a comment.

# --- brace group normalization ---
# split_commands splits "{ cmd; } > file" on ; yielding "{ cmd" and "} > file".
# The engine strips the leading { (recursing on the remainder) and allows the bare }.
# Lone { and } are unconditional engine allows — no rule involvement.
run_test "lone { → allow"           '{'                   "allow"
run_test "bare } → allow"           '}'                   "allow"
run_test "} with redirect → allow"  '} > /tmp/out.xml'    "allow"

# --- subshell group normalization ---
# (cmd ...) and (cmd ...) & are shell syntax, not a command.
# The engine strips the ( ) wrapper (and optional &) so rules see the inner command.
# Requires ) to be a separate token (space before it).
run_test "empty subshell ( ) → allow"              '( )'                                         "allow"
run_test "(echo hello ) → allow"                   '(echo hello )'                               "allow"
run_test "( echo hello ) → allow"                  '( echo hello )'                              "allow"
run_test "(echo hello ) & → allow"                 '(echo hello ) &'                             "allow"
run_test "(rm -rf / ) & → deny"                    '(rm -rf / ) &'                               "deny"
run_test "(unknowncmd ) & → defer"                 '(unknowncmd ) &'                             "defer"
# ) fused with last arg (no space) is NOT stripped — engine defers to rules as-is
run_test "(unknowncmd) no space before ) → defer"  '(unknowncmd)'                                "defer"

# --- array element assignments ---
# VAR[subscript]=value: subscript contains letters, numbers, strings, or paths.
# These are pure in-shell operations — no subprocess → always allow.
run_test "simple array element assignment → allow"      'arr[0]="value"'                           "allow"
run_test "array element with path key → allow"          'sessions["/foo/bar.jsonl"]="slug"'        "allow"
run_test "array element with var subscript → allow"     'arr[$key]="value"'                        "allow"
run_test "array element arithmetic value → allow"       'arr[0]=$(( 1 + 2 ))'                      "allow"
# Negative: array element with $(cmd) value — inner command must pass rules.
# In the engine-test fixture no rule handles 'dangerous', so it defers.
run_test "array element with subshell value → defers"   'arr[0]=$(dangerous)'                      "defer"

# --- deny:<message> passthrough ---
# Rules can return "deny:<message>" to attach a reason to the denial.
# The engine must surface the message in permissionDecisionReason.
# This test uses rm -rf which is in DENY in both rules/ and sample-rules/
# without a DENY_REASONS entry, so it verifies the fallback message path.
run_test_deny_reason "plain deny: fallback reason" \
  'rm -rf /'  'Command matches a DENY rule'
