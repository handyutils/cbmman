#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for the burst tick: the guarantee that a held key cannot stop the clock.
#
# An idle event is not a timer, it is `read -t<interval>` timing out. So the tick fires
# while a key is held only if the idle interval is SHORTER than the terminal's autorepeat
# interval; above it, a byte is always waiting before the timeout lands and the clock stops
# dead for the whole hold. tuish_run counts complete events since the last real idle and
# injects one when the count says no read has timed out in too long.
#
# These drive the REAL tuish_run loop against a scripted reader — the interleaving of bytes
# and timeouts is the entire subject, so a stub of the loop itself would test nothing.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/ord.sh"
. "$TESTS_DIR/../src/tui.sh"
. "$TESTS_DIR/../src/term.sh"
. "$TESTS_DIR/../src/event.sh"
. "$TESTS_DIR/../src/hid.sh"


# Exercise the SHIPPED configuration. tuish_fnfix normally fires from tuish_init, which unit
# tests deliberately never call (they stub the device) — so without this, every suite here
# would validate the framework with its ksh `local` still leaking, i.e. not the library that
# actually runs. It is a no-op on every shell whose `local` already works.
command -v tuish_fnfix >/dev/null 2>&1 && tuish_fnfix

_tuish_out () { :; }

printf 'Unit tests: the burst tick (a held key cannot stop the clock)\n'

# The script is a string: any other character is a byte that arrives with no wait, and 'T'
# is the read timing out (a real idle). Exhausted, it quits the loop — which costs one
# trailing idle, because tuish_run tests _tuish_quit at the TOP of the next iteration.
_feed=''
_log=''

_drive ()   # $1 = script
{
	_feed="$1"
	_log=''
	_tuish_burst=0
	_tuish_pending_byte=''
	_tuish_noinput=no
	tuish_run
}

_tuish_idle_wait ()
{
	if test -z "$_feed"; then _tuish_quit=yes; return 1; fi
	case "$_feed" in
		T*) _feed="${_feed#T}"; return 1;;
	esac
	_tuish_byte="${_feed%"${_feed#?}"}"
	_feed="${_feed#?}"
	return 0
}
# The escape FSM reads its own body through _tuish_get_byte, so it has to draw from the
# SAME feed — stub it away and `ESC [ B` decodes as three events instead of one arrow,
# which is the opposite of what the sequence test is trying to pin.
_tuish_get_byte ()
{
	case "$_feed" in
		''|T*) return 1;;
	esac
	_tuish_byte="${_feed%"${_feed#?}"}"
	_feed="${_feed#?}"
	return 0
}
_tuish_peek_byte () { return 1; }

# Log a letter per dispatched event: I for an idle, E for anything else.
_on_event ()
{
	case "$TUISH_EVENT_KIND" in
		idle) _log="${_log}I";;
		*)    _log="${_log}E";;
	esac
}
tuish_on_event () { _on_event; }

# --- Healthy interleaving never injects a tick -----------------------------------
# byte, timeout, byte, timeout: the read IS timing out, so the clock is already being paid
# and the count never reaches 2. The tick rate must be exactly what it was before the burst
# logic existed — this is the assertion that keeps the guarantee from becoming a tax.
TUISH_BURST_MAX=2
_drive 'aTaTaT'
assert_eq "$_log" "IEIEIEII" "healthy: a natural idle between bytes injects nothing extra"

# --- A sustained burst injects the tick the reader is not delivering --------------
# Three bytes, no timeout anywhere: the read never times out, so before this the app got
# ZERO ticks for the whole hold. Now the 2nd event owes one.
_drive 'aaa'
assert_eq "$_log" "IEIEEI" "burst: a tick is injected once two events pass with no timeout"

# --- The injected tick lands BETWEEN events, never mid-sequence -------------------
# An arrow is ESC [ B — three bytes, one event, one loop iteration. The FSM reads its own
# body, so the count moves once per EVENT and a held arrow banks credit like a held letter.
# An idle injected inside the FSM would split the ESC from its body.
_esc=$(printf '\033')
_drive "${_esc}[B${_esc}[B${_esc}[B"
assert_eq "$_log" "IEIEEI" "burst: an escape sequence counts once — as one event, not three bytes"

# --- A timeout mid-burst resets the debt ------------------------------------------
_drive 'aaTaa'
assert_eq "$_log" "IEIEIEIEI" "burst: a real idle clears the count, so the next pair starts fresh"

# --- The threshold is honoured ----------------------------------------------------
# Six events, MAX=3: a tick before the 3rd and before the 6th. Two injected, not six.
TUISH_BURST_MAX=3
_drive 'aaaaaa'
assert_eq "$_log" "IEEIEEEIEI" "burst: fires every MAX events, not more often"

# A threshold of 1 would fire after every byte — which is why the default is 2. Pinned
# because it is the knob's degenerate end, and it must still behave predictably.
TUISH_BURST_MAX=1
_drive 'aa'
assert_eq "$_log" "IIEIEI" "burst: MAX=1 ticks before every event"
TUISH_BURST_MAX=2

# --- The count does not leak across runs ------------------------------------------
_drive 'a'
_first="$_log"
_drive 'a'
assert_eq "$_log" "$_first" "burst: tuish_run starts each loop with a clean count"

test_summary
