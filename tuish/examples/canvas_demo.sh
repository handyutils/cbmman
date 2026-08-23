#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# canvas_demo.sh - two independently scrollable, boxed panels in a partial
# viewport. The flagship canvas showcase + integration stress test.
#
# Each panel is a draw.sh BOX (decoration, drawn in viewport coords) wrapping a
# CANVAS (src/canvas.sh) that holds the scrollable content. The content list is
# far taller than the canvas, and every line is drawn at its scrolled row —
# rows outside the canvas are CLIPPED by the canvas, so one panel's overflow can
# never spill into the other panel or the status line.
#
# Tab switches the focused panel; up/down (or j/k) move the selection and
# scroll; left/right pan horizontally; q or Ctrl-W quits.
#
# Dual-mode: run it standalone (`sh examples/canvas_demo.sh`) or embed it inside
# another tuish app. When a host has already loaded tuish, we skip our own
# bootstrap and expose _cd_main for the host to run inside a region it created.
# Every name is _cd_-prefixed so nothing collides with the host or a sibling app;
# the code itself is unchanged and never knows whether it is hosted.

# Bring up shell options + modules only when we are the top-level program. If a
# host already sourced tuish (_tuish_tui_loaded set), reuse its modules and do not
# touch its shell options or resolve $0.
if test -z "${_tuish_tui_loaded:-}"
then
	_cd_standalone=1
	set -euf
	_cd_dir="$(cd "$(dirname "$0")" && pwd)"
	_cd_src="${_cd_dir}/../src"
	. "${_cd_src}/compat.sh"
	. "${_cd_src}/ord.sh"
	. "${_cd_src}/tui.sh"
	. "${_cd_src}/term.sh"
	. "${_cd_src}/canvas.sh"
	. "${_cd_src}/event.sh"
	. "${_cd_src}/hid.sh"
	. "${_cd_src}/viewport.sh"
	. "${_cd_src}/str.sh"
	. "${_cd_src}/draw.sh"
	. "${_cd_src}/keybind.sh"
else
	_cd_standalone=0
fi

# Layout (viewport-relative). Two 20x8 boxes side by side, content 18x6 inside.
_cd_NLINES=24
_cd_BOX_R=2 _cd_BOX_W=20 _cd_BOX_H=8
_cd_IN_W=$(( _cd_BOX_W - 2 )) _cd_IN_H=$(( _cd_BOX_H - 2 ))
_cd_P0_C=2 _cd_P1_C=24

# Per-panel state: scroll top (0-based), selected line, horizontal pan.
_cd_focus=0
_cd_help=0
_cd_top_0=0 _cd_sel_0=0 _cd_h_0=0
_cd_top_1=0 _cd_sel_1=0 _cd_h_1=0

_cd_pad2 () { if test "$1" -lt 10; then _cd_p2="0$1"; else _cd_p2="$1"; fi; }

# Content line for panel $1, index $2 -> _cd_lt. Left lines are short; right lines
# overflow the panel width so the horizontal slice (str_window) is exercised.
_cd_line_text ()
{
	_cd_pad2 "$2"
	if test "$1" -eq 0
	then _cd_lt="L${_cd_p2} item ${_cd_p2}"
	else _cd_lt="R${_cd_p2} a fairly long row END${_cd_p2}"
	fi
}

_cd_render_panel ()   # $1 panel  $2 box-col  $3 top  $4 sel  $5 hoff
{
	local _p=$1 _bc=$2 _top=$3 _sel=$4 _h=$5
	local _style=light
	test "$_cd_focus" -eq "$_p" && _style=heavy

	# Box frame + title in viewport coords (canvas OFF).
	tuish_canvas_off
	tuish_draw_box "$_cd_BOX_R" "$_bc" "$_cd_BOX_W" "$_cd_BOX_H" style="$_style"
	if test "$_p" -eq 0
	then tuish_print_at "$_cd_BOX_R" "$(( _bc + 2 ))" " LEFT "
	else tuish_print_at "$_cd_BOX_R" "$(( _bc + 2 ))" " RIGHT "
	fi

	# Scrollable content in a clipped canvas inset by the border.
	tuish_canvas $(( _cd_BOX_R + 1 )) $(( _bc + 1 )) "$_cd_IN_W" "$_cd_IN_H"
	local _i=0 _crow _t _hl
	while test "$_i" -lt "$_cd_NLINES"
	do
		_crow=$(( _i - _top + 1 ))      # canvas row; clipped if <1 or >IN_H
		_cd_line_text "$_p" "$_i"; _t="$_cd_lt"
		tuish_str_window _t "$_h" "$_cd_IN_W"
		_hl=0
		test "$_i" -eq "$_sel" && test "$_crow" -ge 1 && test "$_crow" -le "$_cd_IN_H" && _hl=1
		test "$_hl" -eq 1 && tuish_sgr 7
		tuish_print_at "$_crow" 1 "$TUISH_SWINDOW"
		test "$_hl" -eq 1 && tuish_sgr_reset
		_i=$(( _i + 1 ))
	done
	tuish_canvas_off
}

_cd_render ()
{
	tuish_hide_cursor
	tuish_canvas_off
	tuish_clear_region 1 1 "$TUISH_VIEW_COLS" "$TUISH_VIEW_ROWS"
	tuish_print_at 1 1 "canvas demo — Tab: focus  ↑↓/jk: scroll  ←→: pan  q: quit"
	_cd_render_panel 0 "$_cd_P0_C" "$_cd_top_0" "$_cd_sel_0" "$_cd_h_0"
	_cd_render_panel 1 "$_cd_P1_C" "$_cd_top_1" "$_cd_sel_1" "$_cd_h_1"
	tuish_canvas_off
	local _fl=LEFT
	test "$_cd_focus" -eq 1 && _fl=RIGHT
	tuish_print_at $(( _cd_BOX_R + _cd_BOX_H )) 1 "focus: $_fl   ?: help   (clipped rows never leak between panels)"

	# A centered modal overlay, drawn last so it sits opaque OVER the panels.
	if test "$_cd_help" -eq 1
	then
		tuish_canvas_off
		tuish_overlay \
			"canvas demo — keys" \
			"" \
			"Tab    switch panel" \
			"up/dn  scroll + select" \
			"lt/rt  pan horizontally" \
			"?      toggle this help" \
			"q      quit"
	fi
	tuish_flush
}

# Move the focused panel's selection by $1; keep it visible via clamp_scroll.
_cd_panel_move ()   # $1 delta
{
	local _s _t
	eval "_s=\$_cd_sel_$_cd_focus _t=\$_cd_top_$_cd_focus"
	_s=$(( _s + $1 ))
	test "$_s" -lt 0 && _s=0
	test "$_s" -gt $(( _cd_NLINES - 1 )) && _s=$(( _cd_NLINES - 1 ))
	tuish_clamp_scroll "$_s" "$_t" "$_cd_IN_H"
	_t=$TUISH_SCROLL
	eval "_cd_sel_$_cd_focus=$_s _cd_top_$_cd_focus=$_t"
	tuish_request_redraw
}

_cd_pan ()   # $1 delta
{
	local _h
	eval "_h=\$_cd_h_$_cd_focus"
	_h=$(( _h + $1 ))
	test "$_h" -lt 0 && _h=0
	eval "_cd_h_$_cd_focus=$_h"
	tuish_request_redraw
}

_cd_toggle ()      { _cd_focus=$(( 1 - _cd_focus )); tuish_request_redraw; }
_cd_toggle_help () { _cd_help=$(( 1 - _cd_help )); tuish_request_redraw; }
_cd_q ()           { tuish_quit_clear; return 0; }

# Click a panel to focus it (coordinates are already region-local when hosted).
_cd_click ()
{
	if test "$TUISH_MOUSE_X" -lt "$_cd_P1_C"
	then _cd_focus=0
	else _cd_focus=1
	fi
	tuish_request_redraw
}

# Everything up to (but not including) the event loop: fresh state, device adoption,
# handlers, bindings, viewport, first paint. Split out of _cd_main so a cooperative
# host can tuish_ctx_mount the demo and drive it from ITS loop, without _cd_main's
# blocking tuish_run. The normal lifecycle (tuish_init / tuish_fini) transparently
# adopts whichever context is active — the root standalone, our region when hosted.
_cd_setup ()
{
	# Fresh state each launch (a host may run us more than once).
	_cd_focus=0; _cd_help=0
	_cd_top_0=0; _cd_sel_0=0; _cd_h_0=0
	_cd_top_1=0; _cd_sel_1=0; _cd_h_1=0

	tuish_init
	tuish_mouse_on
	# Bindings must be registered while our context is active, so they land in its
	# namespace — hence in here (after init), not at file scope.
	tuish_on_redraw _cd_render
	tuish_bind 'tab'     '_cd_toggle'
	tuish_bind 'up'      '_cd_panel_move -1'
	tuish_bind 'char k'  '_cd_panel_move -1'
	tuish_bind 'down'    '_cd_panel_move 1'
	tuish_bind 'char j'  '_cd_panel_move 1'
	tuish_bind 'left'    '_cd_pan -1'
	tuish_bind 'right'   '_cd_pan 1'
	tuish_bind 'whup'    '_cd_panel_move -1'
	tuish_bind 'wdown'   '_cd_panel_move 1'
	tuish_bind 'lclik'   '_cd_click'
	tuish_bind 'char ?'  '_cd_toggle_help'
	tuish_bind 'ctrl-w'  '_cd_q'
	tuish_bind 'char q'  '_cd_q'
	tuish_bind 'resize'  'tuish_request_redraw'
	# tuish_pass, not ':' — ':' would silently EAT every event a host offers us,
	# including a wheel we have no binding for, and the host would stop scrolling.
	tuish_bind '*'       'tuish_pass'

	tuish_viewport fixed $(( _cd_BOX_R + _cd_BOX_H ))
	_cd_render
}

# Entry point for the BLOCKING form: standalone (the bootstrap below) or a modal host
# that runs us inside a region it created and gets control back when we quit.
_cd_main ()
{
	_cd_setup
	tuish_run || :
	tuish_fini
}

# Standalone bootstrap: run only when we are the top-level program.
if test "${_cd_standalone:-0}" -eq 1
then
	_cd_main
fi
