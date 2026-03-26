#!/bin/bash
# Checker rule: rm — deny recursive+forced delete regardless of flag order/style.
#
# Handles all flag combinations by looking for any recursive flag AND any force
# flag anywhere in the argument list. This is the authoritative rm deny rule —
# Don't add an "rm -rf" entry to 1-lists.sh — that only matches the exact
# combined token and would shadow this checker for the most common case.
#
#   rm -r -f    (flags split)
#   rm -fr      (flags reversed)
#   rm -R -f    (uppercase -R)
#   rm --recursive --force  (long flags)
#   rm -rRf     (mixed combined)

read -ra TOKENS <<< "$COMMAND"
[[ "${TOKENS[0]}" != "rm" ]] && echo defer && exit 0

has_recursive=false
has_force=false

for tok in "${TOKENS[@]:1}"; do
  case "$tok" in
    --recursive) has_recursive=true ;;
    --force)     has_force=true ;;
    -*)
      flags="${tok#-}"
      [[ "$flags" == *[rR]* ]] && has_recursive=true
      [[ "$flags" == *f* ]]    && has_force=true
      ;;
  esac
  $has_recursive && $has_force && echo deny && exit 0
done

echo defer
