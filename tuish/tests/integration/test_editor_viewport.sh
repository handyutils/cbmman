#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Integration tests: editor.sh viewport management and shell history
#
# Tests the editor's viewport modes (fixed/fullscreen), mode toggling,
# content preservation across mode switches, scrolling within a bounded
# viewport, and clean shell history preservation on exit.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"
. "$TESTS_DIR/lib/tmux_helpers.sh"
. "$TESTS_DIR/lib/screen_helpers.sh"

EXAMPLES_DIR="$(cd "$(dirname "$0")/../.." && pwd)/examples"
trap 'cleanup_session' EXIT

printf 'Integration tests: editor viewport (%s)\n' "$TUISH_SHELL"

# ─── Fixed viewport on startup ──────────────────────────────────

start_example_session "$EXAMPLES_DIR/editor.sh" "Ln 1, Col 1"

# The editor starts in fixed mode with 10 rows.  The status bar should
# show the "full screen" toggle hint, confirming we're NOT fullscreen.
assert_screen_match "full screen" "fixed: status shows 'full screen' toggle hint"

# In fixed mode the viewport occupies a region — the top of the terminal
# should NOT contain editor content.  Capture the screen and verify the
# status bar is not on row 1 (it would be on row 1 only in fullscreen).
_captured="$(capture_screen)"
_first_line="$(printf '%s\n' "$_captured" | head -1)"
_found_status_top=0
case "$_first_line" in
	*"Ln 1"*) _found_status_top=1;;
esac
if test $_found_status_top -eq 0
then
	_test_pass=$((_test_pass + 1))
	_test_total=$((_test_total + 1))
	printf '  PASS: fixed: status bar is NOT on terminal row 1\n'
else
	_test_fail=$((_test_fail + 1))
	_test_total=$((_test_total + 1))
	printf '  FAIL: fixed: status bar should not be on terminal row 1 in fixed mode\n'
	show_screen "$_captured" "captured"
fi

assert_screen "editor_fixed_startup" "screenshot: fixed mode startup"

# ─── Toggle to fullscreen (Alt+F) ──────────────────────────────

# Alt+F = ESC + 'f' sent together so the TUI recognises it as alt-f
send_hex 1b 66
sleep 1

assert_screen_match "short screen" "fullscreen: status shows 'short screen' toggle hint"
assert_screen_match "Ln 1, Col 1" "fullscreen: cursor position preserved"

# In fullscreen, the last line should be the status bar.
_captured="$(capture_screen)"
_last_line="$(printf '%s\n' "$_captured" | tail -1)"
_is_fullscreen=0
case "$_last_line" in
	*"Ln "*"Col "*) _is_fullscreen=1;;
esac
if test $_is_fullscreen -eq 1
then
	_test_pass=$((_test_pass + 1))
	_test_total=$((_test_total + 1))
	printf '  PASS: fullscreen: status bar on last terminal row\n'
else
	_test_fail=$((_test_fail + 1))
	_test_total=$((_test_total + 1))
	printf '  FAIL: fullscreen: status bar should be on last terminal row\n'
	show_screen "$_captured" "captured"
fi

assert_screen "editor_fullscreen" "screenshot: fullscreen mode"

# ─── Type in fullscreen ─────────────────────────────────────────

send_chars 46 75 6c 6c
sleep 0.3

assert_screen_match "Full" "fullscreen: typed text appears"
assert_screen_match "Col 5" "fullscreen: cursor tracks typing"

# ─── Toggle back to fixed (Alt+F) ──────────────────────────────

send_hex 1b 66
sleep 1

assert_screen_match "full screen" "toggle-back: status shows 'full screen' hint again"

# Text typed in fullscreen should persist after returning to fixed
assert_screen_match "Full" "toggle-back: text preserved after mode switch"
assert_screen_match "Col 5" "toggle-back: cursor position preserved"

assert_screen "editor_back_to_fixed" "screenshot: back to fixed after fullscreen"

# ─── Type more and verify content persists ──────────────────────

send_chars 73 63 72 65 65 6e
sleep 0.3

assert_screen_match "Fullscreen" "content: additional typing works after toggle"
assert_screen_match "Col 11" "content: cursor position correct"

# ─── Vertical scrolling in fixed viewport ───────────────────────

# Create multiple lines by pressing Enter repeatedly
_i=0
while test $_i -lt 12
do
	send_hex 0d    # Enter
	sleep 0.15
	_i=$((_i + 1))
done
sleep 0.5

assert_screen_match "Ln 13" "scroll: cursor on line 13 after 12 enters"
assert_screen_match "13 lines" "scroll: buffer has 13 lines"

# The viewport is 10 rows; with 13 lines we should be scrolled.
# First line ("Fullscreen") should NOT be visible since we scrolled past it.
_captured="$(capture_pane)"
_has_first=0
case "$_captured" in
	*Fullscreen*) _has_first=1;;
esac
if test $_has_first -eq 0
then
	_test_pass=$((_test_pass + 1))
	_test_total=$((_test_total + 1))
	printf '  PASS: scroll: first line scrolled out of view\n'
else
	_test_fail=$((_test_fail + 1))
	_test_total=$((_test_total + 1))
	printf '  FAIL: scroll: first line should be scrolled out of view\n'
	show_screen "$(capture_screen)" "captured"
fi

# ─── Ctrl+Home / Ctrl+End ──────────────────────────────────────

# Ctrl+Home: ESC [ 1 ; 5 H  (0x1b 0x5b 0x31 0x3b 0x35 0x48)
send_hex 1b 5b 31 3b 35 48
sleep 0.5

assert_screen_match "Ln 1, Col 1" "ctrl-home: jumped to start"
assert_screen_match "Fullscreen" "ctrl-home: first line visible after scroll-to-top"

# Ctrl+End: ESC [ 1 ; 5 F  (0x1b 0x5b 0x31 0x3b 0x35 0x46)
send_hex 1b 5b 31 3b 35 46
sleep 0.5

assert_screen_match "Ln 13" "ctrl-end: jumped to last line"

# PgUp should move up by roughly the viewport height (9 text rows)
# PgUp: ESC [ 5 ~ (0x1b 0x5b 0x35 0x7e)
send_hex 1b 5b 35 7e
sleep 0.5

# From line 13, PgUp with 9 text rows should land around line 4
assert_screen_match "Ln 4" "pgup: moved up by viewport height"

# PgDn should go back toward the end
# PgDn: ESC [ 6 ~ (0x1b 0x5b 0x36 0x7e)
send_hex 1b 5b 36 7e
sleep 0.5

assert_screen_match "Ln 13" "pgdn: moved back to last line"

# ─── Clean up direct-launch session ─────────────────────────────

quit_tuish
sleep 0.3
cleanup_session

# ─── Shell history preservation ─────────────────────────────────

# Start a shell, run some commands, launch the editor, quit, and verify
# that previous shell output is preserved.

tmux new-session -d -s "$TUISH_SESSION" -x 80 -y 24 \
	$TUISH_SHELL 2>/dev/null

# Wait for shell prompt
sleep 1

# Type a marker command — echo a distinctive string
tmux send-keys -t "$TUISH_SESSION" "echo MARKER_BEFORE_EDITOR" Enter 2>/dev/null
sleep 0.5

if ! wait_for_output "MARKER_BEFORE_EDITOR" 5
then
	printf '  SKIP: shell history (shell did not start)\n'
	test_summary
	exit
fi

# Run the editor
tmux send-keys -t "$TUISH_SESSION" "$TUISH_SHELL $EXAMPLES_DIR/editor.sh" Enter 2>/dev/null

if ! wait_for_output "Ln 1, Col 1" 10
then
	printf '  SKIP: shell history (editor did not start from shell)\n'
	test_summary
	exit
fi
sleep 0.5

# Type something in the editor
send_chars 48 69
sleep 0.3
assert_screen_match "Hi" "history: typed in editor"

# Quit the editor
quit_tuish
sleep 1

# After quitting, the editor viewport should be cleared — no status bar
# or tilde lines visible.
_post_captured="$(capture_pane)"
_has_editor_ui=0
case "$_post_captured" in
	*"alt+f"*|*"ctrl+w: quit"*) _has_editor_ui=1;;
esac
if test $_has_editor_ui -eq 0
then
	_test_pass=$((_test_pass + 1))
	_test_total=$((_test_total + 1))
	printf '  PASS: history: editor viewport cleared after exit\n'
else
	_test_fail=$((_test_fail + 1))
	_test_total=$((_test_total + 1))
	printf '  FAIL: history: editor viewport should be cleared after exit\n'
	show_screen "$(capture_screen)" "captured"
fi

# The marker from before should still be visible
# (either on screen or in scrollback via capture -S).
_history_captured="$(tmux capture-pane -t "$TUISH_SESSION" -p -S -50 2>/dev/null)"
_marker_found=0
case "$_history_captured" in
	*MARKER_BEFORE_EDITOR*) _marker_found=1;;
esac
if test $_marker_found -eq 1
then
	_test_pass=$((_test_pass + 1))
	_test_total=$((_test_total + 1))
	printf '  PASS: history: shell output preserved after editor exit\n'
else
	_test_fail=$((_test_fail + 1))
	_test_total=$((_test_total + 1))
	printf '  FAIL: history: shell output lost after editor exit\n'
	show_screen "$(printf '%s' "$_history_captured")" "scrollback"
fi

# The shell prompt should be usable again — run another command
tmux send-keys -t "$TUISH_SESSION" "echo MARKER_AFTER_EDITOR" Enter 2>/dev/null
sleep 0.5

if wait_for_output "MARKER_AFTER_EDITOR" 5
then
	_test_pass=$((_test_pass + 1))
	_test_total=$((_test_total + 1))
	printf '  PASS: history: shell prompt functional after editor exit\n'
else
	_test_fail=$((_test_fail + 1))
	_test_total=$((_test_total + 1))
	printf '  FAIL: history: shell prompt not functional after editor exit\n'
	show_screen "$(capture_screen)" "captured"
fi

# ─── Clean exit ─────────────────────────────────────────────────

test_summary
