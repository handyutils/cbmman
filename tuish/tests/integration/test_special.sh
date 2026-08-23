#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Integration tests: special keys and edge cases via tmux PTY

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"
. "$TESTS_DIR/lib/tmux_helpers.sh"

trap 'cleanup_session' EXIT

printf 'Integration tests: special keys (%s)\n' "$TUISH_SHELL"

start_tuish_session

# --- Bare ESC (0x1b alone, with no following bytes) ---
# Note: bare ESC delivery through tmux is unreliable under zsh due to
# terminal driver buffering. The unit test covers the parsing logic.
# This integration test only runs under bash/ksh.
if test "$TUISH_SHELL" != "zsh"
then
	send_hex 1b
	if wait_for_output "esc" 5
	then
		_test_pass=$((_test_pass + 1))
		_test_total=$((_test_total + 1))
		printf '  PASS: bare ESC\n'
	else
		_test_fail=$((_test_fail + 1))
		_test_total=$((_test_total + 1))
		printf '  FAIL: bare ESC\n'
	fi
else
	printf '  SKIP: bare ESC (zsh+tmux PTY limitation)\n'
fi

# --- Tab (0x09) ---
assert_event "09" "tab" "tab"

# --- Enter / CR (0x0d) ---
# Note: CR delivery through tmux PTY is unreliable — the terminal driver
# may translate CR before it reaches the raw-mode read. The unit test
# covers the mapping (byte 13 → "enter").
# assert_event "0d" "enter" "enter"

# --- Ctrl+A (0x01) ---
assert_event "01" "ctrl-a" "ctrl-a"

# --- Ctrl+L (0x0c = 12 decimal) ---
assert_event "0c" "ctrl-l" "ctrl-l"

# --- Ctrl+Q via fallback (0x11 = 17 decimal) ---
assert_event "11" "ctrl-q" "ctrl-q (byte 0x11)"

# --- Ctrl+_ (0x1f = 31 decimal, Unit Separator) ---
assert_event "1f" "ctrl-_" "ctrl-_ (byte 0x1f)"

# --- Ctrl+Backslash (0x1c = 28 decimal) ---
assert_event "1c" "ctrl-bslash" "ctrl-bslash (byte 0x1c)"

# --- Ctrl+] (0x1d = 29 decimal) ---
assert_event "1d" "ctrl-]" "ctrl-] (byte 0x1d)"

# --- Ctrl+^ (0x1e = 30 decimal) ---
assert_event "1e" "ctrl-^" "ctrl-^ (byte 0x1e)"

# --- Backspace / DEL (0x7f = 127 decimal) ---
assert_event "7f" "bksp" "backspace"

# --- Ctrl+H / Ctrl+Bksp (0x08 = 8 decimal) ---
# VT mode maps byte 8 to ctrl-bksp (not ctrl-h)
assert_event "08" "ctrl-bksp" "ctrl-bksp (byte 0x08)"

# --- Alt+character (ESC followed by 'a' = 0x61) ---
assert_event "1b 61" "alt-a" "alt-a"

# --- Alt+character (ESC followed by 'A' = 0x41) ---
assert_event "1b 41" "alt-A" "alt-A"

# --- Alt+Ctrl+a (ESC followed by 0x01) ---
# Note: Alt+Ctrl delivery requires ESC + control byte atomically.
# Skip under zsh where ESC delivery is unreliable.
if test "$TUISH_SHELL" != "zsh"
then
	assert_event "1b 01" "ctrl-alt-a" "ctrl-alt-a"
else
	printf '  SKIP: alt-ctrl-a (zsh+tmux PTY limitation)\n'
fi

# --- Focus in: ESC [ I = 1b 5b 49 ---
assert_event "1b 5b 49" "focus-in" "focus in"

# --- Focus out: ESC [ O = 1b 5b 4f ---
assert_event "1b 5b 4f" "focus-out" "focus out"

# --- Paste start: ESC [ 200 ~ = 1b 5b 32 30 30 7e ---
assert_event "1b 5b 32 30 30 7e" "paste-start" "paste start"

# --- Paste end: ESC [ 201 ~ = 1b 5b 32 30 31 7e ---
assert_event "1b 5b 32 30 31 7e" "paste-end" "paste end"

# --- CSI u / kitty keyboard protocol ---
# CSI 97 u = ESC [ 9 7 u = 1b 5b 39 37 75
assert_event "1b 5b 39 37 75" "char a" "CSI u: plain a"

# CSI 122 ; 6 u = ESC [ 1 2 2 ; 6 u = 1b 5b 31 32 32 3b 36 75
assert_event "1b 5b 31 32 32 3b 36 75" "ctrl-shift-z" "CSI u: ctrl-shift-z"

# CSI 9 ; 5 u = ESC [ 9 ; 5 u = 1b 5b 39 3b 35 75
assert_event "1b 5b 39 3b 35 75" "ctrl-tab" "CSI u: ctrl-tab"

# CSI 13 ; 2 u = ESC [ 1 3 ; 2 u = 1b 5b 31 33 3b 32 75
assert_event "1b 5b 31 33 3b 32 75" "shift-enter" "CSI u: shift-enter"

# CSI 97 ; 5 : 3 u = ESC [ 9 7 ; 5 : 3 u = 1b 5b 39 37 3b 35 3a 33 75
assert_event "1b 5b 39 37 3b 35 3a 33 75" "ctrl-a-rel" "CSI u: ctrl-a release"

# --- Quit: Ctrl+W (0x17) should exit the script ---
quit_tuish
sleep 0.5

# Verify the tmux pane is no longer running the script
# (the shell should have exited or returned to prompt)
pane_pid=$(tmux display-message -t "$TUISH_SESSION" -p '#{pane_pid}' 2>/dev/null || echo "")
if test -z "$pane_pid"
then
	_test_pass=$((_test_pass + 1))
	_test_total=$((_test_total + 1))
	printf '  PASS: Ctrl+W quit (session ended)\n'
else
	# Check if the tui.sh process is still running
	if ps -p "$pane_pid" -o args= 2>/dev/null | grep -q "tui.sh"
	then
		_test_fail=$((_test_fail + 1))
		_test_total=$((_test_total + 1))
		printf '  FAIL: Ctrl+W quit (tui.sh still running)\n'
	else
		_test_pass=$((_test_pass + 1))
		_test_total=$((_test_total + 1))
		printf '  PASS: Ctrl+W quit (process exited)\n'
	fi
fi

test_summary
