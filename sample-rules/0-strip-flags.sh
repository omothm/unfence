#!/usr/bin/env bash
# Transparent-flag stripping rule.
#
# Some flags modify execution context (e.g. which directory to run in) without
# changing the semantic identity of the command. Stripping them before
# classification means downstream rules see a clean "git log" instead of
# "git -C /some/path log" and can match normally.
#
# Key constraint: only strip flags you *know* consume a value token for a
# *specific* tool. Global stripping across all commands would silently corrupt
# flags that are meaningful for other tools. Boolean flags are never
# "transparent" in this sense — they take no value.
#
# Returning recurse:<stripped> re-runs the full pipeline on the clean command,
# so all downstream rules (lists and checkers) benefit automatically.
#
# Extend this file with additional tools and their context-setting flags as
# needed. The pattern is always the same: match cmd0, walk tokens, skip known
# flag-value pairs, recurse if anything changed.

read -ra TOKENS <<< "$COMMAND"
[[ ${#TOKENS[@]} -eq 0 ]] && echo defer && exit 0

cmd0="${TOKENS[0]}"
stripped=("$cmd0")
changed=false

# git -C <path>  and  git --prefix <prefix>
if [[ "$cmd0" == "git" ]]; then
  i=1
  while (( i < ${#TOKENS[@]} )); do
    tok="${TOKENS[$i]}"
    case "$tok" in
      -C|--prefix)
        # flag followed by a separate value token — consume both
        (( i + 1 < ${#TOKENS[@]} )) && (( i += 2 )) || (( i++ ))
        changed=true ;;
      -C=*|--prefix=*)
        # flag=value in a single token — consume it
        (( i++ ))
        changed=true ;;
      *) stripped+=("$tok"); (( i++ )) ;;
    esac
  done
fi

# Add more tools here following the same pattern, e.g.:
#   make -C <dir> / --directory <dir>

$changed && echo "recurse:${stripped[*]}" || echo defer
