#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# debug.sh - Event inspector using tui.sh
# Displays parsed events, raw codes, mouse positions, and terminal info.
# Ctrl+W to exit.
#
# Dual-mode, like the other examples: run standalone (a streaming log that grows
# down the screen) or SOURCE it into a host, which then mounts _dbg_setup — the
# non-blocking half that renders a fixed-region ring buffer of the most recent
# events (newest on top). Each row shows KIND:EVENT on the left and the RAW bytes
# on the right, so you can see exactly what the terminal delivered — e.g. whether
# Shift+Arrow arrives as a distinct 'shift-left' or just a plain 'left'.

if test -z "${_tuish_tui_loaded:-}"
then
	_dbg_standalone=1
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
	. "${_tuish_src_dir}/keybind.sh"
else
	_dbg_standalone=0
fi

# ─── State ────────────────────────────────────────────────────────

_dbg_height="${TUISH_DEBUG_HEIGHT:-15}"
_dbg_count=0
_dbg_started=no

# ─── Display helpers ────────────────────────────────────────────────

_dbg_header ()
{
	tuish_sgr '7'
	tuish_print " tui.sh debug (quit: ctrl+w) | ${TUISH_COLUMNS}x${TUISH_LINES} | proto:${TUISH_PROTOCOL} | timing:${TUISH_TIMING} | row:${TUISH_INIT_ROW} "
	tuish_clear_to_eol
	tuish_sgr_reset
}

_dbg_format_event ()
{
	_dbg_count=$((_dbg_count + 1))
	local _num="$_dbg_count"
	local _pad='    '
	test $_num -ge 10 && _pad='   '
	test $_num -ge 100 && _pad='  '
	test $_num -ge 1000 && _pad=' '

	_dbg_left="${_pad}${_num}  ${TUISH_EVENT_KIND}:${TUISH_EVENT}"
	_dbg_right="[${TUISH_RAW}]"

	case "$TUISH_EVENT_KIND" in
		mouse)
			_dbg_right="x:${TUISH_MOUSE_X} y:${TUISH_MOUSE_ABS_Y}  [${TUISH_RAW}]"
			;;
		key)
			# Show display width for character events
			case "$TUISH_EVENT" in
				char\ *)
					local _ch="${TUISH_EVENT#char }"
					test "$_ch" = 'bslash' && _ch='\'
					tuish_str_width _ch
					_dbg_left="${_dbg_left} (w:${TUISH_SWIDTH})"
					;;
			esac
			;;
	esac
}

_dbg_print_line ()
{
	_tuish_write '\r'
	tuish_print "$_dbg_left"
	# Right-align the raw codes
	local _llen=${#_dbg_left}
	local _rlen=${#_dbg_right}
	local _gap=$((TUISH_COLUMNS - _llen - _rlen - 1))
	if test $_gap -gt 0
	then
		_tuish_write "\033[${_gap}C"
	fi
	tuish_print "$_dbg_right"
	tuish_clear_to_eol
}

# ─── Actions (standalone) ──────────────────────────────────────────

_dbg_quit ()
{
	tuish_quit_main
}

_dbg_idle ()
{
	# Draw header on first idle (initial render)
	test "$_dbg_started" = 'no' && {
		_dbg_started=yes
		_tuish_write '\r'
		_dbg_header
	}
}

_dbg_resize ()
{
	# Redraw header if viewport is established
	if test $TUISH_VIEW_ROWS -gt 0
	then
		tuish_move $((TUISH_VIEW_TOP - 1)) 1
		_dbg_header
	fi
	_dbg_show_event
}

_dbg_show_event ()
{
	_dbg_format_event
	tuish_grow
	_dbg_print_line
}

# ─── Hosted half (fixed-region ring buffer) ────────────────────────
# A shift register of the last _DBG_MAX formatted lines, _dbg_l1 newest. Cheap to
# shift (a few dozen string copies) for a debug tool, and it keeps rendering to a
# simple "row i shows _dbg_l(i)" with no modulo bookkeeping.
_DBG_MAX=40
_dbg_ring_init ()
{
	local _i=1
	while test $_i -le $_DBG_MAX; do eval "_dbg_l$_i=''"; _i=$((_i + 1)); done
}

_dbg_push ()
{
	local _i=$_DBG_MAX
	while test $_i -gt 1
	do
		eval "_dbg_l$_i=\$_dbg_l$(( _i - 1 ))"
		_i=$(( _i - 1 ))
	done
	_dbg_l1="${_dbg_left}|${_dbg_right}"
}

_dbg_render ()
{
	local _cols=$TUISH_VIEW_COLS _rows=$TUISH_VIEW_ROWS
	tuish_clear_region 1 1 "$_cols" "$_rows"
	tuish_text 1 1 " events  ${TUISH_COLUMNS}x${TUISH_LINES}  proto:${TUISH_PROTOCOL}  timing:${TUISH_TIMING} " fg=0 bg=6
	local _n=$(( _rows - 1 ))
	test $_n -gt $_DBG_MAX && _n=$_DBG_MAX
	local _i=1 _ln _l _r _rl
	while test $_i -le $_n
	do
		eval "_ln=\$_dbg_l$_i"
		if test -n "$_ln"
		then
			_l="${_ln%%|*}"; _r="${_ln#*|}"
			tuish_text $(( _i + 1 )) 1 "$_l"
			_rl=${#_r}
			test $(( _cols - _rl )) -ge 1 && tuish_text $(( _i + 1 )) $(( _cols - _rl )) "$_r"
		fi
		_i=$(( _i + 1 ))
	done
	return 0
}

_dbg_capture ()
{
	_dbg_format_event
	_dbg_push
	tuish_request_redraw
}

# The non-blocking setup a host mounts. Renders into its region; the host owns
# quit (Ctrl+W) and focus, so this just watches the event stream.
_dbg_setup ()
{
	tuish_init
	_dbg_ring_init
	# Opt this context into mouse: tuish drops mouse events for a context that did
	# not ask for them, so without this a hosted inspector would see keys but no
	# clicks even when the host routes them here. detailed_on so a quick click is
	# reported rather than absorbed (else clicks come through erratically).
	tuish_mouse_on
	tuish_detailed_on
	tuish_on_redraw _dbg_render
	tuish_bind 'idle' 'tuish_pass'     # do not spam on ticks; render on real events
	tuish_bind '*'    '_dbg_capture'
	tuish_viewport fullscreen
	_dbg_render
}

# ─── Standalone bootstrap ──────────────────────────────────────────

if test "${_dbg_standalone:-0}" -eq 1
then
	tuish_bind 'ctrl-w' '_dbg_quit'
	tuish_bind 'idle'   '_dbg_idle'
	tuish_bind 'resize' '_dbg_resize'
	tuish_bind '*'      '_dbg_show_event'

	tuish_init
	tuish_kitty_on || :
	tuish_mouse_on
	tuish_detailed_on
	tuish_modkeys_on
	tuish_viewport grow "$_dbg_height"
	tuish_run || :
	tuish_fini
fi
