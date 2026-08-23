# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Load guard: skip re-definition if already sourced (see tui.sh).
if test -n "${_tuish_str_loaded:-}"; then return 0; fi
_tuish_str_loaded=1
# src/str.sh - String utilities and Unicode width
# Optional module. Source after tui.sh.
#
# Provides:
#   tuish_str_len/left/right/char - character-level string ops (byte-mode UTF-8)
#   tuish_str_width              - display width (columns)
#   tuish_str_window             - visible slice of a horizontal column-window
#   tuish_str_pad                - fit to exactly N display columns
#   tuish_str_repeat             - O(log n) string repetition
#   _tuish_char_width()          - codepoint → display width
#   _tuish_byte_val/utf8_len/char_byte_off - UTF-8 internals
#
# Dependencies: _tuish_ord() (from src/ord.sh)
#
# Requires LC_ALL=C (set by compat.sh) for byte-oriented string indexing.

# ─── Decode memo (exact-match MRU) ───────────────────────────────
# Every function below opens with an ASCII fast path and falls back to a
# byte-by-byte UTF-8 decode. The gap between the two is not a constant factor:
# measured on this tree, tuish_str_width costs 16us on 64 ASCII columns and
# 4499us on a 60-column box rule (60x U+2500) — and ONE non-ASCII byte forfeits
# the fast path for the whole string, so a 20-column label with a single '┤' in
# it costs 498us. tuish_text runs a width on EVERY text draw (term.sh), and the
# default draw backend is unicode, so a UTF-8 app pays milliseconds per label
# before a byte reaches the terminal. That is the 266ms frame docs/event.md
# sizes TUISH_DEFER_MAX against.
#
# What makes it cacheable is that the expensive strings are the REPEATED ones:
# rules, borders, box chrome and fixed labels are redrawn verbatim every frame,
# while the content that genuinely differs row to row is usually prose, which
# takes the ASCII path anyway and is already 16us. So a handful of slots is
# enough — this is not a general cache, it is a guard against re-deriving the
# same chrome N times per frame and again next frame.
#
# The key is the EXACT string (tagged, and with the numeric arguments folded in
# where they change the answer), compared by `case` with the pattern quoted so
# it matches literally — a rule made of '*' or '?' must not glob onto a
# different entry. The value can therefore never be wrong: the only failure mode
# is a miss, which costs the comparisons and then runs the decoder that was
# going to run anyway.
#
# Only the SLOW paths consult it. An ASCII string never looks itself up and
# never evicts anything, so the fast path stays exactly as cheap as it was.
#
# Plain globals, and they have to be: the whole point is to outlive the call that
# filled them. That also keeps _tuish_memo_get/_put off compat.sh's
# _tuish_fnfix_skip — they declare nothing, and they take the key by VALUE rather
# than by variable name, so converting them to ksh-style scoping changes nothing.
# The functions that CONSULT the memo take a name and are on that list already.
_tuish_memo_k0='' _tuish_memo_k1='' _tuish_memo_k2='' _tuish_memo_k3=''
_tuish_memo_k4='' _tuish_memo_k5='' _tuish_memo_k6='' _tuish_memo_k7=''
_tuish_memo_v0='' _tuish_memo_v1='' _tuish_memo_v2='' _tuish_memo_v3=''
_tuish_memo_v4='' _tuish_memo_v5='' _tuish_memo_v6='' _tuish_memo_v7=''
_tuish_memo_val=''

# _tuish_memo_get KEY -> 0 and _tuish_memo_val on a hit, 1 on a miss.
# Slots start empty and every real key carries a non-empty tag, so an untouched
# slot cannot be hit by a lookup of the empty string.
_tuish_memo_get ()
{
	case "$1" in
	"$_tuish_memo_k0") _tuish_memo_val=$_tuish_memo_v0; return 0;;
	"$_tuish_memo_k1") _tuish_memo_val=$_tuish_memo_v1; return 0;;
	"$_tuish_memo_k2") _tuish_memo_val=$_tuish_memo_v2; return 0;;
	"$_tuish_memo_k3") _tuish_memo_val=$_tuish_memo_v3; return 0;;
	"$_tuish_memo_k4") _tuish_memo_val=$_tuish_memo_v4; return 0;;
	"$_tuish_memo_k5") _tuish_memo_val=$_tuish_memo_v5; return 0;;
	"$_tuish_memo_k6") _tuish_memo_val=$_tuish_memo_v6; return 0;;
	"$_tuish_memo_k7") _tuish_memo_val=$_tuish_memo_v7; return 0;;
	esac
	return 1
}

# _tuish_memo_put KEY VALUE — insert at the front, drop the oldest.
_tuish_memo_put ()
{
	_tuish_memo_k7=$_tuish_memo_k6; _tuish_memo_v7=$_tuish_memo_v6
	_tuish_memo_k6=$_tuish_memo_k5; _tuish_memo_v6=$_tuish_memo_v5
	_tuish_memo_k5=$_tuish_memo_k4; _tuish_memo_v5=$_tuish_memo_v4
	_tuish_memo_k4=$_tuish_memo_k3; _tuish_memo_v4=$_tuish_memo_v3
	_tuish_memo_k3=$_tuish_memo_k2; _tuish_memo_v3=$_tuish_memo_v2
	_tuish_memo_k2=$_tuish_memo_k1; _tuish_memo_v2=$_tuish_memo_v1
	_tuish_memo_k1=$_tuish_memo_k0; _tuish_memo_v1=$_tuish_memo_v0
	_tuish_memo_k0=$1;              _tuish_memo_v0=$2
}

# ─── String utilities (byte-mode UTF-8 decoding) ─────────────────
# All take a variable NAME to avoid subshell overhead.
# Results in TUISH_SLEN, TUISH_SLEFT, TUISH_SRIGHT, TUISH_SCHAR.

tuish_str_len ()
{
	eval "local _tuish_sl_str=\"\${$1}\""
	# Fast path: printable ASCII → byte count = char count
	case "$_tuish_sl_str" in *[![:print:]]*)
		local _tuish_sl_i=0 _tuish_sl_n=0
		while _tuish_byte_val "$1" $_tuish_sl_i
		do
			_tuish_utf8_len $_tuish_bval
			_tuish_sl_i=$((_tuish_sl_i + _tuish_cbytes))
			_tuish_sl_n=$((_tuish_sl_n + 1))
		done
		TUISH_SLEN=$_tuish_sl_n
		return;;
	esac
	TUISH_SLEN=${#_tuish_sl_str}
}

tuish_str_left ()
{
	# Fast path: if first $2 bytes are printable ASCII, byte off = char off
	eval "local _tuish_sl_v=\"\${$1:0:$2}\""
	case "$_tuish_sl_v" in *[![:print:]]*)
		_tuish_char_byte_off "$1" "$2"
		eval "_tuish_sl_v=\"\${$1:0:$_tuish_boff}\"";;
	esac
	TUISH_SLEFT=$_tuish_sl_v
}

tuish_str_right ()
{
	# Fast path: if first $2 bytes are printable ASCII, byte off = char off
	eval "local _tuish_sr_pre=\"\${$1:0:$2}\""
	case "$_tuish_sr_pre" in *[![:print:]]*)
		_tuish_char_byte_off "$1" "$2"
		eval "TUISH_SRIGHT=\"\${$1:$_tuish_boff}\""
		return;;
	esac
	eval "TUISH_SRIGHT=\"\${$1:$2}\""
}

tuish_str_char ()
{
	# Fast path: if first $2+1 bytes are printable ASCII, byte off = char off
	eval "local _tuish_sc_pre=\"\${$1:0:$(($2 + 1))}\""
	case "$_tuish_sc_pre" in *[![:print:]]*)
		_tuish_char_byte_off "$1" "$2"
		_tuish_byte_val "$1" $_tuish_boff || { TUISH_SCHAR=''; return; }
		_tuish_utf8_len $_tuish_bval
		eval "TUISH_SCHAR=\"\${$1:$_tuish_boff:$_tuish_cbytes}\""
		return;;
	esac
	eval "TUISH_SCHAR=\"\${$1:$2:1}\""
}

# Repeat string $1 exactly $2 times. O(log n) via doubling.
# Result in TUISH_SREPEATED.
tuish_str_repeat ()
{
	_tuish_repeat "$1" "$2"
	TUISH_SREPEATED=$_tuish_rep
}

# tuish_str_pad VAR WIDTH -> TUISH_SPADDED
# VAR's value fitted to exactly WIDTH display COLUMNS: space-padded when it is
# narrower, sliced when it is wider.
#
# The string counterpart of `tuish_text ... width=N` (term.md). Use that one when the
# field is the whole write; use this one when the row is assembled from several pieces
# and printed as a unit, which is the case that was hand-rolling a pad loop.
#
# Columns, not characters — it goes through tuish_str_window, so it counts a CJK
# ideograph as the two columns it occupies, skips SGR runs rather than counting their
# bytes, and drops (never splits) a wide glyph that would straddle the cut. That last
# case leaves the slice a column short of WIDTH, which the pad then makes up, so the
# result is WIDTH columns either way.
tuish_str_pad ()
{
	tuish_str_window "$1" 0 "$2"
	TUISH_SPADDED=$TUISH_SWINDOW
	if test $TUISH_SWINDOW_W -lt $2
	then
		_tuish_repeat ' ' $(( $2 - TUISH_SWINDOW_W ))
		TUISH_SPADDED="${TUISH_SPADDED}${_tuish_rep}"
	fi
}

# ─── Text width (display columns) ────────────────────────────────
# UTF-8 decode → codepoint → width classification.
# Result in TUISH_SWIDTH. Takes a variable NAME.

tuish_str_width ()
{
	eval "local _tuish_sw_str=\"\${$1}\""
	local _tuish_sw_len=${#_tuish_sw_str}
	# Fast path: under LC_ALL=C, [:print:] is exactly 0x20-0x7E.
	# All printable ASCII chars have width 1, so width = byte count.
	case "$_tuish_sw_str" in *[![:print:]]*) ;; *) TUISH_SWIDTH=$_tuish_sw_len; return;; esac
	if _tuish_memo_get "w $_tuish_sw_str"
	then TUISH_SWIDTH=$_tuish_memo_val; return; fi
	# Slow path: decode UTF-8 inline over the local value. Working on the
	# value (not a variable name) lets us read bytes with direct
	# ${_tuish_sw_str:i:1} substrings, avoiding per-byte eval/indirection — the
	# reason the decode is inlined here (and in tuish_str_window) rather than
	# factored into a shared helper, which would need a per-char eval or string
	# copy. _tuish_ord returns unsigned 1-255 (ord.sh), so no signed correction.
	local _tuish_sw_i=0 _tuish_sw_b0 _tuish_sw_b1 _tuish_sw_b2 _tuish_sw_cp _tuish_sw_w=0
	while test $_tuish_sw_i -lt $_tuish_sw_len
	do
		_tuish_ord "${_tuish_sw_str:$_tuish_sw_i:1}"
		_tuish_sw_b0=$_tuish_code
		# The continuation-byte count a lead implies is only read when those
		# bytes are actually present (the `&& test i+n -lt _tuish_sw_len` guards).
		# A lead whose continuations run past the end — a string sliced mid
		# sequence — falls through to the final branch and is counted as one
		# width-1 cell, so the scan can never read past _tuish_sw_len.
		if test $_tuish_sw_b0 -lt 128
		then
			_tuish_sw_cp=$_tuish_sw_b0
			_tuish_sw_i=$((_tuish_sw_i + 1))
		elif test $_tuish_sw_b0 -lt 224 && test $((_tuish_sw_i + 1)) -lt $_tuish_sw_len
		then
			_tuish_cont6 "${_tuish_sw_str:$((_tuish_sw_i + 1)):1}"; _tuish_sw_b1=$_tuish_c6
			_tuish_sw_cp=$(( (_tuish_sw_b0 & 31) * 64 + _tuish_sw_b1 ))
			_tuish_sw_i=$((_tuish_sw_i + 2))
		elif test $_tuish_sw_b0 -lt 240 && test $((_tuish_sw_i + 2)) -lt $_tuish_sw_len
		then
			_tuish_cont6 "${_tuish_sw_str:$((_tuish_sw_i + 1)):1}"; _tuish_sw_b1=$_tuish_c6
			_tuish_cont6 "${_tuish_sw_str:$((_tuish_sw_i + 2)):1}"; _tuish_sw_b2=$_tuish_c6
			_tuish_sw_cp=$(( (_tuish_sw_b0 & 15) * 4096 + _tuish_sw_b1 * 64 + _tuish_sw_b2 ))
			_tuish_sw_i=$((_tuish_sw_i + 3))
		elif test $_tuish_sw_b0 -lt 248 && test $((_tuish_sw_i + 3)) -lt $_tuish_sw_len
		then
			_tuish_cont6 "${_tuish_sw_str:$((_tuish_sw_i + 1)):1}"; _tuish_sw_b1=$_tuish_c6
			_tuish_cont6 "${_tuish_sw_str:$((_tuish_sw_i + 2)):1}"; _tuish_sw_b2=$_tuish_c6
			_tuish_cont6 "${_tuish_sw_str:$((_tuish_sw_i + 3)):1}"
			_tuish_sw_cp=$(( (_tuish_sw_b0 & 7) * 262144 + _tuish_sw_b1 * 4096 + _tuish_sw_b2 * 64 + _tuish_c6 ))
			_tuish_sw_i=$((_tuish_sw_i + 4))
		else
			# Stray continuation byte, invalid lead (0xF8-0xFF), or a lead
			# whose continuations are truncated: count one cell, advance one.
			_tuish_sw_cp=$_tuish_sw_b0
			_tuish_sw_i=$((_tuish_sw_i + 1))
		fi
		_tuish_char_width $_tuish_sw_cp
		_tuish_sw_w=$((_tuish_sw_w + _tuish_cw))
	done
	TUISH_SWIDTH=$_tuish_sw_w
	_tuish_memo_put "w $_tuish_sw_str" "$_tuish_sw_w"
}

# ─── Horizontal window (display columns) ─────────────────────────
# tuish_str_window VAR OFFSET WIDTH -> TUISH_SWINDOW, TUISH_SWINDOW_W
#
# TUISH_SWINDOW_W is the display width of the slice, which is <= WIDTH and not
# recoverable by measuring the result: the slice may carry SGR runs (zero columns,
# arbitrary bytes) and a wide char that would have crossed the right edge is dropped
# rather than split, leaving the slice a column short. A caller padding the slice out
# to a field needs the number the slicer already knows.
#
# The slice of VAR visible in a horizontal window OFFSET columns from the left,
# WIDTH columns wide — i.e. the characters occupying display columns
# [OFFSET, OFFSET+WIDTH). Width-aware: a wide (2-col) char whose left half is
# scrolled off the left edge renders as a single space for its visible right
# half; a wide char that would cross the right edge is dropped (the result is
# then < WIDTH columns — the caller pads, e.g. tuish_clear_to_eol). Zero-width
# combining marks follow their visible base. Returns content only (no padding).
tuish_str_window ()
{
	eval "local _tuish_wn_str=\"\${$1}\""
	local _tuish_wn_off=$2 _tuish_wn_w=$3
	local _tuish_wn_end=$((_tuish_wn_off + _tuish_wn_w))
	local _tuish_wn_len=${#_tuish_wn_str}
	# Fast path: all printable ASCII → every char is width 1, so display column
	# == byte offset and the window is a plain substring.
	case "$_tuish_wn_str" in *[![:print:]]*) ;; *)
		TUISH_SWINDOW=''
		test "$_tuish_wn_off" -lt "$_tuish_wn_len" && TUISH_SWINDOW="${_tuish_wn_str:$_tuish_wn_off:$_tuish_wn_w}"
		# Every char is one column here, so the byte count IS the width.
		TUISH_SWINDOW_W=${#TUISH_SWINDOW}
		return 0;;
	esac
	# Both the offset and the width change the answer, so both are in the key. The
	# entry holds "<width> <slice>" — the width is not derivable from the slice (see
	# the header), so caching the slice alone would lose it.
	if _tuish_memo_get "n$2,$3 $_tuish_wn_str"
	then
		TUISH_SWINDOW_W=${_tuish_memo_val%% *}
		TUISH_SWINDOW=${_tuish_memo_val#* }
		return 0
	fi
	# Slow path: decode UTF-8 (mirrors tuish_str_width), tracking the running
	# display column _tuish_wn_col (the start column of the current char).
	local _tuish_wn_i=0 _tuish_wn_col=0 _tuish_wn_b0 _tuish_wn_b1 _tuish_wn_b2 _tuish_wn_cp _tuish_wn_n _tuish_wn_ch _tuish_wn_j _tuish_wn_out='' _tuish_wn_ow=0
	while test $_tuish_wn_i -lt $_tuish_wn_len
	do
		_tuish_ord "${_tuish_wn_str:$_tuish_wn_i:1}"; _tuish_wn_b0=$_tuish_code
		# CSI/SGR escape: ESC '[' … final byte (0x40-0x7E). Emit verbatim at ZERO
		# width and never split, so a colour run keeps correct state even when the run
		# that set it is scrolled off the left. (A trailing reset that falls past the
		# right edge is re-asserted by tuish_text's dangling-reset guard.)
		if test $_tuish_wn_b0 -eq 27 && test "${_tuish_wn_str:$((_tuish_wn_i + 1)):1}" = '['
		then
			_tuish_wn_j=$((_tuish_wn_i + 2))
			while test $_tuish_wn_j -lt $_tuish_wn_len
			do
				_tuish_ord "${_tuish_wn_str:$_tuish_wn_j:1}"
				_tuish_wn_j=$((_tuish_wn_j + 1))
				test $_tuish_code -ge 64 && test $_tuish_code -le 126 && break
			done
			_tuish_wn_out="${_tuish_wn_out}${_tuish_wn_str:$_tuish_wn_i:$((_tuish_wn_j - _tuish_wn_i))}"
			_tuish_wn_i=$_tuish_wn_j
			continue
		fi
		if test $_tuish_wn_b0 -lt 128
		then _tuish_wn_n=1; _tuish_wn_cp=$_tuish_wn_b0
		elif test $_tuish_wn_b0 -lt 224 && test $((_tuish_wn_i + 1)) -lt $_tuish_wn_len
		then _tuish_cont6 "${_tuish_wn_str:$((_tuish_wn_i + 1)):1}"; _tuish_wn_b1=$_tuish_c6
		     _tuish_wn_n=2; _tuish_wn_cp=$(( (_tuish_wn_b0 & 31) * 64 + _tuish_wn_b1 ))
		elif test $_tuish_wn_b0 -lt 240 && test $((_tuish_wn_i + 2)) -lt $_tuish_wn_len
		then _tuish_cont6 "${_tuish_wn_str:$((_tuish_wn_i + 1)):1}"; _tuish_wn_b1=$_tuish_c6
		     _tuish_cont6 "${_tuish_wn_str:$((_tuish_wn_i + 2)):1}"; _tuish_wn_b2=$_tuish_c6
		     _tuish_wn_n=3; _tuish_wn_cp=$(( (_tuish_wn_b0 & 15) * 4096 + _tuish_wn_b1 * 64 + _tuish_wn_b2 ))
		elif test $_tuish_wn_b0 -lt 248 && test $((_tuish_wn_i + 3)) -lt $_tuish_wn_len
		then _tuish_cont6 "${_tuish_wn_str:$((_tuish_wn_i + 1)):1}"; _tuish_wn_b1=$_tuish_c6
		     _tuish_cont6 "${_tuish_wn_str:$((_tuish_wn_i + 2)):1}"; _tuish_wn_b2=$_tuish_c6
		     _tuish_cont6 "${_tuish_wn_str:$((_tuish_wn_i + 3)):1}"
		     _tuish_wn_n=4; _tuish_wn_cp=$(( (_tuish_wn_b0 & 7) * 262144 + _tuish_wn_b1 * 4096 + _tuish_wn_b2 * 64 + _tuish_c6 ))
		else _tuish_wn_n=1; _tuish_wn_cp=$_tuish_wn_b0
		fi
		_tuish_char_width $_tuish_wn_cp
		_tuish_wn_ch="${_tuish_wn_str:$_tuish_wn_i:$_tuish_wn_n}"
		if test "$_tuish_cw" -eq 0
		then
			# combining mark: keep it iff attached to a visible base
			if test $_tuish_wn_col -gt $_tuish_wn_off && test $_tuish_wn_col -le $_tuish_wn_end
			then _tuish_wn_out="${_tuish_wn_out}${_tuish_wn_ch}"; fi
		elif test $((_tuish_wn_col + _tuish_cw)) -le $_tuish_wn_off
		then :                                   # entirely left of the window
		elif test $_tuish_wn_col -ge $_tuish_wn_end
		then break                               # entirely right (and all after)
		elif test $_tuish_wn_col -lt $_tuish_wn_off
		then _tuish_wn_out="${_tuish_wn_out} "; _tuish_wn_ow=$((_tuish_wn_ow + 1))  # left straddle: visible right half
		elif test $((_tuish_wn_col + _tuish_cw)) -gt $_tuish_wn_end
		then break                               # right straddle: does not fit, drop
		else _tuish_wn_out="${_tuish_wn_out}${_tuish_wn_ch}"   # fully inside
		     _tuish_wn_ow=$((_tuish_wn_ow + _tuish_cw))
		fi
		_tuish_wn_col=$((_tuish_wn_col + _tuish_cw))
		_tuish_wn_i=$((_tuish_wn_i + _tuish_wn_n))
	done
	TUISH_SWINDOW=$_tuish_wn_out
	TUISH_SWINDOW_W=$_tuish_wn_ow
	_tuish_memo_put "n$2,$3 $_tuish_wn_str" "$_tuish_wn_ow $_tuish_wn_out"
}

# ─── Codepoint width classification ──────────────────────────────
# $1 = codepoint (decimal). Sets _tuish_cw.
# 0 for combining/control, 2 for wide/fullwidth, 1 otherwise.

_tuish_char_width ()
{
	if test $1 -lt 32
	then
		_tuish_cw=0
	elif test $1 -lt 127
	then
		_tuish_cw=1
	elif test $1 -lt 160
	then
		_tuish_cw=0
	elif test $1 -lt 768
	then
		_tuish_cw=1
	elif test $1 -lt 880
	then
		# Combining Diacritical Marks (U+0300-U+036F)
		_tuish_cw=0
	elif test $1 -lt 4352
	then
		_tuish_cw=1
	elif test $1 -lt 4448
	then
		# Hangul Jamo leading consonants (U+1100-U+115F)
		_tuish_cw=2
	elif test $1 -lt 4608
	then
		# Hangul Jamo medial vowels & final consonants
		# (U+1160-U+11FF) are conjoining — zero width.
		_tuish_cw=0
	elif test $1 -lt 8203
	then
		# Check specific zero-width and combining ranges
		if test $1 -ge 6832 && test $1 -le 6911
		then
			_tuish_cw=0  # Combining Diacritical Marks Extended (U+1AB0-U+1AFF)
		elif test $1 -ge 7616 && test $1 -le 7679
		then
			_tuish_cw=0  # Combining Diacritical Marks Supplement (U+1DC0-U+1DFF)
		else
			# U+20D0-U+20FF (Combining marks for symbols) is > 8203,
			# so it cannot occur here — handled in the < 8986 branch.
			_tuish_cw=1
		fi
		return
	elif test $1 -le 8207
	then
		_tuish_cw=0  # Zero-width space, ZWNJ, ZWJ, LRM, RLM
	elif test $1 -lt 8986
	then
		if test $1 -ge 8400 && test $1 -le 8447
		then
			_tuish_cw=0  # Combining marks for symbols
		else
			_tuish_cw=1
		fi
	elif test $1 -le 8987
	then
		_tuish_cw=2  # ⌚⌛ (U+231A-U+231B)
	elif test $1 -lt 11904
	then
		# Emoji-presentation characters (terminals render width 2)
		if test $1 -ge 9725 && test $1 -le 9726
		then
			_tuish_cw=2  # ◽◾ (U+25FD-U+25FE)
		elif test $1 -ge 9748 && test $1 -le 9749
		then
			_tuish_cw=2  # ☔☕ (U+2614-U+2615)
		elif test $1 -ge 9800 && test $1 -le 9811
		then
			_tuish_cw=2  # ♈-♓ zodiac (U+2648-U+2653)
		elif test $1 -eq 9855
		then
			_tuish_cw=2  # ♿ (U+267F)
		elif test $1 -eq 9875
		then
			_tuish_cw=2  # ⚓ (U+2693)
		elif test $1 -eq 9889
		then
			_tuish_cw=2  # ⚡ (U+26A1)
		elif test $1 -ge 9898 && test $1 -le 9899
		then
			_tuish_cw=2  # ⚪⚫ (U+26AA-U+26AB)
		elif test $1 -ge 9917 && test $1 -le 9918
		then
			_tuish_cw=2  # ⚽⚾ (U+26BD-U+26BE)
		elif test $1 -ge 9924 && test $1 -le 9925
		then
			_tuish_cw=2  # ⛄⛅ (U+26C4-U+26C5)
		elif test $1 -eq 9934
		then
			_tuish_cw=2  # ⛎ (U+26CE)
		elif test $1 -eq 9940
		then
			_tuish_cw=2  # ⛔ (U+26D4)
		elif test $1 -eq 9962
		then
			_tuish_cw=2  # ⛪ (U+26EA)
		elif test $1 -ge 9970 && test $1 -le 9971
		then
			_tuish_cw=2  # ⛲⛳ (U+26F2-U+26F3)
		elif test $1 -eq 9973
		then
			_tuish_cw=2  # ⛵ (U+26F5)
		elif test $1 -eq 9978
		then
			_tuish_cw=2  # ⛺ (U+26FA)
		elif test $1 -eq 9981
		then
			_tuish_cw=2  # ⛽ (U+26FD)
		elif test $1 -eq 10024
		then
			_tuish_cw=2  # ✨ (U+2728)
		elif test $1 -ge 10060 && test $1 -le 10062
		then
			_tuish_cw=2  # ❌❍❎ (U+274C-U+274E)
		elif test $1 -ge 10067 && test $1 -le 10069
		then
			_tuish_cw=2  # ❓❔❕ (U+2753-U+2755)
		elif test $1 -eq 10071
		then
			_tuish_cw=2  # ❗ (U+2757)
		elif test $1 -ge 10133 && test $1 -le 10135
		then
			_tuish_cw=2  # ➕➖➗ (U+2795-U+2797)
		elif test $1 -eq 10145
		then
			_tuish_cw=2  # ➡ (U+27A1)
		elif test $1 -eq 10160
		then
			_tuish_cw=2  # ➰ (U+27B0)
		elif test $1 -eq 10175
		then
			_tuish_cw=2  # ➿ (U+27BF)
		elif test $1 -ge 11035 && test $1 -le 11036
		then
			_tuish_cw=2  # ⬛⬜ (U+2B1B-U+2B1C)
		elif test $1 -eq 11088
		then
			_tuish_cw=2  # ⭐ (U+2B50)
		elif test $1 -eq 11093
		then
			_tuish_cw=2  # ⭕ (U+2B55)
		else
			# U+20D0-U+20FF (Combining marks for symbols) is < 8988,
			# so it cannot occur here — handled in the < 8986 branch.
			_tuish_cw=1
		fi
	elif test $1 -lt 12352
	then
		# CJK Radicals, Kangxi, Ideographic, Bopomofo, etc.
		_tuish_cw=2
	elif test $1 -lt 12448
	then
		# Hiragana (U+3040-U+309F)
		_tuish_cw=2
	elif test $1 -lt 12544
	then
		# Katakana (U+30A0-U+30FF)
		_tuish_cw=2
	elif test $1 -lt 12592
	then
		_tuish_cw=2  # Bopomofo Extended, CJK Strokes
	elif test $1 -lt 12688
	then
		# Hangul Compatibility Jamo
		_tuish_cw=2
	elif test $1 -lt 12784
	then
		# Kanbun, CJK Strokes
		_tuish_cw=2
	elif test $1 -lt 12800
	then
		# Katakana Phonetic Ext
		_tuish_cw=2
	elif test $1 -lt 19904
	then
		# Enclosed CJK, CJK Compat, CJK Ext A, Yijing
		_tuish_cw=2
	elif test $1 -lt 19968
	then
		_tuish_cw=1
	elif test $1 -lt 40960
	then
		# CJK Unified Ideographs (U+4E00-U+9FFF)
		_tuish_cw=2
	elif test $1 -lt 44032
	then
		# Yi, Lisu, Vai (mostly single)
		_tuish_cw=1
	elif test $1 -lt 55216
	then
		# Hangul Syllables (U+AC00-U+D7AF)
		_tuish_cw=2
	elif test $1 -lt 63744
	then
		_tuish_cw=1
	elif test $1 -lt 64256
	then
		# CJK Compatibility Ideographs (U+F900-U+FAFF)
		_tuish_cw=2
	elif test $1 -lt 65024
	then
		_tuish_cw=1
	elif test $1 -lt 65040
	then
		# Variation Selectors (U+FE00-U+FE0F)
		_tuish_cw=0
	elif test $1 -lt 65072
	then
		_tuish_cw=1
	elif test $1 -lt 65136
	then
		# CJK Compatibility Forms, Small Form Variants (U+FE30-U+FE6F)
		_tuish_cw=2
	elif test $1 -lt 65281
	then
		_tuish_cw=1
	elif test $1 -lt 65377
	then
		# Fullwidth Latin (U+FF01-U+FF60)
		_tuish_cw=2
	elif test $1 -lt 65504
	then
		# Halfwidth forms (U+FF61-U+FFDF)
		_tuish_cw=1
	elif test $1 -lt 65511
	then
		# Fullwidth signs (U+FFE0-U+FFE6)
		_tuish_cw=2
	elif test $1 -ge 65529 && test $1 -le 65531
	then
		_tuish_cw=0  # Interlinear annotations (U+FFF9-U+FFFB)
	elif test $1 -ge 917760 && test $1 -le 917999
	then
		_tuish_cw=0  # Variation Selectors Supplement (U+E0100-U+E01EF)
	elif test $1 -ge 127744 && test $1 -le 129791
	then
		_tuish_cw=2  # Emoticons, Misc Symbols, etc.
	elif test $1 -ge 131072 && test $1 -le 196607
	then
		_tuish_cw=2  # CJK Ext B-F, Compat Supplement (U+20000-U+2FFFF)
	elif test $1 -ge 196608 && test $1 -le 262143
	then
		_tuish_cw=2  # CJK Ext G-I (U+30000-U+3FFFF)
	else
		_tuish_cw=1
	fi
}

# ─── UTF-8 byte-level decoding ───────────────────────────────────
# Manual UTF-8 decoding from raw bytes under LC_ALL=C.

# Get unsigned byte value at byte offset $2 in variable named $1.
# Result in _tuish_bval. Returns 1 (false) at end of string.
_tuish_byte_val ()
{
	eval "local _tuish_bv_ch=\"\${$1:$2:1}\""
	if test -z "$_tuish_bv_ch"; then _tuish_bval=0; return 1; fi
	_tuish_ord "$_tuish_bv_ch"
	_tuish_bval=$_tuish_code
	if test $_tuish_bval -lt 0; then _tuish_bval=$((_tuish_bval + 256)); fi
}

# Advance past one UTF-8 lead byte, setting _tuish_cbytes.
_tuish_utf8_len ()
{
	if test $1 -lt 128; then   _tuish_cbytes=1
	elif test $1 -lt 224; then _tuish_cbytes=2
	elif test $1 -lt 240; then _tuish_cbytes=3
	else                       _tuish_cbytes=4
	fi
}

# Find byte offset of character index $2 in variable named $1.
# Result in _tuish_boff.
_tuish_char_byte_off ()
{
	# The one decode behind tuish_str_left/right/char's slow paths, so memoing
	# here covers all three. The count is part of the key: the same string
	# answers differently for a different character offset.
	eval "local _bo_s=\"\${$1}\""
	if _tuish_memo_get "o$2 $_bo_s"
	then _tuish_boff=$_tuish_memo_val; return; fi
	local _bo_i=0 _bo_ci=0
	while test $_bo_ci -lt $2
	do
		_tuish_byte_val "$1" $_bo_i || break
		_tuish_utf8_len $_tuish_bval
		_bo_i=$((_bo_i + _tuish_cbytes))
		_bo_ci=$((_bo_ci + 1))
	done
	_tuish_boff=$_bo_i
	_tuish_memo_put "o$2 $_bo_s" "$_bo_i"
}
