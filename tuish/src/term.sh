# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Load guard: skip re-definition if already sourced (see tui.sh).
if test -n "${_tuish_term_loaded:-}"; then return 0; fi
_tuish_term_loaded=1
# src/term.sh - Terminal output and drawing primitives
# Optional module. Source after tui.sh.
#
# Provides:
#   Cursor:     tuish_move, tuish_vmove, tuish_print, tuish_print_at
#   Clearing:   tuish_clear_line, tuish_clear_to_eol, tuish_clear_to_bol,
#               tuish_clear_screen, tuish_clear_region
#   Cursor:     tuish_cursor_shape
#   Scrolling:  tuish_scroll_region, tuish_scroll_up/down, tuish_scroll_up_n/down_n
#   Screen:     tuish_altscreen_on/off, tuish_newline
#   Attributes: tuish_sgr, tuish_sgr_reset, tuish_style,
#               tuish_bold/dim/italic/underline/blink/reverse/strikethrough
#   Colors:     tuish_fg/bg (0-7 basic, 8-15 bright, 16-255 palette,
#               R:G:B truecolor, or 'default')
#   Movement:   tuish_move_up/down/left/right
#
# Dependencies: tui.sh (_tuish_write, tuish_begin/end/flush,
#   tuish_show/hide_cursor, tuish_save/restore_cursor, tuish_reset_scroll)

# ─── Drawing primitives ──────────────────────────────────────────

tuish_move ()           { _tuish_cursor_abs_row=$1; _tuish_write "\033[${1};${2}H"; }
tuish_vmove ()
{
	# One affine+clip transform. _tx_* default to the viewport identity (no
	# column shift, unit cells, no cell clip); a canvas overwrites them to a
	# bounded, optionally CWxCH-scaled sub-region. Clip in cell space on all four
	# edges first, then scale+offset to the absolute cell. The row origin folds in
	# TUISH_VIEW_TOP live, so a resize needs no recompute.
	if test $1 -lt $_tx_lrmin || test $1 -gt $_tx_lrmax \
	   || test $2 -lt $_tx_lcmin || test $2 -gt $_tx_lcmax
	then
		return 1
	fi
	local _abs=$(( TUISH_VIEW_TOP + _tx_off_r + ($1 - 1) * _tx_ch ))
	local _col=$(( TUISH_VIEW_LEFT + _tx_off_c + ($2 - 1) * _tx_cw + 1 ))
	if test $_abs -gt $TUISH_LINES
	then
		return 1
	fi
	_tuish_cursor_abs_row=$_abs
	_tuish_write "\033[$_abs;${_col}H"
	return 0
}
tuish_print ()
{
	local _p="$1"
	case "$_p" in *'\'*) _p="${_p//\\/\\\\}";; esac
	test $_tuish_printf -eq 1 && case "$_p" in *%*) _p="${_p//\%/%%}";; esac
	_tuish_write "$_p"
}
# _tuish_clip_avail COL  ->  _tuish_avail
# TERMINAL COLUMNS drawable from logical COL rightward. The single clip authority:
# tuish_text, tuish_clear_*, and the draw.sh box/line clamps all route through it
# instead of hand-clamping to TUISH_VIEW_COLS (which let content bleed past a hosted
# region's right edge).
#
# It answers in ABSOLUTE COLUMNS because that is the unit its consumers spend —
# tuish_str_left/tuish_str_window take a display-column budget, tuish_clear_region
# writes that many literal spaces. The bounds it must respect do NOT natively share
# that unit: TUISH_VIEW_COLS is viewport-logical columns, while _tx_lcmax is in the
# CURRENT cell space, which under a CWxCH canvas is CANVAS CELLS at an offset. A
# min() over the raw numbers mixes the two and is wrong in BOTH directions — it
# halved a CW=2 canvas's text, and let a canvas at a high _tx_off_c write past the
# screen. So each bound is mapped through the SAME affine transform tuish_vmove
# uses, and only then compared:
#
#   start = VIEW_LEFT + off_c + (COL-1)*cw + 1     first column of cell COL
#   last  = min( VIEW_LEFT + VIEW_COLS,            the region's right edge
#                VIEW_LEFT + off_c + lcmax*cw,     last column of the last cell
#                                                  tuish_vmove will accept
#                TUISH_COLUMNS )                   the physical screen
#
# Each bound is skipped when it is not KNOWN: TUISH_VIEW_COLS is 0 until a viewport
# is set (and stays 0 when viewport.sh is not sourced), TUISH_COLUMNS is 0 until
# tuish_update_size runs. With none of them known the answer is _TUISH_NOCLIP — large
# enough to mean "no trim", finite so callers can still detect it. Folding
# TUISH_COLUMNS in is what lets tuish_clear_to_edge be a single call: its old "no
# viewport, so use the whole terminal" fallback is now just the case where the region
# term is absent and the physical term wins.
#
# It reports a FACT, not a policy. _tuish_wrap ("do not trim text, let the terminal
# wrap") lives at the call sites that mean it — tuish_text, and the five draw.sh
# clamps, which already tested it. An ERASE never honours it: an unclamped clear under
# autowrap spills its spaces onto the next row, outside the region.
#
# _tuish_avail is TERMINAL COLUMNS, never cells. draw.sh positions in cells but writes
# glyph runs, and a terminal advances one column per glyph whatever _tx_cw is, so
# columns is right there too. What stays wrong at CW>1 is draw.sh's OWN geometry (it
# places a box's right border at cell col+W-1, a cw-scaled distance, but draws a run W
# columns long) — pre-existing and orthogonal; this helper can no longer over-permit
# it. A cell budget, if ever needed, is _tuish_avail / _tx_cw (floored — a partly
# visible cell is not drawable). Never negative.
_TUISH_NOCLIP=99999
_tuish_clip_avail ()
{
	local _ca_s=$(( TUISH_VIEW_LEFT + _tx_off_c + ($1 - 1) * _tx_cw + 1 ))
	local _ca_e=$_TUISH_NOCLIP _ca_c
	if test $TUISH_VIEW_COLS -gt 0
	then
		_ca_c=$(( TUISH_VIEW_LEFT + TUISH_VIEW_COLS ))
		test $_ca_c -lt $_ca_e && _ca_e=$_ca_c
	fi
	_ca_c=$(( TUISH_VIEW_LEFT + _tx_off_c + _tx_lcmax * _tx_cw ))
	test $_ca_c -lt $_ca_e && _ca_e=$_ca_c
	test $TUISH_COLUMNS -gt 0 && test $TUISH_COLUMNS -lt $_ca_e && _ca_e=$TUISH_COLUMNS
	# Nothing REAL bounded us: no viewport, no known screen width, and _tx_lcmax still
	# at its ±99999 "no clip" default, which is a sentinel rather than a column anyone
	# means. Answer exactly _TUISH_NOCLIP so callers can recognise it — measuring the
	# width instead would make COL=5 report 99995, which reads as a bound and had
	# tuish_clear_to_edge erase a hundred thousand spaces.
	test $_ca_e -ge $_TUISH_NOCLIP && { _tuish_avail=$_TUISH_NOCLIP; return 0; }
	_tuish_avail=$(( _ca_e - _ca_s + 1 ))
	test $_tuish_avail -lt 0 && _tuish_avail=0
	return 0
}
# tuish_text ROW COL TEXT [fg=N] [bg=N] [maxwidth=N] [width=N]
# The single text-placement entry point. Positions at viewport/canvas (ROW,COL)
# via tuish_vmove and prints TEXT, optionally coloured and width-clipped. Works
# in the minimal, str.sh-less profile (placement + colour only, letting the
# terminal clip at the screen edge); when str.sh is sourced it additionally
# honours maxwidth/width and trims to the display width that fits the visible
# window — including trimming leading cells when COL lands left of column 1
# (e.g. under panning). Resets SGR only when it applied a colour, so the plain
# form stays a pure place-and-print.
#
# maxwidth=N caps the text at N columns. width=N makes it a FIELD: exactly N
# columns, padded with spaces when the text is shorter. The padding is part of
# the same run, which is the point — see the note above the pad below.
tuish_text ()
{
	local _tt_row=$1 _tt_col=$2 _tt_text="$3" _tt_maxw=-1 _tt_fg=-1 _tt_bg=-1 _tt_esc=0 _tt_fw=-1
	shift 3
	while test $# -gt 0
	do
		case "$1" in
			maxwidth=*) _tt_maxw="${1#*=}";;
			width=*)    _tt_fw="${1#*=}";;
			fg=*)       _tt_fg="${1#*=}";;
			bg=*)       _tt_bg="${1#*=}";;
		esac
		shift
	done

	# Display-width clipping needs str.sh; without it, place + colour verbatim
	# and let the terminal clip at the screen edge. All right-edge trims go through
	# _tuish_clip_avail (the true visible window), never TUISH_VIEW_COLS, so text
	# clips at a hosted region's edge rather than bleeding to the screen edge.
	#
	# Asked via str.sh's own load guard rather than `type tuish_str_width`: this runs
	# on EVERY text draw, and the builtin lookup with its two redirections measured
	# 15us against 2us for the variable test — ~13us back on every label in every
	# frame. The guard is set before str.sh defines anything, so the only window where
	# the two disagree is mid-source, which is not a time anyone paints.
	if test -n "${_tuish_str_loaded:-}"
	then
		# Whole placement off the right of the visible window: nothing to draw.
		if test $_tuish_wrap -eq 0 && test $TUISH_VIEW_COLS -gt 0 \
		   && test $_tt_col -gt $_tx_lcmax
		then return 0; fi

		# ONE slice does the left and right clip together, in DISPLAY COLUMNS.
		#
		# There used to be a second, "plain" path here that clipped with
		# tuish_str_left/right instead — and those count CHARACTERS. For ASCII the two
		# units coincide, which is why it looked correct for years; for anything wider
		# they do not. `tuish_text 1 1 "$cjk" maxwidth=6` emitted 12 columns, and a
		# 36-column CJK string placed in a 20-column hosted region emitted all 36,
		# straight through the host's right border — the bleed the clipped tier was
		# supposed to be immune to. tuish_str_window is the only column-correct slicer
		# (it also refuses to split a CSI run, and drops rather than halves a wide char
		# that would straddle the right edge), so everything goes through it.
		#
		# CSI is the only escape form it knows to skip. Text carrying an OSC or SS3 has
		# those bytes counted as columns and can be cut mid-sequence — unchanged from
		# before (the old plain path measured them as columns too), and still wrong.
		# Fixing it means teaching tuish_str_window the other escape forms.
		local _tt_off=0
		if test $_tt_col -lt 1
		then _tt_off=$((1 - _tt_col)); _tt_col=1; fi
		# _tuish_clip_avail reports the columns that EXIST; whether text honours
		# them is this caller's policy, and _tuish_wrap=1 means it does not.
		local _tt_win=$_TUISH_NOCLIP
		if test $_tuish_wrap -eq 0
		then _tuish_clip_avail $_tt_col; _tt_win=$_tuish_avail; fi
		# maxwidth and width both count from the string's OWN start, so a
		# left-scrolled field clips to the same cells either way.
		if test $_tt_maxw -ge 0
		then
			local _tt_mw=$(( _tt_maxw - _tt_off ))
			test $_tt_mw -lt $_tt_win && _tt_win=$_tt_mw
		fi
		if test $_tt_fw -ge 0
		then
			local _tt_fwa=$(( _tt_fw - _tt_off ))
			test $_tt_fwa -lt $_tt_win && _tt_win=$_tt_fwa
		fi
		test $_tt_win -lt 1 && return 0

		# Does it need slicing at all? Text that starts at the left edge, fits the
		# window, and is not being padded into a field comes out verbatim — no slice,
		# no copy. That is not only the cheap case, it is the PORTABLE one:
		# tuish_str_window indexes with ${var:off:len}, which every shell this toolkit
		# targets has but plain POSIX sh does not (REPORT.md X2). Keeping the
		# fits-as-is case off that path is what lets the primitives degrade gracefully
		# on a shell that only ever needed to place and print.
		#
		# Only safe to decide with tuish_str_width when the text carries no CSI, whose
		# bytes it would miscount as visible columns.
		local _tt_esc_in=0
		case "$_tt_text" in *"${_tuish_chr_27}["*) _tt_esc_in=1;; esac
		local _tt_slice=1
		if test $_tt_esc_in -eq 0 && test $_tt_off -eq 0 && test $_tt_fw -lt 0
		then
			tuish_str_width _tt_text
			test $TUISH_SWIDTH -le $_tt_win && _tt_slice=0
		fi

		if test $_tt_slice -eq 1
		then
			tuish_str_window _tt_text $_tt_off $_tt_win
			_tt_text=$TUISH_SWINDOW
			# Force a trailing reset when the text carried SGR of its own: a colour
			# run's own reset may have been past the right cut.
			_tt_esc=$_tt_esc_in

			# width=N: pad the slice out to the field. This is the whole reason the
			# option exists. What an app writes without it is erase-then-print — a
			# tuish_clear_to_edge (or a draw_fill) over the field, then the text on top
			# — which touches every cell TWICE per frame with a blank state in between.
			# One write, no blank state, and the padding carries bg= like the text
			# does, so a coloured field needs no separate fill underneath it.
			if test $_tt_fw -ge 0 && test $TUISH_SWINDOW_W -lt $_tt_win
			then
				_tuish_repeat ' ' $(( _tt_win - TUISH_SWINDOW_W ))
				_tt_text="${_tt_text}${_tuish_rep}"
			fi
		fi

		test -z "$_tt_text" && return 0
	fi

	if tuish_vmove $_tt_row $_tt_col
	then
		test "$_tt_fg" != -1 && { _tuish_color_params fg "$_tt_fg"; tuish_sgr "$_tuish_cparams"; }
		test "$_tt_bg" != -1 && { _tuish_color_params bg "$_tt_bg"; tuish_sgr "$_tuish_cparams"; }
		tuish_print "$_tt_text"
	fi
	if test "$_tt_fg" != -1 || test "$_tt_bg" != -1 || test $_tt_esc -eq 1
	then tuish_sgr_reset; fi
}
tuish_print_at ()       { tuish_text "$1" "$2" "$3"; }
# Place TEXT at (ROW,COL) with NO display-width computation — position (clipping
# off-screen cells via tuish_vmove) then print. tuish_print_at/tuish_text run
# tuish_str_width to width-clip against the viewport edge, which on the shell-WASM
# target is a real per-call cost; when the caller already KNOWS the text fits its
# cell (a fixed-size sprite/glyph, a pre-clipped slice), tuish_put_at skips that
# entirely. Contract: caller guarantees TEXT fits — no right-edge trimming. Text
# is still escaped by tuish_print, so any embedded *_seq sequences pass through.
tuish_put_at ()         { if tuish_vmove "$1" "$2"; then tuish_print "$3"; fi; }
# Raw-write analog of tuish_print_at: position then emit TEXT verbatim, skipping
# the write (and emitting nothing) when the cell is clipped off-screen. Lets the
# draw primitives share one clip-guarded write instead of hand-copying the
# `if tuish_vmove …; then _tuish_write …; fi` idiom at each single-write site.
_tuish_write_at ()      { if tuish_vmove "$1" "$2"; then _tuish_write "$3"; fi; }
# The raw erase primitives. ESC[2K / ESC[K / ESC[1K / ESC[2J act on the PHYSICAL
# terminal line or screen, so they ignore the viewport and — crucially — a hosted
# region: from inside a child context they punch straight through into the host's
# chrome (clear_to_eol eats whatever is to the region's right, clear_to_bol
# whatever is to its left). Code that may ever run hosted must use
# tuish_clear_to_edge / tuish_clear_region instead. These stay for root-owned,
# full-width apps, where they are the cheapest possible erase (one escape, no
# repeat string).
tuish_clear_line ()     { _tuish_write '\033[2K'; }
tuish_clear_to_eol ()   { _tuish_write '\033[K'; }
tuish_clear_screen ()   { _tuish_write '\033[2J'; }
tuish_cursor ()
{
	_tuish_cursor_vrow=0
	_tuish_cursor_vcol=0
	if tuish_vmove "$1" "$2"
	then
		_tuish_cursor_vrow=$1
		_tuish_cursor_vcol=$2
		# The shape goes out WITH the caret, and inside the clip test: a caret placed
		# outside its region shows nothing, so it should leave no shape behind either.
		#
		# ...but only when the device does not already have it. The saving is not the five
		# bytes; it is that re-sending DECSCUSR re-arms a real terminal's blink phase every
		# frame, and re-fires xterm.js's option change over the page's own settings. The
		# cache is what the DEVICE was last told — and event.sh forgets it wherever it
		# throws frame content away, so it can never claim bytes that never landed.
		if test -n "$_tuish_cursor_shape" \
		   && test "$_tuish_cursor_shape" != "$_tuish_cursor_shape_dev"
		then
			_tuish_write "\033[${_tuish_cursor_shape} q"
			_tuish_cursor_shape_dev=$_tuish_cursor_shape
			_tuish_cursor_shape_set=1
		fi
		tuish_show_cursor
	fi
}
tuish_scroll_region ()  { _tuish_write "\033[${1};${2}r"; }
tuish_sgr ()            { _tuish_write "\033[${1}m"; }
tuish_sgr_reset ()      { _tuish_write '\033[0m'; }
tuish_altscreen_on ()   { _tuish_write '\033[?1049h'; }
tuish_altscreen_off ()  { _tuish_write '\033[?1049l'; }
tuish_scroll_up ()      { _tuish_write '\033[S'; }
tuish_scroll_down ()    { _tuish_write '\033[T'; }
tuish_scroll_up_n ()    { _tuish_write "\033[${1}S"; }
tuish_scroll_down_n ()  { _tuish_write "\033[${1}T"; }
tuish_newline ()        { _tuish_write '\n\r'; }
tuish_clear_to_bol ()   { _tuish_write '\033[1K'; }

# Text attributes
tuish_bold ()           { _tuish_write '\033[1m'; }
tuish_dim ()            { _tuish_write '\033[2m'; }
tuish_italic ()         { _tuish_write '\033[3m'; }
tuish_underline ()      { _tuish_write '\033[4m'; }
tuish_blink ()          { _tuish_write '\033[5m'; }
tuish_reverse ()        { _tuish_write '\033[7m'; }
tuish_strikethrough ()  { _tuish_write '\033[9m'; }

# Colors — one parser, two smart entry points. _tuish_color_params ROLE VALUE
# sets _tuish_cparams to the SGR parameter fragment (no leading ';' or 'm').
# ROLE is fg or bg. VALUE: '' (none), 0-7 basic, 8-15 bright, 16-255 palette,
# R:G:B truecolor, or 'default' (reset just this role). Shared by tuish_fg/bg,
# tuish_style, and draw.sh so the color grammar lives in exactly one place.
_tuish_color_params ()
{
	case "$2" in
		'')
			_tuish_cparams='';;
		default)
			if test "$1" = fg; then _tuish_cparams=39; else _tuish_cparams=49; fi;;
		*:*:*)
			local _cp_t="${2#*:}"
			if test "$1" = fg
			then _tuish_cparams="38;2;${2%%:*};${_cp_t%%:*};${_cp_t#*:}"
			else _tuish_cparams="48;2;${2%%:*};${_cp_t%%:*};${_cp_t#*:}"
			fi;;
		*)
			if test "$1" = fg
			then
				if test "$2" -lt 8;    then _tuish_cparams="3$2"
				elif test "$2" -lt 16; then _tuish_cparams="9$(($2 - 8))"
				else _tuish_cparams="38;5;$2"
				fi
			else
				if test "$2" -lt 8;    then _tuish_cparams="4$2"
				elif test "$2" -lt 16; then _tuish_cparams="10$(($2 - 8))"
				else _tuish_cparams="48;5;$2"
				fi
			fi;;
	esac
}
tuish_fg ()             { _tuish_color_params fg "$1"; _tuish_write "\033[${_tuish_cparams}m"; }
tuish_bg ()             { _tuish_color_params bg "$1"; _tuish_write "\033[${_tuish_cparams}m"; }

# Combined style: tuish_style [bold] [dim] [italic] [underline] [reverse] [fg=N] [bg=N]
# Emits a single SGR reset + combined sequence. Color accepts 0-7 (basic),
# 8-15 (bright), 16-255 (256-palette), or R:G:B (truecolor).
# Thin writer over tuish_style_seq (below) so the attribute grammar lives in
# exactly one place; the raw-ESC TUISH_SEQ passes through _tuish_write's
# printf/echo -ne unchanged (same as tuish_save_cursor's raw ESC in tui.sh).
tuish_style ()          { tuish_style_seq "$@"; _tuish_write "$TUISH_SEQ"; }

# ─── Sequence builders (batched, one-write rendering) ────────────
# These build an SGR escape INTO the variable TUISH_SEQ instead of writing it.
# A caller can then assemble a whole row (or segment) as ONE string —
# `row="${row}${TUISH_SEQ}${glyph}"` — and emit it with a single tuish_print,
# spending a *_seq call only when the colour/style CHANGES rather than one
# tuish_fg/tuish_sgr call per cell. On the shell-WASM target (and any slow
# interpreter) the per-frame function-call count is the dominant render cost,
# so this is 3-4x faster for dense output than the per-cell writers.
#
# CRUCIAL: the sequence is built from the LITERAL ESC byte (_tuish_chr_27,
# populated at ord.sh source time), NOT the string '\033'. A raw-ESC sequence
# contains no backslash and no '%', so it survives BOTH tuish_print's
# backslash/percent doubling (see tuish_print) AND _tuish_out's printf/echo
# verbatim — which is what lets it be embedded inside a row string that also
# carries arbitrary %/backslash-bearing text (e.g. an editor line). Building it
# with '\033' would get double-escaped and render literally. Same rationale as
# tuish_save_cursor's raw-ESC use (tui.sh). Colour grammar stays single-sourced
# in _tuish_color_params; the hot per-cell writers (tuish_fg/tuish_sgr/...)
# keep their direct one-call bodies, while tuish_style (above) — a cold,
# multi-arg convenience — delegates to tuish_style_seq to avoid duplicating
# the attribute grammar.
TUISH_SEQ=''
tuish_fg_seq ()         { _tuish_color_params fg "$1"; TUISH_SEQ="${_tuish_chr_27}[${_tuish_cparams}m"; }
tuish_bg_seq ()         { _tuish_color_params bg "$1"; TUISH_SEQ="${_tuish_chr_27}[${_tuish_cparams}m"; }
tuish_sgr_seq ()        { TUISH_SEQ="${_tuish_chr_27}[${1}m"; }
tuish_sgr_reset_seq ()  { TUISH_SEQ="${_tuish_chr_27}[0m"; }
tuish_style_seq ()
{
	local _s_seq='0'
	local _s_fg='' _s_bg=''
	while test $# -gt 0; do
		case "$1" in
			bold)          _s_seq="${_s_seq};1";;
			dim)           _s_seq="${_s_seq};2";;
			italic)        _s_seq="${_s_seq};3";;
			underline)     _s_seq="${_s_seq};4";;
			blink)         _s_seq="${_s_seq};5";;
			reverse)       _s_seq="${_s_seq};7";;
			strikethrough) _s_seq="${_s_seq};9";;
			fg=*)          _s_fg="${1#*=}";;
			bg=*)          _s_bg="${1#*=}";;
		esac
		shift
	done
	if test -n "$_s_fg"; then _tuish_color_params fg "$_s_fg"; _s_seq="${_s_seq};${_tuish_cparams}"; fi
	if test -n "$_s_bg"; then _tuish_color_params bg "$_s_bg"; _s_seq="${_s_seq};${_tuish_cparams}"; fi
	TUISH_SEQ="${_tuish_chr_27}[${_s_seq}m"
}

# ─── The caret's shape ───────────────────────────────────────────
# DECSCUSR: 1=blink-block 2=block 3=blink-underline 4=underline 5=blink-bar 6=bar.
#
# It DECLARES; it does not write. The caret's position and visibility have always been
# re-declared every frame — event.sh hides the caret before each deferred render, and a
# render that wants one calls tuish_cursor, which places it and shows it again. The shape
# was the odd one out: a single escape, written once, at setup.
#
# Which works standalone, and is silently thrown away when hosted. A child is MOUNTED from
# inside the host's event handler, and the rAF path discards that handler's frame content
# when a deferred redraw supersedes it — so the editor's `ESC[6 q` died in a buffer that was
# never written, the render put the caret back without saying what it looked like, and the
# terminal kept what it had. A thin bar in your terminal, a fat block on the website, from
# the same line of code.
#
# So it is state, held per context, and it RIDES WITH THE CARET (see tuish_cursor). Being a
# variable, it survives the discard; being re-asserted every frame, it survives everything
# else. And the negotiation between children falls out for free: the one that shows the
# caret last decides its shape — and a host paints its FOCUSED child last, deliberately, for
# exactly this reason (tuish_host_paint).
#
# 0, or nothing, means NO OPINION: emit no DECSCUSR at all and inherit whatever the device
# has. It does NOT mean "send DECSCUSR 0" — that escape leaves this codebase from one place
# only, the device teardown in tuish_fini, where "put the terminal back" is what it means.
# (On xterm.js it does not even mean that: 0 is read as 1, a BLINKING BLOCK.)
#
# A widget that shows a caret and cares what it looks like declares a shape. One that does
# not, inherits — the same bargain the caret's position has always offered.
tuish_ctx_register _tuish_cursor_shape

tuish_cursor_shape ()   # [$1 = 1..6, or 0/nothing for no opinion]
{
	case "${1:-}" in
		[1-6]) _tuish_cursor_shape=$1;;
		*)     _tuish_cursor_shape='';;
	esac
	return 0
}

# Relative cursor movement (default: 1 cell)
tuish_move_up ()        { _tuish_write "\033[${1:-1}A"; }
tuish_move_down ()      { _tuish_write "\033[${1:-1}B"; }
tuish_move_right ()     { _tuish_write "\033[${1:-1}C"; }
tuish_move_left ()      { _tuish_write "\033[${1:-1}D"; }

# tuish_clear_to_edge ROW [COL]
# Erase logical ROW from COL (default 1) rightward to the edge of the DRAWABLE
# AREA — the viewport standalone, the region when hosted. This is the region-safe
# counterpart of tuish_clear_to_eol: ESC[K erases to the end of the physical line,
# which from inside a hosted region wipes the host's chrome to its right (it ate
# the editor box's right border in examples/cooperative.sh). Bounded by
# TUISH_VIEW_COLS, so it degrades to exactly the old behaviour standalone.
#
# It erases rather than trims, so callers CLEAR FIRST, THEN PRINT (the reverse of
# the print-then-ESC[K idiom): the erase needs no knowledge of what will be drawn,
# and an SGR set before the call (e.g. tuish_reverse) colours the padding.
tuish_clear_to_edge ()
{
	local _cte_c=${2:-1}
	# One call. This hand-rolled the same three bounds (TUISH_VIEW_COLS, a
	# TUISH_COLUMNS fallback for the no-viewport profile, and _tx_lcmax) in logical
	# units; _tuish_clip_avail now resolves all three in terminal columns, so this is
	# a straight delegation.
	_tuish_clip_avail "$_cte_c"
	# Nothing bounds us at all — no viewport AND no known screen width. Erase nothing:
	# an erase must never guess how wide the world is.
	test $_tuish_avail -ge $_TUISH_NOCLIP && return 0
	test $_tuish_avail -gt 0 && tuish_clear_region "$1" "$_cte_c" "$_tuish_avail" 1
	return 0
}

# tuish_clear_region ROW COL W H
# Clear a rectangular area by writing spaces. Transform-aware (goes through
# tuish_vmove), so it is clipped to the region when hosted.
tuish_clear_region ()
{
	local _cr_r=$1 _cr_c=$2 _cr_w=$3 _cr_h=$4 _cr_i=0
	# Clamp the width to the true visible window (every row shares _cr_c): an
	# unclamped clear erases past a hosted region's right edge into the host's chrome.
	# Unconditional — an erase does not honour _tuish_wrap. Autowrap would only mean
	# the overrun lands on the NEXT row instead of the screen edge; either way it is
	# outside the region, and there is nothing to "wrap" when the payload is blanks.
	_tuish_clip_avail $_cr_c
	test $_cr_w -gt $_tuish_avail && _cr_w=$_tuish_avail
	test $_cr_w -lt 1 && return 0
	# Row of _cr_w spaces via the shared base-module primitive (term.sh and
	# str.sh both build repeated strings but each depends only on tui.sh).
	_tuish_repeat ' ' "$_cr_w"
	local _cr_spaces=$_tuish_rep
	while test $_cr_i -lt $_cr_h; do
		if tuish_vmove $((_cr_r + _cr_i)) "$_cr_c"
		then _tuish_write "$_cr_spaces"
		fi
		_cr_i=$((_cr_i + 1))
	done
}
