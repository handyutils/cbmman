#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# host_demo.sh - a tuish app that HOSTS another tuish app in a region.
#
# Draws a full-screen "page" with a bordered content box. Pressing 'e' opens the
# canvas_demo example INSIDE that box — a second, complete tuish app running in a
# region of this one, in the same process, no forks. The example owns the keyboard
# until Ctrl+W, then this page resumes. Used by tests/integration/test_hosting.sh
# to exercise the reentrant event loop and region composition end to end.

set -euf

_hd_dir="$(cd "$(dirname "$0")" && pwd)"
_hd_src="${_hd_dir}/../../src"
_hd_ex="${_hd_dir}/../../examples"

. "${_hd_src}/compat.sh"
. "${_hd_src}/ord.sh"
. "${_hd_src}/tui.sh"
. "${_hd_src}/term.sh"
. "${_hd_src}/canvas.sh"
. "${_hd_src}/event.sh"
. "${_hd_src}/hid.sh"
. "${_hd_src}/viewport.sh"
. "${_hd_src}/str.sh"
. "${_hd_src}/draw.sh"
. "${_hd_src}/keybind.sh"

# Source the hostable example. tuish is already loaded, so it only DEFINES its
# functions (_cd_main, ...) — its own bootstrap does not run.
. "${_hd_ex}/canvas_demo.sh"

# Content box geometry (full-screen page with a border).
_hd_box_r=3
_hd_box_c=2
_hd_box_w () { echo $(( TUISH_COLUMNS - 2 )); }
_hd_box_h () { echo $(( TUISH_LINES - 4 )); }

_hd_render ()
{
	tuish_hide_cursor
	tuish_clear_region 1 1 "$TUISH_VIEW_COLS" "$TUISH_VIEW_ROWS"
	tuish_print_at 1 1 "HOST PAGE  —  press e to open the canvas demo,  Ctrl+W to quit"
	tuish_draw_box "$_hd_box_r" "$_hd_box_c" "$(_hd_box_w)" "$(_hd_box_h)" style=light
	tuish_print_at "$_hd_box_r" 5 " content "
	tuish_flush
}

# Open the example inside the content box's interior — a region of THIS app.
_hd_launch ()
{
	tuish_ctx_create_region \
		$(( _hd_box_r + 1 )) $(( _hd_box_c + 1 )) \
		$(( $(_hd_box_w) - 2 )) $(( $(_hd_box_h) - 2 ))
	_cd_main
	tuish_request_redraw -1
}

_hd_main ()
{
	tuish_init
	tuish_on_redraw _hd_render
	tuish_bind 'char e' '_hd_launch'
	tuish_bind 'ctrl-w' 'tuish_quit_clear'
	tuish_bind 'resize' 'tuish_request_redraw -1'
	tuish_bind '*'      ':'
	tuish_viewport fullscreen
	_hd_render
	tuish_run || :
	tuish_fini
}

_hd_main
