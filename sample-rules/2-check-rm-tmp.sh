#!/usr/bin/env bash
# Special case: rm / rmdir / truncate targeting only safe paths (/tmp/ or ~/.claude/).
# rm -rf is already in the DENY list and will be caught before this rule.

read -ra TOKENS <<< "$COMMAND"
verb="${TOKENS[0]}"
[[ "$verb" == "rm" || "$verb" == "rmdir" || "$verb" == "truncate" ]] || { echo defer; exit 0; }

# Reject rm with recursive flags early (extra safety on top of DENY list)
if [[ "$verb" == "rm" ]]; then
  for tok in "${TOKENS[@]:1}"; do
    [[ "$tok" == -* ]] || break
    [[ "$tok" == *r* || "$tok" == *R* ]] && { echo defer; exit 0; }
  done
fi

is_safe_path() {
  local p="$1"
  [[ "$p" == /tmp/* ]] && return 0
  [[ "$p" == "$HOME"/.claude/* ]] && return 0   # expanded home path
  [[ "$p" == "~/.claude/"* ]] && return 0        # literal ~ as written in commands
  return 1
}

has_path=false
skip_next=false

for tok in "${TOKENS[@]:1}"; do
  if $skip_next; then skip_next=false; continue; fi

  # truncate's -s/--size flag consumes the next token (the size value)
  if [[ "$tok" == "-s" || "$tok" == "--size" ]]; then
    skip_next=true; continue
  fi

  [[ "$tok" == -* ]] && continue   # skip other flags

  has_path=true
  if ! is_safe_path "$tok"; then
    echo defer; exit 0   # path outside safe dirs → unsafe
  fi
done

# Must have at least one path argument
$has_path && echo allow || echo defer
