#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Integration tests: boxes.sh example via tmux PTY
#
# Tests box drawing demo — rendering, page switching, backend toggle,
# scrolling, and visual correctness of box characters.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"
. "$TESTS_DIR/lib/tmux_helpers.sh"
. "$TESTS_DIR/lib/screen_helpers.sh"

EXAMPLES_DIR="$(cd "$(dirname "$0")/../.." && pwd)/examples"
trap 'cleanup_session' EXIT

printf 'Integration tests: boxes example (%s)\n' "$TUISH_SHELL"

# ─── Startup: light page ─────────────────────────────────────────

start_example_session "$EXAMPLES_DIR/boxes.sh" "boxes.sh"

assert_screen_match "light" "startup: light style shown in header"
assert_screen_match "unicode" "startup: unicode backend active"
assert_screen_match "boxes.sh" "startup: title in header"

assert_screen "boxes_light" "screenshot: light page"

# ─── Box character verification (unicode backend) ────────────────

# Light style uses these Unicode box-drawing characters
_captured="$(capture_screen)"
_found_box=0
# Check for at least some box-drawing content (borders or labels)
case "$_captured" in
	*default*) _found_box=1;;
esac
if test $_found_box -eq 1
then
	_test_pass=$((_test_pass + 1))
	_test_total=$((_test_total + 1))
	printf '  PASS: light page renders box content\n'
else
	_test_fail=$((_test_fail + 1))
	_test_total=$((_test_total + 1))
	printf '  FAIL: light page missing box content\n'
	show_screen "$_captured" "captured"
fi

# ─── Page switching ──────────────────────────────────────────────

# Switch to heavy page ('n' = 0x6e)
send_hex 6e
sleep 0.5

assert_screen_match "heavy" "page: switched to heavy style"
assert_screen "boxes_heavy" "screenshot: heavy page"

# Switch to double page
send_hex 6e
sleep 0.5

assert_screen_match "double" "page: switched to double style"
assert_screen "boxes_double" "screenshot: double page"

# Switch to rounded page
send_hex 6e
sleep 0.5

assert_screen_match "rounded" "page: switched to rounded style"
assert_screen "boxes_rounded" "screenshot: rounded page"

# Switch to mixed page
send_hex 6e
sleep 0.5

assert_screen_match "mixed" "page: switched to mixed style"
assert_screen "boxes_mixed" "screenshot: mixed page"

# Wrap around back to light
send_hex 6e
sleep 0.5

assert_screen_match "light" "page: wrapped back to light"

# ─── Previous page ───────────────────────────────────────────────

# 'p' = 0x70 — navigates backward through pages
# (boxes.sh uses (_bx_page + 3) % 5, so from light(0) it goes to rounded(3))
send_hex 70
sleep 0.5

assert_screen_match "rounded" "page: 'p' navigates backward from light"

# Navigate forward back to light: rounded(3) -> mixed(4) -> light(0)
send_hex 6e
sleep 0.3
send_hex 6e
sleep 0.5

assert_screen_match "light" "page: returned to light after p+n+n"

# ─── Backend toggle ──────────────────────────────────────────────

# Toggle to ASCII backend ('b' = 0x62)
send_hex 62
sleep 0.5

assert_screen_match "ascii" "backend: toggled to ascii"
assert_screen "boxes_ascii" "screenshot: light page in ASCII mode"

# Toggle back to Unicode — wait for redraw to finish before sending
sleep 0.5
send_hex 62

assert_screen_match "unicode" "backend: toggled back to unicode" 5

# ─── Scrolling ───────────────────────────────────────────────────

# Scroll down ('j' = 0x6a) — three presses to move content (3 rows each)
send_hex 6a
sleep 0.3
send_hex 6a
sleep 0.3
send_hex 6a
sleep 0.5

# Header always stays; content scrolls
assert_screen_match "boxes.sh" "scroll: header still visible after scroll"
assert_screen "boxes_scrolled" "screenshot: light page scrolled"

# Scroll back up ('k' = 0x6b) — same number of presses
send_hex 6b
sleep 0.3
send_hex 6b
sleep 0.3
send_hex 6b
sleep 0.5

assert_screen_match "default" "scroll: back to top shows default label"

# ─── Clean exit ──────────────────────────────────────────────────

quit_tuish

test_summary
