#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Minimal TUI that echoes parsed events to the screen.
# Used as the tmux target for integration tests.

_dir="$(cd "$(dirname "$0")" && pwd)"
_tuish_src_dir="${_dir}/../../src"
. "${_tuish_src_dir}/compat.sh"
. "${_tuish_src_dir}/ord.sh"
. "${_tuish_src_dir}/tui.sh"
. "${_tuish_src_dir}/term.sh"
. "${_tuish_src_dir}/event.sh"
. "${_tuish_src_dir}/hid.sh"
. "${_tuish_src_dir}/viewport.sh"
. "${_tuish_src_dir}/str.sh"
. "${_tuish_src_dir}/keybind.sh"

_count=0

_show_event () {
	_count=$((_count + 1))
	tuish_grow
	_tuish_write '\r'
	tuish_print "[=${_count}]: ${TUISH_EVENT}"
	tuish_clear_to_eol
}

tuish_bind 'ctrl-w' 'tuish_quit_main'
tuish_bind 'idle'   ':'
tuish_bind '*'      '_show_event'

tuish_init
tuish_mouse_on
tuish_detailed_on
tuish_viewport grow 20
tuish_run || :
tuish_fini
