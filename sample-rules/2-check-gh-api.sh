#!/bin/bash
# Special case: gh api read-only GET requests.
# Blocks explicit non-GET methods and mutation flags (-f, --raw-field, --input).

read -ra TOKENS <<< "$COMMAND"
[[ "${TOKENS[0]}" == "gh" && "${TOKENS[1]}" == "api" ]] || { echo defer; exit 0; }

# Special case: gh api graphql — always POST but read/write is determined by
# the query body. Allow if no `mutation` keyword is present.
if [[ "${TOKENS[2]}" == "graphql" ]]; then
  if echo "$COMMAND" | grep -qw "mutation"; then
    echo ask; exit 0
  fi
  echo allow; exit 0
fi

i=0
while (( i < ${#TOKENS[@]} )); do
  tok="${TOKENS[$i]}"

  # Explicit method override
  if [[ "$tok" == "-X" || "$tok" == "--method" ]]; then
    method="${TOKENS[$((i+1))]}"
    method="${method^^}"
    if [[ "$method" != "GET" ]]; then
      echo ask; exit 0
    fi
    (( i += 2 )); continue
  fi

  # Mutation flags
  case "$tok" in
    -f|--raw-field|--input) echo ask; exit 0 ;;
  esac

  (( i++ ))
done

echo allow
