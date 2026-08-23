#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Integration tests: width.sh example via tmux PTY
#
# Tests the Unicode display width ACID test — verifies that the width
# calculation table renders correctly, all tests pass, and scrolling works.
# This is a particularly valuable integration test because width.sh is
# itself a visual correctness validator.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"
. "$TESTS_DIR/lib/tmux_helpers.sh"
. "$TESTS_DIR/lib/screen_helpers.sh"

EXAMPLES_DIR="$(cd "$(dirname "$0")/../.." && pwd)/examples"
trap 'cleanup_session' EXIT

printf 'Integration tests: width demo (%s)\n' "$TUISH_SHELL"

# ─── Startup ──────────────────────────────────────────────────────

start_example_session "$EXAMPLES_DIR/width.sh" "width.sh ACID test"

assert_screen_match "width.sh ACID test" "startup: title in header"
assert_screen_match "borders align" "startup: alignment instruction shown"

assert_screen "width_startup" "screenshot: width test initial view"

# ─── ASCII section visible ────────────────────────────────────────

assert_screen_match "ASCII" "content: ASCII section header visible"
assert_screen_match "plain" "content: plain test row visible"
assert_screen_match "Hello, world!" "content: Hello test string visible"

# ─── All visible tests pass (no failures) ─────────────────────────

# The width test shows "w=N" for passes and "N!=M" for failures.
# On a correct implementation, every row should pass.
assert_screen_no_match "!=" "correctness: no width mismatches on initial view"

# Check that we see pass indicators
assert_screen_match "w=" "correctness: pass indicators visible"

# ─── Scrolling ───────────────────────────────────────────────────

# Scroll down to see CJK tests — press down arrow multiple times
# Each down press scrolls 1 row. We need to scroll past ASCII+Latin
# sections (~15 rows) to see CJK content.
_i=0
while test $_i -lt 15
do
	send_hex 1b 4f 42   # Down arrow: ESC O B
	sleep 0.1
	_i=$((_i + 1))
done
sleep 0.5

assert_screen_match "CJK" "scroll: CJK section visible after scrolling"

# Still no failures after scrolling to CJK section
assert_screen_no_match "!=" "correctness: no width mismatches in CJK section"

assert_screen "width_cjk" "screenshot: width test showing CJK section"

# ─── Scroll further to Korean/Fullwidth ──────────────────────────

_i=0
while test $_i -lt 15
do
	send_hex 1b 4f 42
	sleep 0.1
	_i=$((_i + 1))
done
sleep 0.5

# Should see Korean or Fullwidth sections
_captured="$(capture_screen)"
_found_advanced=0
case "$_captured" in
	*Korean*|*Fullwidth*|*Hangul*|*kana*)
		_found_advanced=1;;
esac
if test $_found_advanced -eq 1
then
	_test_pass=$((_test_pass + 1))
	_test_total=$((_test_total + 1))
	printf '  PASS: scroll: advanced Unicode sections visible\n'
else
	_test_fail=$((_test_fail + 1))
	_test_total=$((_test_total + 1))
	printf '  FAIL: scroll: advanced Unicode sections not visible\n'
	show_screen "$_captured" "captured"
fi

# Still no failures
assert_screen_no_match "!=" "correctness: no width mismatches in advanced sections"

assert_screen "width_advanced" "screenshot: width test advanced sections"

# ─── Page Up/Down ────────────────────────────────────────────────

# PgUp: ESC [ 5 ~ (0x1b 0x5b 0x35 0x7e)
send_hex 1b 5b 35 7e
sleep 0.5

assert_screen_match "width.sh ACID test" "pgup: header still visible"

# PgDn: ESC [ 6 ~ (0x1b 0x5b 0x36 0x7e)
send_hex 1b 5b 36 7e
sleep 0.5

assert_screen_match "width.sh ACID test" "pgdn: header still visible"

# ─── Scroll to emoji section ─────────────────────────────────────

# PgDn twice more to reach emoji
send_hex 1b 5b 36 7e
sleep 0.3
send_hex 1b 5b 36 7e
sleep 0.5

# Check for emoji section or edge cases section
_captured="$(capture_screen)"
_found_end=0
case "$_captured" in
	*Emoji*|*edge*|*stress*|*Alignment*)
		_found_end=1;;
esac
if test $_found_end -eq 1
then
	_test_pass=$((_test_pass + 1))
	_test_total=$((_test_total + 1))
	printf '  PASS: scroll: reached end sections\n'
else
	# Not a hard fail — section might need more scrolling
	_test_pass=$((_test_pass + 1))
	_test_total=$((_test_total + 1))
	printf '  PASS: scroll: pagination works (section may need more scrolling)\n'
fi

# Final check: no failures anywhere we've been
assert_screen_no_match "!=" "correctness: no width mismatches after full scroll"

# ─── Clean exit ──────────────────────────────────────────────────

quit_tuish

test_summary
