#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Headless benchmark for the PAINT hot path — what a frame costs to compose.
#
# The companion to bench_events.sh, which measures getting input in. This one
# measures putting a frame out, with the terminal stubbed, so it is CPU only:
# no TTY, no write(), no stty.
#
# It exists because the cost that dominates a tuish frame is not the bytes. It
# is measurement: tuish_text runs a display-width pass on every draw, one
# non-ASCII byte forfeits the ASCII fast path for the whole string, and the
# default draw backend is unicode. Before the decode memo landed, a 60-column
# box rule cost ~4.5ms to measure and a modest chrome frame ran to ~26ms —
# which is the "266ms frame" docs/event.md sizes TUISH_DEFER_MAX against.
#
# The cold/hot pairs below are the point of the file: `hot` is the realistic
# case (chrome redrawn verbatim every frame, served by the memo), `cold` is the
# floor with every lookup missing. If a change regresses the memo, cold and hot
# converge — which no single-number benchmark would show.
#
# This is a DEV TOOL, not shipped library code: its use of `date`/`awk`
# (for portable cross-shell wall-clock timing) is outside the library's
# "only stty, builtins-only" runtime contract by design.
#
# Env knobs:  BENCH_TN (text-scenario iterations, default 2000)
#             BENCH_FN (frame-scenario iterations, default 200)
#
# Reports 0.00 under busybox, whose `date` has no %N — the same blind spot
# bench_events.sh has, and for the same reason. Use another shell for numbers.

set -euf

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"

. "$BENCH_DIR/../../src/compat.sh"
. "$BENCH_DIR/../../src/ord.sh"
. "$BENCH_DIR/../../src/tui.sh"
. "$BENCH_DIR/../../src/term.sh"
. "$BENCH_DIR/../../src/str.sh"
. "$BENCH_DIR/../../src/draw.sh"

command -v tuish_fnfix >/dev/null 2>&1 && tuish_fnfix

TN=${BENCH_TN:-2000}
FN=${BENCH_FN:-200}

# ─── Neutralize terminal I/O ─────────────────────────────────────
# Frames are composed and thrown away: this measures composition, which is the
# part the app pays for whether or not the bytes turn out to be needed.
_tuish_out () { :; }

TUISH_LINES=24; TUISH_COLUMNS=80
TUISH_VIEW_TOP=0; TUISH_VIEW_LEFT=0; TUISH_VIEW_ROWS=24; TUISH_VIEW_COLS=80
_tuish_wrap=0
_tuish_tx_reset

# ─── Fixtures ────────────────────────────────────────────────────
_s_ascii='Lorem ipsum dolor sit amet consectetur adipiscing elit sed'
tuish_str_repeat '─' 60; _s_rule="$TUISH_SREPEATED"
_s_label='┌─ tuish · session ─────────────────┐'
_cold_n=0

# ─── Scenarios ───────────────────────────────────────────────────
sc_noop ()        { :; }
sc_text_ascii ()  { _tuish_buf=''; tuish_text 1 1 "$_s_ascii"; }
sc_text_hot ()    { _tuish_buf=''; tuish_text 1 1 "$_s_label"; }
# A string the memo has never seen: same shape, different bytes every call.
sc_text_cold ()   { _cold_n=$((_cold_n + 1)); _tuish_buf=''; tuish_text 1 1 "${_s_label}${_cold_n}"; }
sc_rule_hot ()    { _tuish_buf=''; tuish_text 1 1 "$_s_rule"; }

# The two ways to repaint a fixed-width field. erase+text is the idiom the docs
# taught before width=N existed: it walks the field twice and leaves it blank in
# between, which is what a terminal without synchronized output shows you.
sc_field_two ()   { _tuish_buf=''; tuish_clear_to_edge 1 1; tuish_text 1 1 "$_s_ascii"; }
sc_field_one ()   { _tuish_buf=''; tuish_text 1 1 "$_s_ascii" width=80; }

# A frame in the shape the real apps draw: chrome box, three rules, six unicode
# labels, forty rows of prose.
sc_frame ()
{
	local _i
	_tuish_buf=''
	tuish_begin
	tuish_draw_box 1 1 80 24 fg=7 bg=0
	_i=0; while test $_i -lt 3;  do tuish_text $((_i + 2)) 2 "$_s_rule";  _i=$((_i + 1)); done
	_i=0; while test $_i -lt 6;  do tuish_text $((_i + 5)) 2 "$_s_label"; _i=$((_i + 1)); done
	_i=0; while test $_i -lt 40; do tuish_text $((_i + 1)) 2 "$_s_ascii"; _i=$((_i + 1)); done
	tuish_end
}

# ─── Timing harness ──────────────────────────────────────────────
# Mirrors bench_events.sh: two `date` forks around a fixed-N loop. The noop row is
# the loop + indirect-call overhead, printed rather than subtracted — capturing it
# into a variable costs a fork, and at ~4us against a ~100us floor it would move no
# reading anyone takes from this file.
_report ()
{
	# $1 label  $2 N  $3 t0  $4 t1
	awk -v l="$1" -v n="$2" -v t0="$3" -v t1="$4" \
		'BEGIN { printf "  %-14s %9.1f us/op\n", l, (t1 - t0) * 1000000 / n }'
}

bench_one ()
{
	# $1 label  $2 N  $3 scenario-fn
	local _n=0 _t0 _t1
	_t0=$(date +%s.%N)
	# `|| :` so a scenario returning non-zero can't trip `set -e` mid-run.
	# The loop is strictly bounded by $2 — no recursion, no unbounded reads.
	while test $_n -lt $2
	do
		$3 || :
		_n=$((_n + 1))
	done
	_t1=$(date +%s.%N)
	_report "$1" "$2" "$_t0" "$_t1"
}

printf 'bench_paint  (text-N=%s frame-N=%s)\n' "$TN" "$FN"

printf 'baseline:\n'
bench_one noop        "$TN" sc_noop

printf 'tuish_text (one call):\n'
bench_one ascii       "$TN" sc_text_ascii
bench_one unicode-hot "$TN" sc_text_hot
bench_one unicode-cld "$TN" sc_text_cold
bench_one rule-hot    "$TN" sc_rule_hot

printf 'fixed-width field:\n'
bench_one erase+text  "$TN" sc_field_two
bench_one width=N     "$TN" sc_field_one

printf 'whole frame (box + 3 rules + 6 labels + 40 rows):\n'
bench_one frame       "$FN" sc_frame
