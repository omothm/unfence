run_test "gh api GET (default)" \
  'gh api repos/org/repo/issues/123/comments --jq ".[]"' "allow"
run_test "gh api -X GET" \
  'gh api -X GET repos/org/repo/pulls' "allow"
run_test "gh api -X POST → ask" \
  'gh api -X POST repos/org/repo/issues/123/comments -f body="hello"' "ask"
run_test "gh api --method PATCH → ask" \
  'gh api --method PATCH repos/org/repo/issues/123 -f state=closed' "ask"
run_test "gh api with -f (mutation) → ask" \
  'gh api repos/org/repo/issues -f title="new"' "ask"
run_test "gh api graphql read query → allow" \
  'gh api graphql -f query="{ node(id: \"X\") { ... on Issue { title } } }" --jq .data' "allow"
run_test "gh api graphql mutation → ask" \
  'gh api graphql -f query="mutation { updateIssue(input: {}) { issue { id } } }"' "ask"
