#!/usr/bin/env bash
# Normalize absolute-path commands to their bare names.
#
# When agents invoke tools via full paths (e.g. /usr/bin/jq instead of jq),
# ALLOW/DENY/ASK rules that match the bare command name would miss them.
# This rule strips well-known system binary directory prefixes and recurses,
# so the full pipeline evaluates the normalized bare name.
#
# Only standard system binary directories are matched. Custom or unknown paths
# are left alone (defer) — we never silently rename arbitrary executables.

read -ra TOKENS <<< "$COMMAND"
[[ ${#TOKENS[@]} -eq 0 ]] && echo defer && exit 0

cmd0="${TOKENS[0]}"

# Only process absolute paths
[[ "$cmd0" != /* ]] && echo defer && exit 0

# Match known system binary directories
case "$cmd0" in
  /usr/bin/*          \
  | /usr/local/bin/*  \
  | /bin/*            \
  | /sbin/*           \
  | /usr/sbin/*       \
  | /usr/local/sbin/* \
  | /opt/homebrew/bin/*  \
  | /opt/homebrew/sbin/* )
    bare="$(basename "$cmd0")"
    rest=("${TOKENS[@]:1}")
    if [[ ${#rest[@]} -gt 0 ]]; then
      echo "recurse:$bare ${rest[*]}"
    else
      echo "recurse:$bare"
    fi
    exit 0
    ;;
esac

echo defer
