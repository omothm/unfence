#!/bin/bash
# Unwrapper rule: xargs
#
# The engine sees "xargs git status" as a single command and cannot classify it.
# Returning recurse:<inner_cmd> re-runs the full pipeline on "git status" instead,
# so every other rule you write automatically extends to xargs invocations too.
#
# This is the "0-*" (preprocessing) layer — strip the wrapper, recurse.

read -ra TOKENS <<< "$COMMAND"

# Unwrap eval: eval "cmd args" or eval cmd args
if [[ "${TOKENS[0]}" == "eval" ]]; then
  (( ${#TOKENS[@]} < 2 )) && echo defer && exit 0
  inner="${TOKENS[*]:1}"
  inner="${inner#\"}"; inner="${inner%\"}"   # strip double quotes
  inner="${inner#\'}"; inner="${inner%\'}"   # strip single quotes
  [[ -z "$inner" ]] && echo defer && exit 0
  echo "recurse:$inner"
  exit 0
fi

# Unwrap shell -c: bash/sh/zsh/dash -c "cmd args"
if [[ "${TOKENS[0]}" =~ ^(bash|sh|zsh|dash)$ ]]; then
  for (( i=1; i<${#TOKENS[@]}; i++ )); do
    if [[ "${TOKENS[$i]}" == "-c" ]]; then
      (( i+1 >= ${#TOKENS[@]} )) && echo defer && exit 0
      inner="${TOKENS[*]:$((i+1))}"
      inner="${inner#\"}"; inner="${inner%\"}"
      inner="${inner#\'}"; inner="${inner%\'}"
      [[ -z "$inner" ]] && echo defer && exit 0
      echo "recurse:$inner"
      exit 0
    fi
  done
  echo defer && exit 0
fi

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
