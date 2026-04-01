#!/usr/bin/env bash
# tui-tests/test-narrow-wrap.sh — Verify header tallies and rule title lines wrap
# at narrow terminal widths instead of being silently truncated.
#
# At width=35 (inner=33):
#
#   Stats row (unbordered, full cols=35 available):
#     " 30d: 0 allowed   0 denied   0" fits (30 chars) but adding " prompted" (9)
#     would exceed 35, so " prompted" must appear on a continuation line.
#
#   Rule title line (bordered, inner=33 available):
#     " 1. Test Rule 1 [rule-1.sh]" fits (27 chars) but adding "  just now" (10)
#     would exceed 33, so "just now" must appear on a continuation line.
#
# Without wrapping, both pieces of text are silently clipped by _draw_item.

source "$(dirname "$0")/helper.sh"

run() {
    echo "--- test: narrow terminal wrapping (width=35) ---"
    tui_start_sized 35 30

    # ── Stats row ──────────────────────────────────────────────────────────────
    # "prompted" is the last metric label. Without wrapping it is clipped at
    # width=35; with wrapping it appears on a continuation line.
    tui_assert_screen "stats row: 'prompted' visible after wrap" "prompted"

    # ── Rule title line ────────────────────────────────────────────────────────
    # "just now" is the relative-time segment. Without wrapping the last few
    # chars are clipped at width=35; with wrapping it appears on a continuation
    # line below the title.
    tui_assert_screen "rule title: 'just now' visible after wrap" "just now"

    tui_stop
}

tui_main "$@"
