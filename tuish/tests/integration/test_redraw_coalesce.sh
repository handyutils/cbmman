#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Integration tests: redraw coalescing (rAF) under glued input bursts
#
# Drives examples/slow_menu.sh, which shows live `events` / `redraws`
# counters with a deliberately slow draw. A burst of keys delivered in
# one write must coalesce into fewer redraws than events — both for
# plain characters and for glued escape sequences (held-arrow
# autorepeat, the regression: each glued `ESC [ B` used to trigger a
# full immediate render).
#
# Flake rules: bursts are sent as ONE send-keys -H invocation so the
# bytes arrive glued (per-key sends don't glue and risk esc-timeout
# misparse). Redraw counts are asserted as inequalities, never exact
# values — a scheduling gap mid-burst legitimately renders once early.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"
. "$TESTS_DIR/lib/tmux_helpers.sh"
. "$TESTS_DIR/lib/screen_helpers.sh"

EXAMPLES_DIR="$(cd "$(dirname "$0")/../.." && pwd)/examples"
trap 'cleanup_session' EXIT

printf 'Integration tests: redraw coalescing (%s)\n' "$TUISH_SHELL"

# ─── Helpers ────────────────────────────────────────────────────

get_redraws () {
	capture_pane | sed -n 's/.*redraws: \([0-9][0-9]*\).*/\1/p' | head -1
}

# Numeric comparison with screen dump on failure.
#   $1 = actual  $2 = bound  $3 = label
assert_lt () {
	_test_total=$((_test_total + 1))
	if test "${1:-}" -lt "$2" 2>/dev/null
	then
		_test_pass=$((_test_pass + 1))
		printf '  PASS: %s\n' "$3"
	else
		_test_fail=$((_test_fail + 1))
		printf '  FAIL: %s (%s not < %s)\n' "$3" "${1:-?}" "$2"
		show_screen "$(capture_screen)" "captured"
	fi
}

assert_ge () {
	_test_total=$((_test_total + 1))
	if test "${1:-}" -ge "$2" 2>/dev/null
	then
		_test_pass=$((_test_pass + 1))
		printf '  PASS: %s\n' "$3"
	else
		_test_fail=$((_test_fail + 1))
		printf '  FAIL: %s (%s not >= %s)\n' "$3" "${1:-?}" "$2"
		show_screen "$(capture_screen)" "captured"
	fi
}

# ─── Setup ──────────────────────────────────────────────────────

start_example_session "$EXAMPLES_DIR/slow_menu.sh" "mode:"

# Warmup: zsh can lose first input after idle event (space is unbound)
send_hex 20
sleep 0.5

assert_screen_match "mode: deferred" "startup: deferred mode active"
assert_screen_match "events: 0" "startup: no events counted yet"

# ─── Section 1: glued character burst (baseline, works pre-fix) ──

_r_before="$(get_redraws)"

# 10 × 'j' in one write — glued in the read buffer
send_hex 6a 6a 6a 6a 6a 6a 6a 6a 6a 6a

# The post-burst redraw is what paints the final counter, so seeing
# it implies the coalesced render fired (allow for 1s esc/idle
# timeouts on second-resolution shells).
assert_screen_match "events: 10" "chars: all 10 events dispatched" 8
sleep 1

_r_after="$(get_redraws)"
_delta=$((_r_after - _r_before))
assert_ge "$_delta" 1 "chars: at least one redraw fired"
assert_lt "$_delta" 10 "chars: redraws coalesced (fewer than events)"

# ─── Section 2: glued arrow burst (the regression) ──────────────

_r_before="$(get_redraws)"

# 6 × ESC [ B (down arrow) in one write — held-key autorepeat shape.
# Pre-fix each glued sequence rendered immediately (delta == 6).
send_hex 1b 5b 42 1b 5b 42 1b 5b 42 1b 5b 42 1b 5b 42 1b 5b 42

assert_screen_match "events: 16" "arrows: all 6 events dispatched" 8
sleep 1

_r_after="$(get_redraws)"
_delta=$((_r_after - _r_before))
assert_ge "$_delta" 1 "arrows: at least one redraw fired"
assert_lt "$_delta" 6 "arrows: redraws coalesced (fewer than events)"

# ─── Teardown ───────────────────────────────────────────────────

send_hex 71  # 'q' quits slow_menu
sleep 0.3
cleanup_session

test_summary
