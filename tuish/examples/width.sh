#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# width.sh - Visual ACID test for tuish_str_width
# Displays tables of Unicode strings padded to fixed column widths.
# If width calculation is correct, all vertical borders align perfectly.
# Any misalignment reveals a width bug for that character class.
# Ctrl+W to exit.
#
# Dual-mode: runs standalone (`sh examples/width.sh`) or embedded inside another
# tuish app (the host sources it and calls _w_main inside a region). Every name is
# _w_-prefixed; the code never knows whether it is hosted.

if test -z "${_tuish_tui_loaded:-}"
then
	_w_standalone=1
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
	_w_standalone=0
fi

# ─── State ────────────────────────────────────────────────────────

_w_started=no
_w_scroll=0
_w_n=0          # total cached rows
_w_col1=20
_w_col2=24

# ─── Pre-computation (runs once at startup) ──────────────────────
# Stores each row in indexed variables. Row types: h=hline, s=section, t=test.
#
# This used to exist "so redraw never calls tuish_str_width", which was a real
# concern when a width on a wide string cost milliseconds; str.sh memoizes that
# now, and these rows would be cheap to measure per frame. What the precompute
# still earns is the part that is not measurement: which cases PASS, and the
# padded columns that make the table line up. That is state, not output, so it
# belongs here and not in the render — see docs/event.md.

_w_add_hline ()
{
	eval "_w_type_${_w_n}=h"
	_w_n=$((_w_n + 1))
}

_w_add_section ()
{
	eval "_w_type_${_w_n}=s"
	eval "_w_stitle_${_w_n}=\"\$1\""
	# Pre-build dashes
	local _slen=${#1}
	local _fill=$((58 - _slen))
	local _f=0
	local _dashes=''
	while test $_f -lt $_fill
	do
		_dashes="${_dashes}-"
		_f=$((_f + 1))
	done
	eval "_w_sdash_${_w_n}=\"\$_dashes\""
	_w_n=$((_w_n + 1))
}

_w_add_test ()
{
	# $1=label $2=text $3=expected_width
	eval "_w_type_${_w_n}=t"

	# Pre-pad label
	local _lab="$1"
	tuish_str_pad _lab $_w_col1
	eval "_w_tlab_${_w_n}=\"\$TUISH_SPADDED\""

	# Pre-pad text and record actual width
	local _txt="$2"
	tuish_str_width _txt
	local _actual=$TUISH_SWIDTH
	eval "_w_tactual_${_w_n}=$_actual"
	eval "_w_texpect_${_w_n}=$3"
	tuish_str_pad _txt $_w_col2
	eval "_w_ttxt_${_w_n}=\"\$TUISH_SPADDED\""

	# Pre-build result column (padded to 8 display columns)
	local _rtext
	if test "$_actual" -eq "$3"
	then
		eval "_w_tpass_${_w_n}=1"
		_rtext="w=$_actual"
	else
		eval "_w_tpass_${_w_n}=0"
		_rtext="${_actual}!=$3"
	fi
	eval "_w_tresult_${_w_n}=\"\$_rtext\""
	tuish_str_pad _rtext 8
	eval "_w_trpad_${_w_n}=\"\${TUISH_SPADDED#\"\$_rtext\"}\""

	_w_n=$((_w_n + 1))
}

_w_precompute ()
{
	_w_n=0

	_w_add_section "ASCII "
	_w_add_test 'plain'             'Hello, world!'     13
	_w_add_test 'digits'            '0123456789'        10
	_w_add_test 'punctuation'       '@#$%^&*()_+-='     13
	_w_add_test 'single char'       'X'                 1
	_w_add_test 'spaces'            'a b c'             5
	_w_add_hline

	_w_add_section "Latin accented "
	_w_add_test 'French'            'cafe'              4
	_w_add_test 'French (accented)' 'café'              4
	_w_add_test 'German'            'uber'              4
	_w_add_test 'German (umlaut)'   'über'              4
	_w_add_test 'naive'             'naïve'             5
	_w_add_test 'mixed accents'     'résumé'            6
	_w_add_hline

	_w_add_section "CJK ideographs (width 2) "
	_w_add_test 'Chinese'           '中文'              4
	_w_add_test 'Japanese kanji'    '日本語'            6
	_w_add_test 'single CJK'        '漢'                2
	_w_add_test 'CJK + ASCII'       'hi中文'            6
	_w_add_test 'interleaved'       '中a文b'            6
	_w_add_test 'CJK sentence'      '你好世界'          8
	_w_add_hline

	_w_add_section "Japanese kana (width 2) "
	_w_add_test 'Hiragana'          'あいう'            6
	_w_add_test 'Katakana'          'アイウ'            6
	_w_add_test 'mixed kana'        'あアい'            6
	_w_add_hline

	_w_add_section "Korean (width 2) "
	_w_add_test 'Hangul'            '한글'              4
	_w_add_test 'Korean word'       '가나다'            6
	_w_add_test 'Hangul + ASCII'    '한a글b'            6
	_w_add_hline

	_w_add_section "Fullwidth Latin (width 2) "
	_w_add_test 'fullwidth A'       'Ａ'                2
	_w_add_test 'fullwidth ABC'     'ＡＢＣ'            6
	_w_add_test 'fw vs normal'      'AＡ'               3
	_w_add_hline

	_w_add_section "Width stress (all 10 cols) "
	_w_add_test '10 ASCII'          'abcdefghij'        10
	_w_add_test '5 CJK'             '一二三四五'        10
	_w_add_test 'CJK sandwich'      'abc中文def'        10
	_w_add_test 'CJK bookends'      '中abcd中ab'        10
	_w_add_test 'alternating'       'ab中cd中ef'        10
	_w_add_hline

	_w_add_section "Alignment grid (all 10 cols) "
	_w_add_test '10 dashes'         '----------'        10
	_w_add_test '5 CJK'             '中中中中中'        10
	_w_add_test '4 narrow + 3 wide' 'aaa中中中a'        10
	_w_add_test 'NWNWNWN'           'a中a中a中a'        10
	_w_add_test 'WNWNWNN'           '中a中a中ab'        10
	_w_add_hline

	_w_add_section "Emoji "
	_w_add_test 'smile'             '😀'                2
	_w_add_test 'two emoji'         '😀😎'              4
	_w_add_test 'emoji + ASCII'     'hi😀'              4
	_w_add_test 'ASCII + emoji'     '😀hi'              4
	_w_add_test 'mixed'             'a😀b😎c'           7
	_w_add_test 'hourglass'         '⌛'                2
	_w_add_test 'heart'             '❤'                 1
	_w_add_test 'check mark'        '✓'                 1
	_w_add_test 'warning'           '⚠'                 1
	_w_add_test 'star'              '⭐'                2
	_w_add_hline

	_w_add_section "Empty and edge cases "
	_w_add_test '(empty string)'    ''                  0
	_w_add_test 'single space'      ' '                 1
	_w_add_hline
}

# ─── Table renderer (from cache) ────────────────────────────────

_w_draw_tests ()
{
	local _i=0 _vr _type
	while test $_i -lt $_w_n
	do
		_vr=$((_i - _w_scroll + 3))
		if test $_vr -ge 3 && test $_vr -le $TUISH_VIEW_ROWS
		then
			eval "_type=\$_w_type_${_i}"
			# Erase the row across our drawable width first, then draw over it —
			# one clear for all three row types. ESC[K would erase to the end of
			# the physical line, through an embedding host's chrome.
			tuish_clear_to_edge $_vr
			tuish_vmove $_vr 1
			case "$_type" in
				h)
					tuish_dim
					tuish_print "  +----------------------+--------------------------+----------+"
					tuish_sgr_reset
					;;
				s)
					eval "local _title=\"\$_w_stitle_${_i}\""
					eval "local _dashes=\"\$_w_sdash_${_i}\""
					tuish_dim
					tuish_print "  +- "
					tuish_sgr_reset
					tuish_bold
					tuish_print "$_title"
					tuish_sgr_reset
					tuish_dim
					tuish_print "$_dashes"
					tuish_print "+"
					tuish_sgr_reset
					;;
				t)
					eval "local _lab=\"\$_w_tlab_${_i}\""
					eval "local _txt=\"\$_w_ttxt_${_i}\""
					eval "local _pass=\$_w_tpass_${_i}"
					eval "local _result=\"\$_w_tresult_${_i}\""
					eval "local _rpad=\"\$_w_trpad_${_i}\""
					tuish_dim
					tuish_print "  | "
					tuish_sgr_reset
					tuish_print "$_lab"
					tuish_dim
					tuish_print " | "
					tuish_sgr_reset
					tuish_print "$_txt"
					tuish_dim
					tuish_print " | "
					tuish_sgr_reset
					if test "$_pass" = 1
					then
						tuish_fg 2
						tuish_print "$_result"
						tuish_sgr_reset
						tuish_print "$_rpad"
					else
						tuish_fg 1
						tuish_bold
						tuish_print "$_result"
						tuish_sgr_reset
						tuish_print "$_rpad"
					fi
					tuish_dim
					tuish_print " |"
					tuish_sgr_reset
					;;
			esac
		fi
		_i=$((_i + 1))
	done

	# Clear remaining rows
	_vr=$((_w_n - _w_scroll + 3))
	while test $_vr -ge 3 && test $_vr -le $TUISH_VIEW_ROWS
	do
		tuish_clear_to_edge $_vr
		_vr=$((_vr + 1))
	done
}

# ─── Chrome ──────────────────────────────────────────────────────

_w_header ()
{
	# Reverse-fill row 1 across our width, then print over it (see boxes.sh).
	tuish_sgr '7'
	tuish_clear_to_edge 1
	tuish_vmove 1 1
	tuish_print " width.sh ACID test (quit: ctrl+w  scroll: arrows/pgup/pgdn) "
	tuish_sgr_reset

	tuish_clear_to_edge 2
	tuish_vmove 2 1
	tuish_dim
	tuish_print "  If widths are correct, all vertical borders align."
	tuish_sgr_reset
}

_w_redraw ()
{
	_w_header
	_w_draw_tests
}

# ─── Actions ──────────────────────────────────────────────────────

_w_quit ()    { tuish_quit_main; }
_w_resize ()  { tuish_request_redraw; }
_w_idle ()
{
	if test "$_w_started" = 'no'
	then
		_w_started=yes
		_w_redraw
	fi
}

_w_scroll_up ()
{
	if test $_w_scroll -gt 0
	then
		_w_scroll=$((_w_scroll - 1))
		tuish_request_redraw
	fi
}

_w_scroll_down ()
{
	if test $_w_scroll -lt $((_w_n - 1))
	then
		_w_scroll=$((_w_scroll + 1))
		tuish_request_redraw
	fi
}

_w_pgup ()
{
	_w_scroll=$((_w_scroll - TUISH_VIEW_ROWS + 4))
	if test $_w_scroll -lt 0; then _w_scroll=0; fi
	tuish_request_redraw
}

_w_pgdn ()
{
	_w_scroll=$((_w_scroll + TUISH_VIEW_ROWS - 4))
	if test $_w_scroll -ge $_w_n; then _w_scroll=$((_w_n - 1)); fi
	tuish_request_redraw
}

# ─── Main ─────────────────────────────────────────────────────────

# Everything but the event loop. Split out of _w_main so a cooperative host can
# tuish_ctx_mount us and drive us from ITS loop (we never call tuish_run then).
# Bindings and the render handler are registered here, after tuish_init, so they land
# in whichever context is active — the root standalone, our region when hosted.
_w_setup ()
{
	_w_started=no
	_w_scroll=0

	tuish_init
	tuish_mouse_on
	_w_precompute
	tuish_on_redraw _w_redraw
	tuish_bind 'ctrl-w'  '_w_quit'
	tuish_bind 'idle'    '_w_idle'
	tuish_bind 'resize'  '_w_resize'
	tuish_bind 'up'      '_w_scroll_up'
	tuish_bind 'down'    '_w_scroll_down'
	tuish_bind 'pgup'    '_w_pgup'
	tuish_bind 'pgdn'    '_w_pgdn'
	tuish_bind 'whup'    '_w_scroll_up'
	tuish_bind 'wdown'   '_w_scroll_down'

	tuish_viewport fullscreen
}

# Entry point for the BLOCKING form: standalone (the bootstrap below) or a modal host
# that runs us inside a region it created and gets control back when we quit.
_w_main ()
{
	_w_setup
	tuish_run || :
	tuish_fini
}

if test "${_w_standalone:-0}" -eq 1
then
	_w_main
fi
