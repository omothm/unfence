#!/usr/bin/env bash
# auto-created
# Reads COMMAND env var; outputs "skip" or "proceed".
#
# "skip"    = base command is unsafe or only conditionally safe in some
#             invocations — do not write a blanket allow rule.
# "proceed" = base command passes the static check; Claude applies further
#             judgment before writing a rule.
#
# Called by the sync-permissions hook (Step 2b) to gate rule promotion.

BASE="${COMMAND%% *}"

# Commands that are unsafe or only conditionally safe in at least one
# common invocation form. A blanket allow rule for any of these would
# be over-broad even when the user approved one specific invocation.
SKIP=(
  "osascript"   # 'do shell script' → arbitrary shell execution
  "security"    # macOS keychain: can dump/modify credentials
  "curl"        # network mutations (POST, DELETE, etc.)
  "wget"        # same
  "ssh"         # opens a remote shell
  "scp"         # remote file transfer, overwrite risk
  "rsync"       # local/remote overwrite
  "sudo"        # privilege escalation
  "aws"         # destructive API operations (delete-*, terminate-*, etc.)
  "gcloud"      # same
  "az"          # same
  "terraform"   # infrastructure mutations
  "docker"      # can run privileged containers, bind-mount host paths
  "kubectl"     # cluster-wide destructive operations
  "npm"         # installs packages, runs arbitrary lifecycle scripts
  "npx"         # executes arbitrary remote packages
  "brew"        # installs/removes system packages
  "pip"         # installs packages
  "pip3"        # installs packages
)

for cmd in "${SKIP[@]}"; do
  [[ "$BASE" == "$cmd" ]] && echo "skip" && exit 0
done

echo "proceed"
