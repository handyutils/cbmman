#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for draw.sh box-drawing library

set -uf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/ord.sh"
. "$TESTS_DIR/../src/tui.sh"
. "$TESTS_DIR/../src/term.sh"
. "$TESTS_DIR/../src/str.sh"

_tuish_write () { :; }
tuish_on_event () { :; }

. "$TESTS_DIR/../src/draw.sh"


# Exercise the SHIPPED configuration. tuish_fnfix normally fires from tuish_init, which unit
# tests deliberately never call (they stub the device) — so without this, every suite here
# would validate the framework with its ksh `local` still leaking, i.e. not the library that
# actually runs. It is a no-op on every shell whose `local` already works.
command -v tuish_fnfix >/dev/null 2>&1 && tuish_fnfix

printf 'Unit tests: draw.sh\n'

# ─── Backend detection ────────────────────────────────────────────

# Force ascii and verify
TUISH_DRAW_BACKEND='ascii'
_tuish_draw_orig_lang='' _tuish_draw_orig_lc_all='' _tuish_draw_orig_lc_ctype=''
_tuish_draw_detect_unicode
assert_eq "$TUISH_DRAW_BACKEND" "ascii" "detect: no utf-8 → ascii"

_tuish_draw_orig_lang='en_US.UTF-8'
_tuish_draw_detect_unicode
assert_eq "$TUISH_DRAW_BACKEND" "unicode" "detect: LANG=UTF-8 → unicode"

TUISH_DRAW_BACKEND='ascii'
_tuish_draw_orig_lang=''
_tuish_draw_orig_lc_all='C.utf8'
_tuish_draw_detect_unicode
assert_eq "$TUISH_DRAW_BACKEND" "unicode" "detect: LC_ALL=utf8 → unicode"

TUISH_DRAW_BACKEND='ascii'
_tuish_draw_orig_lc_all=''
_tuish_draw_orig_lc_ctype='en_US.UTF-8'
_tuish_draw_detect_unicode
assert_eq "$TUISH_DRAW_BACKEND" "unicode" "detect: LC_CTYPE=UTF-8 → unicode"

# ─── Style system ─────────────────────────────────────────────────

# Reset cache to force re-evaluation
_tuish_draw_cur_style='' _tuish_draw_cur_join='' _tuish_draw_cur_backend=''

TUISH_DRAW_BACKEND='ascii'
_tuish_draw_set_style 'light'
assert_eq "$_tuish_draw_ch_h" "-" "style: ascii light h"
assert_eq "$_tuish_draw_ch_v" "|" "style: ascii light v"
assert_eq "$_tuish_draw_ch_tl" "+" "style: ascii light tl"
assert_eq "$_tuish_draw_ch_bold" "0" "style: ascii light no bold"

_tuish_draw_cur_style=''
_tuish_draw_set_style 'heavy'
assert_eq "$_tuish_draw_ch_bold" "1" "style: ascii heavy bold"
assert_eq "$_tuish_draw_ch_h" "-" "style: ascii heavy h"

_tuish_draw_cur_style=''
_tuish_draw_set_style 'double'
assert_eq "$_tuish_draw_ch_h" "=" "style: ascii double h"
assert_eq "$_tuish_draw_ch_bold" "0" "style: ascii double no bold"

_tuish_draw_cur_style=''
_tuish_draw_set_style 'rounded'
assert_eq "$_tuish_draw_ch_tl" "." "style: ascii rounded tl"
assert_eq "$_tuish_draw_ch_bl" "'" "style: ascii rounded bl"

# All ascii junctions are '+'
_tuish_draw_cur_style=''
_tuish_draw_set_style 'light'
assert_eq "$_tuish_draw_ch_tee_r" "+" "style: ascii tee_r"
assert_eq "$_tuish_draw_ch_cross" "+" "style: ascii cross"

# Style cache: calling with same args is a no-op
_tuish_draw_ch_h='MARKER'
_tuish_draw_set_style 'light'
assert_eq "$_tuish_draw_ch_h" "MARKER" "style: cache hit skips work"

# ─── Option parsing ───────────────────────────────────────────────

_tuish_draw_parse_opts style=heavy fg=5 join=double
assert_eq "$_tuish_draw_opt_style" "heavy" "opts: style"
assert_eq "$_tuish_draw_opt_fg" "5" "opts: fg"
assert_eq "$_tuish_draw_opt_join" "double" "opts: join"

_tuish_draw_parse_opts style=light
assert_eq "$_tuish_draw_opt_join" "light" "opts: join defaults to style"
assert_eq "$_tuish_draw_opt_fg" "-1" "opts: fg defaults to -1"

_tuish_draw_parse_opts
assert_eq "$_tuish_draw_opt_style" "light" "opts: no args → light"
assert_eq "$_tuish_draw_opt_fg" "-1" "opts: no args → fg -1"

# ─── Viewport state ──────────────────────────────────────────────

tuish_draw_set_origin 10 5
assert_eq "$_tuish_draw_origin_r" "10" "origin: row"
assert_eq "$_tuish_draw_origin_c" "5" "origin: col"

tuish_draw_set_origin
assert_eq "$_tuish_draw_origin_r" "0" "origin: reset row"
assert_eq "$_tuish_draw_origin_c" "0" "origin: reset col"

tuish_draw_set_clip 3 20
assert_eq "$_tuish_draw_clip" "1" "clip: enabled"
assert_eq "$_tuish_draw_clip_top" "3" "clip: top"
assert_eq "$_tuish_draw_clip_bot" "20" "clip: bot"

tuish_draw_reset_clip
assert_eq "$_tuish_draw_clip" "0" "clip: disabled"

# ─── Point transform (_tuish_draw_xform) ─────────────────────────

# No origin, no clip
tuish_draw_set_origin 0 0
tuish_draw_reset_clip
_tuish_draw_xform 5 10
assert_eq "$_tuish_draw_tr" "5" "xform: no origin row"
assert_eq "$_tuish_draw_tc" "10" "xform: no origin col"

# With origin offset
tuish_draw_set_origin 3 2
_tuish_draw_xform 8 7
assert_eq "$_tuish_draw_tr" "5" "xform: origin row 8-3=5"
assert_eq "$_tuish_draw_tc" "5" "xform: origin col 7-2=5"

# With clip: inside
tuish_draw_set_origin 0 0
tuish_draw_set_clip 3 20
_tuish_draw_xform 10 5 && _xr=0 || _xr=$?
assert_eq "$_xr" "0" "xform: inside clip → 0"

# With clip: above
_tuish_draw_xform 2 5 && _xr=0 || _xr=$?
assert_eq "$_xr" "1" "xform: above clip → 1"

# With clip: below
_tuish_draw_xform 21 5 && _xr=0 || _xr=$?
assert_eq "$_xr" "1" "xform: below clip → 1"

# With clip: at boundaries
_tuish_draw_xform 3 5 && _xr=0 || _xr=$?
assert_eq "$_xr" "0" "xform: at clip top → 0"
_tuish_draw_xform 20 5 && _xr=0 || _xr=$?
assert_eq "$_xr" "0" "xform: at clip bot → 0"

# Combined origin + clip
tuish_draw_set_origin 5 0
tuish_draw_set_clip 3 10
_tuish_draw_xform 8 1 && _xr=0 || _xr=$?
assert_eq "$_xr" "0" "xform: origin+clip inside (8-5=3)"
assert_eq "$_tuish_draw_tr" "3" "xform: origin+clip row"

_tuish_draw_xform 16 1 && _xr=0 || _xr=$?
assert_eq "$_xr" "1" "xform: origin+clip outside (16-5=11>10)"

# ─── Rect transform (_tuish_draw_xform_rect) ─────────────────────

# No clipping: passthrough
tuish_draw_set_origin 0 0
tuish_draw_reset_clip
_tuish_draw_xform_rect 5 3 10
assert_eq "$_tuish_draw_tr" "5" "xform_rect: no clip row"
assert_eq "$_tuish_draw_tc" "3" "xform_rect: no clip col"
assert_eq "$_tuish_draw_th" "10" "xform_rect: no clip height"
assert_eq "$_tuish_draw_ct" "0" "xform_rect: no clip ct"
assert_eq "$_tuish_draw_cb" "0" "xform_rect: no clip cb"

# Fully inside clip
tuish_draw_set_clip 3 20
_tuish_draw_xform_rect 5 1 4
assert_eq "$_tuish_draw_tr" "5" "xform_rect: inside row"
assert_eq "$_tuish_draw_th" "4" "xform_rect: inside height"
assert_eq "$_tuish_draw_ct" "0" "xform_rect: inside ct"
assert_eq "$_tuish_draw_cb" "0" "xform_rect: inside cb"

# Top clipped
_tuish_draw_xform_rect 1 1 6 && _xr=0 || _xr=$?
assert_eq "$_xr" "0" "xform_rect: top clip → 0"
assert_eq "$_tuish_draw_tr" "3" "xform_rect: top clip row clamped"
assert_eq "$_tuish_draw_th" "4" "xform_rect: top clip height 6-(3-1)=4"
assert_eq "$_tuish_draw_ct" "1" "xform_rect: top clip ct=1"
assert_eq "$_tuish_draw_cb" "0" "xform_rect: top clip cb=0"

# Bottom clipped
_tuish_draw_xform_rect 18 1 5 && _xr=0 || _xr=$?
assert_eq "$_xr" "0" "xform_rect: bot clip → 0"
assert_eq "$_tuish_draw_tr" "18" "xform_rect: bot clip row"
assert_eq "$_tuish_draw_th" "3" "xform_rect: bot clip height 20-18+1=3"
assert_eq "$_tuish_draw_ct" "0" "xform_rect: bot clip ct=0"
assert_eq "$_tuish_draw_cb" "1" "xform_rect: bot clip cb=1"

# Both clipped
tuish_draw_set_clip 5 8
_tuish_draw_xform_rect 3 1 10 && _xr=0 || _xr=$?
assert_eq "$_xr" "0" "xform_rect: both clip → 0"
assert_eq "$_tuish_draw_tr" "5" "xform_rect: both clip row"
assert_eq "$_tuish_draw_th" "4" "xform_rect: both clip height 8-5+1=4"
assert_eq "$_tuish_draw_ct" "1" "xform_rect: both clip ct=1"
assert_eq "$_tuish_draw_cb" "1" "xform_rect: both clip cb=1"

# Fully above clip
_tuish_draw_xform_rect 1 1 3 && _xr=0 || _xr=$?
assert_eq "$_xr" "1" "xform_rect: fully above → 1"

# Fully below clip
_tuish_draw_xform_rect 10 1 3 && _xr=0 || _xr=$?
assert_eq "$_xr" "1" "xform_rect: fully below → 1"

# Height reduced to zero
tuish_draw_set_clip 5 5
_tuish_draw_xform_rect 4 1 1 && _xr=0 || _xr=$?
assert_eq "$_xr" "1" "xform_rect: height→0 → 1"

# With origin offset
tuish_draw_set_origin 10 0
tuish_draw_set_clip 3 12
_tuish_draw_xform_rect 12 1 6 && _xr=0 || _xr=$?
assert_eq "$_xr" "0" "xform_rect: origin+clip inside"
assert_eq "$_tuish_draw_tr" "3" "xform_rect: origin+clip row 12-10=2→clamped to 3"
assert_eq "$_tuish_draw_th" "5" "xform_rect: origin+clip height"
assert_eq "$_tuish_draw_ct" "1" "xform_rect: origin+clip ct=1"

# ─── Border mask clipping (_tuish_draw_clip_border) ──────────────

# No clipping
_tuish_draw_ct=0 _tuish_draw_cb=0
_tuish_draw_clip_border 'tlbr'
assert_eq "$_tuish_draw_adj_border" "tlbr" "clip_border: no clip → tlbr"

# Top clipped
_tuish_draw_ct=1 _tuish_draw_cb=0
_tuish_draw_clip_border 'tlbr'
assert_eq "$_tuish_draw_adj_border" "lbr" "clip_border: top clip → lbr"

# Bottom clipped
_tuish_draw_ct=0 _tuish_draw_cb=1
_tuish_draw_clip_border 'tlbr'
assert_eq "$_tuish_draw_adj_border" "tlr" "clip_border: bot clip → tlr"

# Both clipped
_tuish_draw_ct=1 _tuish_draw_cb=1
_tuish_draw_clip_border 'tlbr'
assert_eq "$_tuish_draw_adj_border" "lr" "clip_border: both clip → lr"

# Partial border input
_tuish_draw_ct=1 _tuish_draw_cb=0
_tuish_draw_clip_border 'tb'
assert_eq "$_tuish_draw_adj_border" "b" "clip_border: tb top clip → b"

# All borders stripped
_tuish_draw_ct=1 _tuish_draw_cb=1
_tuish_draw_clip_border 'tb'
assert_eq "$_tuish_draw_adj_border" "none" "clip_border: all stripped → none"

# Only sides
_tuish_draw_ct=0 _tuish_draw_cb=0
_tuish_draw_clip_border 'lr'
assert_eq "$_tuish_draw_adj_border" "lr" "clip_border: lr no clip → lr"

_tuish_draw_ct=1 _tuish_draw_cb=1
_tuish_draw_clip_border 'lr'
assert_eq "$_tuish_draw_adj_border" "lr" "clip_border: lr both clip → lr"

# None input
_tuish_draw_ct=1 _tuish_draw_cb=1
_tuish_draw_clip_border 'none'
assert_eq "$_tuish_draw_adj_border" "none" "clip_border: none → none"

# ─── Rendering output capture ────────────────────────────────────

# Redefine stubs to capture output
_draw_out=''
_tuish_write () { _draw_out="${_draw_out}$*"; }
tuish_vmove () { _draw_out="${_draw_out}[M$1,$2]"; }
tuish_print () { _draw_out="${_draw_out}$*"; }
tuish_sgr_reset () { _draw_out="${_draw_out}[R]"; }
tuish_bold () { _draw_out="${_draw_out}[B]"; }
# draw.sh emits color via tuish_sgr with a fragment from _tuish_color_params
# (real). Capture the fragment: fg=N -> [S3N], bg=N -> [S4N], etc.
tuish_sgr () { _draw_out="${_draw_out}[S$1]"; }

# Reset viewport for rendering tests
tuish_draw_set_origin 0 0
tuish_draw_reset_clip
TUISH_DRAW_BACKEND='ascii'
_tuish_draw_cur_style='' _tuish_draw_cur_join='' _tuish_draw_cur_backend=''

# hline
_draw_out=''
tuish_draw_hline 1 1 4
assert_contains "$_draw_out" "[M1,1]" "hline: moves to position"
assert_contains "$_draw_out" "----" "hline: draws dashes"
assert_contains "$_draw_out" "[R]" "hline: resets sgr"

# hline clipped away
tuish_draw_set_clip 5 10
_draw_out=''
tuish_draw_hline 2 1 4
assert_eq "$_draw_out" "" "hline: clipped → no output"
tuish_draw_reset_clip

# vline
_draw_out=''
tuish_draw_vline 1 1 3
assert_contains "$_draw_out" "[M1,1]" "vline: first row"
assert_contains "$_draw_out" "[M2,1]" "vline: second row"
assert_contains "$_draw_out" "[M3,1]" "vline: third row"

# hdiv
_draw_out=''
_tuish_draw_cur_style=''
tuish_draw_hdiv 5 1 6
assert_contains "$_draw_out" "[M5,1]" "hdiv: moves to position"
assert_contains "$_draw_out" "+----+" "hdiv: tee_r + line + tee_l"

# cross
_draw_out=''
_tuish_draw_cur_style=''
tuish_draw_cross 3 5
assert_contains "$_draw_out" "[M3,5]" "cross: moves to position"
assert_contains "$_draw_out" "+" "cross: draws junction"

# tee directions
_draw_out=''
_tuish_draw_cur_style=''
tuish_draw_tee 2 4 r
assert_contains "$_draw_out" "[M2,4]" "tee r: moves to position"
assert_contains "$_draw_out" "+" "tee r: draws junction"

# Box rendering
_draw_out=''
_tuish_draw_cur_style=''
tuish_draw_box 1 1 5 3
assert_contains "$_draw_out" "[M1,1]" "box: top-left position"
assert_contains "$_draw_out" "+---+" "box: top border"
assert_contains "$_draw_out" "[M3,1]" "box: bottom row position"

# Box border=none
_draw_out=''
_tuish_draw_cur_style=''
tuish_draw_box 1 1 4 2 border=none bg=2
# Should have fill rows but no border chars
case "$_draw_out" in
	*+*) _has_border=1;; *) _has_border=0;;
esac
assert_eq "$_has_border" "0" "box border=none: no border chars"
assert_contains "$_draw_out" "[S42]" "box border=none: bg color set"

# Box with viewport transform
tuish_draw_set_origin 5 0
tuish_draw_reset_clip
_draw_out=''
_tuish_draw_cur_style=''
tuish_draw_box 8 1 4 3
assert_contains "$_draw_out" "[M3,1]" "box origin: row 8-5=3"
tuish_draw_set_origin 0 0

# Box fully clipped
tuish_draw_set_clip 10 20
_draw_out=''
tuish_draw_box 1 1 5 3
assert_eq "$_draw_out" "" "box: fully above clip → no output"
tuish_draw_reset_clip

# vdiv with clipping
tuish_draw_set_clip 3 6
_draw_out=''
_tuish_draw_cur_style=''
tuish_draw_vdiv 1 5 8
# Top tee should be missing (clipped), bottom tee should be missing (clipped)
# Middle verticals should be present
assert_contains "$_draw_out" "[M3,5]" "vdiv clip: starts at clip top"
assert_contains "$_draw_out" "[R]" "vdiv clip: completes"
tuish_draw_reset_clip

# fill shorthand
_draw_out=''
_tuish_draw_cur_style=''
tuish_draw_fill 1 1 3 2 4
assert_contains "$_draw_out" "[S44]" "fill: bg color set"

# fg option
_draw_out=''
_tuish_draw_cur_style=''
tuish_draw_hline 1 1 3 fg=3
assert_contains "$_draw_out" "[S33]" "hline fg: color set"

# style=heavy with ascii backend
_draw_out=''
_tuish_draw_cur_style=''
tuish_draw_hline 1 1 3 style=heavy
assert_contains "$_draw_out" "[B]" "hline heavy: bold enabled"

# ─── draw_text width clipping (regression) ───────────────────────
# The str helpers take a variable NAME; draw_text must pass _dt_text directly.
# A spurious indirection used to measure/slice the literal name "_dt_text", so
# clipped text printed garbage like "_dt_t" instead of the real characters.
refute_contains () { case "$1" in *"$2"*) assert_eq "found:$2" "absent" "$3";; *) assert_eq absent absent "$3";; esac; }
_tuish_draw_origin_r=0 _tuish_draw_origin_c=0 _tuish_draw_clip=0
_tuish_wrap=0 TUISH_VIEW_COLS=40

_draw_out=''
tuish_draw_text 1 1 "abcdefghijklmnop" maxwidth=5
assert_contains "$_draw_out" "abcde"   "draw_text maxwidth: keeps the first 5 columns"
refute_contains "$_draw_out" "abcdef"  "draw_text maxwidth: clipped at 5 (no 6th char)"
refute_contains "$_draw_out" "_dt_"    "draw_text: no internal variable-name leak"

_draw_out=''
tuish_draw_text 1 38 "abcdefghij"
assert_contains "$_draw_out" "abc"     "draw_text right-edge: prints the fitting head (cols 38-40)"
refute_contains "$_draw_out" "abcd"    "draw_text right-edge: trimmed to the 3 available columns"

# ─── tuish_draw_centered + tuish_overlay ─────────────────────────
# Mocked tuish_vmove records "[Mrow,col]", so the centered column is observable.
TUISH_VIEW_COLS=40 TUISH_VIEW_ROWS=20

_draw_out=''
tuish_draw_centered 1 "hello"               # w5 in 40 -> 1 + (40-5)/2 = 18
assert_contains "$_draw_out" "[M1,18]" "centered: ascii 'hello' at col 18"
assert_contains "$_draw_out" "hello"   "centered: ascii text drawn"

_draw_out=''
tuish_draw_centered 2 "a中b"                # display width 4 (not byte length 5)
assert_contains "$_draw_out" "[M2,19]" "centered: width-aware (wide char counts as 2)"

_draw_out=''
tuish_draw_centered 5 "hi" col=10 width=8   # 10 + (8-2)/2 = 13
assert_contains "$_draw_out" "[M5,13]" "centered: within an explicit column band"

_draw_out=''
tuish_draw_centered 1 "abcdefghij" width=4  # wider than band -> floored to band col
assert_contains "$_draw_out" "[M1,1]"  "centered: text wider than band floors to band col"

_draw_out=''
tuish_overlay "Hi" "Bye"                    # maxw3 -> box 7x4, centered in 40x20
assert_contains "$_draw_out" "Hi"      "overlay: line 1 present"
assert_contains "$_draw_out" "Bye"     "overlay: line 2 present"
assert_contains "$_draw_out" "[M10,19]" "overlay: line 1 centered inside the box"
assert_contains "$_draw_out" "[M11,19]" "overlay: line 2 centered inside the box"

test_summary
