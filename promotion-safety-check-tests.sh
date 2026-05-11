#!/usr/bin/env bash
# promotion-safety-check-tests.sh — Tests for hooks/promotion-safety-check.sh.
# Run standalone: bash promotion-safety-check-tests.sh
# Also sourced by run-tests.sh for inclusion in the full test suite.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$SCRIPT_DIR/hooks/promotion-safety-check.sh"

PASS=0
FAIL=0

_chk() {
  local desc="$1" cmd="$2" expected="$3"
  local actual
  actual=$(COMMAND="$cmd" bash "$CHECKER")
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $desc"
    (( PASS++ )) || true
  else
    echo "FAIL: $desc — expected=$expected actual=$actual"
    (( FAIL++ )) || true
  fi
}

echo "═══════════════════════════════════════════════════════════════════"
echo " promotion-safety-check tests"
echo "═══════════════════════════════════════════════════════════════════"

# ── Known-unsafe: must return "skip" ──────────────────────────────────────────
_chk "osascript tell-application → skip" \
  "osascript -e 'tell application \"Finder\" to beep'" "skip"
_chk "osascript do-shell-script → skip" \
  "osascript -e 'do shell script \"echo hi\"'" "skip"
_chk "osascript bare script → skip" \
  "osascript script.applescript" "skip"
_chk "security dump-keychain → skip" \
  "security dump-keychain ~/Library/Keychains/login.keychain" "skip"
_chk "curl POST → skip" \
  "curl -X POST https://api.example.com/data -d '{\"key\":\"val\"}'" "skip"
_chk "curl GET → skip (curl is always conditionally safe)" \
  "curl https://example.com" "skip"
_chk "sudo → skip" \
  "sudo rm -rf /var/log/app" "skip"
_chk "aws s3 rm → skip" \
  "aws s3 rm s3://bucket/key" "skip"
_chk "npm install → skip" \
  "npm install lodash" "skip"
_chk "docker run → skip" \
  "docker run --rm ubuntu bash" "skip"

# ── Negative: must return "proceed" ───────────────────────────────────────────
_chk "ls → proceed" "ls -la /tmp" "proceed"
_chk "grep → proceed" "grep -r foo ." "proceed"
_chk "cat → proceed" "cat /etc/hosts" "proceed"
_chk "jq → proceed" "jq '.key' file.json" "proceed"
_chk "git status → proceed" "git status" "proceed"
_chk "osascriptX → proceed (prefix non-match)" "osascriptX -e 'test'" "proceed"
_chk "curlX → proceed (prefix non-match)" "curlX https://example.com" "proceed"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
if (( FAIL == 0 )); then
  printf "All %d promotion-safety-check tests passed.\n" "$PASS"
else
  printf "%d/%d promotion-safety-check tests failed.\n" "$FAIL" "$(( PASS + FAIL ))"
fi
echo "═══════════════════════════════════════════════════════════════════"

(( FAIL == 0 ))
