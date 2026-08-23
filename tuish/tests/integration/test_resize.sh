#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Integration tests: terminal resize behaviour via tmux PTY
#
# Tests viewport resize handling across grow, fixed, and fullscreen modes
# by programmatically resizing the tmux window and verifying visual outcomes.
# The PTY driver sends SIGWINCH automatically when tmux resizes the window.
#
# Note: resize targets must be wide enough for the UI under test.  The
# debug.sh header is ~73 chars; the editor status bar drops the help
# text below ~65 cols.  Keep minimum width at 70 for content assertions.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"
. "$TESTS_DIR/lib/tmux_helpers.sh"
. "$TESTS_DIR/lib/screen_helpers.sh"

EXAMPLES_DIR="$(cd "$(dirname "$0")/../.." && pwd)/examples"
trap 'cleanup_session' EXIT

printf 'Integration tests: terminal resize (%s)\n' "$TUISH_SHELL"

# ─── Helper ─────────────────────────────────────────────────────

# Resize the tmux window and wait for the app to process SIGWINCH.
#   $1 = width
#   $2 = height
resize_window () {
	tmux resize-window -x "$1" -y "$2" -t "$TUISH_SESSION" 2>/dev/null
	sleep 1
}

# ─── Section 1: Grow mode size reporting (debug.sh) ─────────────

start_example_session "$EXAMPLES_DIR/debug.sh" "tui.sh debug"

assert_screen_match "80x24" "debug startup: shows 80x24"

# Send a key to force the grow-mode viewport to establish TUISH_VIEW_ROWS > 0
# (the idle event draws the header but doesn't call tuish_grow, so the first
# resize would skip the header redraw if VIEW_ROWS is still 0).
send_hex 61
sleep 0.5

# Shrink height (keep width ≥74 so the header doesn't wrap)
resize_window 80 18
assert_screen_match "80x18" "debug resize: shrink to 80x18"

# Grow back
resize_window 80 24
assert_screen_match "80x24" "debug resize: grow back to 80x24"

# Width-only change
resize_window 100 24
assert_screen_match "100x24" "debug resize: width-only change to 100x24"

# Shrink width+height (the header wraps at narrow widths, but we can
# still check the dimension string by looking for the NxN pattern)
resize_window 80 8
assert_screen_match "80x8" "debug resize: small terminal 80x8"

# Grow from small to large
resize_window 120 30
assert_screen_match "120x30" "debug resize: grow from small to 120x30"

# Content preservation: send a char, then resize and verify the header
# survived.  In grow mode, old event lines may scroll out of view during
# viewport rearrangement, so we check the header rather than old events.
send_hex 5a
sleep 0.5
assert_screen_match "key:char Z" "debug pre-resize: event Z logged"

resize_window 80 24
assert_screen_match "80x24" "debug resize: dimensions updated to 80x24"

# Header integrity after multiple resizes
assert_screen_match "tui.sh debug" "debug resize: header title intact"
assert_screen_match "quit: ctrl+w" "debug resize: quit hint intact"

assert_screen "resize_debug_final" "screenshot: debug after resize cycle"

quit_tuish
sleep 0.3
cleanup_session

# ─── Section 2: Fixed mode stability (editor.sh) ────────────────

start_example_session "$EXAMPLES_DIR/editor.sh" "Ln 1, Col 1"

# Type recognizable content
send_chars 52 65 73 69 7a 65 54 65 73 74
sleep 0.5

assert_screen_match "ResizeTest" "editor setup: typed text visible"
assert_screen_match "Col 11" "editor setup: cursor position correct"

# Shrink height
resize_window 80 16
assert_screen_match "ResizeTest" "editor shrink: text preserved"
assert_screen_match "full screen" "editor shrink: status bar mode hint present"
assert_screen_match "Ln 1" "editor shrink: cursor line shown in status"

# Grow height back
resize_window 80 24
assert_screen_match "ResizeTest" "editor grow: text preserved"
assert_screen_match "full screen" "editor grow: status bar present"

# Width change
resize_window 100 24
assert_screen_match "ResizeTest" "editor width: text visible after width change"
assert_screen_match "ctrl+w: quit" "editor width: status bar present"

# Shrink to narrow but still usable width
resize_window 50 10
assert_screen_match "ResizeTest" "editor narrow: text visible at 50 cols"
assert_screen_match "1 lines" "editor narrow: line count in status bar"

# Restore to normal
resize_window 80 24
assert_screen_match "ResizeTest" "editor restore: text visible after restore"
assert_screen_match "full screen" "editor restore: mode hint visible"

assert_screen "resize_editor_fixed" "screenshot: editor fixed mode after resize cycle"

quit_tuish
sleep 0.3
cleanup_session

# ─── Section 3: Fullscreen mode resize (editor.sh) ──────────────

start_example_session "$EXAMPLES_DIR/editor.sh" "Ln 1, Col 1"

# Toggle to fullscreen (Alt+F = ESC + 'f')
send_hex 1b 66
sleep 1

assert_screen_match "short screen" "fullscreen setup: in fullscreen mode"

# Type content
send_chars 46 75 6c 6c
sleep 0.3
assert_screen_match "Full" "fullscreen setup: typed text visible"

# Grow terminal
resize_window 100 30
assert_screen_match "Full" "fullscreen grow: text preserved"
assert_screen_match "short screen" "fullscreen grow: mode hint present"

# Status bar should be on the last line of the new size
_captured="$(capture_screen)"
_last_line="$(printf '%s\n' "$_captured" | tail -1)"
_has_status=0
case "$_last_line" in
	*"Ln "*"Col "*) _has_status=1;;
esac
if test $_has_status -eq 1
then
	_test_pass=$((_test_pass + 1))
	_test_total=$((_test_total + 1))
	printf '  PASS: fullscreen grow: status bar on last row of 30-line terminal\n'
else
	_test_fail=$((_test_fail + 1))
	_test_total=$((_test_total + 1))
	printf '  FAIL: fullscreen grow: status bar should be on last row\n'
	show_screen "$_captured" "captured"
fi

# Shrink terminal (keep width ≥70 so status bar keeps help text)
resize_window 80 15
assert_screen_match "Full" "fullscreen shrink: text preserved"
assert_screen_match "short screen" "fullscreen shrink: mode hint present"

assert_screen "resize_editor_fullscreen" "screenshot: fullscreen editor after resize"

quit_tuish
sleep 0.3
cleanup_session

# ─── Section 4: Rapid resize cycle (debug.sh) ───────────────────

start_example_session "$EXAMPLES_DIR/debug.sh" "tui.sh debug"

# Fire 4 resizes in sequence
resize_window 80 15
resize_window 100 30
resize_window 80 10
resize_window 80 24

# After the dust settles, verify the app is still alive and correct
assert_screen_match "80x24" "rapid resize: final size 80x24 shown"
assert_screen_match "tui.sh debug" "rapid resize: header title intact"

assert_screen "resize_rapid_final" "screenshot: debug after rapid resize cycle"

quit_tuish
sleep 0.3
cleanup_session

# ─── Section 5: Mode toggle + resize interaction (editor.sh) ────

start_example_session "$EXAMPLES_DIR/editor.sh" "Ln 1, Col 1"

# Type content in fixed mode
send_chars 4d 6f 64 65
sleep 0.3
assert_screen_match "Mode" "mode-toggle setup: typed text"

# Toggle to fullscreen
send_hex 1b 66
sleep 1
assert_screen_match "short screen" "mode-toggle: entered fullscreen"

# Resize while in fullscreen
resize_window 90 28
assert_screen_match "Mode" "mode-toggle: text preserved after fullscreen resize"

# Toggle back to fixed
send_hex 1b 66
sleep 1
assert_screen_match "full screen" "mode-toggle: back to fixed after resize"
assert_screen_match "Mode" "mode-toggle: text preserved after mode switch + resize"

assert_screen "resize_mode_toggle" "screenshot: editor after mode-switch + resize"

quit_tuish

# ─── Done ────────────────────────────────────────────────────────

test_summary
