#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# twins.sh — the SAME app, mounted twice, in one loop.
#
# cooperative.sh hosts two DIFFERENT apps (a clock and an editor) and makes the point that
# one loop can drive both at their own tick rates. This one makes a narrower point that was
# impossible until recently: two instances of ONE app, each with its own state.
#
# Two copies of examples/editor.sh, side by side. Type in the left one and the right one's
# cursor does not move; scroll one and the other stays put; each edits its own buffer. Tab
# swaps focus, or click.
#
# Why that was hard: an app's state is plain shell globals (_cur_row, _view_top, …), and a
# shell has exactly one of each. Mounting the editor twice used to mean two widgets sharing
# a cursor. The fix is tuish_ctx_declare: the app declares its state as a context FIELD SET
# at source time, and each mounted instance gets its own copy of the whole set, marshalled
# with the context. editor.sh declares one; that is the only reason this file works, and it
# is nine lines in editor.sh.
#
# The editor itself is unchanged and does not know any of this is happening. It does not
# know it is hosted, it does not know there is another one of it, and it never asks.

# ─── Bootstrap ────────────────────────────────────────────────────
if test -z "${_tuish_tui_loaded:-}"
then
	_tw_standalone=1
	set -euf
	_tw_dir="$(cd "$(dirname "$0")" && pwd)"
	_src="${_tw_dir}/../src"
	. "${_src}/compat.sh"
	. "${_src}/ord.sh"
	. "${_src}/tui.sh"
	. "${_src}/term.sh"
	. "${_src}/event.sh"
	. "${_src}/hid.sh"
	. "${_src}/viewport.sh"
	. "${_src}/str.sh"
	. "${_src}/buf.sh"
	. "${_src}/draw.sh"
	. "${_src}/keybind.sh"
	. "${_src}/host.sh"
	_tw_ex="${_tw_dir}"
else
	_tw_standalone=0
	_tw_ex="${TUISH_EXAMPLES:-.}"
fi

# The editor, SOURCED: tuish is loaded, so this only defines its _ed_* functions.
. "${_tw_ex}/editor.sh"

C_BG=0
C_ACCENT=6
C_BORDER=8
C_FOCUS=6
C_DIM=8

# ─── Layout ───────────────────────────────────────────────────────
_tw_lay ()
{
	_W=$TUISH_COLUMNS; _H=$TUISH_LINES
	_top=3
	_bot=$(( _H - 1 ))
	_bh=$(( _bot - _top + 1 ))
	_half=$(( (_W - 3) / 2 ))
	_lc=2
	_rc=$(( _lc + _half + 1 ))
	_li_r=$(( _top + 1 )); _li_c=$(( _lc + 1 )); _li_w=$(( _half - 2 )); _li_h=$(( _bh - 2 ))
	_ri_r=$(( _top + 1 )); _ri_c=$(( _rc + 1 )); _ri_w=$(( _half - 2 )); _ri_h=$(( _bh - 2 ))
}

# Two slots, the SAME setup function. The ids differ, and that is all that has to: each
# slot gets its own context, and _ed_setup's `tuish_ctx_fields _ed` gives each context its
# own copy of the editor's state. No argument distinguishes them, because none needs to.
_tw_slots ()
{
	tuish_host_begin
	tuish_host_slot left  _ed_setup '' "$_li_r" "$_li_c" "$_li_w" "$_li_h"
	tuish_host_slot right _ed_setup '' "$_ri_r" "$_ri_c" "$_ri_w" "$_ri_h"
	tuish_host_commit
}

# ─── Render ───────────────────────────────────────────────────────
_tw_render ()
{
	_tw_lay
	tuish_begin
	tuish_draw_fill 1 1 "$_W" "$_H" bg=$C_BG
	tuish_text 1 2 "twins — one app, mounted twice" fg=$C_ACCENT bg=$C_BG
	local _hint='tab/click: focus · Ctrl+W: quit'
	tuish_str_width _hint; local _hw=$TUISH_SWIDTH
	tuish_text 1 $(( _W - _hw )) "$_hint" fg=$C_DIM bg=$C_BG

	local _lfg=$C_BORDER _rfg=$C_BORDER
	case "$TUISH_HOST_FOCUS" in
		left)  _lfg=$C_FOCUS;;
		right) _rfg=$C_FOCUS;;
	esac
	tuish_draw_box "$_top" "$_lc" "$_half" "$_bh" fg=$_lfg bg=$C_BG title=' left '
	tuish_draw_box "$_top" "$_rc" "$_half" "$_bh" fg=$_rfg bg=$C_BG title=' right '

	tuish_host_paint    # both children, into THIS frame — one write
	tuish_end
}

# ─── Events ───────────────────────────────────────────────────────
_tw_focus_next ()
{
	case "$TUISH_HOST_FOCUS" in
		left) tuish_host_focus right;;
		*)    tuish_host_focus left;;
	esac
	tuish_request_redraw 3
}

_tw_on_event ()
{
	# Tab is ours, before the children see it: an editor would insert it.
	if test "$TUISH_EVENT_KIND" = 'key' && test "$TUISH_EVENT" = 'tab'
	then _tw_focus_next; return 0; fi

	if tuish_host_route
	then
		# A child ended itself (its own Ctrl+W). One editor closing closes the demo —
		# there is nothing else here to look at.
		test -n "$TUISH_HOST_QUIT" && tuish_quit
		return 0
	fi

	case "$TUISH_EVENT" in
		resize) _tw_lay; _tw_slots; tuish_request_redraw 3;;
	esac
	return 0
}

_tw_setup ()
{
	tuish_init
	tuish_on_event  _tw_on_event
	tuish_on_redraw _tw_render
	tuish_viewport fullscreen
	_tuish_mouse=0; tuish_mouse_on

	_tw_lay
	_tw_slots
	tuish_host_focus left     # somebody has to have the keyboard to start
	_tw_render
}

_tw_main ()
{
	_tw_setup
	tuish_run || :
	tuish_host_clear
	tuish_fini
}

if test "${_tw_standalone:-0}" -eq 1
then
	_tw_main "$@"
fi
