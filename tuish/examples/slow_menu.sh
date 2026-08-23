#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# slow_menu.sh - Redraw scheduler demo
# j/k or arrows move the selection, m toggles draw mode, q quits.
#
# The render is padded with busy work to stand in for a realistically
# expensive full-screen draw. Hold j or k and watch the counters:
#
#   deferred mode:  events climbs faster than redraws, and the UI
#                   stops the instant you release the key.
#   immediate mode: one redraw per event; queued keypresses keep
#                   the UI churning after you release the key.

_dir="$(cd "$(dirname "$0")" && pwd)"
_tuish_src_dir="${_dir}/../src"
. "${_tuish_src_dir}/compat.sh"
. "${_tuish_src_dir}/ord.sh"
. "${_tuish_src_dir}/tui.sh"
. "${_tuish_src_dir}/term.sh"
. "${_tuish_src_dir}/event.sh"
. "${_tuish_src_dir}/hid.sh"
. "${_tuish_src_dir}/viewport.sh"
. "${_tuish_src_dir}/keybind.sh"

_items='Alpha Bravo Charlie Delta Echo'
_total=0
for _it in $_items; do _total=$((_total + 1)); done
_selected=1
_events=0
_redraws=0
_mode='deferred'
_painted=0

_changed ()
{
	_events=$((_events + 1))
	if test "$_mode" = 'deferred'
	then
		tuish_request_redraw      # schedule, don't draw
	else
		_draw                     # draw right now, every time
	fi
}

_prev ()
{
	_selected=$((_selected - 1))
	test "$_selected" -lt 1 && _selected=$_total
	_changed
}

_next ()
{
	_selected=$((_selected + 1))
	test "$_selected" -gt "$_total" && _selected=1
	_changed
}

_toggle_mode ()
{
	if test "$_mode" = 'deferred'
	then _mode='immediate'
	else _mode='deferred'
	fi
	_draw
}

_draw ()
{
	_redraws=$((_redraws + 1))

	# Busy work: simulate an expensive render (50-110ms depending
	# on the shell), slower than typical keyboard autorepeat.
	_i=0
	while test "$_i" -lt 30000; do _i=$((_i + 1)); done

	tuish_hide_cursor
	_row=1
	for _it in $_items
	do
		if tuish_vmove "$_row" 2
		then
			if test "$_row" -eq "$_selected"
			then
				tuish_reverse
				tuish_print " $_it "
				tuish_sgr_reset
			else
				tuish_print " $_it "
			fi
			tuish_clear_to_eol
		fi
		_row=$((_row + 1))
	done
	if tuish_vmove $((_total + 2)) 2
	then
		tuish_dim
		tuish_print "mode: $_mode | events: $_events | redraws: $_redraws"
		tuish_clear_to_eol
	fi
	if tuish_vmove $((_total + 3)) 2
	then
		tuish_print 'hold j/k to move, m toggles mode, q quits'
		tuish_clear_to_eol
	fi
	tuish_sgr_reset
	tuish_show_cursor
}

tuish_on_redraw () { _draw; }

_first_paint ()
{
	test "$_painted" -eq 1 && return 0
	_painted=1
	tuish_request_redraw
}

tuish_bind 'up'     '_prev'
tuish_bind 'down'   '_next'
tuish_bind 'char k' '_prev'
tuish_bind 'char j' '_next'
tuish_bind 'char m' '_toggle_mode'
tuish_bind 'char q' 'tuish_quit'
tuish_bind 'idle'   '_first_paint'
tuish_bind 'resize' 'tuish_request_redraw'

tuish_init
tuish_viewport fullscreen
tuish_run || :
tuish_fini
