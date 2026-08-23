#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# editor.sh - CUA-like text editor using tui.sh
# Ctrl+W to exit.

# Dual-mode: standalone (`sh examples/editor.sh [file]`) or embedded (a host sources
# it and calls _ed_main in a region). It registers its render/event handlers by
# name — never redefining the global hooks — so it composes with a host cleanly.
if test -z "${_tuish_tui_loaded:-}"
then
	_ed_standalone=1
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
	. "${_tuish_src_dir}/buf.sh"
	. "${_tuish_src_dir}/clip.sh"
	. "${_tuish_src_dir}/keybind.sh"
else
	_ed_standalone=0
fi

# ─── Editor state ───────────────────────────────────────────────────

_cur_row=1
_cur_col=1       # cursor character index (1-based)
_cur_dcol=0      # cursor display column (0-based; width of the prefix before it)
_view_top=1
_view_left=0     # horizontal scroll offset in DISPLAY COLUMNS (0-based)
_view_height=0
_view_width=0
_sel_row=0       # 0 = no selection
_sel_col=0
_status_msg=''

# The line buffer we edit. A NAME, not a literal, so a host can hand us a buffer it
# already populated (a doc snippet) and read it back afterwards — see _ed_text.
# Standalone this stays '_', the historical scratch buffer.
#
# PER-CONTEXT: a host sets it from inside our context (after our tuish_init adopts it),
# so two editors mounted in the same page can edit two different buffers without one
# clobbering the other's target.
_ed_buf='_'
command -v tuish_ctx_register >/dev/null 2>&1 && tuish_ctx_register _ed_buf

# Everything above this line is ONE EDITOR'S state, and an editor is a thing you can have
# two of. Declare it as a context field set and each mounted instance gets its own copy —
# its own cursor, its own scroll offset, its own selection. Before this, two editors in one
# page shared all of it: type in the left one and the right one's cursor moved.
#
# Declared HERE, at source time, and not inside _ed_setup, because that is where the real
# defaults are. Captured at attach time instead, the SECOND editor would open holding the
# first one's cursor row.
#
# _ed_buf is deliberately NOT in the set. It is a buffer NAME a host may seed before
# mounting us (the website hands us a doc snippet), and attaching resets a set to its
# declared defaults — which would wipe the seed. It stays on the framework tier, where it
# already works.
command -v tuish_ctx_declare >/dev/null 2>&1 && tuish_ctx_declare _ed \
	_cur_row _cur_col _cur_dcol \
	_view_top _view_left _view_height _view_width \
	_sel_row _sel_col _status_msg

# The editor's own clipboard. Held here rather than read back from the system
# clipboard because OSC 52 is write-only by design (see src/clip.sh): a terminal
# will let us SET the clipboard but not read it, so an app that wants copy/paste
# within itself must keep its own register. Copy mirrors OUT to the system
# clipboard; paste comes IN via bracketed paste, which is a different path entirely.
_ed_clip=''

# Out-var for _ed_selected_text / _ed_text.
_ed_sel_text=''

# ─── Cursor helpers ─────────────────────────────────────────────────

_clamp_col ()
{
	tuish_buf_get "$_ed_buf" $_cur_row; local _line="$TUISH_BLINE"
	tuish_str_len _line
	if test $_cur_col -gt $((TUISH_SLEN + 1))
	then
		_cur_col=$((TUISH_SLEN + 1))
	fi
	test $_cur_col -lt 1 && _cur_col=1
}

# Display column (0-based) of the cursor: width of the line prefix before it.
_compute_dcol ()
{
	tuish_buf_get "$_ed_buf" $_cur_row
	local _dc="$TUISH_BLINE"
	tuish_str_left _dc $((_cur_col - 1))
	local _dcp="$TUISH_SLEFT"
	tuish_str_width _dcp
	_cur_dcol=$TUISH_SWIDTH
}

# Map a display column (0-based) to a 1-based character index on the cursor's
# line (mouse positioning). Sets _cur_col to the char at or after the column.
_col_to_char ()
{
	local _target=$1
	test $_target -lt 0 && _target=0
	tuish_buf_get "$_ed_buf" $_cur_row
	local _ctc="$TUISH_BLINE"
	tuish_str_len _ctc
	local _ctc_len=$TUISH_SLEN _ctc_i=0 _ctc_col=0 _ctc_ch
	while test $_ctc_i -lt $_ctc_len
	do
		test $_ctc_col -ge $_target && break
		tuish_str_char _ctc $_ctc_i
		_ctc_ch="$TUISH_SCHAR"
		tuish_str_width _ctc_ch
		_ctc_col=$((_ctc_col + TUISH_SWIDTH))
		_ctc_i=$((_ctc_i + 1))
	done
	_cur_col=$((_ctc_i + 1))
}

# Place the cursor, mapping its character index to a display column and
# subtracting the horizontal (column) scroll offset.
_place_cursor ()
{
	_compute_dcol
	tuish_cursor $((_cur_row - _view_top + 1)) $((_cur_dcol - _view_left + 1))
}

_ensure_visible ()
{
	tuish_clamp_scroll $_cur_row $_view_top $_view_height
	if test $TUISH_SCROLL -ne $_view_top
	then
		_view_top=$TUISH_SCROLL
		tuish_request_redraw
	fi
	# Horizontal scrolling (in display columns)
	_compute_dcol
	tuish_clamp_scroll $_cur_dcol $_view_left $_view_width
	if test $TUISH_SCROLL -ne $_view_left
	then
		_view_left=$TUISH_SCROLL
		tuish_request_redraw
	fi
}

_clear_sel ()
{
	if test $_sel_row -ne 0
	then
		_sel_row=0
		_sel_col=0
		tuish_request_redraw
	fi
}

_start_sel ()
{
	if test $_sel_row -eq 0
	then
		_sel_row=$_cur_row
		_sel_col=$_cur_col
	fi
}

# ─── Word navigation ────────────────────────────────────────────────

_word_left ()
{
	tuish_buf_get "$_ed_buf" $_cur_row; local _line="$TUISH_BLINE"
	if test $_cur_col -le 1
	then
		# Move to end of previous line
		if test $_cur_row -gt 1
		then
			_cur_row=$((_cur_row - 1))
			tuish_buf_get "$_ed_buf" $_cur_row; _line="$TUISH_BLINE"
			tuish_str_len _line
			_cur_col=$((TUISH_SLEN + 1))
		fi
		return
	fi

	# O(n) via parameter expansion instead of O(n²) char-by-char
	tuish_str_left _line $((_cur_col - 1))
	local _before="$TUISH_SLEFT"

	# Strip trailing whitespace
	local _trail_ws="${_before##*[! 	]}"
	local _no_ws="${_before%"$_trail_ws"}"

	# All whitespace or empty → go to column 1
	if test -z "$_no_ws"
	then
		_cur_col=1
		return
	fi

	# Strip trailing word chars (find last whitespace boundary)
	case "$_no_ws" in
		*' '*|*'	'*)
			local _trail_word="${_no_ws##*[ 	]}"
			_no_ws="${_no_ws%"$_trail_word"}"
			;;
		*)
			# No whitespace: word starts at beginning of line
			_cur_col=1
			return
			;;
	esac

	tuish_str_len _no_ws
	_cur_col=$((TUISH_SLEN + 1))
}

_word_right ()
{
	tuish_buf_get "$_ed_buf" $_cur_row; local _line="$TUISH_BLINE"
	tuish_str_len _line
	local _len=$TUISH_SLEN

	if test $_cur_col -gt $_len
	then
		if test $_cur_row -lt $TUISH_BUF_COUNT
		then
			_cur_row=$((_cur_row + 1))
			_cur_col=1
		fi
		return
	fi

	# O(n) via parameter expansion instead of O(n²) char-by-char
	tuish_str_right _line $((_cur_col - 1))
	local _after="$TUISH_SRIGHT"

	# Strip leading word chars (non-whitespace)
	local _lead_word="${_after%%[	 ]*}"
	local _rest="${_after#"$_lead_word"}"

	# Strip leading whitespace
	local _lead_ws="${_rest%%[!	 ]*}"

	tuish_str_len _lead_word
	local _wlen=$TUISH_SLEN
	tuish_str_len _lead_ws
	_cur_col=$((_cur_col + _wlen + TUISH_SLEN))
}

# ─── Selection helpers ──────────────────────────────────────────────

# Determine selection bounds: _sr1/_sc1 = start, _sr2/_sc2 = end
_sel_bounds ()
{
	if test $_sel_row -eq 0
	then
		_sr1=0; _sc1=0; _sr2=0; _sc2=0
		return
	fi

	if test $_sel_row -lt $_cur_row || {
		test $_sel_row -eq $_cur_row && test $_sel_col -le $_cur_col ;}
	then
		_sr1=$_sel_row; _sc1=$_sel_col
		_sr2=$_cur_row;  _sc2=$_cur_col
	else
		_sr1=$_cur_row;  _sc1=$_cur_col
		_sr2=$_sel_row; _sc2=$_sel_col
	fi
}

# The selected text -> _ed_sel_text (empty when there is no selection).
# The selection machinery could previously only RENDER a selection or DELETE it —
# nothing ever extracted the text, which is why the editor had no copy. Same bounds
# and same edge cases as _delete_selection; kept adjacent so the two stay in step.
_ed_selected_text ()
{
	_sel_bounds
	_ed_sel_text=''
	test $_sr1 -eq 0 && return 1

	if test $_sr1 -eq $_sr2
	then
		# Same line: the slice between the two columns.
		tuish_buf_get "$_ed_buf" $_sr1; local _line="$TUISH_BLINE"
		tuish_str_right _line $((_sc1 - 1))
		local _rest="$TUISH_SRIGHT"
		tuish_str_left _rest $((_sc2 - _sc1))
		_ed_sel_text="$TUISH_SLEFT"
		return 0
	fi

	# Multi-line: tail of the first line, every line between, head of the last.
	tuish_buf_get "$_ed_buf" $_sr1; local _first="$TUISH_BLINE"
	tuish_str_right _first $((_sc1 - 1))
	_ed_sel_text="$TUISH_SRIGHT"

	local _i=$((_sr1 + 1))
	while test $_i -lt $_sr2
	do
		tuish_buf_get "$_ed_buf" $_i
		_ed_sel_text="${_ed_sel_text}${_tuish_chr_10}${TUISH_BLINE}"
		_i=$((_i + 1))
	done

	tuish_buf_get "$_ed_buf" $_sr2; local _last="$TUISH_BLINE"
	tuish_str_left _last $((_sc2 - 1))
	_ed_sel_text="${_ed_sel_text}${_tuish_chr_10}${TUISH_SLEFT}"
	return 0
}

# The whole buffer as one newline-separated string -> _ed_sel_text. The editor had no
# way to hand its contents anywhere; a host that seeds _ed_buf with a snippet needs
# this to read the edit back.
_ed_text ()
{
	_ed_sel_text=''
	tuish_buf_count "$_ed_buf"
	local _i=1 _n=$TUISH_BUF_COUNT
	while test $_i -le $_n
	do
		tuish_buf_get "$_ed_buf" $_i
		if test $_i -eq 1
		then _ed_sel_text="$TUISH_BLINE"
		else _ed_sel_text="${_ed_sel_text}${_tuish_chr_10}${TUISH_BLINE}"
		fi
		_i=$((_i + 1))
	done
	return 0
}

_delete_selection ()
{
	_sel_bounds
	test $_sr1 -eq 0 && return 1

	if test $_sr1 -eq $_sr2
	then
		# Same line: delete columns
		tuish_buf_get "$_ed_buf" $_sr1; local _line="$TUISH_BLINE"
		tuish_str_left _line $((_sc1 - 1))
		local _left="$TUISH_SLEFT"
		tuish_str_right _line $((_sc2 - 1))
		tuish_buf_set "$_ed_buf" $_sr1 "${_left}${TUISH_SRIGHT}"
	else
		# Multi-line: join first and last, delete middle
		tuish_buf_get "$_ed_buf" $_sr1; local _first="$TUISH_BLINE"
		tuish_str_left _first $((_sc1 - 1))
		local _head="$TUISH_SLEFT"

		tuish_buf_get "$_ed_buf" $_sr2; local _last="$TUISH_BLINE"
		tuish_str_right _last $((_sc2 - 1))
		local _tail="$TUISH_SRIGHT"

		tuish_buf_set "$_ed_buf" $_sr1 "${_head}${_tail}"

		local _d=$_sr2
		while test $_d -gt $_sr1
		do
			tuish_buf_delete_at "$_ed_buf" $((_sr1 + 1))
			_d=$((_d - 1))
		done
	fi

	_cur_row=$_sr1
	_cur_col=$_sc1
	_sel_row=0
	_sel_col=0
	tuish_request_redraw
}

# ─── Action functions (bound via tuish_bind) ─────────────────────

_ed_quit ()      { tuish_quit_clear; }

# ─── Clipboard ──────────────────────────────────────────────────────

# Insert TEXT (which may contain newlines) at the cursor as ONE edit. This is the
# whole point of the atomic `paste` event: the old path replayed a paste as a burst
# of key events, so a pasted newline ran the `enter` BINDING and a pasted tab ran
# `tab` (expanding to 4 spaces). Here the text is data, not input.
_ed_insert_text ()   # $1 = text
{
	local _nl="$_tuish_chr_10"
	test $_sel_row -ne 0 && _delete_selection
	tuish_buf_get "$_ed_buf" $_cur_row; local _line="$TUISH_BLINE"
	tuish_str_left  _line $((_cur_col - 1)); local _left="$TUISH_SLEFT"
	tuish_str_right _line $((_cur_col - 1)); local _right="$TUISH_SRIGHT"

	# Walk the text a line at a time. The FIRST segment continues the current line
	# (after _left); the LAST one is followed by _right; anything between becomes a
	# whole new line.
	local _t="$1" _seg _last='' _row=$_cur_row
	while :
	do
		case "$_t" in
			*"$_nl"*) _seg="${_t%%"$_nl"*}"; _t="${_t#*"$_nl"}";;
			*)        _last="$_t"; break;;
		esac
		if test "$_row" -eq "$_cur_row"
		then tuish_buf_set "$_ed_buf" "$_row" "${_left}${_seg}"
		else tuish_buf_insert_at "$_ed_buf" "$_row" "$_seg"
		fi
		_row=$((_row + 1))
	done

	tuish_str_len _last
	local _lw=$TUISH_SLEN
	if test "$_row" -eq "$_cur_row"
	then
		# Single-line paste: the cursor just advances along the current line.
		tuish_buf_set "$_ed_buf" "$_row" "${_left}${_last}${_right}"
		_cur_col=$((_cur_col + _lw))
	else
		tuish_buf_insert_at "$_ed_buf" "$_row" "${_last}${_right}"
		_cur_row=$_row
		_cur_col=$((_lw + 1))
	fi
	_sel_row=0; _sel_col=0
	_clamp_col
	tuish_request_redraw
}

# Copy: keep the text in our own register AND mirror it to the system clipboard.
# Both are needed — OSC 52 can only WRITE the system clipboard, never read it back
# (see src/clip.sh), so in-editor paste has to come from the register.
_ed_copy ()
{
	_ed_selected_text || { _status_msg='nothing selected'; return 0; }
	_ed_clip="$_ed_sel_text"
	type tuish_clip_set >/dev/null 2>&1 && tuish_clip_set "$_ed_clip"
	_status_msg='copied'
	tuish_request_redraw
}

_ed_cut ()
{
	_ed_selected_text || { _status_msg='nothing selected'; return 0; }
	_ed_clip="$_ed_sel_text"
	type tuish_clip_set >/dev/null 2>&1 && tuish_clip_set "$_ed_clip"
	_delete_selection
	_status_msg='cut'
	tuish_request_redraw
}

_ed_paste ()
{
	test -n "$_ed_clip" || return 0
	_ed_insert_text "$_ed_clip"
	_status_msg='pasted'
}

# A paste from the TERMINAL (bracketed paste): the body arrives in TUISH_PASTE as one
# event. Route it through the same atomic insert, and adopt it as our register so a
# subsequent in-editor paste repeats it.
_ed_on_paste ()
{
	test -n "${TUISH_PASTE:-}" || return 0
	_ed_clip="$TUISH_PASTE"
	_ed_insert_text "$TUISH_PASTE"
	_status_msg='pasted'
}

_ed_toggle_fullscreen ()
{
	if test "$TUISH_VIEW_MODE" = 'fullscreen'
	then
		tuish_viewport fixed 10
	else
		tuish_viewport fullscreen
	fi
	_view_height=$((TUISH_VIEW_ROWS - 1))
	_view_width=$TUISH_VIEW_COLS   # region width when hosted; full width standalone
	tuish_request_redraw
}

_ed_up ()        { _clear_sel; test $_cur_row -gt 1 && _cur_row=$((_cur_row - 1)); _clamp_col; }
_ed_down ()      { _clear_sel; test $_cur_row -lt $TUISH_BUF_COUNT && _cur_row=$((_cur_row + 1)); _clamp_col; }

_ed_left ()
{
	_clear_sel
	if test $_cur_col -gt 1
	then
		_cur_col=$((_cur_col - 1))
	elif test $_cur_row -gt 1
	then
		_cur_row=$((_cur_row - 1))
		tuish_buf_get "$_ed_buf" $_cur_row; local _l="$TUISH_BLINE"; tuish_str_len _l
		_cur_col=$((TUISH_SLEN + 1))
	fi
}

_ed_right ()
{
	_clear_sel
	tuish_buf_get "$_ed_buf" $_cur_row; local _l="$TUISH_BLINE"; tuish_str_len _l
	if test $_cur_col -le $TUISH_SLEN
	then
		_cur_col=$((_cur_col + 1))
	elif test $_cur_row -lt $TUISH_BUF_COUNT
	then
		_cur_row=$((_cur_row + 1))
		_cur_col=1
	fi
}

_ed_home ()      { _clear_sel; _cur_col=1; }

_ed_end ()
{
	_clear_sel
	tuish_buf_get "$_ed_buf" $_cur_row; local _l="$TUISH_BLINE"; tuish_str_len _l
	_cur_col=$((TUISH_SLEN + 1))
}

_ed_word_left ()  { _clear_sel; _word_left; }
_ed_word_right () { _clear_sel; _word_right; }

_ed_top ()       { _clear_sel; _cur_row=1; _cur_col=1; }

_ed_bottom ()
{
	_clear_sel
	_cur_row=$TUISH_BUF_COUNT
	tuish_buf_get "$_ed_buf" $_cur_row; local _l="$TUISH_BLINE"; tuish_str_len _l
	_cur_col=$((TUISH_SLEN + 1))
}

_ed_pgup ()
{
	_clear_sel
	_cur_row=$((_cur_row - _view_height))
	test $_cur_row -lt 1 && _cur_row=1
	_clamp_col
}

_ed_pgdn ()
{
	_clear_sel
	_cur_row=$((_cur_row + _view_height))
	test $_cur_row -gt $TUISH_BUF_COUNT && _cur_row=$TUISH_BUF_COUNT
	_clamp_col
}

# Selection navigation
_ed_sel_up ()
{
	_start_sel
	test $_cur_row -gt 1 && _cur_row=$((_cur_row - 1))
	_clamp_col; tuish_request_redraw
}

_ed_sel_down ()
{
	_start_sel
	test $_cur_row -lt $TUISH_BUF_COUNT && _cur_row=$((_cur_row + 1))
	_clamp_col; tuish_request_redraw
}

_ed_sel_left ()
{
	_start_sel
	if test $_cur_col -gt 1
	then
		_cur_col=$((_cur_col - 1))
	elif test $_cur_row -gt 1
	then
		_cur_row=$((_cur_row - 1))
		tuish_buf_get "$_ed_buf" $_cur_row; local _l="$TUISH_BLINE"; tuish_str_len _l
		_cur_col=$((TUISH_SLEN + 1))
	fi
	tuish_request_redraw
}

_ed_sel_right ()
{
	_start_sel
	tuish_buf_get "$_ed_buf" $_cur_row; local _l="$TUISH_BLINE"; tuish_str_len _l
	if test $_cur_col -le $TUISH_SLEN
	then
		_cur_col=$((_cur_col + 1))
	elif test $_cur_row -lt $TUISH_BUF_COUNT
	then
		_cur_row=$((_cur_row + 1)); _cur_col=1
	fi
	tuish_request_redraw
}

_ed_sel_home ()  { _start_sel; _cur_col=1; tuish_request_redraw; }

_ed_sel_end ()
{
	_start_sel
	tuish_buf_get "$_ed_buf" $_cur_row; local _l="$TUISH_BLINE"; tuish_str_len _l
	_cur_col=$((TUISH_SLEN + 1)); tuish_request_redraw
}

_ed_sel_word_left ()  { _start_sel; _word_left; tuish_request_redraw; }
_ed_sel_word_right () { _start_sel; _word_right; tuish_request_redraw; }
_ed_sel_top ()        { _start_sel; _cur_row=1; _cur_col=1; tuish_request_redraw; }

_ed_sel_bottom ()
{
	_start_sel; _cur_row=$TUISH_BUF_COUNT
	tuish_buf_get "$_ed_buf" $_cur_row; local _l="$TUISH_BLINE"; tuish_str_len _l
	_cur_col=$((TUISH_SLEN + 1)); tuish_request_redraw
}

# Mouse actions
_ed_click ()
{
	_clear_sel
	_cur_row=$((_view_top + TUISH_MOUSE_Y - 1))
	# Clamp the row to the buffer BEFORE _col_to_char, which reads that line: a
	# click below the last line (e.g. empty space) would otherwise index an unbound
	# buffer var under set -u and abort. Matters in a region host, where clicking
	# the editor's empty area is common.
	test $_cur_row -lt 1 && _cur_row=1
	test $_cur_row -gt $TUISH_BUF_COUNT && _cur_row=$TUISH_BUF_COUNT
	_col_to_char $((_view_left + TUISH_MOUSE_X - 1))
	_clamp_col
}

_ed_drag ()
{
	if test $_sel_row -eq 0
	then
		_sel_row=$_cur_row
		_sel_col=$_cur_col
	fi
	_cur_row=$((_view_top + TUISH_MOUSE_Y - 1))
	# Clamp BEFORE _col_to_char reads the line (as _ed_click does) — a drag below
	# the last line would otherwise index an unbound buffer var under set -u and
	# abort. This is the common case in a region host: drag-selecting past the text.
	test $_cur_row -lt 1 && _cur_row=1
	test $_cur_row -gt $TUISH_BUF_COUNT && _cur_row=$TUISH_BUF_COUNT
	_col_to_char $((_view_left + TUISH_MOUSE_X - 1))
	_clamp_col
	tuish_request_redraw
}

# The wheel. Both CHAIN: if the view cannot actually move -- we are already at the
# top/bottom, or the whole buffer fits -- the event is handed back with tuish_pass so
# whatever hosts us can scroll instead. A two-line editor embedded in a scrolling page
# must not swallow the page's wheel.
_ed_scroll_up ()
{
	test $_view_top -le 1 && { tuish_pass; return 0; }
	_view_top=$((_view_top - 3))
	test $_view_top -lt 1 && _view_top=1
	tuish_request_redraw
}

_ed_scroll_down ()
{
	tuish_buf_count "$_ed_buf"
	local _max=$((TUISH_BUF_COUNT - _view_height + 1))
	test $_max -lt 1 && _max=1
	test $_view_top -ge $_max && { tuish_pass; return 0; }
	_view_top=$((_view_top + 3))
	test $_view_top -gt $_max && _view_top=$_max
	tuish_request_redraw
}

# Editing actions
_ed_insert_char ()
{
	local _ch="${TUISH_EVENT#char }"
	test "$_ch" = 'bslash' && _ch='\'
	test $_sel_row -ne 0 && _delete_selection
	tuish_buf_get "$_ed_buf" $_cur_row; local _line="$TUISH_BLINE"
	tuish_str_left _line $((_cur_col - 1))
	local _left="$TUISH_SLEFT"
	tuish_str_right _line $((_cur_col - 1))
	tuish_buf_set "$_ed_buf" $_cur_row "${_left}${_ch}${TUISH_SRIGHT}"
	_cur_col=$((_cur_col + 1))
	_ed_render_line_now
	tuish_request_redraw 1
}

_ed_space ()
{
	test $_sel_row -ne 0 && _delete_selection
	tuish_buf_get "$_ed_buf" $_cur_row; local _line="$TUISH_BLINE"
	tuish_str_left _line $((_cur_col - 1))
	local _left="$TUISH_SLEFT"
	tuish_str_right _line $((_cur_col - 1))
	tuish_buf_set "$_ed_buf" $_cur_row "${_left} ${TUISH_SRIGHT}"
	_cur_col=$((_cur_col + 1))
	_ed_render_line_now
	tuish_request_redraw 1
}

_ed_tab ()
{
	test $_sel_row -ne 0 && _delete_selection
	tuish_buf_get "$_ed_buf" $_cur_row; local _line="$TUISH_BLINE"
	tuish_str_left _line $((_cur_col - 1))
	local _left="$TUISH_SLEFT"
	tuish_str_right _line $((_cur_col - 1))
	tuish_buf_set "$_ed_buf" $_cur_row "${_left}    ${TUISH_SRIGHT}"
	_cur_col=$((_cur_col + 4))
	_ed_render_line_now
	tuish_request_redraw 1
}

_ed_enter ()
{
	test $_sel_row -ne 0 && _delete_selection
	tuish_buf_get "$_ed_buf" $_cur_row; local _line="$TUISH_BLINE"
	tuish_str_left _line $((_cur_col - 1))
	local _left="$TUISH_SLEFT"
	tuish_str_right _line $((_cur_col - 1))
	local _right="$TUISH_SRIGHT"
	tuish_buf_set "$_ed_buf" $_cur_row "$_left"
	tuish_buf_insert_at "$_ed_buf" $((_cur_row + 1)) "$_right"
	_cur_row=$((_cur_row + 1))
	_cur_col=1
	tuish_request_redraw
}

_ed_bksp ()
{
	if test $_sel_row -ne 0
	then
		_delete_selection
	elif test $_cur_col -gt 1
	then
		tuish_buf_get "$_ed_buf" $_cur_row; local _line="$TUISH_BLINE"
		tuish_str_left _line $((_cur_col - 2))
		local _left="$TUISH_SLEFT"
		tuish_str_right _line $((_cur_col - 1))
		tuish_buf_set "$_ed_buf" $_cur_row "${_left}${TUISH_SRIGHT}"
		_cur_col=$((_cur_col - 1))
		_ed_render_line_now
		tuish_request_redraw 1
	elif test $_cur_row -gt 1
	then
		# Join with previous line
		tuish_buf_get "$_ed_buf" $((_cur_row - 1)); local _prev="$TUISH_BLINE"
		tuish_buf_get "$_ed_buf" $_cur_row; local _curr="$TUISH_BLINE"
		tuish_str_len _prev
		local _newcol=$((TUISH_SLEN + 1))
		tuish_buf_set "$_ed_buf" $((_cur_row - 1)) "${_prev}${_curr}"
		tuish_buf_delete_at "$_ed_buf" $_cur_row
		_cur_row=$((_cur_row - 1))
		_cur_col=$_newcol
		tuish_request_redraw
	fi
}

_ed_del ()
{
	if test $_sel_row -ne 0
	then
		_delete_selection
	else
		tuish_buf_get "$_ed_buf" $_cur_row; local _line="$TUISH_BLINE"
		tuish_str_len _line
		if test $_cur_col -le $TUISH_SLEN
		then
			tuish_str_left _line $((_cur_col - 1))
			local _left="$TUISH_SLEFT"
			tuish_str_right _line $_cur_col
			tuish_buf_set "$_ed_buf" $_cur_row "${_left}${TUISH_SRIGHT}"
			_ed_render_line_now
			tuish_request_redraw 1
		elif test $_cur_row -lt $TUISH_BUF_COUNT
		then
			# Join with next line
			tuish_buf_get "$_ed_buf" $((_cur_row + 1)); local _next="$TUISH_BLINE"
			tuish_buf_set "$_ed_buf" $_cur_row "${_line}${_next}"
			tuish_buf_delete_at "$_ed_buf" $((_cur_row + 1))
			tuish_request_redraw
		fi
	fi
}

_ed_del_word_left ()
{
	if test $_sel_row -ne 0
	then
		_delete_selection
		return
	fi
	if test $_cur_col -le 1
	then
		# At start of line: join with previous (same as bksp)
		if test $_cur_row -gt 1
		then
			tuish_buf_get "$_ed_buf" $((_cur_row - 1)); local _prev="$TUISH_BLINE"
			tuish_buf_get "$_ed_buf" $_cur_row; local _curr="$TUISH_BLINE"
			tuish_str_len _prev
			local _newcol=$((TUISH_SLEN + 1))
			tuish_buf_set "$_ed_buf" $((_cur_row - 1)) "${_prev}${_curr}"
			tuish_buf_delete_at "$_ed_buf" $_cur_row
			_cur_row=$((_cur_row - 1))
			_cur_col=$_newcol
			tuish_request_redraw
		fi
		return
	fi
	local _old_col=$_cur_col
	_word_left
	tuish_buf_get "$_ed_buf" $_cur_row; local _line="$TUISH_BLINE"
	tuish_str_left _line $((_cur_col - 1))
	local _left="$TUISH_SLEFT"
	tuish_str_right _line $((_old_col - 1))
	tuish_buf_set "$_ed_buf" $_cur_row "${_left}${TUISH_SRIGHT}"
	_ed_render_line_now
	tuish_request_redraw 1
}

_ed_del_word_right ()
{
	if test $_sel_row -ne 0
	then
		_delete_selection
		return
	fi
	tuish_buf_get "$_ed_buf" $_cur_row; local _line="$TUISH_BLINE"
	tuish_str_len _line
	if test $_cur_col -gt $TUISH_SLEN
	then
		# At end of line: join with next (same as del)
		if test $_cur_row -lt $TUISH_BUF_COUNT
		then
			tuish_buf_get "$_ed_buf" $((_cur_row + 1)); local _next="$TUISH_BLINE"
			tuish_buf_set "$_ed_buf" $_cur_row "${_line}${_next}"
			tuish_buf_delete_at "$_ed_buf" $((_cur_row + 1))
			tuish_request_redraw
		fi
		return
	fi
	local _old_col=$_cur_col
	_word_right
	tuish_str_left _line $((_old_col - 1))
	local _left="$TUISH_SLEFT"
	tuish_str_right _line $((_cur_col - 1))
	tuish_buf_set "$_ed_buf" $_cur_row "${_left}${TUISH_SRIGHT}"
	_cur_col=$_old_col
	_ed_render_line_now
	tuish_request_redraw 1
}

_ed_resize ()
{
	_view_height=$((TUISH_VIEW_ROWS - 1))
	test $_view_height -lt 0 && _view_height=0
	_view_width=$TUISH_VIEW_COLS   # region width when hosted; full width standalone
	test $_view_width -lt 1 && _view_width=1
	# Clear viewport to prevent rewrap garbage after width change
	local _i=1
	while test $_i -le $TUISH_VIEW_ROWS
	do
		if tuish_vmove $_i 1; then tuish_clear_line; fi
		_i=$((_i + 1))
	done
	tuish_request_redraw
}

_ed_noop () { :; }

# The catch-all. It exists so an unbound key is visibly a no-op rather than falling
# through to some default -- but "no-op" means we did NOT act on it, so hand it back
# (tuish_pass) instead of silently consuming it on a host's behalf.
_ed_show_unbound () { tuish_pass; }

# ─── Rendering ──────────────────────────────────────────────────────

# Render current line immediately and flush to terminal.
# Use inside event handlers for latency-sensitive updates (typing).
# Deferred redraw (level 1) handles the status bar afterward.
_ed_render_line_now ()
{
	_render_line $_cur_row
	_compute_dcol
	tuish_vmove $((_cur_row - _view_top + 1)) $((_cur_dcol - _view_left + 1))
	tuish_flush
}

# Clip a line to the visible horizontal window (_view_left, _view_width).
# Outputs the visible portion of the line. Does not clear to EOL.
_render_clipped_line ()
{
	local _line="$1"
	tuish_str_window _line $_view_left $_view_width
	tuish_print "$TUISH_SWINDOW"
}

_ed_render ()
{
	tuish_hide_cursor
	_sel_bounds

	# Text area
	local _vrow=1
	local _lnum=$_view_top
	local _line
	while test $_vrow -le $_view_height
	do
		# Erase the row first, bounded by our drawable width, then draw over it.
		# (The old print-then-clear_to_eol erased to the end of the PHYSICAL line,
		# which from a hosted region punched through into the host's chrome.)
		tuish_clear_to_edge $_vrow
		if tuish_vmove $_vrow 1
		then
			if test $_lnum -le $TUISH_BUF_COUNT
			then
				tuish_buf_get "$_ed_buf" $_lnum; _line="$TUISH_BLINE"

				# Check if this line has selection
				if test $_sr1 -ne 0 && test $_lnum -ge $_sr1 && test $_lnum -le $_sr2
				then
					_render_sel_line "$_lnum" "$_line"
				else
					_render_clipped_line "$_line"
				fi
			else
				tuish_sgr '2'
				tuish_print '~'
				tuish_sgr_reset
			fi
		fi

		_vrow=$((_vrow + 1))
		_lnum=$((_lnum + 1))
	done

	# Status bar
	_render_status

	# Place cursor (adjusted for horizontal column scroll)
	_place_cursor
}

_render_sel_line ()
{
	local _lnum=$1
	local _line="$2"
	tuish_str_len _line
	local _len=$TUISH_SLEN

	# Selection bounds in character coordinates: _s = first selected char,
	# _e = one past the last (both 1-based).
	local _s=1 _e=$((_len + 1))
	test $_lnum -eq $_sr1 && _s=$_sc1
	test $_lnum -eq $_sr2 && _e=$_sc2

	# Convert those char bounds to display columns (0-based), the same way
	# _compute_dcol maps the cursor: width of the line prefix before each.
	tuish_str_left _line $((_s - 1)); local _pre="$TUISH_SLEFT"
	tuish_str_width _pre; local _sel_c0=$TUISH_SWIDTH
	tuish_str_left _line $((_e - 1)); _pre="$TUISH_SLEFT"
	tuish_str_width _pre; local _sel_c1=$TUISH_SWIDTH

	# Visible window in display columns: [_view_left, _vw_r).
	local _vw_r=$((_view_left + _view_width))

	# Three column sub-windows of the line — before (normal), selected
	# (reverse), after (normal) — each clipped to the visible window. Splitting
	# at a char-aligned column boundary tiles to the same glyphs as
	# _render_clipped_line, with tuish_str_window handling the edge straddles.
	# Build the three sub-windows — before (normal), selected (reverse), after
	# (normal) — into ONE string with the reverse-video toggles embedded via the
	# *_seq builders, then emit with a SINGLE tuish_print. The embedded sequences
	# use the raw ESC byte (see term.sh) so they survive tuish_print's escaping
	# while the line's own %/backslash text is escaped correctly.
	local _off _end _w _out=''

	# Before selection.
	_end=$_sel_c0
	test $_end -gt $_vw_r && _end=$_vw_r
	_w=$((_end - _view_left))
	if test $_w -gt 0
	then tuish_str_window _line $_view_left $_w; _out="$TUISH_SWINDOW"; fi

	# Selected text (reverse video).
	_off=$_sel_c0
	test $_off -lt $_view_left && _off=$_view_left
	_end=$_sel_c1
	test $_end -gt $_vw_r && _end=$_vw_r
	_w=$((_end - _off))
	if test $_w -gt 0
	then
		tuish_sgr_seq 7;       _out="${_out}${TUISH_SEQ}"
		tuish_str_window _line $_off $_w; _out="${_out}${TUISH_SWINDOW}"
		tuish_sgr_reset_seq;   _out="${_out}${TUISH_SEQ}"
	fi

	# After selection.
	_off=$_sel_c1
	test $_off -lt $_view_left && _off=$_view_left
	_w=$((_vw_r - _off))
	if test $_w -gt 0
	then tuish_str_window _line $_off $_w; _out="${_out}${TUISH_SWINDOW}"; fi

	tuish_print "$_out"
}

_render_status ()
{
	tuish_vmove $TUISH_VIEW_ROWS 1
	tuish_sgr '7'
	# The status bar spans OUR drawable width, not the terminal's: hosted, padding
	# to TUISH_COLUMNS would paint a full-width reverse bar across the host's page.
	local _w=$TUISH_VIEW_COLS
	test $_w -lt 1 && { tuish_sgr_reset; return; }
	local _info=" Ln ${_cur_row}, Col ${_cur_col}  |  ${TUISH_BUF_COUNT} lines "
	if test $_sel_row -ne 0
	then
		_info="${_info}  |  sel"
	fi
	if test -n "$_status_msg"
	then
		_info="${_info}  |  ${_status_msg}"
	fi
	if test "$TUISH_VIEW_MODE" = 'fullscreen'
	then
		local _help=' alt+f: short screen | ctrl+w: quit '
	else
		local _help=' alt+f: full screen | ctrl+w: quit '
	fi
	# Build a full-width status line padded with spaces so every cell
	# gets the reverse-video background (avoids terminal-dependent
	# clear_to_eol behaviour that can leave gaps).
	local _il=${#_info} _hl=${#_help}
	local _pad=$((_w - _il - _hl))
	if test $_pad -lt 0
	then
		# Not enough room for help text; truncate info to fit
		test $_il -ge $_w && _info="${_info:0:$((_w - 1))}"
		_il=${#_info}
		_pad=$((_w - _il))
		_help=''
		_hl=0
	fi
	tuish_print "$_info"
	# Emit padding spaces so the entire line has reverse-video background
	if test $_pad -gt 0
	then
		local _spaces='                                '  # 32 spaces
		while test ${#_spaces} -lt $_pad
		do
			_spaces="${_spaces}${_spaces}"
		done
		tuish_print "${_spaces:0:$_pad}"
	fi
	tuish_print "$_help"
	tuish_sgr_reset
	# No clear-to-eol: the padding above already fills the line to _w (our drawable
	# width). ESC[K here would erase past the region into the host's chrome.
}

_render_line ()
{
	local _lnum=$1
	local _vrow=$((_lnum - _view_top + 1))
	# Skip if outside the text area (avoids overwriting status bar)
	test $_vrow -lt 1 && return
	test $_vrow -gt $_view_height && return
	# Erase-then-draw, bounded by our drawable width (see _ed_render).
	tuish_clear_to_edge $_vrow
	tuish_vmove $_vrow 1
	if test $_lnum -le $TUISH_BUF_COUNT
	then
		tuish_buf_get "$_ed_buf" $_lnum; local _rl_line="$TUISH_BLINE"
		_render_clipped_line "$_rl_line"
	else
		tuish_sgr '2'
		tuish_print '~'
		tuish_sgr_reset
	fi
}

# ─── Key bindings ───────────────────────────────────────────────────

_ed_setup_bindings ()
{
	tuish_bind 'ctrl-w'          '_ed_quit'
	tuish_bind 'alt-f'           '_ed_toggle_fullscreen'

	# Clipboard. ctrl-c is free to mean Copy here: tuish_init runs the terminal with
	# `stty -isig`, so ctrl-c never raises SIGINT — it arrives as a plain key event
	# (and was unbound until now). `paste` is the atomic bracketed-paste event; the
	# text is in TUISH_PASTE.
	tuish_bind 'ctrl-c'          '_ed_copy'
	tuish_bind 'ctrl-x'          '_ed_cut'
	tuish_bind 'ctrl-v'          '_ed_paste'
	tuish_bind 'paste'           '_ed_on_paste'
	# Boundary markers: consumed so they cannot reach the catch-all. The body is
	# delivered by the `paste` event above, not between these.
	tuish_bind 'paste-start'     ':'
	tuish_bind 'paste-end'       ':'

	# Navigation
	tuish_bind 'up'              '_ed_up'
	tuish_bind 'down'            '_ed_down'
	tuish_bind 'left'            '_ed_left'
	tuish_bind 'right'           '_ed_right'
	tuish_bind 'home'            '_ed_home'
	tuish_bind 'end'             '_ed_end'
	tuish_bind 'ctrl-left'       '_ed_word_left'
	tuish_bind 'ctrl-right'      '_ed_word_right'
	tuish_bind 'ctrl-home'       '_ed_top'
	tuish_bind 'ctrl-end'        '_ed_bottom'
	tuish_bind 'pgup'            '_ed_pgup'
	tuish_bind 'pgdn'            '_ed_pgdn'

	# macOS motions: Cmd = line/document, Option = word (in a terminal that
	# reports them; see docs/hid.md). Harmless on other platforms.
	tuish_bind 'super-left'      '_ed_home'
	tuish_bind 'super-right'     '_ed_end'
	tuish_bind 'super-up'        '_ed_top'
	tuish_bind 'super-down'      '_ed_bottom'
	tuish_bind 'alt-left'        '_ed_word_left'
	tuish_bind 'alt-right'       '_ed_word_right'

	# Selection
	tuish_bind 'shift-up'         '_ed_sel_up'
	tuish_bind 'shift-down'       '_ed_sel_down'
	tuish_bind 'shift-left'       '_ed_sel_left'
	tuish_bind 'shift-right'      '_ed_sel_right'
	tuish_bind 'shift-home'       '_ed_sel_home'
	tuish_bind 'shift-end'        '_ed_sel_end'
	tuish_bind 'ctrl-shift-left'  '_ed_sel_word_left'
	tuish_bind 'ctrl-shift-right' '_ed_sel_word_right'
	tuish_bind 'ctrl-shift-home'  '_ed_sel_top'
	tuish_bind 'ctrl-shift-end'   '_ed_sel_bottom'

	# macOS selection motions: Cmd+Shift = line/document, Option+Shift = word.
	tuish_bind 'shift-super-left'  '_ed_sel_home'
	tuish_bind 'shift-super-right' '_ed_sel_end'
	tuish_bind 'shift-super-up'    '_ed_sel_top'
	tuish_bind 'shift-super-down'  '_ed_sel_bottom'
	tuish_bind 'alt-shift-left'    '_ed_sel_word_left'
	tuish_bind 'alt-shift-right'   '_ed_sel_word_right'

	# Mouse
	tuish_bind 'lclik'           '_ed_click'
	tuish_bind 'lhold'           '_ed_drag'
	tuish_bind 'whup'            '_ed_scroll_up'
	tuish_bind 'wdown'           '_ed_scroll_down'

	# Editing
	tuish_bind 'char *'          '_ed_insert_char'
	tuish_bind 'space'           '_ed_space'
	tuish_bind 'tab'             '_ed_tab'
	tuish_bind 'enter'           '_ed_enter'
	tuish_bind 'bksp'            '_ed_bksp'
	tuish_bind 'ctrl-bksp'       '_ed_del_word_left'
	tuish_bind 'alt-bksp'        '_ed_del_word_left'   # macOS: Option+Backspace
	tuish_bind 'del'             '_ed_del'
	tuish_bind 'ctrl-del'        '_ed_del_word_right'

	# Signals & misc
	tuish_bind 'resize'          '_ed_resize'
	tuish_bind 'focus-in'        '_ed_noop'
	tuish_bind 'focus-out'       '_ed_noop'
	tuish_bind 'idle'            '_ed_noop'

	# Catch-all: show unbound events in status bar
	tuish_bind '*'               '_ed_show_unbound'
}

# ─── Event handler ──────────────────────────────────────────────────

_ed_on_event ()
{
	_status_msg=''
	local _prev_row=$_cur_row
	local _prev_col=$_cur_col

	tuish_dispatch || :

	_ensure_visible

	# Cursor moved → at least status + cursor update
	if test $_cur_row -ne $_prev_row || test $_cur_col -ne $_prev_col
	then
		tuish_request_redraw 1
	fi
}

_ed_on_redraw ()
{
	if test "$1" -eq -1
	then
		_ed_render
	elif test "$1" -ge 2
	then
		_render_line $_cur_row
		_render_status
		_place_cursor
	else
		_render_status
		_place_cursor
	fi
}

# ─── Main ───────────────────────────────────────────────────────────

# Everything but the event loop. Split out of _ed_main so a cooperative host can
# tuish_ctx_mount us and drive us from ITS loop (we never call tuish_run then).
# Takes an optional file path in $1, exactly like _ed_main.
_ed_setup ()
{
	tuish_init
	# Our instance state, at its declared defaults. This replaces the hand-written "fresh
	# state each launch" block that used to sit above tuish_init: the framework knows the
	# defaults because we declared them, and — the part the old block could not do —
	# these are now OUR copy, not the process's.
	#
	# Guarded to match the tuish_ctx_declare above: that one is optional (an older tuish has
	# no field sets), so this one has to be too. Guard the declaration and not the attach and
	# the app sources cleanly, then dies in setup with "command not found".
	command -v tuish_ctx_fields >/dev/null 2>&1 && tuish_ctx_fields _ed

	# A buffer of our own, unless a host handed us one. Keyed on the context id, so two
	# editors mounted side by side do not edit the same lines. (Standalone we are context
	# 1 and this is just a name.)
	test "$_ed_buf" = '_' && _ed_buf="ed$TUISH_CTX"

	tuish_cursor_shape 6          # steady bar: declared once, re-asserted with every caret
	tuish_mouse_on

	# Register render/event handlers BY NAME (not by redefining the global hooks),
	# so hosting composes: our handlers live in our context, the host keeps its own.
	tuish_on_event  _ed_on_event
	tuish_on_redraw _ed_on_redraw
	_ed_setup_bindings

	tuish_viewport fixed 10

	_view_height=$((TUISH_VIEW_ROWS - 1))
	_view_width=$TUISH_VIEW_COLS   # region width when hosted; full width standalone

	# Load a file from argv; otherwise keep whatever is in _ed_buf and start empty
	# only if it is genuinely empty.
	if test -n "${1:-}" && test -f "$1"
	then
		_status_msg="$1"
		while IFS= read -r _fline || test -n "$_fline"
		do
			tuish_buf_append "$_ed_buf" "$_fline"
		done < "$1"
		test $TUISH_BUF_COUNT -eq 0 && tuish_buf_append "$_ed_buf" ''
	else
		# A HOST may have seeded _ed_buf before mounting us (a doc snippet to edit).
		# Initializing unconditionally would wipe exactly what we were handed.
		tuish_buf_count "$_ed_buf"
		test "$TUISH_BUF_COUNT" -eq 0 && tuish_buf_init "$_ed_buf"
	fi

	_ed_render
}

# We declare a bar caret (tuish_cursor_shape 6, above) and that is the whole of our
# involvement with it. We do not put it back.
#
# There used to be a fini hook here that did, and it had to ask `tuish_hosted` first —
# because a host unmounts us for its own reasons (you left edit mode; the block you were
# editing scrolled off its pane), and resetting the caret there reached out and changed the
# terminal device-wide, under whatever else was still on screen and being typed into. Asking
# was the workaround. Not restoring is the fix: we own our rectangle, not the device, and
# that is true standalone as well — the device layer took the caret and the device layer puts
# it back (tuish_fini emits DECSCUSR 0 exactly once, if anyone ever had an opinion).
#
# An app REQUESTS device state. It never restores it. Which is why this app no longer has
# to know whether it is hosted at all.

# Entry point for the BLOCKING form: standalone (the bootstrap below) or a modal host
# that runs us inside a region it created and gets control back when we quit.
_ed_main ()
{
	_ed_setup "${@:-}"
	tuish_run || :
	tuish_fini
}

if test "${_ed_standalone:-0}" -eq 1
then
	_ed_main "${@:-}"
fi
