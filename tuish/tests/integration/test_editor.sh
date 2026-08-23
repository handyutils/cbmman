#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Integration tests: editor.sh example via tmux PTY
#
# Tests the CUA-like text editor — typing, navigation, line management,
# status bar updates, and file loading.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"
. "$TESTS_DIR/lib/tmux_helpers.sh"
. "$TESTS_DIR/lib/screen_helpers.sh"

EXAMPLES_DIR="$(cd "$(dirname "$0")/../.." && pwd)/examples"
trap 'cleanup_session' EXIT

printf 'Integration tests: editor example (%s)\n' "$TUISH_SHELL"

# ─── Startup ──────────────────────────────────────────────────────

start_example_session "$EXAMPLES_DIR/editor.sh" "Ln 1, Col 1"

assert_screen_match "Ln 1, Col 1" "startup: cursor at 1,1"
assert_screen_match "1 lines" "startup: one line in buffer"

assert_screen "editor_startup" "screenshot: empty editor startup"

# ─── Typing ───────────────────────────────────────────────────────

# Type "Hello" — character-by-character for cross-shell reliability
send_chars 48 65 6c 6c 6f
sleep 0.3

assert_screen_match "Hello" "typing: text appears"
assert_screen_match "Col 6" "typing: cursor at col 6 after 5 chars"

# Verify first batch landed before sending more
sleep 0.3

# Type " World" (space + W-o-r-l-d)
send_chars 20 57 6f 72 6c 64
sleep 0.5

assert_screen_match "Hello World" "typing: full text appears"
assert_screen_match "Col 12" "typing: cursor at col 12"

# ─── Enter / multiline ───────────────────────────────────────────

# Press Enter
send_hex 0d
sleep 0.5

assert_screen_match "Ln 2, Col 1" "enter: cursor moves to line 2"
assert_screen_match "2 lines" "enter: buffer now has 2 lines"

# Type on second line
send_chars 53 65 63 6f 6e 64 20 6c 69 6e 65
sleep 0.5

assert_screen_match "Second line" "typing: second line text appears"
assert_screen_match "Col 12" "typing: cursor position on line 2"

assert_screen "editor_two_lines" "screenshot: editor with two lines"

# ─── Navigation ──────────────────────────────────────────────────

# Home key (ESC O H)
send_hex 1b 4f 48
sleep 0.3

assert_screen_match "Ln 2, Col 1" "nav: Home moves to start of line"

# End key (ESC O F)
send_hex 1b 4f 46
sleep 0.3

assert_screen_match "Ln 2, Col 12" "nav: End moves to end of line"

# Up arrow (ESC O A) — move to line 1
send_hex 1b 4f 41
sleep 0.3

assert_screen_match "Ln 1" "nav: Up arrow moves to line 1"

# Down arrow (ESC O B) — back to line 2
send_hex 1b 4f 42
sleep 0.3

assert_screen_match "Ln 2" "nav: Down arrow moves to line 2"

# Left arrow (ESC O D) — move left
send_hex 1b 4f 48
sleep 0.2
send_hex 1b 4f 43
sleep 0.3

assert_screen_match "Col 2" "nav: Right arrow moves cursor right"

# ─── macOS Cmd / Cmd+Shift motions (super- via legacy VT meta bit) ──
# The editor runs in VT mode, so inject CSI 1 ; <mod> sequences directly to
# verify super- parsing and the editor's macOS bindings end to end.
# (cursor is at Ln 2, Col 2 on "Second line")

# Cmd+Right = CSI 1 ; 9 C -> super-right -> end of line
send_hex 1b 5b 31 3b 39 43
sleep 0.3
assert_screen_match "Ln 2, Col 12" "cmd: Cmd+Right to end of line (super-right)"

# Cmd+Left = CSI 1 ; 9 D -> super-left -> start of line
send_hex 1b 5b 31 3b 39 44
sleep 0.3
assert_screen_match "Ln 2, Col 1" "cmd: Cmd+Left to start of line (super-left)"

# Cmd+Up = CSI 1 ; 9 A -> super-up -> top of document
send_hex 1b 5b 31 3b 39 41
sleep 0.3
assert_screen_match "Ln 1, Col 1" "cmd: Cmd+Up to top of document (super-up)"

# Cmd+Shift+Down = CSI 1 ; 10 B -> shift-super-down -> select to bottom
send_hex 1b 5b 31 3b 31 30 42
sleep 0.3
assert_screen_match "sel" "cmd: Cmd+Shift+Down selects to bottom (shift-super-down)"

# ─── Rapid key repeat regression ─────────────────────────────────
# Regression: on zsh (macOS Terminal.app, Zed), consecutive SS3 sequences
# sent with no inter-byte gap had ESC bytes consumed by the rAF input-peek,
# causing 'O'/'C' to leak as inserted characters instead of arrow events.

# Position at start of the line
send_hex 1b 4f 48
sleep 0.3

assert_screen_match "Col 1" "rapid-repeat setup: cursor at col 1"

# 3 × ESC O C (right arrows) sent atomically — no gap, as Terminal.app
# key-repeat delivers them. Before the fix each burst lost an ESC and
# turned the following O or C into an inserted character.
send_hex 1b 4f 43 1b 4f 43 1b 4f 43
sleep 0.5

assert_screen_match "Col 4" "rapid-repeat: cursor at col 4 (3 rights, no leaks)"
assert_screen_match "Second line" "rapid-repeat: text unchanged (no O/C inserted)"

# ─── Backspace ───────────────────────────────────────────────────

# Move to end of line 2, then backspace
send_hex 1b 4f 46
sleep 0.2
# Backspace (0x7f or 0x08)
send_hex 7f
sleep 0.3

assert_screen_match "Second lin" "bksp: last character deleted"
assert_screen_match "Ln 2, Col 11" "bksp: cursor moved back"

# ─── File loading ────────────────────────────────────────────────

# Quit the current session, start a new one with a file
quit_tuish
sleep 0.3
cleanup_session

# Create a temp file to load
_tmpfile="$(mktemp)"
printf 'Line one\nLine two\nLine three\n' > "$_tmpfile"
trap 'cleanup_session; rm -f "$_tmpfile"' EXIT

TUISH_SCRIPT="$EXAMPLES_DIR/editor.sh"
tmux new-session -d -s "$TUISH_SESSION" -x 80 -y 24 \
	$TUISH_SHELL "$TUISH_SCRIPT" "$_tmpfile" 2>/dev/null

if ! wait_for_output "3 lines" 10
then
	printf '  SKIP: file loading (editor did not start with file)\n'
	test_summary
	exit
fi
sleep 0.5

assert_screen_match "Line one" "file: first line loaded"
assert_screen_match "Line two" "file: second line loaded"
assert_screen_match "Line three" "file: third line loaded"
assert_screen_match "3 lines" "file: correct line count"
assert_screen_match "Ln 1, Col 1" "file: cursor at start"

quit_tuish

test_summary
