#!/usr/bin/env bash
#
# PreToolUse hook — rule-file based permission engine.
#
# Rules live in ~/.claude/unfence/rules/*.sh (sorted by filename).
# Each rule receives a normalized COMMAND env var and writes one of:
#   allow | deny | ask | defer | recurse:<new_command>
# to stdout. The engine passes the command through rules in order until
# one returns a definitive verdict (allow/deny/ask), or all defer.
#
# Special return "recurse:<cmd>" restarts the pipeline from rule 0 with
# a new command (e.g. after unwrapping a wrapper like xargs).
#

if (( BASH_VERSINFO[0] < 4 )); then
  printf 'unfence requires bash 4+; found %s. Install via Homebrew: brew install bash\n' "$BASH_VERSION" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_DIR="${UNFENCE_RULES_DIR:-$SCRIPT_DIR/../rules}"
LOG_FILE="$SCRIPT_DIR/../logs/unfence.log"
DISABLED_FLAG="${UNFENCE_CACHE_DIR:-$SCRIPT_DIR/../.claude/cache}/.disabled"
SESSION_ID="${CLAUDE_SESSION_ID:-${PPID}}"
MAX_RECURSE=10

# Populated at runtime from <cwd>/.claude/unfence.json (if present).
# Exported so rule subshells can read project-specific config.
PROJECT_CONFIG=""

log() {
  [[ -n "${NO_LOG:-}" ]] && return 0
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$SESSION_ID" "$*" \
    >> "$LOG_FILE" 2>/dev/null
}

_output() {
  local decision="$1" reason="$2"
  log "=> $decision  $reason"
  jq -n --arg d "$decision" --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: $d,
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# ── Utility functions (same as v1) ────────────────────────────────────────────

split_commands() {
  local cmd="$1"
  local len=${#cmd} i=0
  local in_single=false in_double=false
  local current="" heredoc_delim=""
  local double_bracket_depth=0
  local paren_depth=0

  while (( i < len )); do
    local ch="${cmd:$i:1}"

    if [[ -n "$heredoc_delim" ]]; then
      if [[ "$ch" == $'\n' ]]; then
        current+="$ch"; (( i++ ))
        local remaining="${cmd:$i}"
        local next_line="${remaining%%$'\n'*}"
        local trimmed="${next_line#"${next_line%%[![:space:]]*}"}"
        if [[ "$trimmed" == "$heredoc_delim" ]]; then
          current+="$next_line"; (( i += ${#next_line} )); heredoc_delim=""
        fi
        continue
      fi
      current+="$ch"; (( i++ )); continue
    fi

    if [[ "$ch" == "\\" ]] && ! $in_single && (( i + 1 < len )); then
      if [[ "${cmd:$((i+1)):1}" == $'\n' ]]; then
        # Backslash-newline: line continuation — skip both chars
        (( i += 2 )); continue
      fi
      current+="${cmd:$i:2}"; (( i += 2 )); continue
    fi
    if [[ "$ch" == "'" ]] && ! $in_double; then
      in_single=$( $in_single && echo false || echo true )
      current+="$ch"; (( i++ )); continue
    fi
    if [[ "$ch" == '"' ]] && ! $in_single; then
      in_double=$( $in_double && echo false || echo true )
      current+="$ch"; (( i++ )); continue
    fi

    if ! $in_single && ! $in_double; then
      if [[ "${cmd:$i:2}" == "<<" ]]; then
        local j=$(( i + 2 ))
        [[ "${cmd:$j:1}" == "-" ]] && (( j++ ))
        while [[ "${cmd:$j:1}" == " " || "${cmd:$j:1}" == $'\t' ]]; do (( j++ )); done
        local delim="" quote_ch="${cmd:$j:1}"
        if [[ "$quote_ch" == "'" || "$quote_ch" == '"' ]]; then
          (( j++ ))
          while (( j < len )) && [[ "${cmd:$j:1}" != "$quote_ch" ]]; do
            delim+="${cmd:$j:1}"; (( j++ ))
          done
          (( j++ ))
        elif [[ "$quote_ch" == "\\" ]]; then
          (( j++ ))
          while (( j < len )) && [[ "${cmd:$j:1}" =~ [A-Za-z0-9_] ]]; do
            delim+="${cmd:$j:1}"; (( j++ ))
          done
        else
          while (( j < len )) && [[ "${cmd:$j:1}" =~ [A-Za-z0-9_] ]]; do
            delim+="${cmd:$j:1}"; (( j++ ))
          done
        fi
        if [[ -n "$delim" ]]; then
          heredoc_delim="$delim"
          current+="${cmd:$i:$((j - i))}"; i=$j; continue
        fi
      fi
      if [[ "${cmd:$i:2}" == "[[" ]]; then
        (( double_bracket_depth++ ))
        current+="[["; (( i += 2 )); continue
      fi
      if [[ "${cmd:$i:2}" == "]]" ]]; then
        (( double_bracket_depth > 0 )) && (( double_bracket_depth-- ))
        current+="]]"; (( i += 2 )); continue
      fi
      if [[ "$ch" == "(" ]]; then
        (( paren_depth++ ))
        current+="$ch"; (( i++ )); continue
      fi
      if [[ "$ch" == ")" ]]; then
        (( paren_depth > 0 )) && (( paren_depth-- ))
        current+="$ch"; (( i++ )); continue
      fi
      if (( double_bracket_depth == 0 && paren_depth == 0 )); then
        if [[ "${cmd:$i:2}" == "||" ]]; then printf '%s\0' "$current"; current=""; (( i += 2 )); continue; fi
        if [[ "${cmd:$i:2}" == "&&" ]]; then printf '%s\0' "$current"; current=""; (( i += 2 )); continue; fi
        if [[ "$ch" == ";" ]];       then printf '%s\0' "$current"; current=""; (( i++ ));    continue; fi
        if [[ "$ch" == "|" ]];       then printf '%s\0' "$current"; current=""; (( i++ ));    continue; fi
        if [[ "$ch" == $'\n' ]];     then printf '%s\0' "$current"; current=""; (( i++ ));    continue; fi
        # Inline comment: # preceded by whitespace (or nothing) starts a comment → skip to EOL.
        # Only applies at top-level (outside brackets/parens), matching bash semantics.
        if [[ "$ch" == "#" && ( -z "$current" || "${current: -1}" == " " || "${current: -1}" == $'\t' ) ]]; then
          printf '%s\0' "$current"; current=""
          while (( i < len )) && [[ "${cmd:$i:1}" != $'\n' ]]; do (( i++ )); done
          continue
        fi
      fi
    fi

    current+="$ch"; (( i++ ))
  done
  [[ -n "$current" ]] && printf '%s\0' "$current"
}

strip_redirections() {
  echo "$1" | sed -E \
    's/[0-9]*>&[0-9]+//g
     s/[0-9]*>[>]?[[:space:]]*[^ |;&]+//g
     s/<[[:space:]]*[^ |;&]+//g'
}

tokenize() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    local arr; read -ra arr <<< "$line"
    printf '%s\n' "${arr[@]}"
  done <<< "$1"
}

# ── Rule pipeline ──────────────────────────────────────────────────────────────

# Set by classify_single to the basename of the rule that gave the verdict.
# For recurse: chains, contains all participating rules joined by " → ".
# Empty if verdict was defer or came from a built-in check (empty cmd, etc.).
_LAST_RULE=""
# Set by classify_single to the verdict string (allow/deny/ask/defer).
# Used by the recurse: handler to read the inner verdict without a subshell.
_LAST_VERDICT=""
# Set by classify_single to the deepest normalized command that failed to match.
# For recurse: chains this is the unwrapped inner command, not the original surface form.
# Used by EVAL_MODE to report the actual culprit rather than the whole top-level part.
_LAST_DEFER_CMD=""

# Run all rule files against a single, already-normalized command string.
# Returns: allow | deny | ask | defer
# Side-effect: sets $_LAST_RULE to the matching rule's basename (or "").
classify_single() {
  local cmd="$1"
  local depth="${2:-0}"
  _LAST_RULE=""
  _LAST_VERDICT=""
  _LAST_DEFER_CMD=""

  if (( depth > MAX_RECURSE )); then
    log "  recursion limit ($MAX_RECURSE) hit for: $cmd"
    _LAST_DEFER_CMD="$cmd"
    echo "defer"; return
  fi

  # ── Normalize ──────────────────────────────────────────────────────────────
  cmd=$(strip_redirections "$cmd")
  cmd=$(echo "$cmd" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [[ -z "$cmd" ]] && echo "allow" && return

  # Tokenize
  local TOKENS=()
  while IFS= read -r t; do
    [[ -n "$t" ]] && TOKENS+=("$t")
  done < <(tokenize "$cmd")
  [[ ${#TOKENS[@]} -eq 0 ]] && echo "allow" && return

  # Strip variable-assignment prefix
  # $((…)) arithmetic expansion: no external command, always safe.
  # Must be checked before the generic VAR=$( branch since $(( matches $(.
  if [[ "${TOKENS[0]}" =~ ^[A-Za-z_][A-Za-z0-9_]*=\$\(\( ]]; then
    echo "allow"; return
  fi
  if [[ "${TOKENS[0]}" =~ ^[A-Za-z_][A-Za-z0-9_]*=\$\( ]]; then
    local rest="${TOKENS[0]#*=\$(}"
    if [[ -n "$rest" ]]; then TOKENS[0]="$rest"; else TOKENS=("${TOKENS[@]:1}"); fi
    local last_idx=$(( ${#TOKENS[@]} - 1 ))
    [[ "${TOKENS[$last_idx]}" == *")" ]] && TOKENS[$last_idx]="${TOKENS[$last_idx]%%)}"
  elif [[ "${TOKENS[0]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    echo "allow"; return   # simple VAR=value → allow
  elif [[ "${TOKENS[0]}" =~ ^[A-Za-z_][A-Za-z0-9_]*\[ ]]; then
    # Array element assignment: VAR[subscript]=value / VAR[subscript]=$(cmd)
    if [[ "${TOKENS[0]}" =~ \]=\$\(\( ]]; then
      echo "allow"; return  # VAR[k]=$(( expr )) — arithmetic, no subprocess
    elif [[ "${TOKENS[0]}" =~ \]=\$\( ]]; then
      # VAR[k]=$(cmd ...) — extract subshell command and re-run through rules
      local rest="${TOKENS[0]#*]=\$(}"
      if [[ -n "$rest" ]]; then TOKENS[0]="$rest"; else TOKENS=("${TOKENS[@]:1}"); fi
      local last_idx=$(( ${#TOKENS[@]} - 1 ))
      [[ "${TOKENS[$last_idx]}" == *")" ]] && TOKENS[$last_idx]="${TOKENS[$last_idx]%%)}"
    else
      echo "allow"; return  # VAR[k]=value — simple array element assignment → allow
    fi
  fi
  # Strip leading inline env-var prefixes (e.g. TZ=UTC from 'var=$(TZ=UTC cmd ...)')
  while [[ ${#TOKENS[@]} -gt 0 && "${TOKENS[0]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    TOKENS=("${TOKENS[@]:1}")
  done
  [[ ${#TOKENS[@]} -eq 0 ]] && echo "allow" && return

  # Brace group normalization: { cmd... } split on ; yields "{ cmd args" and "}".
  # Neither is a command — strip the opener and allow the closer unconditionally.
  [[ "${TOKENS[0]}" == "}" ]] && echo "allow" && return
  if [[ "${TOKENS[0]}" == "{" ]]; then
    TOKENS=("${TOKENS[@]:1}")
    [[ ${#TOKENS[@]} -eq 0 ]] && echo "allow" && return  # lone {
  fi

  # Subshell group normalization: (cmd ...) and (cmd ...) &
  # Shell syntax, not a command — strip the ( ) wrapper and optional trailing &
  # so downstream rules see the real command.  Requires ) to be a separate token
  # (i.e. a space before it), which is the form bash-generated commands use.
  if [[ "${TOKENS[0]}" == \(* ]]; then
    local n_t=${#TOKENS[@]}
    # Strip trailing & when the preceding token is )
    if (( n_t >= 3 )) && [[ "${TOKENS[$((n_t-1))]}" == "&" && "${TOKENS[$((n_t-2))]}" == ")" ]]; then
      TOKENS=("${TOKENS[@]:0:$((n_t-2))}"); n_t=${#TOKENS[@]}
    fi
    # Strip trailing )
    if (( n_t >= 2 )) && [[ "${TOKENS[$((n_t-1))]}" == ")" ]]; then
      TOKENS=("${TOKENS[@]:0:$((n_t-1))}"); n_t=${#TOKENS[@]}
    fi
    # Strip leading ( from first token (may be fused: "(cmd" → "cmd")
    TOKENS[0]="${TOKENS[0]#(}"
    [[ -z "${TOKENS[0]}" ]] && TOKENS=("${TOKENS[@]:1}") && n_t=${#TOKENS[@]}
    [[ $n_t -eq 0 ]] && echo "allow" && return  # empty subshell
  fi

  local normalized="${TOKENS[*]}"
  log "  classify[$depth]: $normalized"

  # ── Run rules in sorted order ──────────────────────────────────────────────
  for rule_file in "${RULE_FILES[@]}"; do
    local verdict
    verdict=$(COMMAND="$normalized" PROJECT_CONFIG="$PROJECT_CONFIG" COMMAND_CWD="$SESSION_CWD" source "$rule_file" 2>/dev/null)

    case "$verdict" in
      allow|deny|ask)
        log "  -> $verdict  ($(basename "$rule_file"))"
        _LAST_RULE="$(basename "$rule_file")"
        _LAST_VERDICT="$verdict"
        echo "$verdict"; return
        ;;
      deny:*)
        log "  -> deny  ($(basename "$rule_file"))"
        _LAST_RULE="$(basename "$rule_file")"
        _LAST_VERDICT="deny"
        echo "$verdict"; return  # pass through "deny:<message>" for caller to extract reason
        ;;
      recurse:*)
        local new_cmd="${verdict#recurse:}"
        local _recurse_rule="$(basename "$rule_file")"
        log "  -> recurse: $new_cmd  ($_recurse_rule)"
        # Direct function call (no subshell) — _LAST_RULE/_LAST_VERDICT propagate back
        classify_single "$new_cmd" $(( depth + 1 ))
        # Emit a credit line so TUI log stats attribute this wrapper rule too
        if [[ "$_LAST_VERDICT" == "allow" || "$_LAST_VERDICT" == "deny" ]]; then
          log "  -> $_LAST_VERDICT  ($_recurse_rule)  [via recurse]"
        fi
        # Prepend wrapper to build the full rule chain (e.g. "0-unwrap.sh → 1-lists.sh")
        _LAST_RULE="$_recurse_rule${_LAST_RULE:+ → $_LAST_RULE}"
        return
        ;;
      defer|"")
        continue
        ;;
      *)
        log "  WARN unexpected output from $(basename "$rule_file"): $verdict"
        continue
        ;;
    esac
  done

  log "  -> defer (no rule decided)"
  _LAST_DEFER_CMD="$normalized"
  echo "defer"
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Load rule files once (sorted by filename)
RULE_FILES=()
if [[ -d "$RULES_DIR" ]]; then
  while IFS= read -r -d '' f; do
    RULE_FILES+=("$f")
  done < <(find "$RULES_DIR" -maxdepth 1 -name "*.sh" ! -name "*.test.sh" -print0 \
           | sort -z)
fi

# ── Disabled check ────────────────────────────────────────────────────────────
if [[ -f "$DISABLED_FLAG" ]]; then
  if [[ -n "$EVAL_MODE" ]]; then
    printf '{"verdict":"defer","rule":null,"disabled":true}\n'; exit 0
  fi
  log "DISABLED: no-op"
  exit 0
fi

# ── EVAL_MODE: called by the summary TUI for live evaluation ──────────────────
# Usage: EVAL_MODE=1 CMD="<raw command>" bash unfence.sh
# Output: {"verdict":"allow|deny|ask|defer","rule":"filename or null"}
# On defer: also includes "parts": ["cmd1","cmd2",...] listing the unmatched parts.
if [[ -n "$EVAL_MODE" ]]; then
  RAW_COMMAND=$(printf '%s' "${CMD:-}" | sed '/^[[:space:]]*#/d')
  if [[ -z "$RAW_COMMAND" ]]; then
    printf '{"verdict":"allow","rule":null}\n'; exit 0
  fi

  has_deny=false; has_ask=false; all_allow=true
  deny_rule=""; ask_rule=""; allow_rule=""
  defer_parts=()
  _vtmp=$(mktemp)

  while IFS= read -r -d '' part; do
    part=$(echo "$part" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [[ -z "$part" ]] && continue
    # Redirect (not subshell) so _LAST_RULE propagates back to this shell
    classify_single "$part" > "$_vtmp"
    v=$(cat "$_vtmp")
    r="$_LAST_RULE"
    case "$v" in
      deny|deny:*)  has_deny=true; all_allow=false; [[ -z "$deny_rule" ]] && deny_rule="$r"  ;;
      ask)   has_ask=true;  all_allow=false; [[ -z "$ask_rule"   ]] && ask_rule="$r"   ;;
      allow) [[ -z "$allow_rule" ]] && allow_rule="$r" ;;
      *)     all_allow=false; defer_parts+=("${_LAST_DEFER_CMD:-$part}") ;;
    esac
  done < <(split_commands "$RAW_COMMAND")
  rm -f "$_vtmp"

  _null_or_str() { [[ -n "$1" ]] && printf '"%s"' "$1" || printf 'null'; }
  _parts_json() {
    local json="[" sep=""
    for p in "${defer_parts[@]}"; do
      json+="${sep}$(printf '%s' "$p" | jq -Rs .)"
      sep=","
    done
    printf '%s]' "$json"
  }
  if   $has_deny;  then printf '{"verdict":"deny","rule":%s}\n'  "$(_null_or_str "$deny_rule")"
  elif $has_ask;   then printf '{"verdict":"ask","rule":%s}\n'   "$(_null_or_str "$ask_rule")"
  elif $all_allow; then printf '{"verdict":"allow","rule":%s}\n' "$(_null_or_str "$allow_rule")"
  else                  printf '{"verdict":"defer","rule":null,"parts":%s}\n' "$(_parts_json)"
  fi
  exit 0
fi

INPUT=$(cat)
RAW_COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

SESSION_CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [[ -n "$SESSION_CWD" && -f "$SESSION_CWD/.claude/unfence.json" ]]; then
  PROJECT_CONFIG=$(cat "$SESSION_CWD/.claude/unfence.json")
  log "CONFIG loaded from $SESSION_CWD/.claude/unfence.json"
fi

if [[ -z "$RAW_COMMAND" ]]; then
  log "SKIP  empty command"
  exit 0
fi

# Strip comment lines
RAW_COMMAND=$(echo "$RAW_COMMAND" | sed '/^[[:space:]]*#/d')
if [[ -z "$RAW_COMMAND" ]]; then
  _output "allow" "Only comments, nothing to run"
fi

log "INPUT $RAW_COMMAND"

has_deny=false
has_ask=false
all_allow=true
_DENY_MSG=""

while IFS= read -r -d '' part; do
  part=$(echo "$part" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [[ -z "$part" ]] && continue

  verdict=$(classify_single "$part")

  case "$verdict" in
    deny)        has_deny=true; all_allow=false ;;
    deny:*)      has_deny=true; all_allow=false
                 [[ -z "$_DENY_MSG" ]] && _DENY_MSG="${verdict#deny:}" ;;
    ask)         has_ask=true;  all_allow=false ;;
    allow)       ;;
    *)           all_allow=false ;;
  esac
done < <(split_commands "$RAW_COMMAND")

if $has_deny; then _output "deny" "${_DENY_MSG:-Command matches a DENY rule}"; fi
if $has_ask; then
  log "=> ask (rule requested user prompt)"
  jq -n '{"hookSpecificOutput":{"hookEventName":"PreToolUse","ruleVerdict":"ask"}}'
  exit 0
fi
if $all_allow;  then _output "allow" "All command parts match ALLOW rules"; fi

log "=> defer (some parts had no matching rule)"
exit 0
