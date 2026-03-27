#!/bin/bash
# Special case: any command run solely to query its version or usage.
# Allows if --version or --help appears anywhere in the arguments.

read -ra TOKENS <<< "$COMMAND"
[[ ${#TOKENS[@]} -ge 1 ]] || { echo defer; exit 0; }

for tok in "${TOKENS[@]:1}"; do
  [[ "$tok" == "--version" || "$tok" == "--help" ]] && echo allow && exit 0
done

echo defer
