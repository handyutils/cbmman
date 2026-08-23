#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# boxes.sh - Demo of draw.sh styles and composable box drawing
# Pages: light, heavy, double, rounded, mixed (cross-style junctions).
# n/p to switch pages, b to toggle backend, j/k to scroll, q to exit.
#
# Dual-mode: runs standalone (`sh examples/boxes.sh`) or embedded inside another
# tuish app (the host sources it and calls _bx_main inside a region). Every name
# is _bx_-prefixed; the code never knows whether it is hosted.

if test -z "${_tuish_tui_loaded:-}"
then
	_bx_standalone=1
	_dir="$(cd "$(dirname "$0")" && pwd)"
	_tuish_src_dir="${_dir}/../src"
	. "${_tuish_src_dir}/compat.sh"
	. "${_tuish_src_dir}/ord.sh"
	. "${_tuish_src_dir}/tui.sh"
	. "${_tuish_src_dir}/term.sh"
	. "${_tuish_src_dir}/event.sh"
	. "${_tuish_src_dir}/hid.sh"
	. "${_tuish_src_dir}/viewport.sh"
	. "${_tuish_src_dir}/str.sh"
	. "${_tuish_src_dir}/draw.sh"
	. "${_tuish_src_dir}/keybind.sh"
else
	_bx_standalone=0
fi

# ─── State ──────────────────────────────────────────────────────

_bx_started=no
_bx_page=0           # 0=light, 1=heavy, 2=double, 3=rounded, 4=mixed
_bx_scroll=0
_bx_real_backend=''
_bx_page_h=0
_bx_color=0
_bx_cfgv=0
_bx_cbgv=0

# ─── Style names ────────────────────────────────────────────────

_bx_style_name ()
{
	case $1 in
		0) _bx_sname='light';;
		1) _bx_sname='heavy';;
		2) _bx_sname='double';;
		3) _bx_sname='rounded';;
		4) _bx_sname='mixed';;
	esac
}

# ─── Draw helpers (style/color; clipping is handled by draw.sh) ──

# A dim label at a VIEWPORT cell, guarded on tuish_vmove.
#
# The guard is the whole point: tuish_vmove REFUSES a clipped cell (non-zero return),
# and printing anyway drops the text at whatever cell the cursor last happened to sit
# on. Standalone that almost never bites, because a cell is rejected only off-screen.
# Hosted in a CLIPPED region — a live widget scrolled under a doc pane's edge — it
# fires constantly, and the symptom is stray labels smeared across the host's chrome.
# A row/column bounds test is not a substitute: TUISH_VIEW_ROWS is the layout height,
# which stays full-size while the visible clip shrinks. Only vmove knows.
_bx_dim_at ()   # $1=row (viewport) $2=col $3=text
{
	# Row 1 is the fixed header, and the root context's clip has no upper edge, so a
	# scrolled-off row (0 or negative) would still resolve to a cell. Keep the bound.
	test "$1" -lt 2 && return 0
	tuish_dim
	tuish_text "$1" "$2" "$3"   # clips to the region (raw print bled a narrow host)
	tuish_sgr_reset
}

_bx_label ()
{
	_bx_dim_at "$(( $1 - _bx_scroll ))" "$2" "$3"
}

_bx_box ()
{
	local _r=$1 _c=$2 _w=$3 _h=$4
	shift 4

	_bx_style_name $_bx_page
	local _args="style=$_bx_sname"
	local _a
	for _a in "$@"; do
		case "$_a" in
			fg=*)
				if test $_bx_color -gt 0
				then _args="$_args fg=$_bx_cfgv"
				else _args="$_args $_a"
				fi;;
			bg=*)
				if test $_bx_color -gt 0
				then _args="$_args bg=$_bx_cbgv"
				else _args="$_args $_a"
				fi;;
			*) _args="$_args $_a";;
		esac
	done

	tuish_draw_box $_r $_c $_w $_h $_args
}

_bx_fill ()
{
	local _color=$5
	test $_bx_color -gt 0 && _color=$_bx_cbgv
	tuish_draw_fill $1 $2 $3 $4 "$_color"
}

_bx_hdiv ()
{
	local _r=$1 _c=$2 _w=$3
	shift 3
	_bx_style_name $_bx_page
	local _fg=-1
	local _a
	for _a in "$@"; do
		case "$_a" in fg=*) _fg="${_a#*=}";; esac
	done
	test $_bx_color -gt 0 && _fg=$_bx_cfgv
	tuish_draw_hdiv $_r $_c $_w style=$_bx_sname fg=$_fg
}

_bx_vdiv ()
{
	local _r=$1 _c=$2 _h=$3
	shift 3
	_bx_style_name $_bx_page
	local _fg=-1
	local _a
	for _a in "$@"; do
		case "$_a" in fg=*) _fg="${_a#*=}";; esac
	done
	test $_bx_color -gt 0 && _fg=$_bx_cfgv
	tuish_draw_vdiv $_r $_c $_h style=$_bx_sname fg=$_fg
}

_bx_cross ()
{
	local _r=$1 _c=$2
	shift 2
	_bx_style_name $_bx_page
	local _fg=-1
	local _a
	for _a in "$@"; do
		case "$_a" in fg=*) _fg="${_a#*=}";; esac
	done
	test $_bx_color -gt 0 && _fg=$_bx_cfgv
	tuish_draw_cross $_r $_c style=$_bx_sname fg=$_fg
}

_bx_hline ()
{
	local _r=$1 _c=$2 _w=$3
	shift 3
	_bx_style_name $_bx_page
	local _fg=-1
	local _a
	for _a in "$@"; do
		case "$_a" in fg=*) _fg="${_a#*=}";; esac
	done
	test $_bx_color -gt 0 && _fg=$_bx_cfgv
	tuish_draw_hline $_r $_c $_w style=$_bx_sname fg=$_fg
}

_bx_vline ()
{
	local _r=$1 _c=$2 _h=$3
	shift 3
	_bx_style_name $_bx_page
	local _fg=-1
	local _a
	for _a in "$@"; do
		case "$_a" in fg=*) _fg="${_a#*=}";; esac
	done
	test $_bx_color -gt 0 && _fg=$_bx_cfgv
	tuish_draw_vline $_r $_c $_h style=$_bx_sname fg=$_fg
}

# ─── Header (fixed at row 1, never scrolls) ────────────────────

_bx_header ()
{
	_bx_style_name $_bx_page
	# Reverse-fill the header row across OUR drawable width, then print over it.
	# (tuish_clear_to_eol would reverse-fill to the end of the physical line —
	# a full-terminal-width bar straight across an embedding host's page.)
	tuish_reverse
	tuish_clear_to_edge 1
	# tuish_text positions and clips the header bar to the region (raw print overran a
	# host pane); the reverse attribute set above carries into it, closed by the reset.
	tuish_text 1 1 " boxes.sh | ${_bx_sname} (${TUISH_DRAW_BACKEND}) | b:backend n/p c j/k q:quit "
	tuish_sgr_reset
}

# ─── Page content (same layout, rendered in page's style) ──────

_bx_page_content ()
{
	_bx_page_h=52

	# ── Row 1: Basics ──
	_bx_label 3 2 'default'
	_bx_box 4 2 16 5

	_bx_label 3 20 'fg=4 bg=0'
	_bx_box 4 20 16 5 fg=4 bg=0

	_bx_label 3 38 'wide'
	_bx_box 4 38 30 5 fg=3 bg=234

	# ── Row 2: Partial borders ──
	_bx_label 10 2 'border=tb'
	_bx_box 11 2 14 5 border=tb fg=3

	_bx_label 10 18 'border=lr'
	_bx_box 11 18 14 5 border=lr fg=2

	_bx_label 10 34 'border=tl'
	_bx_box 11 34 14 5 border=tl fg=5

	_bx_label 10 50 'border=br'
	_bx_box 11 50 14 5 border=br fg=6

	# ── Row 3: Dividers ──
	_bx_label 17 2 'hdiv (header/body)'
	_bx_box 18 2 22 7 fg=4
	_bx_hdiv 20 2 22 fg=4

	_bx_label 17 26 'vdiv (sidebar)'
	_bx_box 18 26 22 7 fg=2
	_bx_vdiv 18 35 7 fg=2

	_bx_label 17 50 '2x2 grid'
	_bx_box 18 50 22 7 fg=6
	_bx_hdiv 21 50 22 fg=6
	_bx_vdiv 18 61 7 fg=6
	_bx_cross 21 61 fg=6

	# ── Row 4: Bare lines ──
	_bx_label 26 2 'hline'
	_bx_hline 27 2 20 fg=5

	_bx_label 26 24 'vline'
	_bx_vline 27 24 4 fg=5

	_bx_label 26 31 'nested boxes'
	_bx_box 27 31 24 6 fg=4 bg=0
	_bx_box 28 33 20 4 fg=6 bg=232

	# ── Row 5: Composed layout ──
	_bx_label 33 2 'app layout:'
	_bx_box 34 2 50 10 fg=4
	_bx_hdiv 36 2 50 fg=4
	_bx_vdiv 36 16 8 fg=4

	# Labels inside the composed layout
	local _lr
	_lr=$((35 - _bx_scroll))
	_bx_dim_at $_lr 4 'Header'
	_lr=$((37 - _bx_scroll))
	_bx_dim_at $_lr 4 'Nav'
	_bx_dim_at $_lr 18 'Content area'

	# ── Row 6: Color palette ──
	_bx_label 45 2 'color palette:'
	_bx_box 46 2  6 3 fg=1 bg=0
	_bx_box 46 9  6 3 fg=2 bg=0
	_bx_box 46 16 6 3 fg=3 bg=0
	_bx_box 46 23 6 3 fg=4 bg=0
	_bx_box 46 30 6 3 fg=5 bg=0
	_bx_box 46 37 6 3 fg=6 bg=0
	_bx_box 46 44 6 3 fg=9 bg=0
	_bx_box 46 51 6 3 fg=10 bg=0
	_bx_box 46 58 6 3 fg=11 bg=0
	_bx_box 46 65 6 3 fg=14 bg=0
}

# ─── Page: Mixed junctions (join=) ─────────────────────────────

_bx_page_mixed ()
{
	_bx_page_h=48

	# ── Section 1: light dividers in double box ──
	_bx_label 3 2 'double box + light hdiv'
	tuish_draw_box 4 2 24 6 style=double fg=4
	tuish_draw_hdiv 6 2 24 style=light join=double fg=4

	_bx_label 3 28 'double box + light grid'
	tuish_draw_box 4 28 24 6 style=double fg=5
	tuish_draw_hdiv 6 28 24 style=light join=double fg=5
	tuish_draw_vdiv 4 40 6 style=light join=double fg=5
	tuish_draw_cross 6 40 style=light fg=5

	_bx_label 3 54 'light box + double hdiv'
	tuish_draw_box 4 54 22 6 style=light fg=6
	tuish_draw_hdiv 6 54 22 style=double join=light fg=6

	# ── Section 2: light/heavy mixing ──
	_bx_label 11 2 'heavy box + light hdiv'
	tuish_draw_box 12 2 24 6 style=heavy fg=3
	tuish_draw_hdiv 14 2 24 style=light join=heavy fg=3

	_bx_label 11 28 'light box + heavy grid'
	tuish_draw_box 12 28 24 6 style=light fg=2
	tuish_draw_hdiv 14 28 24 style=heavy join=light fg=2
	tuish_draw_vdiv 12 40 6 style=heavy join=light fg=2
	tuish_draw_cross 14 40 style=heavy fg=2

	_bx_label 11 54 'heavy box + light vdiv'
	tuish_draw_box 12 54 22 6 style=heavy fg=1
	tuish_draw_vdiv 12 65 6 style=light join=heavy fg=1

	# ── Section 3: mixed cross showcase ──
	_bx_label 19 2 'mixed crosses:'
	# ╫ = light horizontal, double vertical
	_bx_label 20 2 'light h + double v'
	tuish_draw_box 21 2 18 7 style=double fg=4
	tuish_draw_hdiv 24 2 18 style=light join=double fg=4
	tuish_draw_vdiv 21 11 7 style=double fg=4
	tuish_draw_cross 24 11 style=light join=double fg=4

	# ╪ = double horizontal, light vertical
	_bx_label 20 22 'double h + light v'
	tuish_draw_box 21 22 18 7 style=light fg=5
	tuish_draw_hdiv 24 22 18 style=double join=light fg=5
	tuish_draw_vdiv 21 31 7 style=light fg=5
	tuish_draw_cross 24 31 style=double join=light fg=5

	# ┿ = heavy horizontal, light vertical
	_bx_label 20 42 'heavy h + light v'
	tuish_draw_box 21 42 18 7 style=light fg=2
	tuish_draw_hdiv 24 42 18 style=heavy join=light fg=2
	tuish_draw_vdiv 21 51 7 style=light fg=2
	tuish_draw_cross 24 51 style=heavy join=light fg=2

	# ╂ = light horizontal, heavy vertical
	_bx_label 20 62 'light h + heavy v'
	tuish_draw_box 21 62 16 7 style=heavy fg=3
	tuish_draw_hdiv 24 62 16 style=light join=heavy fg=3
	tuish_draw_vdiv 21 70 7 style=heavy fg=3
	tuish_draw_cross 24 70 style=light join=heavy fg=3

	# ── Section 4: composed app layout with mixed styles ──
	_bx_label 29 2 'double frame + light internals:'
	tuish_draw_box 30 2 50 10 style=double fg=4
	tuish_draw_hdiv 32 2 50 style=light join=double fg=4
	tuish_draw_vdiv 32 16 8 style=light join=double fg=4
	tuish_draw_tee 32 16 d style=light fg=4

	local _lr
	_lr=$((31 - _bx_scroll))
	_bx_dim_at $_lr 4 'Header'
	_lr=$((33 - _bx_scroll))
	_bx_dim_at $_lr 4 'Nav'
	_bx_dim_at $_lr 18 'Content area'

	_bx_label 29 54 'heavy frame + light internals:'
	tuish_draw_box 30 54 24 10 style=heavy fg=2
	tuish_draw_hdiv 32 54 24 style=light join=heavy fg=2
	tuish_draw_vdiv 32 65 8 style=light join=heavy fg=2
	tuish_draw_tee 32 65 d style=light fg=2

	_lr=$((31 - _bx_scroll))
	_bx_dim_at $_lr 56 'Title'
	_lr=$((33 - _bx_scroll))
	_bx_dim_at $_lr 56 'Side'
	_bx_dim_at $_lr 67 'Main'

	# ── Section 5: junction char reference ──
	_bx_label 41 2 'junction reference (style:join):'
	_bx_label 42 2 'l:d'
	tuish_draw_hdiv 43 2 6 style=light join=double fg=4
	_bx_label 42 10 'd:l'
	tuish_draw_hdiv 43 10 6 style=double join=light fg=5
	_bx_label 42 18 'l:h'
	tuish_draw_hdiv 43 18 6 style=light join=heavy fg=2
	_bx_label 42 26 'h:l'
	tuish_draw_hdiv 43 26 6 style=heavy join=light fg=3
	_bx_label 42 34 'l:l'
	tuish_draw_hdiv 43 34 6 style=light fg=7
	_bx_label 42 42 'h:h'
	tuish_draw_hdiv 43 42 6 style=heavy fg=7
	_bx_label 42 50 'd:d'
	tuish_draw_hdiv 43 50 6 style=double fg=7
}

# ─── Redraw ─────────────────────────────────────────────────────

_bx_redraw ()
{
	tuish_begin
	# Clear our drawable area only (the whole screen standalone; just our region
	# when hosted) so an embedding host's chrome is never wiped.
	tuish_clear_region 1 1 "$TUISH_VIEW_COLS" "$TUISH_VIEW_ROWS"

	tuish_draw_set_origin $_bx_scroll 0
	tuish_draw_set_clip 2 $TUISH_VIEW_ROWS

	if test $_bx_page -eq 4
	then _bx_page_mixed
	else _bx_page_content
	fi

	_bx_header
	tuish_end
}

# ─── Actions ─────────────────────────────────────────────────────

_bx_quit ()   { tuish_quit_main; }
_bx_resize () { tuish_request_redraw; }

_bx_next ()
{
	_bx_page=$(( (_bx_page + 1) % 5 ))
	_bx_scroll=0
	tuish_request_redraw
}

_bx_prev ()
{
	_bx_page=$(( (_bx_page + 3) % 5 ))
	_bx_scroll=0
	tuish_request_redraw
}

_bx_toggle_backend ()
{
	case "$TUISH_DRAW_BACKEND" in
		unicode) TUISH_DRAW_BACKEND='ascii';;
		*)       TUISH_DRAW_BACKEND='unicode';;
	esac
	# No cache to invalidate by hand: _tuish_draw_set_style keys its cache on the
	# backend as well as the style, so switching the backend misses it on the next
	# draw and it re-evaluates itself. This used to poke _tuish_draw_cur_style from
	# out here, which stopped being necessary when the cache learned the backend.
	tuish_request_redraw
}

_bx_scroll_down ()
{
	local _max=$((_bx_page_h - TUISH_VIEW_ROWS + 2))
	test $_max -lt 0 && _max=0
	test $_bx_scroll -lt $_max && {
		_bx_scroll=$((_bx_scroll + 3))
		test $_bx_scroll -gt $_max && _bx_scroll=$_max
		tuish_request_redraw
	}
}

_bx_scroll_up ()
{
	test $_bx_scroll -gt 0 && {
		_bx_scroll=$((_bx_scroll - 3))
		test $_bx_scroll -lt 0 && _bx_scroll=0
		tuish_request_redraw
	}
}

_bx_cycle_color ()
{
	_bx_color=$(( (_bx_color + 1) % 7 ))
	case $_bx_color in
		1) _bx_cfgv=6;  _bx_cbgv=0;;
		2) _bx_cfgv=3;  _bx_cbgv=232;;
		3) _bx_cfgv=1;  _bx_cbgv=234;;
		4) _bx_cfgv=4;  _bx_cbgv=17;;
		5) _bx_cfgv=2;  _bx_cbgv=52;;
		6) _bx_cfgv=5;  _bx_cbgv=22;;
	esac
	tuish_request_redraw
}

_bx_idle ()
{
	if test "$_bx_started" = 'no'
	then
		_bx_started=yes
		_bx_real_backend="$TUISH_DRAW_BACKEND"
		_bx_redraw
	fi
}

# ─── Main ────────────────────────────────────────────────────────

# Everything but the event loop. Split out of _bx_main so a cooperative host can
# tuish_ctx_mount us and drive us from ITS loop (we never call tuish_run then).
# Bindings and the render handler are registered here, after tuish_init, so they land
# in whichever context is active — the root standalone, our region when hosted.
_bx_setup ()
{
	_bx_started=no
	_bx_scroll=0

	tuish_init
	tuish_mouse_on
	tuish_on_redraw _bx_redraw
	tuish_bind 'ctrl-w'  '_bx_quit'
	tuish_bind 'char q'  '_bx_quit'   # q works everywhere; Ctrl+W is reserved by browsers
	tuish_bind 'idle'    '_bx_idle'
	tuish_bind 'resize'  '_bx_resize'
	tuish_bind 'char n'  '_bx_next'
	tuish_bind 'char p'  '_bx_prev'
	tuish_bind 'char b'  '_bx_toggle_backend'
	tuish_bind 'char c'  '_bx_cycle_color'
	tuish_bind 'char j'  '_bx_scroll_down'
	tuish_bind 'char k'  '_bx_scroll_up'
	tuish_bind 'down'    '_bx_scroll_down'
	tuish_bind 'up'      '_bx_scroll_up'
	tuish_bind 'wdown'   '_bx_scroll_down'
	tuish_bind 'whup'    '_bx_scroll_up'

	tuish_viewport fullscreen
}

# Entry point for the BLOCKING form: standalone (the bootstrap below) or a modal host
# that runs us inside a region it created and gets control back when we quit.
_bx_main ()
{
	_bx_setup
	tuish_run || :
	tuish_fini
}

if test "${_bx_standalone:-0}" -eq 1
then
	_bx_main
fi
