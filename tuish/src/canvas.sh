# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Load guard: skip re-definition if already sourced (see tui.sh).
if test -n "${_tuish_canvas_loaded:-}"; then return 0; fi
_tuish_canvas_loaded=1
# src/canvas.sh - Canvas: a bounded drawing surface within the viewport
# Optional module. Source after term.sh.
#
# A canvas is a rectangular sub-region of the viewport with its own local,
# 1-based CELL coordinate system: canvas-local (1,1) is the canvas top-left.
# While a canvas is active, tuish_vmove — and therefore every positioned
# primitive built on it (tuish_print_at, draw.sh ops, ...) — translates
# canvas-local coordinates onto the screen and clips to the canvas bounds on
# all four edges. A cell may span CW x CH terminal columns/rows, so a canvas
# with CW=2 addresses a grid of 2-wide glyphs (e.g. emoji) with plain 1..W
# column indices. The canvas composes with the viewport the way the viewport
# composes with the terminal — one level down.
#
# Provides:
#   tuish_canvas R C W H [CW] [CH] - define + activate a canvas
#   tuish_canvas_off               - deactivate (back to plain viewport coords)
#   tuish_canvas_clear             - clear the canvas interior (spaces)
#
# Variables (set by tuish_canvas):
#   TUISH_CANVAS        - 1 while a canvas is active, 0 otherwise
#   TUISH_CANVAS_W/H    - canvas size in cells
#   TUISH_CANVAS_CW/CH  - cell size in terminal columns/rows
#
# Dependencies: term.sh (tuish_clear_region) and a viewport (TUISH_VIEW_TOP).
# The _tuish_canvas_* state and TUISH_CANVAS* defaults live in tui.sh so
# tuish_vmove's canvas branch stays inert when this module is not sourced.

# tuish_canvas R C W H [CW] [CH]
# R C: canvas top-left in viewport-relative coords (1-based). W H: canvas size
# in cells. CW CH: terminal columns/rows per cell (default 1x1). Activates it.
# Integer floor/ceil division (shells truncate toward zero, which is ceil for a
# negative quotient and floor for a positive one — so each needs one correction).
# Result in _tuish_div.
_tuish_ceil_div ()   # $1=a $2=b>0
{
	_tuish_div=$(( $1 / $2 ))
	test $(( $1 % $2 )) -ne 0 && test $1 -gt 0 && _tuish_div=$(( _tuish_div + 1 ))
	return 0
}
_tuish_floor_div ()  # $1=a $2=b>0
{
	_tuish_div=$(( $1 / $2 ))
	test $(( $1 % $2 )) -ne 0 && test $1 -lt 0 && _tuish_div=$(( _tuish_div - 1 ))
	return 0
}

# Intersect the canvas's own cell clip with the context's BASE clip — the window a
# hosted child may draw through. tuish_vmove clips a logical coordinate and only
# THEN maps it to an absolute cell; it never re-checks the result against the base.
# So a canvas that overwrote the clip outright (as this did) could address cells
# outside its host's region entirely, and a child scrolled partly out of a pane
# would leak its hidden rows over the host's chrome.
#
# The two clips live in different spaces, so this is a conversion, not a min/max:
# base bounds are viewport-logical cells, canvas bounds are CWxCH-scaled canvas
# cells at an offset. Canvas cell r is visible iff its origin row lands inside the
# base window:  off_r + (r-1)*ch  ∈  [base_lrmin - 1, base_lrmax - 1]   (cols alike).
# For the root context the base is ±99999, so this is a no-op — an unhosted canvas
# behaves exactly as before.
_tuish_canvas_clamp ()
{
	local _lo _hi
	_tuish_ceil_div  $(( _tuish_base_lrmin - 1 - _tx_off_r )) $_tx_ch; _lo=$(( _tuish_div + 1 ))
	_tuish_floor_div $(( _tuish_base_lrmax - 1 - _tx_off_r )) $_tx_ch; _hi=$(( _tuish_div + 1 ))
	test $_lo -gt $_tx_lrmin && _tx_lrmin=$_lo
	test $_hi -lt $_tx_lrmax && _tx_lrmax=$_hi

	_tuish_ceil_div  $(( _tuish_base_lcmin - 1 - _tx_off_c )) $_tx_cw; _lo=$(( _tuish_div + 1 ))
	_tuish_floor_div $(( _tuish_base_lcmax - 1 - _tx_off_c )) $_tx_cw; _hi=$(( _tuish_div + 1 ))
	test $_lo -gt $_tx_lcmin && _tx_lcmin=$_lo
	test $_hi -lt $_tx_lcmax && _tx_lcmax=$_hi
	return 0
}

tuish_canvas ()
{
	_tuish_canvas_r=$1
	_tuish_canvas_c=$2
	TUISH_CANVAS_W=$3
	TUISH_CANVAS_H=$4
	TUISH_CANVAS_CW=${5:-1}
	TUISH_CANVAS_CH=${6:-1}
	# Configure the vmove transform: origin relative to the live viewport top,
	# CWxCH cell scale, and a 4-edge clip to the canvas's W x H cells — then
	# intersect that with the context's base clip so the canvas can never draw
	# outside the region its context was given.
	_tx_off_r=$(( $1 - 1 ))
	_tx_off_c=$(( $2 - 1 ))
	_tx_ch=$TUISH_CANVAS_CH
	_tx_cw=$TUISH_CANVAS_CW
	_tx_lrmin=1
	_tx_lrmax=$4
	_tx_lcmin=1
	_tx_lcmax=$3
	_tuish_canvas_clamp
	_tuish_canvas_on=1
	TUISH_CANVAS=1
}

# Deactivate the canvas; subsequent moves use plain viewport coordinates.
tuish_canvas_off ()
{
	_tuish_tx_reset
	_tuish_canvas_on=0
	TUISH_CANVAS=0
}

# Clear the canvas interior to spaces — the canvas-aware alternative to
# tuish_clear_screen. Fills W*CW by H*CH terminal cells, leaving everything
# outside the canvas (and the rest of the screen) untouched.
tuish_canvas_clear ()
{
	local _cc_w=$(( TUISH_CANVAS_W * TUISH_CANVAS_CW ))
	local _cc_h=$(( TUISH_CANVAS_H * TUISH_CANVAS_CH ))
	# Clear in plain viewport coords (transform reset) so the region is not
	# re-scaled — R,C are already viewport-relative — then restore the canvas.
	_tuish_tx_reset
	tuish_clear_region "$_tuish_canvas_r" "$_tuish_canvas_c" "$_cc_w" "$_cc_h"
	tuish_canvas "$_tuish_canvas_r" "$_tuish_canvas_c" "$TUISH_CANVAS_W" "$TUISH_CANVAS_H" "$TUISH_CANVAS_CW" "$TUISH_CANVAS_CH"
}
