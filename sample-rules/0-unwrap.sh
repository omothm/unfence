#!/bin/bash
# Unwrapper rule: xargs
#
# The engine sees "xargs git status" as a single command and cannot classify it.
# Returning recurse:<inner_cmd> re-runs the full pipeline on "git status" instead,
# so every other rule you write automatically extends to xargs invocations too.
#
# This is the "0-*" (preprocessing) layer — strip the wrapper, recurse.

read -ra TOKENS <<< "$COMMAND"
[[ "${TOKENS[0]}" != "xargs" ]] && echo defer && exit 0

# Skip xargs own flags, including those that consume the next token as a value
i=1
while (( i < ${#TOKENS[@]} )); do
  tok="${TOKENS[$i]}"
  [[ "$tok" == "--" ]] && (( i++ )) && break    # -- ends xargs options
  [[ "$tok" != -* ]] && break                   # first non-flag = wrapped command
  case "${tok:0:2}" in
    -I|-n|-P|-L|-J|-s|-E|-R)
      (( ${#tok} > 2 )) && (( i++ )) || (( i += 2 )); continue ;;
  esac
  (( i++ ))
done

(( i >= ${#TOKENS[@]} )) && echo "recurse:echo" || echo "recurse:${TOKENS[*]:$i}"
