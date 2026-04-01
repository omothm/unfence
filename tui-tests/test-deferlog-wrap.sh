#!/usr/bin/env bash
# tui-tests/test-deferlog-wrap.sh — Verify deferlog control row wraps at narrow
# terminal widths instead of being silently truncated.
#
# At width=40 (inner=38), the control tokens wrap across two rows:
#   Row 1: "  [e] eval  [c] copy  [r] reload"   (32 chars, fits in 40)
#   Row 2: "  [esc] close"                        (13 chars, fits in 40)
#
# Without wrapping, the single hint string is 54 chars — "[esc] close" is never
# rendered (clipped at col 40 by _draw_item).

source "$(dirname "$0")/helper.sh"

run() {
    echo "--- test: deferlog control row wraps at narrow width (width=40) ---"
    tui_start_sized 40 20

    # Open the deferlog view
    tui_send "d" ""
    tui_wait_for "Deferred Log" 20 \
        || { tui_fail "deferlog view did not open within 2s"; tui_stop; return; }

    # Without the fix, the single control line is 54 chars and is truncated at
    # col 40 — "[esc] close" is never rendered. With wrapping, it appears on a
    # second control row.
    tui_assert_screen "deferlog ctrl: '[esc] close' visible after wrap" "\[esc\] close"

    tui_stop
}

tui_main "$@"
