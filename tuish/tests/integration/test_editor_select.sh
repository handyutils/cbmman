#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Integration tests: editor.sh column-aware selection rendering
#
# Selecting across wide (CJK) characters must keep the reverse-video highlight
# aligned with display columns: _render_sel_line slices the visible line with
# tuish_str_window (display columns), not raw byte offsets. Regression guard for
# the Step D fix — the old byte-slicing treated the display-column scroll offset
# as a byte index, splitting a multi-byte character across the SGR boundary and
# truncating/garbling the line once any wide character was on it.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"
. "$TESTS_DIR/lib/tmux_helpers.sh"
. "$TESTS_DIR/lib/screen_helpers.sh"

EXAMPLES_DIR="$(cd "$(dirname "$0")/../.." && pwd)/examples"

# A buffer file with one CJK line: 中文中文 (4 chars, 8 display columns). Loaded
# from argv so the bytes reach the buffer intact, isolating the render path.
CJK_FILE="$(mktemp)"
printf '\344\270\255\346\226\207\344\270\255\346\226\207\n' > "$CJK_FILE"

cleanup () { cleanup_session; rm -f "$CJK_FILE"; }
trap 'cleanup' EXIT

printf 'Integration tests: editor selection rendering (%s)\n' "$TUISH_SHELL"

# Start the editor with the CJK file loaded (40x12 — the line fits, no scroll).
tmux new-session -d -s "$TUISH_SESSION" -x 40 -y 12 \
	$TUISH_SHELL "$EXAMPLES_DIR/editor.sh" "$CJK_FILE" 2>/dev/null

if ! wait_for_output '中文中文' 10
then
	printf '  FAIL: editor did not load the CJK line\n'
	capture_pane | sed 's/^/    | /'
	test_summary
	exit 0
fi
sleep 0.5

# Baseline: the unselected line (rendered by _render_clipped_line) is intact.
assert_screen_match '中文中文' 'load: CJK line renders intact'

# Home, then select the first two wide chars (shift-right x2 = CSI 1;2C). This
# drives _render_sel_line, splitting the line at the char-2 / column-4 boundary.
send_hex 1b 4f 48              # Home
sleep 0.3
send_hex 1b 5b 31 3b 32 43    # shift-right
sleep 0.3
send_hex 1b 5b 31 3b 32 43    # shift-right
sleep 0.5

# capture-pane strips the SGR attribute, so we assert the glyphs survive: the
# old byte-slicing garbled/truncated the line here; the column-aware version
# keeps 中文中文 intact (first half reverse-video, which the capture drops).
assert_screen_match '中文中文' 'select: CJK line intact under selection highlight'
assert_screen_match 'Col 3'   'select: cursor at char 3 after selecting two wide chars'

quit_tuish

test_summary
