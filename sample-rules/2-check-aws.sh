#!/bin/bash
# Special case: AWS read-only commands.
# Allows any aws command that contains a read-only verb token.

read -ra TOKENS <<< "$COMMAND"
[[ "${TOKENS[0]}" != "aws" ]] && echo defer && exit 0

for tok in "${TOKENS[@]}"; do
  case "$tok" in
    describe-*|list-*|get-*|filter-*|assume-role) echo allow && exit 0 ;;
  esac
done

echo defer
