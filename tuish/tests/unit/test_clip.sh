#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for off-screen draw clipping.
#
# A draw that extends past the bottom of the physical screen must not trip
# `set -e` (compat.sh enables `set -euf`) and abort the redraw, and the trailing
# SGR reset must still be emitted so colors do not leak. Each draw primitive
# guards its writes on tuish_vmove's return (vmove emits nothing and returns
# non-zero when a row is off-screen); there is no global suppression flag.
#
# `set -e` only triggers on a *bare* top-level command, and shells disable it
# inside if/while/&&/|| conditions — so the off-screen scenario cannot be
# observed reliably in-process. Instead we run it as bare statements in a
# child shell (where compat.sh re-arms `set -euf`) and inspect what reaches
# stdout: a finished run prints the trailing marker; an aborted one does not.

set -uf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

SRC="$TESTS_DIR/../src"

printf 'Unit tests: off-screen clipping (errexit + SGR reset)\n'

# Drive every drawing primitive past the bottom of a fake 5-row screen, as
# bare statements under `set -euf`. Output is buffered, so only the explicit
# trailing marker reaches stdout — and only if nothing aborted along the way.
_probe=$(
	{ printf '%s\n' \
		". \"$SRC/compat.sh\"" \
		". \"$SRC/ord.sh\"" \
		". \"$SRC/tui.sh\"" \
		". \"$SRC/term.sh\"" \
		". \"$SRC/str.sh\"" \
		". \"$SRC/draw.sh\"" \
		'TUISH_LINES=5; TUISH_COLUMNS=40; TUISH_VIEW_COLS=40' \
		'TUISH_VIEW_TOP=1; _tuish_wrap=0' \
		'tuish_begin' \
		'tuish_draw_box 1 1 10 8 fg=2 bg=4' \
		'_boxbuf="$_tuish_buf"' \
		'tuish_begin' \
		'tuish_draw_vline 1 1 12 fg=3' \
		'tuish_draw_hline 9 1 10' \
		'tuish_draw_text 9 1 hi fg=1' \
		'tuish_draw_hdiv 9 1 10' \
		'tuish_draw_vdiv 1 1 12' \
		'tuish_clear_region 1 1 4 9' \
		'tuish_print_at 9 1 x' \
		'printf "%s@@DONE" "$_boxbuf"' \
	; } | sh 2>/dev/null
) || :

# ─── Nothing aborted — the trailing marker survived ──────────────
case "$_probe" in
	*DONE) _reached=yes;;
	*)     _reached=no;;
esac
assert_eq "$_reached" "yes" "box/vline/hline/text/hdiv/vdiv/clear_region/print_at past bottom: no errexit abort"

# ─── The off-bottom box's trailing SGR reset was still emitted ────
case "$_probe" in
	*'\033[0m@@DONE') _ends_reset=yes;;
	*)                _ends_reset=no;;
esac
assert_eq "$_ends_reset" "yes" "box past bottom: buffer ends with SGR reset (no color leak)"

# ─── Sanity: a fully on-screen colored box still ends with a reset ──
# (In-process is safe here: nothing clips, so no abort is possible.)
. "$SRC/compat.sh"; . "$SRC/ord.sh"; . "$SRC/tui.sh"
. "$SRC/term.sh";   . "$SRC/str.sh"; . "$SRC/draw.sh"; . "$SRC/canvas.sh"
TUISH_LINES=24; TUISH_COLUMNS=80; TUISH_VIEW_COLS=80
TUISH_VIEW_TOP=1; _tuish_wrap=0
tuish_begin
tuish_draw_box 1 1 6 3 fg=2 bg=4
_cap="$_tuish_buf"; _tuish_buf=''; _tuish_buffering=0
case "$_cap" in
	*'\033[0m') _ok=yes;;
	*)          _ok=no;;
esac
assert_eq "$_ok" "yes" "on-screen box: still ends with SGR reset"

# ─── A clipped vmove emits nothing and returns non-zero ──────────
tuish_begin
tuish_vmove 999 1 && _vc=0 || _vc=1
assert_eq "$_vc" "1" "off-bottom vmove returns non-zero"
tuish_print 'X'
# The print after a clipped vmove is NOT suppressed (no global guard) — the
# caller decides via the return value; print on its own always writes.
case "$_tuish_buf" in *X*) _wrote=yes;; *) _wrote=no;; esac
assert_eq "$_wrote" "yes" "print after clipped vmove writes (no implicit suppression)"
_tuish_buf=''; _tuish_buffering=0

# ─── Right-edge clip: content stops at the visible region edge, not the screen ──
# The bleed bug: writes clamped to TUISH_VIEW_COLS (region full width) or not at all,
# so a hosted child's over-wide row ran to the physical screen edge. Now every
# region-aware write clips to min(TUISH_VIEW_COLS, _tx_lcmax) via _tuish_clip_avail.
_count_char () {   # $1 string $2 char -> _cc = occurrences of char in string
	_cc=0; _s=$1
	while case "$_s" in *"$2"*) true;; *) false;; esac
	do _s=${_s#*"$2"}; _cc=$((_cc + 1)); done
}
ESC=$(printf '\033')
_sixtyA=''; _i=0; while test $_i -lt 60; do _sixtyA="${_sixtyA}A"; _i=$((_i + 1)); done

TUISH_LINES=24; TUISH_COLUMNS=80; TUISH_VIEW_COLS=40; TUISH_VIEW_TOP=1; _tuish_wrap=0
_tuish_tx_reset            # no sub-clip: _tx_lcmax defaults wide, so clip == VIEW_COLS

tuish_begin; _tuish_buf=''
tuish_text 1 1 "$_sixtyA"
_count_char "$_tuish_buf" A
assert_eq "$_cc" "40" "tuish_text: 60-col string clipped to region width 40"

tuish_begin; _tuish_buf=''
tuish_clear_region 1 1 60 1
_count_char "$_tuish_buf" ' '
assert_eq "$_cc" "40" "tuish_clear_region: width 60 clamped to region width 40"

# SGR-bearing row: clipped to 40 visible cells (escape bytes not miscounted), and a
# forced trailing reset closes the run whose own reset fell past the cut. tuish emits
# its own escapes as the literal string \033[…m (expanded at flush), so match that.
tuish_begin; _tuish_buf=''
tuish_text 1 1 "${ESC}[31m${_sixtyA}${ESC}[0m"
_count_char "$_tuish_buf" A
assert_eq "$_cc" "40" "tuish_text SGR row: clipped to 40 visible cells (escapes not counted)"
case "$_tuish_buf" in *'\033[0m') _sgr_reset=yes;; *) _sgr_reset=no;; esac
assert_eq "$_sgr_reset" "yes" "tuish_text SGR row: ends with reset (no colour leak into chrome)"

# Scroll-under-pane: a visible clip narrower than the region (_tx_lcmax < VIEW_COLS).
# Previously bled to VIEW_COLS=40; must now stop at the visible window (20).
tuish_begin; _tuish_buf=''; _tx_lcmax=20
tuish_text 1 1 "$_sixtyA"
_count_char "$_tuish_buf" A
assert_eq "$_cc" "20" "tuish_text: clips to the visible window (_tx_lcmax=20), not region 40"

tuish_begin; _tuish_buf=''; _tx_lcmax=20
tuish_clear_region 1 1 60 1
_count_char "$_tuish_buf" ' '
assert_eq "$_cc" "20" "tuish_clear_region: clamps to the visible window (_tx_lcmax=20)"
_tuish_tx_reset
_tuish_buf=''; _tuish_buffering=0

# ─── The SGR path and the plain path clip a scrolled field identically ─────────
# A left-scrolled fixed-width field (COL < 1 plus maxwidth) is the one call shape
# where the two paths could disagree: maxwidth counts from the string's own start,
# so trimming the scrolled-off head has to come out of it. 10 cells of budget minus
# 4 scrolled off the left = 6 drawn — whether or not the row carries colour.
tuish_begin; _tuish_buf=''
tuish_text 1 -3 "$_sixtyA" maxwidth=10
_count_char "$_tuish_buf" A
assert_eq "$_cc" "6" "tuish_text plain: maxwidth counts the head scrolled off the left"

tuish_begin; _tuish_buf=''
tuish_text 1 -3 "${ESC}[31m${_sixtyA}${ESC}[0m" maxwidth=10
_count_char "$_tuish_buf" A
assert_eq "$_cc" "6" "tuish_text SGR: same cells as the plain path for the same call"

# An OSC (ESC ']' … ST) is not a CSI, so it stays on the plain path — which also
# means no forced trailing reset. Keying the escape path on ESC alone would fire it
# here and clobber an attribute the caller set around the call (the `tuish_bold;
# tuish_text …` idiom), for a sequence the CSI-only window cannot skip anyway.
tuish_begin; _tuish_buf=''
tuish_text 1 1 "${ESC}]0;title${ESC}\\ok"
case "$_tuish_buf" in *"0;title"*) _osc=kept;; *) _osc=mangled;; esac
assert_eq "$_osc" "kept" "tuish_text: a non-CSI escape reaches the terminal intact"
case "$_tuish_buf" in *'\033[0m') _osc_reset=yes;; *) _osc_reset=no;; esac
assert_eq "$_osc_reset" "no" "tuish_text: a non-CSI escape forces no trailing reset"
_tuish_buf=''; _tuish_buffering=0

# ─── The clip authority answers in TERMINAL COLUMNS, not mixed units ───────────
# TUISH_VIEW_COLS is viewport-logical columns; _tx_lcmax is in the CURRENT cell space,
# which under a canvas is CANVAS CELLS of _tx_cw columns each at offset _tx_off_c.
# min()-ing them raw and then spending the answer as columns is wrong in BOTH
# directions. Every bound now goes through the same affine map tuish_vmove uses
# before the comparison.
_ninety=''; _i=0; while test $_i -lt 90; do _ninety="${_ninety}A"; _i=$((_i + 1)); done

# A canvas whose cells are 2 columns wide owns twice as many COLUMNS as cells.
# Root-style base clip (1..80); 50 cells at CW=2 is exactly the 80-column screen.
TUISH_LINES=24; TUISH_COLUMNS=80; TUISH_VIEW_COLS=80
TUISH_VIEW_TOP=1; TUISH_VIEW_LEFT=0; _tuish_wrap=0
_tuish_base_lrmin=1; _tuish_base_lrmax=24; _tuish_base_lcmin=1; _tuish_base_lcmax=80
_tuish_tx_reset
tuish_canvas 1 1 50 3 2
_tuish_clip_avail 1
assert_eq "$_tuish_avail" "80" "clip_avail: a CW=2 canvas has 80 COLUMNS, not 40 cells"

tuish_begin; _tuish_buf=''
tuish_text 1 1 "$_ninety"
_count_char "$_tuish_buf" A
assert_eq "$_cc" "80" "tuish_text: a CW=2 canvas gets its full width (was cut to half)"

# A canvas at a high column offset must stop at the SCREEN, not at its own cell
# count. This is the un-seated profile (base clip still ±99999) — an app that sourced
# term.sh + canvas.sh without a viewport, so _tuish_canvas_clamp has nothing to
# intersect with and the physical backstop is the only bound left.
_tuish_base_lrmin=-99999; _tuish_base_lrmax=99999
_tuish_base_lcmin=-99999; _tuish_base_lcmax=99999
_tuish_tx_reset
tuish_canvas 1 71 20 3          # cells 1..20 at terminal columns 71..90 — 10 off-screen
_tuish_clip_avail 1
assert_eq "$_tuish_avail" "10" "clip_avail: a canvas at column 71 stops at COLUMNS=80"

tuish_begin; _tuish_buf=''
tuish_text 1 1 "$_ninety"
_count_char "$_tuish_buf" A
assert_eq "$_cc" "10" "tuish_text: a canvas at column 71 does not pass the screen edge"

# A region seated so its right edge falls off the screen. Nothing in the old helper
# mentioned TUISH_VIEW_LEFT or TUISH_COLUMNS, so an erase ran the region's full
# nominal width from an absolute column that had less room than that.
tuish_canvas_off
TUISH_VIEW_LEFT=70; TUISH_VIEW_COLS=40
_tuish_base_lcmin=1; _tuish_base_lcmax=40; _tuish_tx_reset
_tuish_clip_avail 1
assert_eq "$_tuish_avail" "10" "clip_avail: VIEW_LEFT=70 + 40 wide is bounded by COLUMNS=80"

tuish_begin; _tuish_buf=''
tuish_clear_region 1 1 40 1
_count_char "$_tuish_buf" ' '
assert_eq "$_cc" "10" "tuish_clear_region: an off-screen region erases only what exists"

tuish_begin; _tuish_buf=''
tuish_clear_to_edge 1
_count_char "$_tuish_buf" ' '
assert_eq "$_cc" "10" "tuish_clear_to_edge: same bound, now via one _tuish_clip_avail"

# No viewport at all: the "whole terminal" fallback tuish_clear_to_edge used to carry
# by hand is now just the case where the region bound is absent and the physical one
# wins. tuish_text unifies with it — pixel-identical, since tuish_init leaves DECAWM
# off and the terminal already discards those columns, but ten fewer bytes and the
# same region-correct rule as everywhere else.
TUISH_VIEW_LEFT=0; TUISH_VIEW_COLS=0
_tuish_base_lcmin=-99999; _tuish_base_lcmax=99999; _tuish_tx_reset
_tuish_clip_avail 1
assert_eq "$_tuish_avail" "80" "clip_avail: no viewport falls back to TUISH_COLUMNS"

tuish_begin; _tuish_buf=''
tuish_text 1 1 "$_ninety"
_count_char "$_tuish_buf" A
assert_eq "$_cc" "80" "tuish_text: with no viewport, trims at the screen edge"

# Nothing known at ALL — no viewport, no screen width, _tx_lcmax still its ±99999
# "no clip" default. That default is a sentinel, not a column anyone means, so the
# answer has to be exactly _TUISH_NOCLIP however far right COL is: measuring the width
# from it would report 99995 for COL=5, which reads as a real bound and had
# tuish_clear_to_edge erase a hundred thousand spaces.
TUISH_COLUMNS=0
_tuish_clip_avail 1
assert_eq "$_tuish_avail" "99999" "clip_avail: nothing known at all means no trim"
_tuish_clip_avail 5
assert_eq "$_tuish_avail" "99999" "clip_avail: ... and still no trim from a later column"
tuish_begin; _tuish_buf=''
tuish_clear_to_edge 1 5
assert_eq "${#_tuish_buf}" "0" "tuish_clear_to_edge: erases nothing when nothing bounds it"
TUISH_COLUMNS=80

# _tuish_wrap is the CALLER's policy ("let the terminal wrap"), so it moved out of the
# helper to the sites that mean it. An erase never has it: an unclamped clear under
# autowrap spills its spaces onto the next row, still outside the region.
TUISH_VIEW_COLS=40; _tuish_tx_reset; _tuish_wrap=1
tuish_begin; _tuish_buf=''
tuish_clear_region 1 1 60 1
_count_char "$_tuish_buf" ' '
assert_eq "$_cc" "40" "clear_region under autowrap: still clamped (an erase cannot wrap)"

tuish_begin; _tuish_buf=''
tuish_text 1 1 "$_sixtyA"
_count_char "$_tuish_buf" A
assert_eq "$_cc" "60" "tuish_text under autowrap: still untrimmed (the policy survived)"
_tuish_wrap=0
_tuish_tx_reset; _tuish_buf=''; _tuish_buffering=0

# ─── Wide characters clip in COLUMNS, not characters ─────────────
# The regression this covers: tuish_text's plain path trimmed with
# tuish_str_left/right, which count CHARACTERS. For ASCII the two units coincide,
# so it read as correct for as long as the toolkit was ASCII-first. For anything
# wider they diverge by exactly the character's width — a 36-column CJK string
# placed in a 20-column region emitted all 36, straight through the host's right
# border. Same bleed bleed-report.md describes, reached through the tier that was
# supposed to be immune to it.
TUISH_LINES=24; TUISH_COLUMNS=80; TUISH_VIEW_COLS=20; TUISH_VIEW_TOP=1; _tuish_wrap=0
_tuish_tx_reset

# 18 CJK ideographs = 36 columns, into a 20-column region.
_cjk=''; _i=0; while test $_i -lt 18; do _cjk="${_cjk}日"; _i=$((_i + 1)); done
tuish_begin; _tuish_buf=''
tuish_text 1 1 "$_cjk"
_body=${_tuish_buf#*H}; _w=$_body; tuish_str_width _w
assert_eq "$TUISH_SWIDTH" "20" "tuish_text: wide text clips to the region in COLUMNS"

# maxwidth is a column budget too — 6 must mean 3 ideographs, not 6.
tuish_begin; _tuish_buf=''
tuish_text 1 1 "$_cjk" maxwidth=6
_body=${_tuish_buf#*H}; _w=$_body; tuish_str_width _w
assert_eq "$TUISH_SWIDTH" "6" "tuish_text: maxwidth counts columns, not characters"

# An odd budget cannot be filled by 2-column cells: the straddling char is dropped
# rather than half-drawn, so the result is one column short. Short is correct; a
# split wide char would corrupt the cell to its right.
tuish_begin; _tuish_buf=''
tuish_text 1 1 "$_cjk" maxwidth=5
_body=${_tuish_buf#*H}; _w=$_body; tuish_str_width _w
assert_eq "$TUISH_SWIDTH" "4" "tuish_text: a wide char straddling the cut is dropped, not split"

# ─── width=N — the one-pass field ────────────────────────────────
# Erase-then-print touches every cell twice with a blank state between the two.
# width=N is the same field in one run, so there is no intermediate blank to see.
TUISH_VIEW_COLS=40; _tuish_tx_reset

tuish_begin; _tuish_buf=''
tuish_text 1 1 'hi' width=10
_body=${_tuish_buf#*H}
assert_eq "$_body" "hi        " "width=N: short text is padded to the field, in ONE run"

tuish_begin; _tuish_buf=''
tuish_text 1 1 'hello world' width=5
_body=${_tuish_buf#*H}
assert_eq "$_body" "hello" "width=N: long text is truncated to the field"

tuish_begin; _tuish_buf=''
tuish_text 1 1 'exact' width=5
_body=${_tuish_buf#*H}
assert_eq "$_body" "exact" "width=N: an exact fit is neither padded nor cut"

# Padding is capped by the visible window like everything else — a field wider than
# the region must not pad its way through the host's border.
tuish_begin; _tuish_buf=''; _tx_lcmax=8
tuish_text 1 1 'ab' width=30
_body=${_tuish_buf#*H}
assert_eq "${#_body}" "8" "width=N: the pad clips at the visible window, it does not bleed"
_tuish_tx_reset

# A wide char counts its columns against the field, so the pad makes up the rest.
tuish_begin; _tuish_buf=''
tuish_text 1 1 '日本' width=6
_body=${_tuish_buf#*H}; _w=$_body; tuish_str_width _w
assert_eq "$TUISH_SWIDTH" "6" "width=N: field width is columns, so wide text pads correctly"

_tuish_tx_reset; _tuish_buf=''; _tuish_buffering=0

test_summary
