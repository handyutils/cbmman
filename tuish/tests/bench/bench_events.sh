#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Headless benchmark for the input/event + width hot paths.
#
# Drives the resolution/dispatch pipeline directly on synthetic inputs, with
# all terminal I/O stubbed, so it measures CPU cost only — no TTY, no stty,
# no read(). Source order mirrors tests/unit/test_event_keyboard.sh.
#
# This is a DEV TOOL, not shipped library code: its use of `date`/`awk`
# (for portable cross-shell wall-clock timing) is outside the library's
# "only stty, builtins-only" runtime contract by design.
#
# Each scenario runs a fixed-N tight loop wrapped by two `date +%s.%N` forks;
# the `noop` baseline captures loop + indirect-call overhead to subtract.
#
# Env knobs:  BENCH_N  (event-scenario iterations, default 30000)
#             BENCH_WN (width-scenario iterations, default 2000)

set -euf

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"

. "$BENCH_DIR/../../src/compat.sh"
. "$BENCH_DIR/../../src/ord.sh"
. "$BENCH_DIR/../../src/tui.sh"
. "$BENCH_DIR/../../src/event.sh"
. "$BENCH_DIR/../../src/hid.sh"
. "$BENCH_DIR/../../src/str.sh"

# ─── Neutralize terminal I/O and app callbacks ───────────────────
# Measure resolution + dispatch, never a terminal write.
_tuish_write ()   { :; }
_tuish_out ()     { :; }
tuish_on_event () { :; }
tuish_on_redraw (){ :; }

# Don't let the event filters drop the synthetic mouse/detailed/modkey
# events before they reach resolution (see event.sh:89-108).
_tuish_mouse=1
_tuish_detailed=1
_tuish_modkeys=1
TUISH_VIEW_COLS=80

N="${BENCH_N:-30000}"
WN="${BENCH_WN:-2000}"

# ─── Width workload strings ──────────────────────────────────────
_s_ascii='the quick brown fox jumps over the lazy dog'
_s_latin='café über naïve résumé Ångström'
_s_cjk='日本語中文한글テスト'
_s_emoji='🎉🚀✨🔥💯🎯🌟'

# ─── Scenario bodies ─────────────────────────────────────────────
sc_noop ()        { :; }

# Full dispatch (parse_event → resolve + begin/on_event/end)
sc_typing ()      { _tuish_parse_event "C a"; }
sc_arrow ()       { _tuish_parse_event "E 91 65"; }
sc_modkey ()      { _tuish_parse_event "E 91 49 59 53 65"; }
sc_modfkey ()     { _tuish_parse_event "E 91 49 53 59 53 126"; }
sc_mouse ()       { _tuish_parse_event "M 32 10 5"; _tuish_parse_event "M 35 11 5"; }

# Resolve-only (isolates the parsing cost Phases 2/3 target)
sc_r_typing ()    { _tuish_resolve_event C a; }
sc_r_arrow ()     { _tuish_resolve_event E 91 65; }
sc_r_modkey ()    { _tuish_resolve_event E 91 49 59 53 65; }
sc_r_modfkey ()   { _tuish_resolve_event E 91 49 53 59 53 126; }

# Width (str_width takes a variable NAME).
#
# These re-measure the SAME string every iteration, so since the decode memo landed
# (str.sh) the non-ASCII ones report the memo's hit cost, not the decoder's. That is
# the realistic number for chrome redrawn verbatim each frame — but it is no longer
# the cost of decoding, so do not read it as one. tests/bench/bench_paint.sh carries
# paired hot/cold scenarios that keep both visible.
sc_w_ascii ()     { tuish_str_width _s_ascii; }
sc_w_latin ()     { tuish_str_width _s_latin; }
sc_w_cjk ()       { tuish_str_width _s_cjk; }
sc_w_emoji ()     { tuish_str_width _s_emoji; }

# ─── Timing harness ──────────────────────────────────────────────
_report ()
{
	# $1 label  $2 N  $3 t0  $4 t1
	awk -v l="$1" -v n="$2" -v a="$3" -v b="$4" 'BEGIN {
		d = b - a; if (d < 0) d = 0
		per = (n > 0) ? (d * 1000000 / n) : 0
		printf "  %-14s %8d calls  %9.2f ms  %9.3f us/call\n", l, n, d * 1000, per
	}'
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

printf 'bench_events  (N=%s width-N=%s)\n' "$N" "$WN"

printf 'full-dispatch:\n'
bench_one noop      "$N"  sc_noop
bench_one typing    "$N"  sc_typing
bench_one arrow     "$N"  sc_arrow
bench_one modkey    "$N"  sc_modkey
bench_one modfkey   "$N"  sc_modfkey
bench_one mouse     "$N"  sc_mouse

printf 'resolve-only:\n'
bench_one r-typing  "$N"  sc_r_typing
bench_one r-arrow   "$N"  sc_r_arrow
bench_one r-modkey  "$N"  sc_r_modkey
bench_one r-modfkey "$N"  sc_r_modfkey

printf 'str_width:\n'
bench_one w-ascii   "$WN" sc_w_ascii
bench_one w-latin   "$WN" sc_w_latin
bench_one w-cjk     "$WN" sc_w_cjk
bench_one w-emoji   "$WN" sc_w_emoji
