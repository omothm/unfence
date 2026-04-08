#!/usr/bin/env bash
# Special case: docker-compose (hyphenated) with allowed subcommands.
# docker compose (space) is already covered by the ALLOW list in 1-lists.sh.

read -ra TOKENS <<< "$COMMAND"
[[ "${TOKENS[0]}" != "docker-compose" ]] && echo defer && exit 0

allowed_subs=(ps logs config up down build pull exec)

# docker-compose flags that take a value argument
flags_with_arg=(-f --file -p --project-name --project-directory --env-file --profile)

i=1
while (( i < ${#TOKENS[@]} )); do
  tok="${TOKENS[$i]}"

  # Skip known flag-value pairs
  skip=false
  for df in "${flags_with_arg[@]}"; do
    if [[ "$tok" == "$df" ]];    then skip=true; (( i += 2 )); break; fi
    if [[ "$tok" == "$df="* ]];  then skip=true; (( i++ ));    break; fi
  done
  $skip && continue

  # Skip other flags
  if [[ "$tok" == -* ]]; then (( i++ )); continue; fi

  # This is the subcommand
  for sub in "${allowed_subs[@]}"; do
    [[ "$tok" == "$sub" ]] && echo allow && exit 0
  done
  echo defer; exit 0
done

echo defer
