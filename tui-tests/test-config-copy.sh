#!/usr/bin/env bash
# tui-tests/test-config-copy.sh — Verify the config copy shortcut ([c]) in detail view.
#
# Behavioral contracts:
#  1. [c] appears in ctrl line for a rule whose cache has config_keys
#  2. [c] does NOT appear for rules without config_keys in cache
#  3. Pressing c shows the copy flash message ("Copied")
#  4. Any keypress dismisses the flash and restores normal controls

source "$(dirname "$0")/helper.sh"

# Set up a fixture where rule-1 is config-aware with config_keys in cache.
_start_with_config_rule() {
    _tui_fixture_setup

    # Make rule-1.sh reference PROJECT_CONFIG (so uses_project_config() returns True)
    printf '#!/usr/bin/env bash\n# Uses PROJECT_CONFIG for config\necho defer\n' \
        > "$_TUI_FIXTURE_DIR/rules/rule-1.sh"

    # Write rule-1 cache with config_keys populated
    local long_desc="Sentence 1: dummy config-aware rule used only for TUI testing."
    jq -n \
       --arg d "$long_desc" \
       '{
         "title": "Config Rule",
         "summary": "Dummy config-aware rule for testing.",
         "description": $d,
         "config_schema": "{\n  \"test-rule\": {\n    \"safe-list\": [] // allowed values\n  }\n}",
         "config_keys": [{"path": "test-rule.safe-list", "type": "array"}]
       }' \
       > "$_TUI_FIXTURE_DIR/cache/rule-1.sh"

    tmux new-session -d -s "$SESSION" \
        "env UNFENCE_RULES_DIR='$_TUI_FIXTURE_DIR/rules' \
             UNFENCE_CACHE_DIR='$_TUI_FIXTURE_DIR/cache' \
             python3 $TUI_SCRIPT" 2>/dev/null \
        || { echo "ERROR: could not create tmux session" >&2; exit 1; }
    tui_wait_for "navigate" 50 \
        || { echo "ERROR: TUI did not render within 5s" >&2; exit 1; }
}

run() {
    echo "--- test: config copy shortcut ---"
    _start_with_config_rule

    # Open rule-1 (config-aware with config_keys in cache)
    tui_send "1" ""; tui_wait_for_ctrl "\[m\]"

    # 1. [c] must appear in the ctrl line for this rule
    tui_assert_ctrl "rule-1 detail: [c] copy config cmd visible" "\[c\]"

    # 2. Press c — should show the copy flash message
    tui_send c ""; tui_wait_for "Copied"
    tui_assert_screen "c key: flash message appears" "Copied"
    # Normal controls must be replaced by the flash (no [m] while flash is shown)
    tui_assert_ctrl_not "c key: [m] not in ctrl during flash" "\[m\]"

    # 3. Any keypress dismisses the flash and restores normal controls
    tui_send x ""; tui_wait_for_ctrl "\[m\]"
    tui_assert_not_screen "dismiss: flash gone" "Copied"
    tui_assert_ctrl "dismiss: normal controls restored" "\[m\]"

    # 4. Navigate to rule-2 (no config_keys) — [c] must NOT appear.
    # Wait for "rule-2.sh" to appear in the header (uniquely identifies the new render),
    # NOT just [m] (which was already in the ctrl line for rule-1 as well).
    tui_send Right ""; tui_wait_for "rule-2.sh"
    tui_assert_ctrl_not "rule-2 detail: [c] absent (no config_keys)" "\[c\]"

    tui_stop
}

tui_main "$@"
