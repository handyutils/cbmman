#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Integration tests: debug.sh example via tmux PTY
#
# Tests the event inspector — header display, event logging with
# incrementing counter, different event types, and raw code display.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"
. "$TESTS_DIR/lib/tmux_helpers.sh"
. "$TESTS_DIR/lib/screen_helpers.sh"

EXAMPLES_DIR="$(cd "$(dirname "$0")/../.." && pwd)/examples"
trap 'cleanup_session' EXIT

printf 'Integration tests: debug example (%s)\n' "$TUISH_SHELL"

# ─── Startup ──────────────────────────────────────────────────────

start_example_session "$EXAMPLES_DIR/debug.sh" "tui.sh debug"

assert_screen_match "tui.sh debug" "startup: header title present"
assert_screen_match "quit: ctrl+w" "startup: quit hint in header"
assert_screen_match "80x24" "startup: terminal size shown"

# ─── Character events ────────────────────────────────────────────

# Send 'a' (0x61)
send_hex 61
sleep 0.5

assert_screen_match "key:char a" "event: character 'a' logged"

# Send 'Z' (0x5a)
send_hex 5a
sleep 0.5

assert_screen_match "key:char Z" "event: character 'Z' logged"

# Send '5' (0x35)
send_hex 35
sleep 0.5

assert_screen_match "key:char 5" "event: character '5' logged"

# ─── Special key events ──────────────────────────────────────────

# Space (0x20) — should show as "key:space"
send_hex 20
sleep 0.5

assert_screen_match "key:space" "event: space key logged"

# Tab (0x09)
send_hex 09
sleep 0.5

assert_screen_match "key:tab" "event: tab key logged"

# Enter (0x0d)
send_hex 0d
sleep 0.5

assert_screen_match "key:enter" "event: enter key logged"

# ─── Arrow key events ────────────────────────────────────────────

# Up arrow: ESC O A (0x1b 0x4f 0x41)
send_hex 1b 4f 41
sleep 0.5

assert_screen_match "key:up" "event: up arrow logged"

# Down arrow: ESC O B
send_hex 1b 4f 42
sleep 0.5

assert_screen_match "key:down" "event: down arrow logged"

# ─── Counter increments ──────────────────────────────────────────

# At this point we've sent ~8 events (plus warmup).
# Verify that the counter is incrementing by checking for a
# multi-digit count in the output.
_captured="$(capture_screen)"
_has_counter=0
case "$_captured" in
	*[0-9][0-9]*key:*) _has_counter=1;;
esac
if test $_has_counter -eq 1
then
	_test_pass=$((_test_pass + 1))
	_test_total=$((_test_total + 1))
	printf '  PASS: event counter is incrementing\n'
else
	_test_fail=$((_test_fail + 1))
	_test_total=$((_test_total + 1))
	printf '  FAIL: event counter not incrementing\n'
	show_screen "$_captured" "captured"
fi

# ─── Display width annotation ────────────────────────────────────

# Character events should show display width: "(w:1)" for ASCII
_captured="$(capture_screen)"
_has_width=0
case "$_captured" in
	*'(w:'*) _has_width=1;;
esac
if test $_has_width -eq 1
then
	_test_pass=$((_test_pass + 1))
	_test_total=$((_test_total + 1))
	printf '  PASS: character events show display width\n'
else
	_test_fail=$((_test_fail + 1))
	_test_total=$((_test_total + 1))
	printf '  FAIL: character events missing display width\n'
	show_screen "$_captured" "captured"
fi

# ─── Raw code display ─────────────────────────────────────────────

# Raw byte codes are shown in brackets. The exact values differ between
# shells (e.g. enter: [E 10] in bash vs [E 13] in zsh), so we just
# verify the bracket format appears.
assert_screen_match "[C a]" "raw: character raw codes shown in brackets"

# ─── Modifier key events ─────────────────────────────────────────

# Ctrl+A (0x01)
send_hex 01
sleep 0.5

assert_screen_match "key:ctrl-a" "event: ctrl-a logged"

# F1: ESC O P (0x1b 0x4f 0x50)
send_hex 1b 4f 50
sleep 0.5

assert_screen_match "key:f1" "event: F1 logged"

# ─── Clean exit ──────────────────────────────────────────────────

quit_tuish

test_summary
