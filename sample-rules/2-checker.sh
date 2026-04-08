#!/usr/bin/env bash
# Checker rule: curl — allow GET/HEAD, defer anything that sends data.
#
# A command-specific checker goes beyond prefix matching by inspecting flags
# and arguments. Here we parse curl's flags to distinguish read-only requests
# from mutations, allowing safe API lookups while deferring data uploads.
#
# The same pattern applies to any tool with a mix of safe and unsafe operations.

read -ra TOKENS <<< "$COMMAND"
[[ "${TOKENS[0]}" != "curl" ]] && echo defer && exit 0

i=0
while (( i < ${#TOKENS[@]} )); do
  tok="${TOKENS[$i]}"

  # Explicit method: -X GET/HEAD is fine; anything else is not
  if [[ "$tok" == "-X" || "$tok" == "--request" ]]; then
    method="${TOKENS[$((i+1))]}"; method="${method^^}"
    [[ "$method" != "GET" && "$method" != "HEAD" ]] && echo defer && exit 0
    (( i += 2 )); continue
  fi

  # Any data or upload flag implies a write operation
  case "$tok" in
    -d|--data|--data-raw|--data-binary|--data-urlencode|\
    -F|--form|-T|--upload-file|\
    -d=*|--data=*|--data-raw=*|--data-binary=*|-F=*|--form=*|-T=*|--upload-file=*)
      echo defer; exit 0 ;;
  esac

  (( i++ ))
done

echo allow   # no mutating flags found; default method is GET
