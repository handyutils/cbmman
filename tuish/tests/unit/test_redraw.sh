#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for redraw scheduling (tuish_request_redraw, tuish_on_redraw)

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

_captured=''
_tuish_out () { _captured="${_captured}${1:-}"; }
_event_log=''
_redraw_count=0
_redraw_level=''

tuish_on_event () { _event_log="${_event_log}E"; }
tuish_on_redraw () { _redraw_count=$((_redraw_count + 1)); _redraw_level="$1"; _event_log="${_event_log}R"; }

reset_state () {
	TUISH_EVENT=''
	TUISH_EVENT_KIND=''
	TUISH_RAW=''
	TUISH_MOUSE_X=0
	TUISH_MOUSE_Y=0
	_tuish_held=''
	_tuish_redraw_requested=0
	_tuish_redraw_level=0
	_tuish_raf_inhibit=0
	_tuish_raf_defers=0
	_tuish_pending_byte=''
	_event_log=''
	_redraw_count=0
	_redraw_level=''
	_captured=''
}

printf 'Unit tests: redraw scheduling\n'

# --- tuish_request_redraw sets flag ---
reset_state
tuish_request_redraw
assert_eq "$_tuish_redraw_requested" "1" "request_redraw sets flag"

# --- tuish_request_redraw defaults to level -1 ---
reset_state
tuish_request_redraw
assert_eq "$_tuish_redraw_level" "-1" "request_redraw defaults to level -1"

# --- tuish_request_redraw with explicit level ---
reset_state
tuish_request_redraw 2
assert_eq "$_tuish_redraw_requested" "1" "request_redraw 2 sets flag"
assert_eq "$_tuish_redraw_level" "2" "request_redraw 2 sets level"

# --- tuish_request_redraw 0 is a no-op ---
reset_state
tuish_request_redraw 0
assert_eq "$_tuish_redraw_requested" "0" "request_redraw 0 does not set flag"
assert_eq "$_tuish_redraw_level" "0" "request_redraw 0 does not set level"

# --- Level coalescing: higher positive wins ---
reset_state
tuish_request_redraw 1
tuish_request_redraw 3
tuish_request_redraw 2
assert_eq "$_tuish_redraw_level" "3" "higher positive level wins"

# --- Level coalescing: -1 always wins ---
reset_state
tuish_request_redraw 2
tuish_request_redraw
assert_eq "$_tuish_redraw_level" "-1" "-1 wins over positive"

# --- Level coalescing: positive after -1 stays -1 ---
reset_state
tuish_request_redraw
tuish_request_redraw 2
assert_eq "$_tuish_redraw_level" "-1" "-1 sticky over positive"

# --- tuish_cancel_redraw clears flag and level ---
reset_state
tuish_request_redraw 3
tuish_cancel_redraw
assert_eq "$_tuish_redraw_requested" "0" "cancel_redraw clears flag"
assert_eq "$_tuish_redraw_level" "0" "cancel_redraw clears level"

# --- Event without request_redraw flushes normally ---
reset_state
tuish_on_event () { tuish_print "hello"; }
_tuish_parse_event "C a"
assert_contains "$_captured" "hello" "normal event flushes output"

# --- Event with request_redraw: no pending input -> immediate redraw ---
reset_state
_redraw_count=0
tuish_on_event () { tuish_request_redraw; }
tuish_on_redraw () {
	_redraw_count=$((_redraw_count + 1))
	_redraw_level="$1"
	tuish_print "redrawn"
}
_tuish_parse_event "C a"
assert_eq "$_redraw_count" "1" "redraw fires when no pending input"
assert_contains "$_captured" "redrawn" "redraw output is flushed"
assert_eq "$_redraw_level" "-1" "redraw receives level -1"

# --- Redraw level is passed to tuish_on_redraw ---
reset_state
_redraw_level=''
tuish_on_event () { tuish_request_redraw 2; }
tuish_on_redraw () { _redraw_level="$1"; }
_tuish_parse_event "C a"
assert_eq "$_redraw_level" "2" "redraw receives level 2"

# --- Event handler output is discarded when redraw requested ---
reset_state
_captured=''
tuish_on_event () { tuish_print "discard_me"; tuish_request_redraw; }
tuish_on_redraw () { tuish_print "kept"; }
_tuish_parse_event "C a"
# "discard_me" should NOT appear in output, "kept" should
case "$_captured" in
	*discard_me*) assert_eq "found" "not_found" "handler output discarded when redraw requested";;
	*kept*) assert_eq "1" "1" "handler output discarded when redraw requested";;
	*) assert_eq "empty" "kept" "handler output discarded when redraw requested";;
esac

# --- Level resets after redraw fires ---
reset_state
tuish_on_event () { tuish_request_redraw 3; }
tuish_on_redraw () { :; }
_tuish_parse_event "C a"
assert_eq "$_tuish_redraw_level" "0" "level resets after redraw fires"
assert_eq "$_tuish_redraw_requested" "0" "flag resets after redraw fires"

# --- tuish_has_pending_input returns 1 when no input ---
reset_state
if tuish_has_pending_input
then
	assert_eq "pending" "none" "has_pending_input with no input"
else
	assert_eq "1" "1" "has_pending_input returns false when no input"
fi

# --- pending_byte is consumed in loop condition ---
reset_state
_tuish_pending_byte='x'
# Simulate what the loop condition does
if test -n "${_tuish_pending_byte}"
then
	_tuish_byte="$_tuish_pending_byte"
	_tuish_pending_byte=''
fi
assert_eq "$_tuish_byte" "x" "pending byte consumed correctly"
assert_eq "$_tuish_pending_byte" "" "pending byte cleared after consume"

# --- Flushed output survives rAF discard ---
# When tuish_flush is called inside the event handler, that output
# reaches the terminal even though rAF discards the remaining buffer.
reset_state
_captured=''
tuish_on_event () {
	tuish_print "immediate"
	tuish_flush
	tuish_print "deferred"
	tuish_request_redraw 1
}
tuish_on_redraw () { tuish_print "redraw"; }
_tuish_parse_event "C a"
# "immediate" should be in the output (flushed before rAF discard)
assert_contains "$_captured" "immediate" "flush: flushed output survives rAF discard"
# "deferred" should NOT be in the output (written after flush, discarded by rAF)
case "$_captured" in
	*deferred*) assert_eq "found" "not_found" "flush: post-flush output discarded by rAF";;
	*) assert_eq "1" "1" "flush: post-flush output discarded by rAF";;
esac
# "redraw" should be in the output (on_redraw fires after discard)
assert_contains "$_captured" "redraw" "flush: on_redraw still fires after flush"

# --- Flush without redraw request passes all output through ---
reset_state
_captured=''
tuish_on_event () {
	tuish_print "part1"
	tuish_flush
	tuish_print "part2"
}
tuish_on_redraw () { :; }
_tuish_parse_event "C a"
assert_contains "$_captured" "part1" "flush no-rAF: flushed part present"
assert_contains "$_captured" "part2" "flush no-rAF: post-flush part present"

# --- Flush + redraw level 1: level preserved through to on_redraw ---
reset_state
_captured=''
_redraw_level=''
tuish_on_event () {
	tuish_flush
	tuish_request_redraw 2
}
tuish_on_redraw () { _redraw_level="$1"; }
_tuish_parse_event "C a"
assert_eq "$_redraw_level" "2" "flush: redraw level preserved after flush"

# --- rAF inhibit: redraw deferred, request stays pending ---
# Glued escape-sequence bursts dispatch with _tuish_raf_inhibit=1
# (more input known in flight); the render must be skipped, not fired.
reset_state
tuish_on_event () { tuish_print "discard_me"; tuish_request_redraw 2; }
tuish_on_redraw () { _redraw_count=$((_redraw_count + 1)); tuish_print "drawn"; }
_tuish_raf_inhibit=1
_tuish_parse_event "C a"
_tuish_raf_inhibit=0
assert_eq "$_redraw_count" "0" "inhibit: render deferred"
assert_eq "$_tuish_redraw_requested" "1" "inhibit: request stays pending"
assert_eq "$_tuish_redraw_level" "2" "inhibit: level preserved"
case "$_captured" in
	*discard_me*|*drawn*) assert_eq "output" "empty" "inhibit: handler output discarded, no render output";;
	*) assert_eq "1" "1" "inhibit: handler output discarded, no render output";;
esac

# --- Glued burst: inhibit 1/1/0 -> exactly one redraw at max level ---
reset_state
tuish_on_event () { tuish_request_redraw 1; }
tuish_on_redraw () { _redraw_count=$((_redraw_count + 1)); _redraw_level="$1"; }
_tuish_raf_inhibit=1
_tuish_parse_event "E 91 66"
tuish_on_event () { tuish_request_redraw 3; }
_tuish_parse_event "E 91 66"
_tuish_raf_inhibit=0
tuish_on_event () { tuish_request_redraw 1; }
_tuish_parse_event "E 91 66"
assert_eq "$_redraw_count" "1" "glued burst: exactly one redraw"
assert_eq "$_redraw_level" "3" "glued burst: max level across burst"
assert_eq "$_tuish_redraw_requested" "0" "glued burst: flag cleared after render"

# --- Pending redraw fires on idle even if idle requests nothing ---
reset_state
tuish_on_event () { tuish_request_redraw 2; }
tuish_on_redraw () { _redraw_count=$((_redraw_count + 1)); _redraw_level="$1"; }
_tuish_raf_inhibit=1
_tuish_parse_event "C a"
_tuish_raf_inhibit=0
assert_eq "$_redraw_count" "0" "idle fallback: deferred while inhibited"
tuish_on_event () { :; }
_tuish_parse_event "F"
assert_eq "$_redraw_count" "1" "idle fallback: pending redraw fires on idle"
assert_eq "$_redraw_level" "2" "idle fallback: level preserved to idle"

# --- Signal mid-burst neither fires nor loses the pending redraw ---
reset_state
tuish_on_event () { tuish_request_redraw 2; }
tuish_on_redraw () { _redraw_count=$((_redraw_count + 1)); _redraw_level="$1"; }
_tuish_raf_inhibit=1
_tuish_parse_event "E 91 66"
tuish_on_event () { :; }
_tuish_parse_event "S winch"
_tuish_raf_inhibit=0
assert_eq "$_redraw_count" "0" "signal mid-burst: still deferred"
assert_eq "$_tuish_redraw_requested" "1" "signal mid-burst: request not lost"
assert_eq "$_tuish_redraw_level" "2" "signal mid-burst: level not lost"
_tuish_parse_event "F"
assert_eq "$_redraw_count" "1" "signal mid-burst: redraw fires after burst"

# --- Saved pending byte defers render and is not clobbered ---
reset_state
_tuish_pending_byte='x'
tuish_on_event () { tuish_request_redraw; }
tuish_on_redraw () { _redraw_count=$((_redraw_count + 1)); }
_tuish_parse_event "C a"
assert_eq "$_redraw_count" "0" "pending byte: render deferred"
assert_eq "$_tuish_pending_byte" "x" "pending byte: saved byte not clobbered"
assert_eq "$_tuish_redraw_requested" "1" "pending byte: request stays pending"

# --- The discarded frame must not take device state with it ---------------------
# A deferred redraw supersedes whatever the handler drew, so the handler's frame CONTENT
# is thrown away. Anything a handler wrote as bytes went with it — which is exactly how a
# hosted editor lost its bar caret: it emitted the shape while being mounted, inside the
# handler, and the render that followed re-showed the caret without ever re-declaring what
# it looked like. The shape is a DECLARATION now, so it is a variable and survives; and the
# cache of what the device has must be forgotten, because those bytes never landed.
# The captured bytes are what the WRITER was handed, before the flush expands them — so
# match on the escape-agnostic tail, "[6 q", not on a literal ESC.
TUISH_LINES=24; TUISH_COLUMNS=80          # tuish_vmove clips against these
TUISH_VIEW_ROWS=24; TUISH_VIEW_COLS=80

# The handler mounts something that declares a bar and asks for a redraw. The render is the
# frame that actually reaches the terminal, and the caret in it must be a bar.
tuish_on_event  () { tuish_cursor_shape 6; _tuish_write 'THROWN AWAY'; tuish_request_redraw 2; }
tuish_on_redraw () { tuish_cursor 1 1; }

reset_state
_tuish_cursor_shape=''
_tuish_cursor_shape_dev=''
_tuish_parse_event "C a"
case "$_captured" in
	*"THROWN AWAY"*) _r=kept;;
	*) _r=discarded;;
esac
assert_eq "$_r" "discarded" "the handler's content is superseded by the redraw, as before"
case "$_captured" in
	*'[6 q'*) _r=yes;;
	*) _r=no;;
esac
assert_eq "$_r" "yes" "the caret's SHAPE survives the discard — it is state, not bytes"

# And the device cache may not claim bytes that were thrown away: pretend the terminal
# already had the bar, discard a frame, and the render must still re-assert it.
reset_state
_tuish_cursor_shape=''
_tuish_cursor_shape_dev=6
_tuish_parse_event "C a"
case "$_captured" in
	*'[6 q'*) _r=yes;;
	*) _r=no;;
esac
assert_eq "$_r" "yes" "a discarded frame forgets what the device was told it had"

# --- An idle NEVER defers -------------------------------------------------------
# Idle means _tuish_idle_wait let a whole interval pass with nothing arriving. A byte that
# lands while the handler runs does not undo that wait, so the frame is owed. Before this,
# a game whose tick and autorepeat were close enough to race would drop frames on exactly
# the ticks it had already paid full price for.
reset_state
_tuish_pending_byte='x'
tuish_on_event () { tuish_request_redraw 2; }
tuish_on_redraw () { _redraw_count=$((_redraw_count + 1)); _redraw_level="$1"; }
_tuish_parse_event "F"
assert_eq "$_redraw_count" "1" "idle: renders even with a byte already pending"
assert_eq "$_tuish_pending_byte" "x" "idle: renders WITHOUT peeking — the pending byte is untouched"
assert_eq "$_tuish_redraw_requested" "0" "idle: request cleared"

# The same byte on a KEY event still defers: only idle is special.
reset_state
_tuish_pending_byte='x'
_tuish_parse_event "C a"
assert_eq "$_redraw_count" "0" "key: still defers while input is pending"

# An idle also flushes a frame that a burst has been holding, and clears the budget with it.
reset_state
_tuish_raf_defers=5
_tuish_pending_byte='x'
_tuish_parse_event "F"
assert_eq "$_redraw_count" "1" "idle: flushes a frame the burst was holding"
assert_eq "$_tuish_raf_defers" "0" "idle: the render resets the budget"

# --- The deferral is BOUNDED ----------------------------------------------------
# "Input pending" is a -t0 peek: it means we are behind, not that a burst is coming. Held
# with no bound that is a livelock — a frame slower than autorepeat lets bytes queue faster
# than they drain, the peek never comes back empty, and the screen is withheld until the key
# is released. Spend a budget instead: hold at most TUISH_DEFER_MAX events, then paint.
reset_state
TUISH_DEFER_MAX=3
_tuish_pending_byte='x'
tuish_on_event () { tuish_request_redraw 2; }
tuish_on_redraw () { _redraw_count=$((_redraw_count + 1)); _redraw_level="$1"; }
_tuish_parse_event "C a"
assert_eq "$_redraw_count" "0" "budget: 1st deferred"
_tuish_parse_event "C a"
_tuish_parse_event "C a"
assert_eq "$_redraw_count" "0" "budget: held for the whole budget, not one event less"
assert_eq "$_tuish_raf_defers" "3" "budget: counted"
_tuish_parse_event "C a"
assert_eq "$_redraw_count" "1" "budget: spent — renders despite input still pending"
assert_eq "$_tuish_raf_defers" "0" "budget: reset by the render"
assert_eq "$_tuish_redraw_requested" "0" "budget: request cleared by the forced render"
assert_eq "$_tuish_pending_byte" "x" "budget: the forced render does not eat the pending byte"

# The budget outranks the inhibit, and that is deliberate: inhibit stops the PEEK from
# eating a sequence body, and rendering never peeks — it writes. A half-read escape
# sequence must not be able to freeze the screen either.
reset_state
TUISH_DEFER_MAX=2
_tuish_raf_inhibit=1
_tuish_parse_event "C a"
_tuish_parse_event "C a"
assert_eq "$_redraw_count" "0" "budget+inhibit: held while the budget lasts"
_tuish_parse_event "C a"
assert_eq "$_redraw_count" "1" "budget+inhibit: a half-read sequence cannot freeze the screen forever"
unset TUISH_DEFER_MAX

# Cancelling ends the wait, so the next frame starts its budget fresh; re-requesting a
# still-pending frame does NOT, because that is precisely what is being counted.
reset_state
tuish_on_event () { tuish_request_redraw 2; }
_tuish_pending_byte='x'
_tuish_parse_event "C a"
assert_eq "$_tuish_raf_defers" "1" "budget: a re-request does not reset the count"
tuish_cancel_redraw
assert_eq "$_tuish_raf_defers" "0" "budget: cancel resets the count"

# --- The peek inhibit belongs to the DEVICE, not to a context -------------------
# There is one input stream, so "do not peek right now" cannot be per-context. It was,
# and the failure needs a host to show itself: tuish_run raises the flag in ITS context
# mid-sequence, then a cooperative host routes the event on with tuish_ctx_dispatch,
# which activates the child — and the child's saved frame carries its own copy, 0. The
# child peeks, stashes a byte in _tuish_pending_byte, and the escape loop reading the tty
# directly never sees it again in order.
#
# Drive the marshalling itself: a switch is the whole mechanism, so if the flag survives
# one, it survives every path built on one.
reset_state
tuish_ctx_create; _rt_ctx=$TUISH_CTX          # a root to switch away from and back to
tuish_ctx_activate "$_rt_ctx"
tuish_ctx_create; _ch_ctx=$TUISH_CTX

_tuish_raf_inhibit=1
tuish_ctx_activate "$_ch_ctx"
assert_eq "$_tuish_raf_inhibit" "1" "inhibit: survives activating a child — it is the device's"
_tuish_raf_inhibit=0
tuish_ctx_activate "$_rt_ctx"
assert_eq "$_tuish_raf_inhibit" "0" "inhibit: a child clearing it is not undone by switching back"

# ...whereas the redraw REQUEST is per-context and must keep swapping: a child's pending
# frame is not its host's. The two live one line apart in event.sh, so pin the difference.
_tuish_redraw_requested=0
tuish_ctx_activate "$_ch_ctx"
_tuish_redraw_requested=1
tuish_ctx_activate "$_rt_ctx"
assert_eq "$_tuish_redraw_requested" "0" "request: stays per-context — a child's pending frame is its own"

# The defer budget goes with the request, for the same reason and one that is easier to get
# wrong: it measures how long THIS context's frame has been owed. Device-global, a host
# driving four children would spend one budget across all four and paint none of them.
_tuish_raf_defers=0
tuish_ctx_activate "$_ch_ctx"
_tuish_raf_defers=6
tuish_ctx_activate "$_rt_ctx"
assert_eq "$_tuish_raf_defers" "0" "budget: per-context — one child's backlog is not another's"

test_summary
