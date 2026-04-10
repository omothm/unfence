#!/usr/bin/env bash
#
# Stop hook: detect new Bash permissions.allow entries in settings.local.json
# and spawn a claude session (with hooks disabled) to translate them into
# unfence rules (rule files under ~/.claude/unfence/rules/).
#
# Forks immediately so the hook never blocks session completion.
#

LOCKFILE="/tmp/sync-permissions.lock"
LOG="/tmp/sync-permissions.log"
CWD="$PWD"

_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DISABLED_FLAG="$_HOOK_DIR/../.claude/cache/.disabled"
[[ -f "$_DISABLED_FLAG" ]] && exit 0

(
  ts() { date '+%Y-%m-%d %H:%M:%S'; }

  # PID-based lock: skip if a sync session is already running
  if [[ -f "$LOCKFILE" ]]; then
    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null)
    if kill -0 "$LOCK_PID" 2>/dev/null; then
      echo "[$(ts)] SKIP  sync already running (pid $LOCK_PID)" >> "$LOG"
      exit 0
    fi
    rm -f "$LOCKFILE"
  fi

  # Trigger if: Bash(...) entries exist in either settings file, OR
  # non-Bash permissions.allow entries exist in the project-local file (need promoting).
  HAS_ENTRIES=false
  for SETTINGS in "$CWD/.claude/settings.local.json" "$HOME/.claude/settings.local.json"; do
    [[ ! -f "$SETTINGS" ]] && continue
    COUNT=$(jq '[.permissions.allow[]? | select(startswith("Bash("))] | length' "$SETTINGS" 2>/dev/null)
    if [[ "$COUNT" != "null" && "$COUNT" != "0" && -n "$COUNT" ]]; then
      HAS_ENTRIES=true
      break
    fi
  done

  if ! $HAS_ENTRIES; then
    LOCAL="$CWD/.claude/settings.local.json"
    if [[ -f "$LOCAL" ]]; then
      COUNT=$(jq '[.permissions.allow[]? | select(startswith("Bash(") | not)] | length' "$LOCAL" 2>/dev/null)
      if [[ "$COUNT" != "null" && "$COUNT" != "0" && -n "$COUNT" ]]; then
        HAS_ENTRIES=true
      fi
    fi
  fi

  if ! $HAS_ENTRIES; then
    echo "[$(ts)] SKIP  no promotable entries in any settings.local.json" >> "$LOG"
    exit 0
  fi

  echo $BASHPID > "$LOCKFILE"
  echo "[$(ts)] START cwd=$CWD" >> "$LOG"

  PROMPT_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../.claude/prompts/sync-permissions.md"
  PROMPT=$(cat "$PROMPT_FILE")

  # --setting-sources project,local: skips ~/.claude/settings.json so no hooks
  # are loaded in the spawned session — prevents cascade.
  # Unset CLAUDECODE so the child is not blocked as a nested session.
  unset CLAUDECODE
  claude --model claude-sonnet-4-6 \
    --setting-sources project,local \
    --dangerously-skip-permissions \
    -p "$PROMPT" \
    >> "$LOG" 2>&1

  EXIT=$?
  echo "[$(ts)] DONE  exit=$EXIT" >> "$LOG"
  rm -f "$LOCKFILE"
) >> "$LOG" 2>&1 &

exit 0
