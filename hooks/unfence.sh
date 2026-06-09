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
CACHE_DIR="${UNFENCE_CACHE_DIR:-$SCRIPT_DIR/../.claude/cache}"
DISABLED_FLAG="$CACHE_DIR/.disabled"
SESSION_ID="${CLAUDE_SESSION_ID:-${PPID}}"
MAX_RECURSE=10

# Populated at runtime from <cwd>/.claude/unfence.json (if present).
# Exported so rule subshells can read project-specific config.
PROJECT_CONFIG=""

# Populated per-part as the engine iterates a compound command.
# Holds simple VAR=literal assignments seen so far, serialized as a JSON object.
# Rules read this to resolve leading $VAR references in their tokens.
INLINE_VARS="{}"

# Populated by _scan_and_register_fns for the current invocation.
# Maps user-defined function names to their body's worst verdict.
# Only entries whose body verdict is non-defer are stored (skip-registration policy).
declare -A _FN_REGISTRY=()

log() {
  [[ -n "${NO_LOG:-}" ]] && return 0
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$SESSION_ID" "$*" \
    >> "$LOG_FILE" 2>/dev/null
}

# Drop log lines older than 30 days. Reads only the first line to decide whether
# rotation is needed (fast path); rewrites the file only when the first entry is
# outside the window.
_rotate_log() {
  [[ -f "$LOG_FILE" ]] || return 0
  local first_line cutoff_date first_date
  first_line=$(head -1 "$LOG_FILE")
  # Extract the date portion: "[2026-03-26 ..." → "2026-03-26"
  first_date="${first_line:1:10}"
  [[ "$first_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 0
  cutoff_date=$(date -v-30d '+%Y-%m-%d' 2>/dev/null \
    || date -d '30 days ago' '+%Y-%m-%d' 2>/dev/null) || return 0
  [[ "$first_date" < "$cutoff_date" ]] || return 0
  # First line is older than 30 days — rewrite keeping only lines within window.
  local tmp
  tmp=$(mktemp "$LOG_FILE.XXXXXX") || return 0
  # awk: once we've seen a line with a date >= cutoff, keep it and everything after.
  awk -v cutoff="$cutoff_date" '
    !printing && /^\[([0-9]{4}-[0-9]{2}-[0-9]{2})/ {
      d = substr($0, 2, 10)
      if (d >= cutoff) printing = 1
    }
    printing { print }
  ' "$LOG_FILE" > "$tmp" && mv "$tmp" "$LOG_FILE" || rm -f "$tmp"
}

# ── User-defined function registry ────────────────────────────────────────────

# Return the worse of two verdicts: deny > ask > defer > allow.
_fn_worst() {
  local a="$1" b="$2"
  [[ "$a" == deny* || "$b" == deny* ]] && echo "deny" && return
  [[ "$a" == "ask"  || "$b" == "ask"  ]] && echo "ask"  && return
  [[ "$a" == "defer" || "$b" == "defer" ]] && echo "defer" && return
  echo "allow"
}

# Count unquoted { and } in a string. Outputs: "<open> <close>"
_count_unquoted_braces() {
  local s="$1" open=0 close=0 in_single=false in_double=false
  local i=0 len=${#s}
  while (( i < len )); do
    local c="${s:$i:1}"
    if $in_single; then
      [[ "$c" == "'" ]] && in_single=false
    elif $in_double; then
      [[ "$c" == "\\" ]] && (( i++ ))
      [[ "$c" == '"'  ]] && in_double=false
    else
      case "$c" in
        "'") in_single=true ;;
        '"') in_double=true ;;
        '{') (( open++ )) ;;
        '}') (( close++ )) ;;
      esac
    fi
    (( i++ ))
  done
  echo "$open $close"
}

# Scan a raw command for function definitions and populate _FN_REGISTRY.
# Must be called before the main classification loop.
# Only registers functions whose body verdict is non-defer (skip-registration policy).
_scan_and_register_fns() {
  local raw_cmd="$1"
  local _fn_state="normal" _fn_name="" _fn_depth=0 _fn_bv="allow"
  local part

  while IFS= read -r -d '' part; do
    part=$(echo "$part" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [[ -z "$part" ]] && continue

    if [[ "$_fn_state" == "normal" ]]; then
      local tokens=()
      while IFS= read -r t; do [[ -n "$t" ]] && tokens+=("$t"); done < <(tokenize "$part")
      [[ ${#tokens[@]} -eq 0 ]] && continue

      local fname=""
      # NAME()  — no space before ()
      if [[ "${tokens[0]}" =~ ^([A-Za-z_][A-Za-z0-9_]*)\(\)$ ]]; then
        fname="${BASH_REMATCH[1]}"
      # NAME () — space before ()
      elif [[ ${#tokens[@]} -ge 2 && "${tokens[1]}" == "()" ]]; then
        [[ "${tokens[0]}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && fname="${tokens[0]}"
      # function NAME or function NAME()
      elif [[ "${tokens[0]}" == "function" && ${#tokens[@]} -ge 2 ]]; then
        local t1="${tokens[1]%\(\)}"
        [[ "$t1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && fname="$t1"
      fi

      if [[ -n "$fname" && "$part" == *"{"* ]]; then
        _fn_name="$fname"
        _fn_state="in_fn"
        _fn_bv="allow"

        local counts; counts=$(_count_unquoted_braces "$part")
        _fn_depth=$(( ${counts% *} - ${counts#* } ))

        # Evaluate any body content on the same line as the opening {.
        local body_here="${part#*\{}"
        if (( _fn_depth <= 0 )); then
          # Entire function on one part — strip trailing } (and anything after) from body.
          body_here="${body_here%\}*}"
        fi
        if [[ -n "${body_here//[[:space:]]/}" ]]; then
          local bv; bv=$(classify_single "$body_here")
          [[ "$bv" == deny* ]] && bv="deny"
          _fn_bv=$(_fn_worst "$_fn_bv" "$bv")
        fi

        if (( _fn_depth <= 0 )); then
          if [[ "$_fn_bv" != "defer" ]]; then
            _FN_REGISTRY["$_fn_name"]="$_fn_bv"
            log "  fn-scan: $_fn_name → $_fn_bv"
          fi
          _fn_state="normal"
        fi
        continue
      fi

    elif [[ "$_fn_state" == "in_fn" ]]; then
      local counts; counts=$(_count_unquoted_braces "$part")
      _fn_depth=$(( _fn_depth + ${counts% *} - ${counts#* } ))

      local bv; bv=$(classify_single "$part")
      [[ "$bv" == deny* ]] && bv="deny"
      _fn_bv=$(_fn_worst "$_fn_bv" "$bv")

      if (( _fn_depth <= 0 )); then
        if [[ "$_fn_bv" != "defer" ]]; then
          _FN_REGISTRY["$_fn_name"]="$_fn_bv"
          log "  fn-scan: $_fn_name → $_fn_bv"
        fi
        _fn_state="normal"
      fi
      continue
    fi
  done < <(split_commands "$raw_cmd")
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
        if [[ "$ch" == "|" ]]; then
          # Case-arm pattern OR separator: Pat1|Pat2) — no spaces around |, right
          # side ends with ) before any whitespace.  Don't split; accumulate so
          # classify_single sees the full pattern token (e.g. "Superseded|Merged)")
          # and strips it via the case-arm normalization path.
          local _prev="${current: -1}" _next="${cmd:$((i+1)):1}"
          if [[ -n "$_prev" && "$_prev" != " " && "$_prev" != $'\t' && \
                -n "$_next" && "$_next" != " " && "$_next" != $'\t' ]]; then
            local _jl=$((i+1)) _arm=false
            while (( _jl < len )); do
              local _lc="${cmd:$_jl:1}"
              [[ "$_lc" == ")" ]] && _arm=true && break
              [[ "$_lc" == " " || "$_lc" == $'\t' ]] && break
              (( _jl++ ))
            done
            if $_arm; then current+="$ch"; (( i++ )); continue; fi
          fi
          printf '%s\0' "$current"; current=""; (( i++ )); continue
        fi
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
  # Quote-aware word splitter. Splits on unquoted whitespace; preserves quotes
  # in output tokens (same as the shell's word-splitting stage, before expansion).
  # Tracks $(...) depth inside double quotes so spaces in "$(cmd with spaces)"
  # do not split the token.
  local s="$1" len=${#1} i=0
  local tok="" in_single=false in_double=false subsh_depth=0
  while (( i < len )); do
    local ch="${s:$i:1}"
    if $in_single; then
      tok+="$ch"; (( i++ ))
      [[ "$ch" == "'" ]] && in_single=false
      continue
    fi
    if $in_double; then
      if [[ "$ch" == "\\" ]] && (( i+1 < len )); then
        tok+="${s:$i:2}"; (( i += 2 )); continue
      fi
      if [[ "$ch" == '"' ]] && (( subsh_depth == 0 )); then
        tok+="$ch"; in_double=false; (( i++ )); continue
      fi
      if [[ "${s:$i:2}" == '$(' ]]; then
        (( subsh_depth++ )); tok+='$('; (( i += 2 )); continue
      fi
      if [[ "$ch" == ')' ]] && (( subsh_depth > 0 )); then
        (( subsh_depth-- )); tok+="$ch"; (( i++ )); continue
      fi
      tok+="$ch"; (( i++ )); continue
    fi
    # Unquoted context
    if [[ "$ch" == "'" ]]; then
      in_single=true; tok+="$ch"; (( i++ )); continue
    fi
    if [[ "$ch" == '"' ]]; then
      in_double=true; tok+="$ch"; (( i++ )); continue
    fi
    if [[ "$ch" == ' ' || "$ch" == $'\t' ]]; then
      [[ -n "$tok" ]] && printf '%s\n' "$tok"
      tok=""; (( i++ )); continue
    fi
    tok+="$ch"; (( i++ ))
  done
  [[ -n "$tok" ]] && printf '%s\n' "$tok"
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
  # so downstream rules see the real command.  Handles both spaced ( cmd ) and
  # fused (cmd) forms.
  if [[ "${TOKENS[0]}" == \(* ]]; then
    local n_t=${#TOKENS[@]}
    # Strip trailing & when the preceding token is )
    if (( n_t >= 3 )) && [[ "${TOKENS[$((n_t-1))]}" == "&" && "${TOKENS[$((n_t-2))]}" == ")" ]]; then
      TOKENS=("${TOKENS[@]:0:$((n_t-2))}"); n_t=${#TOKENS[@]}
    fi
    # Strip trailing ) — either as a separate token or fused to the last token.
    if (( n_t >= 2 )) && [[ "${TOKENS[$((n_t-1))]}" == ")" ]]; then
      TOKENS=("${TOKENS[@]:0:$((n_t-1))}"); n_t=${#TOKENS[@]}
    elif [[ "${TOKENS[$((n_t-1))]}" == *")" ]]; then
      local _lt="${TOKENS[$((n_t-1))]}"; TOKENS[$((n_t-1))]="${_lt%)}"
    fi
    # Strip leading ( from first token (may be fused: "(cmd" → "cmd")
    TOKENS[0]="${TOKENS[0]#(}"
    [[ -z "${TOKENS[0]}" ]] && TOKENS=("${TOKENS[@]:1}") && n_t=${#TOKENS[@]}
    [[ $n_t -eq 0 ]] && echo "allow" && return  # empty subshell
  fi

  # Case-arm pattern: PATTERN) cmd — strip the label so rules see the inner command.
  # A bare ")" is a subshell closer (shell syntax, no command) → allow, mirroring "}".
  [[ "${TOKENS[0]}" == ")" ]] && echo "allow" && return
  if [[ "${TOKENS[0]}" == *")" && "${TOKENS[0]}" != "(" ]]; then
    TOKENS=("${TOKENS[@]:1}")
    [[ ${#TOKENS[@]} -eq 0 ]] && echo "allow" && return  # lone arm label, no command
    # Recurse so the inner command goes through the full normalization pipeline
    # (VAR= check, brace/subshell stripping, etc.) rather than jumping straight to rules.
    local _inner_verdict
    _inner_verdict=$(classify_single "${TOKENS[*]}" $((depth+1)))
    [[ -n "$_inner_verdict" ]] && echo "$_inner_verdict" && return
  fi

  local normalized="${TOKENS[*]}"
  log "  classify[$depth]: $normalized"

  # ── Run rules in sorted order ──────────────────────────────────────────────
  for rule_file in "${RULE_FILES[@]}"; do
    local verdict
    verdict=$(eval "$(declare -p TOKENS)"; COMMAND="$normalized" PROJECT_CONFIG="$PROJECT_CONFIG" COMMAND_CWD="$SESSION_CWD" source "$rule_file" 2>/dev/null)

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

  # ── User-defined function lookup ──────────────────────────────────────────────
  # If all rules deferred, check whether this command name was registered as a
  # user-defined function in the current invocation and return its stored verdict.
  local _fn_v="${_FN_REGISTRY[${TOKENS[0]}]:-}"
  if [[ -n "$_fn_v" ]]; then
    log "  -> $_fn_v  (fn:${TOKENS[0]})"
    _LAST_RULE="[fn:${TOKENS[0]}]"
    _LAST_VERDICT="$_fn_v"
    echo "$_fn_v"; return
  fi

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

# Rotate log on every normal invocation (skipped in EVAL_MODE which has no log).
[[ -z "$EVAL_MODE" ]] && _rotate_log

# ── Disabled check ────────────────────────────────────────────────────────────
if [[ -f "$DISABLED_FLAG" ]]; then
  if [[ -n "$EVAL_MODE" ]]; then
    printf '{"verdict":"defer","rule":null,"disabled":true}\n'; exit 0
  fi
  log "DISABLED: no-op"
  exit 0
fi

# ── EVAL_MODE: called by the summary TUI for live evaluation ──────────────────
# Usage: EVAL_MODE=1 CMD="<raw command>" [EVAL_CWD="<project_dir>"] bash unfence.sh
# Output: {"verdict":"allow|deny|ask|defer","rule":"filename or null"}
# On defer: also includes "parts": ["cmd1","cmd2",...] listing the unmatched parts.
if [[ -n "$EVAL_MODE" ]]; then
  if [[ -n "${EVAL_CWD:-}" && -f "${EVAL_CWD}/.claude/unfence.json" ]]; then
    PROJECT_CONFIG=$(cat "${EVAL_CWD}/.claude/unfence.json")
  fi
  RAW_COMMAND=$(printf '%s' "${CMD:-}" | sed '/^[[:space:]]*#/d')
  if [[ -z "$RAW_COMMAND" ]]; then
    printf '{"verdict":"allow","rule":null}\n'; exit 0
  fi

  _scan_and_register_fns "$RAW_COMMAND"

  has_deny=false; has_ask=false; all_allow=true
  deny_rule=""; ask_rule=""; allow_rule=""
  defer_parts=()
  _vtmp=$(mktemp)

  declare -A _ivars=()
  while IFS= read -r -d '' part; do
    part=$(echo "$part" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [[ -z "$part" ]] && continue
    # Track simple VAR=literal assignments so rules can expand inline $VAR references.
    # Strip export/local/readonly prefix so "export VAR=val" is tracked like "VAR=val".
    _iv_part="$part"
    _iv_part="${_iv_part#export }"; _iv_part="${_iv_part#local }"; _iv_part="${_iv_part#readonly }"
    if [[ "$_iv_part" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      _ivk="${BASH_REMATCH[1]}" _ivv="${BASH_REMATCH[2]}"
      if [[ "$_ivv" != *'$('* && "$_ivv" != *'`'* ]]; then
        _ivv="${_ivv#\'}" ; _ivv="${_ivv%\'}" ; _ivv="${_ivv#\"}" ; _ivv="${_ivv%\"}"
        _ivars["$_ivk"]="$_ivv"
        _ivj="{" _ivs=""
        for _ivk in "${!_ivars[@]}"; do
          _ivj+="${_ivs}\"${_ivk}\":$(printf '%s' "${_ivars[$_ivk]}" | jq -Rs .)"
          _ivs=","
        done
        INLINE_VARS="${_ivj}}"
      fi
    fi
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

# Load PROJECT_CONFIG from the session's initial project directory.
# CLAUDE_PROJECT_DIR is set by Claude Code in the hook environment and always
# points to the directory where the session started, regardless of any cd
# commands the agent may have run. Fall back to SESSION_CWD for tests/eval
# where CLAUDE_PROJECT_DIR is not set.
_root="${CLAUDE_PROJECT_DIR:-$SESSION_CWD}"
if [[ -n "$_root" && -f "$_root/.claude/unfence.json" ]]; then
  PROJECT_CONFIG=$(cat "$_root/.claude/unfence.json")
  log "CONFIG loaded from $_root/.claude/unfence.json"
fi
unset _root

if [[ -z "$RAW_COMMAND" ]]; then
  log "SKIP  empty command"
  exit 0
fi

# Strip comment lines
RAW_COMMAND=$(echo "$RAW_COMMAND" | sed '/^[[:space:]]*#/d')
if [[ -z "$RAW_COMMAND" ]]; then
  _output "allow" "Only comments, nothing to run"
fi

log "CWD $SESSION_CWD"
log "INPUT $RAW_COMMAND"

_scan_and_register_fns "$RAW_COMMAND"

has_deny=false
has_ask=false
all_allow=true
_DENY_MSG=""

declare -A _ivars=()
while IFS= read -r -d '' part; do
  part=$(echo "$part" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [[ -z "$part" ]] && continue
  # Track simple VAR=literal assignments so rules can expand inline $VAR references.
  # Strip export/local/readonly prefix so "export VAR=val" is tracked like "VAR=val".
  _iv_part="$part"
  _iv_part="${_iv_part#export }"; _iv_part="${_iv_part#local }"; _iv_part="${_iv_part#readonly }"
  if [[ "$_iv_part" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    _ivk="${BASH_REMATCH[1]}" _ivv="${BASH_REMATCH[2]}"
    if [[ "$_ivv" != *'$('* && "$_ivv" != *'`'* ]]; then
      _ivv="${_ivv#\'}" ; _ivv="${_ivv%\'}" ; _ivv="${_ivv#\"}" ; _ivv="${_ivv%\"}"
      _ivars["$_ivk"]="$_ivv"
      _ivj="{" _ivs=""
      for _ivk in "${!_ivars[@]}"; do
        _ivj+="${_ivs}\"${_ivk}\":$(printf '%s' "${_ivars[$_ivk]}" | jq -Rs .)"
        _ivs=","
      done
      INLINE_VARS="${_ivj}}"
    fi
  fi

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
