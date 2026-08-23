#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Load guard: skip re-definition if already sourced (see tui.sh).
if test -n "${_tuish_draw_loaded:-}"; then return 0; fi
_tuish_draw_loaded=1
# src/draw.sh - Box drawing with style support, mixed-style junctions, viewport clipping
# Optional module. Source after term.sh and str.sh.
#
# Backends (auto-detected, stored in TUISH_DRAW_BACKEND):
#   ascii   - always available: +-.|=#  (bold for heavy style)
#   unicode - UTF-8 locale: ┌─┐│└┘  ┏━┓┃┗┛  ╔═╗║╚╝  ╭╮╰╯
#
# Styles: light (default), heavy, double, rounded
#
# Dividers accept join=STYLE to produce mixed junction characters
# when a divider of one style meets a border of another style.
#
# Viewport:
#   tuish_draw_set_origin ROW COL - offset subtracted from coordinates
#   tuish_draw_set_clip TOP BOT   - vertical clip region (screen rows)
#   tuish_draw_reset_clip          - disable clipping
#
# Text:
#   tuish_draw_text ROW COL TEXT [maxwidth=N] [fg=N] [bg=N] - positioned text
#   tuish_draw_centered ROW TEXT [col=N] [width=N] [fg=N] [bg=N]
#       - center TEXT (display-width-aware) in a column band (default: viewport)
#   tuish_overlay LINE [LINE...] - centered, auto-sized, opaque modal box

# ─── Locale (reads originals saved by compat.sh before LC_ALL=C) ──

_tuish_draw_orig_lang="${_tuish_orig_lang:-}"
_tuish_draw_orig_lc_all="${_tuish_orig_lc_all:-}"
_tuish_draw_orig_lc_ctype="${_tuish_orig_lc_ctype:-}"

# ─── State ─────────────────────────────────────────────────────────

TUISH_DRAW_BACKEND='ascii'

# Viewport transform + clipping state
_tuish_draw_origin_r=0
_tuish_draw_origin_c=0
_tuish_draw_clip=0
_tuish_draw_clip_top=1
_tuish_draw_clip_bot=9999

# The draw origin/clip layer is per-context. (TUISH_DRAW_BACKEND is registered
# below, after its source-time detection, so its captured default is the detected
# value.)
tuish_ctx_register \
	_tuish_draw_origin_r _tuish_draw_origin_c _tuish_draw_clip \
	_tuish_draw_clip_top _tuish_draw_clip_bot

# ─── Unicode box-drawing characters (hex-encoded UTF-8) ───────────

# Light
_tuish_draw_u_h='\xE2\x94\x80'         # ─ U+2500
_tuish_draw_u_v='\xE2\x94\x82'         # │ U+2502
_tuish_draw_u_tl='\xE2\x94\x8C'        # ┌ U+250C
_tuish_draw_u_tr='\xE2\x94\x90'        # ┐ U+2510
_tuish_draw_u_bl='\xE2\x94\x94'        # └ U+2514
_tuish_draw_u_br='\xE2\x94\x98'        # ┘ U+2518
_tuish_draw_u_tee_r='\xE2\x94\x9C'     # ├ U+251C
_tuish_draw_u_tee_l='\xE2\x94\xA4'     # ┤ U+2524
_tuish_draw_u_tee_d='\xE2\x94\xAC'     # ┬ U+252C
_tuish_draw_u_tee_u='\xE2\x94\xB4'     # ┴ U+2534
_tuish_draw_u_cross='\xE2\x94\xBC'     # ┼ U+253C

# Heavy
_tuish_draw_u_hv_h='\xE2\x94\x81'      # ━ U+2501
_tuish_draw_u_hv_v='\xE2\x94\x83'      # ┃ U+2503
_tuish_draw_u_hv_tl='\xE2\x94\x8F'     # ┏ U+250F
_tuish_draw_u_hv_tr='\xE2\x94\x93'     # ┓ U+2513
_tuish_draw_u_hv_bl='\xE2\x94\x97'     # ┗ U+2517
_tuish_draw_u_hv_br='\xE2\x94\x9B'     # ┛ U+251B
_tuish_draw_u_hv_tee_r='\xE2\x94\xA3'  # ┣ U+2523
_tuish_draw_u_hv_tee_l='\xE2\x94\xAB'  # ┫ U+252B
_tuish_draw_u_hv_tee_d='\xE2\x94\xB3'  # ┳ U+2533
_tuish_draw_u_hv_tee_u='\xE2\x94\xBB'  # ┻ U+253B
_tuish_draw_u_hv_cross='\xE2\x95\x8B'  # ╋ U+254B

# Double
_tuish_draw_u_db_h='\xE2\x95\x90'      # ═ U+2550
_tuish_draw_u_db_v='\xE2\x95\x91'      # ║ U+2551
_tuish_draw_u_db_tl='\xE2\x95\x94'     # ╔ U+2554
_tuish_draw_u_db_tr='\xE2\x95\x97'     # ╗ U+2557
_tuish_draw_u_db_bl='\xE2\x95\x9A'     # ╚ U+255A
_tuish_draw_u_db_br='\xE2\x95\x9D'     # ╝ U+255D
_tuish_draw_u_db_tee_r='\xE2\x95\xA0'  # ╠ U+2560
_tuish_draw_u_db_tee_l='\xE2\x95\xA3'  # ╣ U+2563
_tuish_draw_u_db_tee_d='\xE2\x95\xA6'  # ╦ U+2566
_tuish_draw_u_db_tee_u='\xE2\x95\xA9'  # ╩ U+2569
_tuish_draw_u_db_cross='\xE2\x95\xAC'  # ╬ U+256C

# Rounded corners (uses light h/v/tees)
_tuish_draw_u_rtl='\xE2\x95\xAD'       # ╭ U+256D
_tuish_draw_u_rtr='\xE2\x95\xAE'       # ╮ U+256E
_tuish_draw_u_rbl='\xE2\x95\xB0'       # ╰ U+2570
_tuish_draw_u_rbr='\xE2\x95\xAF'       # ╯ U+256F

# ─── Mixed junction characters (cross-style composability) ───────
# Naming: style:join (style=divider weight, join=border weight)

# Light divider joining heavy border
_tuish_draw_u_lh_tee_r='\xE2\x94\xA0'  # ┠ U+2520  heavy vert + right light
_tuish_draw_u_lh_tee_l='\xE2\x94\xA8'  # ┨ U+2528  heavy vert + left light
_tuish_draw_u_lh_tee_d='\xE2\x94\xAF'  # ┯ U+252F  heavy horiz + down light
_tuish_draw_u_lh_tee_u='\xE2\x94\xB7'  # ┷ U+2537  heavy horiz + up light
_tuish_draw_u_lh_cross='\xE2\x95\x82'  # ╂ U+2542  heavy vert + light horiz

# Heavy divider joining light border
_tuish_draw_u_hl_tee_r='\xE2\x94\x9D'  # ┝ U+251D  light vert + right heavy
_tuish_draw_u_hl_tee_l='\xE2\x94\xA5'  # ┥ U+2525  light vert + left heavy
_tuish_draw_u_hl_tee_d='\xE2\x94\xB0'  # ┰ U+2530  light horiz + down heavy
_tuish_draw_u_hl_tee_u='\xE2\x94\xB8'  # ┸ U+2538  light horiz + up heavy
_tuish_draw_u_hl_cross='\xE2\x94\xBF'  # ┿ U+253F  light vert + heavy horiz

# Light divider joining double border
_tuish_draw_u_ld_tee_r='\xE2\x95\x9F'  # ╟ U+255F  dbl vert + right single
_tuish_draw_u_ld_tee_l='\xE2\x95\xA2'  # ╢ U+2562  dbl vert + left single
_tuish_draw_u_ld_tee_d='\xE2\x95\xA4'  # ╤ U+2564  dbl horiz + down single
_tuish_draw_u_ld_tee_u='\xE2\x95\xA7'  # ╧ U+2567  dbl horiz + up single
_tuish_draw_u_ld_cross='\xE2\x95\xAB'  # ╫ U+256B  dbl vert + single horiz

# Double divider joining light border
_tuish_draw_u_dl_tee_r='\xE2\x95\x9E'  # ╞ U+255E  single vert + right dbl
_tuish_draw_u_dl_tee_l='\xE2\x95\xA1'  # ╡ U+2561  single vert + left dbl
_tuish_draw_u_dl_tee_d='\xE2\x95\xA5'  # ╥ U+2565  single horiz + down dbl
_tuish_draw_u_dl_tee_u='\xE2\x95\xA8'  # ╨ U+2568  single horiz + up dbl
_tuish_draw_u_dl_cross='\xE2\x95\xAA'  # ╪ U+256A  single vert + dbl horiz

# ─── Unicode detection (at source time) ───────────────────────────

_tuish_draw_detect_unicode ()
{
	local _tuish_draw_loc="${_tuish_draw_orig_lc_all}${_tuish_draw_orig_lc_ctype}${_tuish_draw_orig_lang}"
	case "$_tuish_draw_loc" in
		*[Uu][Tt][Ff][-_]8*|*[Uu][Tt][Ff]8*) TUISH_DRAW_BACKEND='unicode';;
	esac
}
_tuish_draw_detect_unicode

# The backend is per-context STATE seeded from the detected terminal capability:
# every context starts at the detected value, but an app that switches itself to
# ascii (boxes' backend toggle) must not leak that choice to its host or siblings.
# Registered after detection so the captured default is the detected backend. The
# style cache (_tuish_draw_cur_style/_cur_backend) keys by value and self-corrects
# on the next draw call, so it stays device-global.
tuish_ctx_register TUISH_DRAW_BACKEND

# ─── Style system ─────────────────────────────────────────────────

# Working variables (populated by _tuish_draw_set_style)
_tuish_draw_ch_h=''
_tuish_draw_ch_v=''
_tuish_draw_ch_tl=''
_tuish_draw_ch_tr=''
_tuish_draw_ch_bl=''
_tuish_draw_ch_br=''
_tuish_draw_ch_tee_r=''
_tuish_draw_ch_tee_l=''
_tuish_draw_ch_tee_d=''
_tuish_draw_ch_tee_u=''
_tuish_draw_ch_cross=''
_tuish_draw_ch_bold=0

# Cache: style + join + backend
_tuish_draw_cur_style=''
_tuish_draw_cur_join=''
_tuish_draw_cur_backend=''

# ─── Glyph rows ───────────────────────────────────────────────────
# Each row packs the 11 working glyphs in order — h v tl tr bl br tee_r tee_l
# tee_d tee_u cross — built from the named glyphs above so the catalog stays the
# single source. _tuish_draw_set_style selects a row by backend+style and splits
# it with `set --` (tokens never contain spaces; -f keeps the split glob-free).
_tuish_box_u_light="$_tuish_draw_u_h $_tuish_draw_u_v $_tuish_draw_u_tl $_tuish_draw_u_tr $_tuish_draw_u_bl $_tuish_draw_u_br $_tuish_draw_u_tee_r $_tuish_draw_u_tee_l $_tuish_draw_u_tee_d $_tuish_draw_u_tee_u $_tuish_draw_u_cross"
_tuish_box_u_heavy="$_tuish_draw_u_hv_h $_tuish_draw_u_hv_v $_tuish_draw_u_hv_tl $_tuish_draw_u_hv_tr $_tuish_draw_u_hv_bl $_tuish_draw_u_hv_br $_tuish_draw_u_hv_tee_r $_tuish_draw_u_hv_tee_l $_tuish_draw_u_hv_tee_d $_tuish_draw_u_hv_tee_u $_tuish_draw_u_hv_cross"
_tuish_box_u_double="$_tuish_draw_u_db_h $_tuish_draw_u_db_v $_tuish_draw_u_db_tl $_tuish_draw_u_db_tr $_tuish_draw_u_db_bl $_tuish_draw_u_db_br $_tuish_draw_u_db_tee_r $_tuish_draw_u_db_tee_l $_tuish_draw_u_db_tee_d $_tuish_draw_u_db_tee_u $_tuish_draw_u_db_cross"
_tuish_box_u_rounded="$_tuish_draw_u_h $_tuish_draw_u_v $_tuish_draw_u_rtl $_tuish_draw_u_rtr $_tuish_draw_u_rbl $_tuish_draw_u_rbr $_tuish_draw_u_tee_r $_tuish_draw_u_tee_l $_tuish_draw_u_tee_d $_tuish_draw_u_tee_u $_tuish_draw_u_cross"
_tuish_box_a_light='- | + + + + + + + + +'
_tuish_box_a_heavy='- | + + + + + + + + +'
_tuish_box_a_double='= | # # # # # # # # #'
_tuish_box_a_rounded="- | . . ' ' + + + + +"

# Mixed-junction override rows (unicode only): 5 glyphs tee_r tee_l tee_d tee_u
# cross, keyed dividerStyle_borderStyle. An absent pair keeps the divider's own
# junctions (e.g. heavy_double has no dedicated glyphs).
_tuish_boxj_u_light_heavy="$_tuish_draw_u_lh_tee_r $_tuish_draw_u_lh_tee_l $_tuish_draw_u_lh_tee_d $_tuish_draw_u_lh_tee_u $_tuish_draw_u_lh_cross"
_tuish_boxj_u_heavy_light="$_tuish_draw_u_hl_tee_r $_tuish_draw_u_hl_tee_l $_tuish_draw_u_hl_tee_d $_tuish_draw_u_hl_tee_u $_tuish_draw_u_hl_cross"
_tuish_boxj_u_light_double="$_tuish_draw_u_ld_tee_r $_tuish_draw_u_ld_tee_l $_tuish_draw_u_ld_tee_d $_tuish_draw_u_ld_tee_u $_tuish_draw_u_ld_cross"
_tuish_boxj_u_double_light="$_tuish_draw_u_dl_tee_r $_tuish_draw_u_dl_tee_l $_tuish_draw_u_dl_tee_d $_tuish_draw_u_dl_tee_u $_tuish_draw_u_dl_cross"

# _tuish_draw_set_style STYLE [JOIN]
# Populate _tuish_draw_ch_* from the glyph-row tables. The base 6 glyphs come
# from STYLE; the 5 junctions come from STYLE's divider joining a JOIN-styled
# border (rounded shares light's junctions). A missing mixed-junction row keeps
# the divider's own junctions, so e.g. heavy:double needs no special case.
_tuish_draw_set_style ()
{
	local _join="${2:-$1}"

	test "$1" = "$_tuish_draw_cur_style" \
		&& test "$_join" = "$_tuish_draw_cur_join" \
		&& test "$TUISH_DRAW_BACKEND" = "$_tuish_draw_cur_backend" \
		&& return 0

	_tuish_draw_cur_style="$1"
	_tuish_draw_cur_join="$_join"
	_tuish_draw_cur_backend="$TUISH_DRAW_BACKEND"

	# Normalize: unknown style -> light; the effective style (for junctions)
	# folds rounded into light. Backend prefix u/a. (Locals are _ss_-prefixed:
	# ksh93 POSIX functions don't reliably scope `local`, so a bare _row would
	# clobber the callers' _row — the codebase avoids that with unique prefixes.)
	local _ss_bp=a _ss_style="$1" _sn="$1" _jn="$_join" _ss_row
	case "$TUISH_DRAW_BACKEND" in unicode) _ss_bp=u;; esac
	case "$_ss_style" in light|heavy|double|rounded) ;; *) _ss_style=light;; esac
	case "$_sn" in heavy|double) ;; *) _sn=light;; esac
	case "$_jn" in heavy|double) ;; *) _jn=light;; esac

	# ascii heavy fakes weight with SGR bold
	_tuish_draw_ch_bold=0
	if test "$_ss_bp" = a && test "$_ss_style" = heavy; then _tuish_draw_ch_bold=1; fi

	# Base row: 11 glyphs (h v tl tr bl br tee_r tee_l tee_d tee_u cross).
	eval "_ss_row=\$_tuish_box_${_ss_bp}_${_ss_style}"
	set -- $_ss_row
	_tuish_draw_ch_h=$1     _tuish_draw_ch_v=$2
	_tuish_draw_ch_tl=$3    _tuish_draw_ch_tr=$4
	_tuish_draw_ch_bl=$5    _tuish_draw_ch_br=$6
	_tuish_draw_ch_tee_r=$7 _tuish_draw_ch_tee_l=$8
	_tuish_draw_ch_tee_d=$9 _tuish_draw_ch_tee_u=${10} _tuish_draw_ch_cross=${11}

	# Mixed junctions: unicode only, when divider and border styles differ and a
	# cross-style row exists. Otherwise the base row's own junctions stand.
	if test "$_ss_bp" = u && test "$_sn" != "$_jn"
	then
		eval "_ss_row=\${_tuish_boxj_u_${_sn}_${_jn}:-}"
		set -- $_ss_row
		if test $# -ge 5
		then
			_tuish_draw_ch_tee_r=$1 _tuish_draw_ch_tee_l=$2
			_tuish_draw_ch_tee_d=$3 _tuish_draw_ch_tee_u=$4 _tuish_draw_ch_cross=$5
		fi
	fi
}

# ─── Color utilities ──────────────────────────────────────────────

# -1 is draw.sh's internal "no color" sentinel (the default for omitted fg=/bg=).
# Real colors route through the shared term.sh parser so the grammar lives once.
_tuish_draw_set_fg ()
{
	test "$1" = -1 && return 0
	_tuish_color_params fg "$1"
	tuish_sgr "$_tuish_cparams"
}

_tuish_draw_set_bg ()
{
	test "$1" = -1 && return 0
	_tuish_color_params bg "$1"
	tuish_sgr "$_tuish_cparams"
}

_tuish_draw_set_colors ()
{
	_tuish_draw_set_fg "$1"
	_tuish_draw_set_bg "$2"
	test $_tuish_draw_ch_bold -eq 1 && tuish_bold
	return 0
}

# ─── Viewport helpers ────────────────────────────────────────────

# _tuish_draw_xform ROW COL
# Apply origin offset; check point against clip region.
# Sets: _tuish_draw_tr  _tuish_draw_tc
# Returns 1 if outside clip region or past right edge.
_tuish_draw_xform ()
{
	_tuish_draw_tr=$(($1 - _tuish_draw_origin_r))
	_tuish_draw_tc=$(($2 - _tuish_draw_origin_c))
	# Left-edge cull: column before viewport
	test $_tuish_draw_tc -lt 1 && return 1
	# Right-edge cull: column past viewport
	if test $_tuish_wrap -eq 0 && test $TUISH_VIEW_COLS -gt 0
	then _tuish_clip_avail $_tuish_draw_tc; test $_tuish_avail -lt 1 && return 1; fi
	test $_tuish_draw_clip -eq 0 && return 0
	test $_tuish_draw_tr -lt $_tuish_draw_clip_top && return 1
	test $_tuish_draw_tr -gt $_tuish_draw_clip_bot && return 1
	return 0
}

# _tuish_draw_xform_rect ROW COL H
# Apply origin offset; clamp vertical extent to clip region.
# Sets: _tuish_draw_tr  _tuish_draw_tc  _tuish_draw_th
#        _tuish_draw_ct (1=top clipped)  _tuish_draw_cb (1=bottom clipped)
# Returns 1 if fully outside clip region.
_tuish_draw_xform_rect ()
{
	_tuish_draw_tr=$(($1 - _tuish_draw_origin_r))
	_tuish_draw_tc=$(($2 - _tuish_draw_origin_c))
	_tuish_draw_th=$3
	_tuish_draw_ct=0
	_tuish_draw_cb=0
	# Right-edge cull: column past viewport
	if test $_tuish_wrap -eq 0 && test $TUISH_VIEW_COLS -gt 0
	then _tuish_clip_avail $_tuish_draw_tc; test $_tuish_avail -lt 1 && return 1; fi
	test $_tuish_draw_clip -eq 0 && return 0
	test $((_tuish_draw_tr + _tuish_draw_th - 1)) -lt $_tuish_draw_clip_top && return 1
	test $_tuish_draw_tr -gt $_tuish_draw_clip_bot && return 1
	if test $_tuish_draw_tr -lt $_tuish_draw_clip_top; then
		_tuish_draw_th=$((_tuish_draw_th - (_tuish_draw_clip_top - _tuish_draw_tr)))
		_tuish_draw_tr=$_tuish_draw_clip_top
		_tuish_draw_ct=1
	fi
	if test $((_tuish_draw_tr + _tuish_draw_th - 1)) -gt $_tuish_draw_clip_bot; then
		_tuish_draw_th=$((_tuish_draw_clip_bot - _tuish_draw_tr + 1))
		_tuish_draw_cb=1
	fi
	test $_tuish_draw_th -lt 1 && return 1
	return 0
}

# _tuish_draw_clip_border BORDER
# Adjust border mask for clipped edges (uses _tuish_draw_ct/_tuish_draw_cb).
# Sets: _tuish_draw_adj_border
_tuish_draw_clip_border ()
{
	if test $_tuish_draw_ct -eq 0 && test $_tuish_draw_cb -eq 0; then
		_tuish_draw_adj_border=$1
		return 0
	fi
	_tuish_draw_adj_border=''
	test $_tuish_draw_ct -eq 0 && case "$1" in *t*) _tuish_draw_adj_border="${_tuish_draw_adj_border}t";; esac
	case "$1" in *l*) _tuish_draw_adj_border="${_tuish_draw_adj_border}l";; esac
	test $_tuish_draw_cb -eq 0 && case "$1" in *b*) _tuish_draw_adj_border="${_tuish_draw_adj_border}b";; esac
	case "$1" in *r*) _tuish_draw_adj_border="${_tuish_draw_adj_border}r";; esac
	test -z "$_tuish_draw_adj_border" && _tuish_draw_adj_border='none'
	return 0
}

# ─── Unified renderer ────────────────────────────────────────────

_tuish_draw_box_impl ()
{
	local _row=$1 _col=$2 _w=$3 _h=$4
	local _fg=$5 _bg=$6
	local _bt=$7 _bb=$8 _bl=$9
	shift 9
	local _br=$1

	# Left-edge clipping
	local _clip_l=0
	if test $_col -lt 1; then
		_clip_l=1
		_w=$((_w - (1 - _col)))
		_col=1
		_bl=0   # left border clipped away
	fi
	test $_w -lt 1 && return 0

	# Right-edge clipping
	local _clip_r=0
	if test $_tuish_wrap -eq 0 && test $TUISH_VIEW_COLS -gt 0; then
		_tuish_clip_avail $_col; local _avail=$_tuish_avail
		test $_avail -lt 1 && return 0
		if test $_w -gt $_avail; then
			_clip_r=1
			_w=$_avail
			_br=0   # right border clipped away
		fi
	fi

	# Build horizontal line: subtract 1 per visible border char
	local _inner=$((_w))
	test $_clip_l -eq 0 && _inner=$((_inner - 1))
	test $_clip_r -eq 0 && _inner=$((_inner - 1))
	tuish_str_repeat "$_tuish_draw_ch_h" $_inner
	local _hline=$TUISH_SREPEATED

	# Build interior fill
	local _fill_w=$_w
	test $_bl -eq 1 && _fill_w=$((_fill_w - 1))
	test $_br -eq 1 && _fill_w=$((_fill_w - 1))
	test $_fill_w -lt 0 && _fill_w=0
	tuish_str_repeat ' ' $_fill_w
	local _fill=$TUISH_SREPEATED

	# Set colors
	_tuish_draw_set_colors $_fg $_bg

	# ── Top border ──
	if test $_bt -eq 1 && tuish_vmove $_row $_col
	then
		local _top=''
		if test $_clip_l -eq 0; then
			if test $_bl -eq 1
			then _top=$_tuish_draw_ch_tl
			else _top=$_tuish_draw_ch_h
			fi
		fi
		_top="${_top}${_hline}"
		if test $_clip_r -eq 0; then
			if test $_br -eq 1
			then _top="${_top}${_tuish_draw_ch_tr}"
			else _top="${_top}${_tuish_draw_ch_h}"
			fi
		fi
		_tuish_write "$_top"
	fi

	# ── Middle rows ──
	# Borders and fill are loop-invariant: build the row body once and
	# emit a single write per row.
	local _midrow=$_fill
	test $_bl -eq 1 && _midrow="${_tuish_draw_ch_v}${_midrow}"
	test $_br -eq 1 && _midrow="${_midrow}${_tuish_draw_ch_v}"
	local _r=0
	test $_bt -eq 1 && _r=1
	local _mid_end=$_h
	test $_bb -eq 1 && _mid_end=$((_h - 1))
	while test $_r -lt $_mid_end
	do
		if tuish_vmove $((_row + _r)) $_col; then _tuish_write "$_midrow"; fi
		_r=$((_r + 1))
	done

	# ── Bottom border ──
	if test $_bb -eq 1 && tuish_vmove $((_row + _h - 1)) $_col
	then
		local _bot=''
		if test $_clip_l -eq 0; then
			if test $_bl -eq 1
			then _bot=$_tuish_draw_ch_bl
			else _bot=$_tuish_draw_ch_h
			fi
		fi
		_bot="${_bot}${_hline}"
		if test $_clip_r -eq 0; then
			if test $_br -eq 1
			then _bot="${_bot}${_tuish_draw_ch_br}"
			else _bot="${_bot}${_tuish_draw_ch_h}"
			fi
		fi
		_tuish_write "$_bot"
	fi

	tuish_sgr_reset
}

# ─── Public API ───────────────────────────────────────────────────

# Viewport: set origin offset (subtracted from logical coordinates).
tuish_draw_set_origin ()
{
	_tuish_draw_origin_r=${1:-0}
	_tuish_draw_origin_c=${2:-0}
}

# Viewport: set vertical clip region (screen-space row bounds).
tuish_draw_set_clip ()
{
	_tuish_draw_clip=1
	_tuish_draw_clip_top=$1
	_tuish_draw_clip_bot=$2
}

# Viewport: disable clipping.
tuish_draw_reset_clip ()
{
	_tuish_draw_clip=0
}

tuish_draw_box ()
{
	local _db_row=$1 _db_col=$2 _db_w=$3 _db_h=$4
	shift 4

	# Defaults
	local _db_fg=-1
	local _db_bg=-1
	local _db_border='tlbr'
	local _db_style='light'

	# Parse named options
	while test $# -gt 0
	do
		case "$1" in
			fg=*)     _db_fg="${1#*=}";;
			bg=*)     _db_bg="${1#*=}";;
			border=*) _db_border="${1#*=}";;
			style=*)  _db_style="${1#*=}";;
		esac
		shift
	done

	# Viewport transform + clipping
	_tuish_draw_xform_rect $_db_row $_db_col $_db_h || return 0
	_db_row=$_tuish_draw_tr
	_db_col=$_tuish_draw_tc
	_db_h=$_tuish_draw_th
	_tuish_draw_clip_border "$_db_border"
	_db_border=$_tuish_draw_adj_border

	# Decompose border mask
	local _db_bt=0 _db_bb=0 _db_bl=0 _db_br=0
	case "$_db_border" in
		none) ;;
		*)
			case "$_db_border" in *t*) _db_bt=1;; esac
			case "$_db_border" in *b*) _db_bb=1;; esac
			case "$_db_border" in *l*) _db_bl=1;; esac
			case "$_db_border" in *r*) _db_br=1;; esac
			;;
	esac

	_tuish_draw_set_style "$_db_style"
	_tuish_draw_box_impl $_db_row $_db_col $_db_w $_db_h \
		$_db_fg $_db_bg $_db_bt $_db_bb $_db_bl $_db_br
}

tuish_draw_fill ()
{
	local _df_row=$1 _df_col=$2 _df_w=$3 _df_h=$4 _df_bg=-1
	shift 4
	while test $# -gt 0
	do
		case "$1" in
			bg=*) _df_bg="${1#*=}";;
			*)    _df_bg="$1";;
		esac
		shift
	done
	tuish_draw_box "$_df_row" "$_df_col" "$_df_w" "$_df_h" border=none bg="$_df_bg"
}

# ─── Parse style/fg/join helper (shared by divider/line funcs) ───

_tuish_draw_parse_opts ()
{
	_tuish_draw_opt_style='light'
	_tuish_draw_opt_fg=-1
	_tuish_draw_opt_join=''
	while test $# -gt 0
	do
		case "$1" in
			style=*) _tuish_draw_opt_style="${1#*=}";;
			fg=*)    _tuish_draw_opt_fg="${1#*=}";;
			join=*)  _tuish_draw_opt_join="${1#*=}";;
		esac
		shift
	done
	test -z "$_tuish_draw_opt_join" && _tuish_draw_opt_join="$_tuish_draw_opt_style"
	return 0
}

# ─── Horizontal divider: ├───┤  (or ╟───╢ with join=) ───────────

tuish_draw_hdiv ()
{
	local _row=$1 _col=$2 _w=$3
	shift 3

	# Transform (inline, not xform — need column even if < 1 for clipping)
	_row=$(($_row - _tuish_draw_origin_r))
	_col=$(($_col - _tuish_draw_origin_c))
	if test $_tuish_draw_clip -eq 1; then
		test $_row -lt $_tuish_draw_clip_top && return 0
		test $_row -gt $_tuish_draw_clip_bot && return 0
	fi

	_tuish_draw_parse_opts "$@"

	# Left-edge clipping
	local _clip_l=0
	if test $_col -lt 1; then
		_clip_l=1
		_w=$((_w - (1 - _col)))
		_col=1
	fi
	test $_w -lt 1 && return 0

	# Right-edge clipping
	local _clip_r=0
	if test $_tuish_wrap -eq 0 && test $TUISH_VIEW_COLS -gt 0; then
		_tuish_clip_avail $_col; local _avail=$_tuish_avail
		test $_avail -lt 1 && return 0
		test $_w -gt $_avail && { _clip_r=1; _w=$_avail; }
	fi

	_tuish_draw_set_style "$_tuish_draw_opt_style" "$_tuish_draw_opt_join"
	_tuish_draw_set_fg $_tuish_draw_opt_fg
	test $_tuish_draw_ch_bold -eq 1 && tuish_bold

	local _inner=$_w
	test $_clip_l -eq 0 && _inner=$((_inner - 1))
	test $_clip_r -eq 0 && _inner=$((_inner - 1))
	test $_inner -lt 0 && _inner=0
	tuish_str_repeat "$_tuish_draw_ch_h" $_inner
	local _out=''
	test $_clip_l -eq 0 && _out=$_tuish_draw_ch_tee_r
	_out="${_out}${TUISH_SREPEATED}"
	test $_clip_r -eq 0 && _out="${_out}${_tuish_draw_ch_tee_l}"
	_tuish_write_at $_row $_col "$_out"
	tuish_sgr_reset
}

# ─── Vertical divider: ┬│┴  (or ╤│╧ with join=) ────────────────

tuish_draw_vdiv ()
{
	local _row=$1 _col=$2 _h=$3
	shift 3
	_tuish_draw_parse_opts "$@"

	test $_h -lt 2 && return 0

	_tuish_draw_xform_rect $_row $_col $_h || return 0
	_row=$_tuish_draw_tr
	_col=$_tuish_draw_tc
	_h=$_tuish_draw_th

	_tuish_draw_set_style "$_tuish_draw_opt_style" "$_tuish_draw_opt_join"
	_tuish_draw_set_fg $_tuish_draw_opt_fg
	test $_tuish_draw_ch_bold -eq 1 && tuish_bold

	# Top T (only if not clipped)
	if test $_tuish_draw_ct -eq 0 && tuish_vmove $_row $_col; then
		_tuish_write "$_tuish_draw_ch_tee_d"
	fi

	# Middle verticals
	local _r_start=0 _r_end=$((_h - 1))
	test $_tuish_draw_ct -eq 0 && _r_start=1
	test $_tuish_draw_cb -eq 0 && _r_end=$((_h - 2))
	local _r=$_r_start
	while test $_r -le $_r_end
	do
		if tuish_vmove $((_row + _r)) $_col; then _tuish_write "$_tuish_draw_ch_v"; fi
		_r=$((_r + 1))
	done

	# Bottom T (only if not clipped)
	if test $_tuish_draw_cb -eq 0 && tuish_vmove $((_row + _h - 1)) $_col; then
		_tuish_write "$_tuish_draw_ch_tee_u"
	fi
	tuish_sgr_reset
}

# ─── Bare horizontal line: ───── ────────────────────────────────

tuish_draw_hline ()
{
	local _row=$1 _col=$2 _w=$3
	shift 3

	# Transform inline for left-edge clipping
	_row=$((_row - _tuish_draw_origin_r))
	_col=$((_col - _tuish_draw_origin_c))
	if test $_tuish_draw_clip -eq 1; then
		test $_row -lt $_tuish_draw_clip_top && return 0
		test $_row -gt $_tuish_draw_clip_bot && return 0
	fi

	_tuish_draw_parse_opts "$@"

	# Left-edge clipping
	if test $_col -lt 1; then
		_w=$((_w - (1 - _col)))
		_col=1
	fi
	test $_w -lt 1 && return 0

	# Right-edge clipping
	if test $_tuish_wrap -eq 0 && test $TUISH_VIEW_COLS -gt 0; then
		_tuish_clip_avail $_col; local _avail=$_tuish_avail
		test $_avail -lt 1 && return 0
		test $_w -gt $_avail && _w=$_avail
	fi

	_tuish_draw_set_style "$_tuish_draw_opt_style"
	_tuish_draw_set_fg $_tuish_draw_opt_fg
	test $_tuish_draw_ch_bold -eq 1 && tuish_bold

	if tuish_vmove $_row $_col
	then
		tuish_str_repeat "$_tuish_draw_ch_h" $_w
		_tuish_write "$TUISH_SREPEATED"
	fi
	tuish_sgr_reset
}

# ─── Bare vertical line: │││ ────────────────────────────────────

tuish_draw_vline ()
{
	local _row=$1 _col=$2 _h=$3
	shift 3

	_tuish_draw_xform_rect $_row $_col $_h || return 0
	_row=$_tuish_draw_tr
	_col=$_tuish_draw_tc
	_h=$_tuish_draw_th

	_tuish_draw_parse_opts "$@"

	test $_h -lt 1 && return 0

	_tuish_draw_set_style "$_tuish_draw_opt_style"
	_tuish_draw_set_fg $_tuish_draw_opt_fg
	test $_tuish_draw_ch_bold -eq 1 && tuish_bold

	local _r=0
	while test $_r -lt $_h
	do
		if tuish_vmove $((_row + _r)) $_col; then _tuish_write "$_tuish_draw_ch_v"; fi
		_r=$((_r + 1))
	done
	tuish_sgr_reset
}

# ─── Cross/junction: ┼  (style=horizontal, join=vertical) ───────

tuish_draw_cross ()
{
	local _row=$1 _col=$2
	shift 2

	_tuish_draw_xform $_row $_col || return 0
	_row=$_tuish_draw_tr
	_col=$_tuish_draw_tc

	_tuish_draw_parse_opts "$@"

	_tuish_draw_set_style "$_tuish_draw_opt_style" "$_tuish_draw_opt_join"
	_tuish_draw_set_fg $_tuish_draw_opt_fg
	test $_tuish_draw_ch_bold -eq 1 && tuish_bold

	_tuish_write_at $_row $_col "$_tuish_draw_ch_cross"
	tuish_sgr_reset
}

# ─── Tee/T-junction: ├ ┤ ┬ ┴  (single character) ──────────────

tuish_draw_tee ()
{
	local _row=$1 _col=$2 _dir=$3
	shift 3

	_tuish_draw_xform $_row $_col || return 0
	_row=$_tuish_draw_tr
	_col=$_tuish_draw_tc

	_tuish_draw_parse_opts "$@"

	_tuish_draw_set_style "$_tuish_draw_opt_style" "$_tuish_draw_opt_join"
	_tuish_draw_set_fg $_tuish_draw_opt_fg
	test $_tuish_draw_ch_bold -eq 1 && tuish_bold

	local _tee=''
	case "$_dir" in
		r) _tee=$_tuish_draw_ch_tee_r;;
		l) _tee=$_tuish_draw_ch_tee_l;;
		d) _tee=$_tuish_draw_ch_tee_d;;
		u) _tee=$_tuish_draw_ch_tee_u;;
	esac
	_tuish_write_at $_row $_col "$_tee"
	tuish_sgr_reset
}

# ─── Text rendering ─────────────────────────────────────────────

# tuish_draw_text ROW COL TEXT [maxwidth=N] [fg=N] [bg=N]
# Render text at (ROW,COL) with optional color and width clipping. Applies the
# draw-layer transform (origin offset + vertical clip region), then delegates
# placement, colour, maxwidth, and column/edge clipping to term.sh's tuish_text.
tuish_draw_text ()
{
	local _dt_row=$1 _dt_col=$2 _dt_text="$3"
	shift 3

	local _dt_tr=$((_dt_row - _tuish_draw_origin_r))
	local _dt_tc=$((_dt_col - _tuish_draw_origin_c))
	if test $_tuish_draw_clip -eq 1; then
		test $_dt_tr -lt $_tuish_draw_clip_top && return 0
		test $_dt_tr -gt $_tuish_draw_clip_bot && return 0
	fi

	tuish_text $_dt_tr $_dt_tc "$_dt_text" "$@"
}

# tuish_draw_centered ROW TEXT [col=N] [width=N] [fg=N] [bg=N]
# Center TEXT (display-width-aware, so wide glyphs count as 2) within the column
# band [col, col+width) — defaults to the whole viewport. Delegates to
# tuish_draw_text, so color and edge clipping come for free. Intended for use
# with the canvas off (plain viewport coordinates).
tuish_draw_centered ()
{
	local _ce_row=$1 _ce_text="$2" _ce_fg=-1 _ce_bg=-1 _ce_col=1 _ce_w=$TUISH_VIEW_COLS
	shift 2
	while test $# -gt 0
	do
		case "$1" in
			fg=*)    _ce_fg="${1#*=}";;
			bg=*)    _ce_bg="${1#*=}";;
			col=*)   _ce_col="${1#*=}";;
			width=*) _ce_w="${1#*=}";;
		esac
		shift
	done
	tuish_str_width _ce_text
	local _ce_tc=$(( _ce_col + (_ce_w - TUISH_SWIDTH) / 2 ))
	test $_ce_tc -lt $_ce_col && _ce_tc=$_ce_col
	tuish_draw_text "$_ce_row" "$_ce_tc" "$_ce_text" fg="$_ce_fg" bg="$_ce_bg"
}

# tuish_overlay LINE [LINE...]
# A centered, auto-sized modal box (one argument per line) drawn over the
# viewport, each line centered inside. Opaque: the interior is cleared to the
# default background first, so it covers whatever is behind it. Use with the
# canvas off. For splash screens, dialogs, and "press a key" / "too small"
# notices.
tuish_overlay ()
{
	local _ov_maxw=0 _ov_n=$# _ov_t
	for _ov_t in "$@"
	do
		tuish_str_width _ov_t
		test "$TUISH_SWIDTH" -gt "$_ov_maxw" && _ov_maxw=$TUISH_SWIDTH
	done
	local _ov_iw=$(( _ov_maxw + 2 ))    # interior: one column of padding each side
	local _ov_bw=$(( _ov_iw + 2 ))      # plus the two border columns
	local _ov_bh=$(( _ov_n + 2 ))       # lines plus the two border rows
	local _ov_br=$(( (TUISH_VIEW_ROWS - _ov_bh) / 2 + 1 ))
	local _ov_bc=$(( (TUISH_VIEW_COLS - _ov_bw) / 2 + 1 ))
	test "$_ov_br" -lt 1 && _ov_br=1
	test "$_ov_bc" -lt 1 && _ov_bc=1
	tuish_clear_region "$_ov_br" "$_ov_bc" "$_ov_bw" "$_ov_bh"
	tuish_draw_box "$_ov_br" "$_ov_bc" "$_ov_bw" "$_ov_bh" style=double
	local _ov_i=0
	for _ov_t in "$@"
	do
		tuish_draw_centered $(( _ov_br + 1 + _ov_i )) "$_ov_t" \
			col=$(( _ov_bc + 1 )) width="$_ov_iw"
		_ov_i=$(( _ov_i + 1 ))
	done
}
