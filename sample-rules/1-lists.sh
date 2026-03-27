#!/bin/bash
# List rule: DENY / ASK / ALLOW prefix matching with specificity.
#
# Rules are matched by token prefix. The most-specific match (most tokens) wins,
# with DENY > ASK > ALLOW on ties. This lets you block "git push --force" while
# allowing "git push" — more-specific rules always beat less-specific ones.
#
# Flags prefixed with - are treated as required flags (must be present anywhere
# in the command) rather than positional words, so "git push --force" in DENY
# blocks "git push origin main --force" even though --force isn't the 3rd token.

DENY=(
  "git push --force"   # irreversible; --force can appear anywhere in the command
  "git push -f"
  "git reset --hard"
  "git clean -f"
  "chmod 777"
  "rm -rf"
)

ASK=(
  "git push"           # prompt before any push (less specific than deny rules above)
  "git commit"
  "git rebase"
  "git reset"
  "git clean"
  "git branch -D"
  "gh pr create"
  "gh pr merge"
  "gh pr close"
  "gh pr comment"
  "gh pr edit"
  "gh pr review"
  "gh issue comment"
  "gh issue edit"
  "gh issue close"
  "gh release create"
)

ALLOW=(
  # Shell basics
  "echo"
  "printf"
  "cat"
  "head"
  "tail"
  "grep"
  "awk"
  "sed"
  "tr"
  "cut"
  "sort"
  "wc"
  "diff"
  "jq"
  "find"
  "ls"
  "cd"
  "mkdir"
  "cp"
  "mv"
  "date"
  "sleep"
  "env"
  "which"
  "read"
  "test"
  "true"
  "false"
  "set"
  "export"

  # Git (read-only / safe write)
  "git status"
  "git diff"
  "git log"
  "git show"
  "git branch"
  "git fetch"
  "git pull"
  "git add"
  "git checkout"
  "git stash"
  "git stash list"
  "git stash show"
  "git remote"
  "git config"
  "git rev-parse"
  "git ls-files"
  "git blame"
  "git describe"
  "git shortlog"
  "git merge-base"
  "git cherry-pick"
  "git tag"

  # GitHub CLI (read-only)
  "gh pr list"
  "gh pr view"
  "gh pr diff"
  "gh pr ready"
  "gh issue list"
  "gh issue view"
  "gh repo list"
  "gh repo view"
  "gh release list"
  "gh release view"
  "gh run list"
  "gh run view"
  "gh run watch"
  "gh auth status"
  "gh search"
  "gh workflow list"
  "gh workflow view"
)

# ── Matching ─────────────────────────────────────────────────────────────────

read -ra CMD_TOKENS <<< "$COMMAND"
[[ ${#CMD_TOKENS[@]} -eq 0 ]] && echo allow && exit 0

# A rule matches if: its positional words appear in order at the start of the
# command (skipping flags), and every required flag appears somewhere.
matches_rule() {
  local rule="$1"; shift; local cmd=("$@")
  local pos=() flags=()
  for t in $rule; do [[ "$t" == -* ]] && flags+=("$t") || pos+=("$t"); done

  local pi=0
  for t in "${cmd[@]}"; do
    [[ $pi -ge ${#pos[@]} ]] && break
    [[ "$t" == -* ]] && continue
    if [[ "$t" == "${pos[$pi]}" ]]; then (( pi++ )) || true
    else return 1
    fi
  done
  [[ $pi -lt ${#pos[@]} ]] && return 1

  for f in "${flags[@]}"; do
    local found=0
    for t in "${cmd[@]}"; do [[ "$t" == "$f" ]] && found=1 && break; done
    (( found )) || return 1
  done
  return 0
}
count_tokens() { echo $#; }

best="" best_n=0 best_p=0
for rule in "${DENY[@]}";  do
  matches_rule "$rule" "${CMD_TOKENS[@]}" || continue
  n=$(count_tokens $rule); (( n > best_n || (n == best_n && 3 > best_p) )) \
    && best="deny"  && best_n=$n && best_p=3
done
for rule in "${ASK[@]}";   do
  matches_rule "$rule" "${CMD_TOKENS[@]}" || continue
  n=$(count_tokens $rule); (( n > best_n || (n == best_n && 2 > best_p) )) \
    && best="ask"   && best_n=$n && best_p=2
done
for rule in "${ALLOW[@]}"; do
  matches_rule "$rule" "${CMD_TOKENS[@]}" || continue
  n=$(count_tokens $rule); (( n > best_n || (n == best_n && 1 > best_p) )) \
    && best="allow" && best_n=$n && best_p=1
done

[[ -z "$best" ]] && echo defer || echo "$best"
