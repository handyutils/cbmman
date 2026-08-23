# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Load guard: skip re-definition if already sourced (see tui.sh).
if test -n "${_tuish_hl_loaded:-}"; then return 0; fi
_tuish_hl_loaded=1
# src/hl.sh - Generic code highlighter
# Standalone module. Depends on NOTHING — not compat.sh, not ord.sh, not str.sh.
#
# Provides:
#   tuish_hl_begin [INFO]  - start a code block; INFO is the fence info string
#   tuish_hl_line LINE     - lex one line -> TUISH_HL_PAY
#   tuish_hl_end           - drop the carried state
#
# TUISH_HL_PAY is a SEGMENTED payload: "style<US>text" fields joined by US (0x1f),
# the same shape the rest of the record stream uses.
#
# ONE LEXER, NOT ONE PER LANGUAGE. It knows strings, comments, numbers, operators
# and "identifier immediately before ( is a function" — the shapes nearly every
# language shares. The fence info string does not select a grammar; it only flips
# three rules that genuinely disagree between language families (see tuish_hl_begin).
#
# NEVER CALL tuish_hl_line IN A SUBSHELL. `/* */` carries across lines in
# _tuish_hl_st, so `pay=$(tuish_hl_line "$l")` would silently lose the state and
# every block comment would reopen on the next line. That is why the result is a
# register and not stdout.
#
# ROUND-TRIP INVARIANT: concatenating a line's segment texts reproduces the source
# line BYTE FOR BYTE. Readers reconstruct code from these segments to put it on the
# clipboard, so any transformation here (expanding tabs, trimming) corrupts what the
# user pastes. Whitespace-only text is kept; only "" is dropped.

# US, built once at load. `$( )` is a fork, which this codebase avoids — but this is
# one fork per process at source time, not per line, the same trade ord.sh makes for
# its byte tables.
_TUISH_HL_US=$(printf '\037')

TUISH_HL_PAY=''

# Identifiers matched here are painted as keywords. ONE list for every language —
# a generic lexer has no grammar to ask, and the alternative is that `K`, the most
# visible colour in the palette, is never emitted at all. The cost is that a
# variable literally named `type` or `class` gets keyword colour. Set to '' to
# disable. Entries are space-delimited on BOTH sides; the lookup is a `case` glob.
TUISH_HL_KEYWORDS=' if then else elif fi for while do done case esac in return function def class import from export const let var func struct type package public private protected static void new try catch finally switch break continue and or not is None True False null true false '

_tuish_hl_st=0          # 0 = normal, 1 = inside a /* */ block comment
_tuish_hl_last=''       # style of the last segment appended (for merging)
_tuish_hl_hash=1        # 1 = '#' can open a comment
_tuish_hl_slash=1       # 1 = '//' and '/* */' can open a comment
_tuish_hl_sqesc=0       # 1 = backslash escapes apply inside '...'
_tuish_hl_off=0         # 1 = emit the line verbatim as one default segment
_tuish_hl_diff=0        # 1 = classify by leading +/- instead of lexing

# tuish_hl_begin [INFO]
# Reset the carried state and pick the three context rules from the fence info
# string. This runs once per code block, never per line.
#
# The rules, and why each one exists:
#   hash  - '#' is a comment in shell/python/make/yaml, but '#include' and the CSS
#           '#4fd1c2' are code. Getting this wrong paints the rest of the line as
#           a comment, which is the loudest mistake this lexer can make.
#   slash - '//' and '/* */' are comments almost everywhere they appear at all.
#   sqesc - shell single quotes have no escapes; C and JS ones do.
#   off   - program output is not source. Lexing it is not merely useless: one
#           apostrophe in "don't actually delete anything" opens a string that
#           runs to end of line.
#
# An UNLABELLED fence has to default to something, and this defaults to the shell
# family. An unlabelled C or CSS block will mis-colour its '#' lines; label the
# fence. That is an authoring requirement, not something to chase with heuristics.
tuish_hl_begin ()
{
	_tuish_hl_st=0
	_tuish_hl_last=''
	case "${1:-}" in
		c|h|cc|cpp|hpp|cs|js|mjs|cjs|ts|jsx|tsx|java|go|rust|rs|php|css|scss|less|json|swift|kotlin|kt|scala|dart)
			_tuish_hl_hash=0 _tuish_hl_slash=1 _tuish_hl_sqesc=1 _tuish_hl_off=0 _tuish_hl_diff=0 ;;
		diff|patch)
			_tuish_hl_hash=0 _tuish_hl_slash=0 _tuish_hl_sqesc=0 _tuish_hl_off=0 _tuish_hl_diff=1 ;;
		output|out|text|txt|log|plain|none|console|term|shell-session)
			_tuish_hl_hash=0 _tuish_hl_slash=0 _tuish_hl_sqesc=0 _tuish_hl_off=1 _tuish_hl_diff=0 ;;
		*)
			# Shell family and everything unrecognized.
			_tuish_hl_hash=1 _tuish_hl_slash=1 _tuish_hl_sqesc=0 _tuish_hl_off=0 _tuish_hl_diff=0 ;;
	esac
	return 0
}

# tuish_hl_end — forget the carried state. Calling tuish_hl_begin already does
# this; this exists so a caller can close a block without opening another.
tuish_hl_end ()
{
	_tuish_hl_st=0
	_tuish_hl_last=''
	return 0
}

# _tuish_hl_add STYLE TEXT — append one segment, merging into the previous one when
# the style repeats. Merging is what keeps a typical line at 4-8 segments instead of
# one per token, which matters: every segment is a separate paint call downstream.
_tuish_hl_add ()
{
	if test -z "$2"; then return 0; fi
	if test "$1" = "$_tuish_hl_last"
	then
		TUISH_HL_PAY="${TUISH_HL_PAY}$2"
		return 0
	fi
	if test -n "$TUISH_HL_PAY"
	then TUISH_HL_PAY="${TUISH_HL_PAY}${_TUISH_HL_US}$1${_TUISH_HL_US}$2"
	else TUISH_HL_PAY="$1${_TUISH_HL_US}$2"
	fi
	_tuish_hl_last="$1"
	return 0
}

# _tuish_hl_text TEXT — tokenize a stretch known to hold no string or comment.
#
# THE HOT LOOP OF THE WHOLE MODULE. It advances by RUNS, not characters: one
# parameter expansion yields a maximal identifier run, the complement yields the
# maximal punctuation run. Measured on this repo's largest post, run-skipping is
# 1.6ms against 20ms for the equivalent per-character loop.
#
# Both bracket classes are written LITERALLY, and must stay that way. Putting the
# pattern in a variable works on bash, mksh, dash and busybox and SILENTLY DOES NOT
# MATCH on zsh (which needs ${~var}) — it returns the whole string, so the lexer
# would emit one giant token per line and merely look unhighlighted.
#
# The classes are ENUMERATED rather than written as A-Z ranges. POSIX leaves range
# behaviour outside the C locale unspecified, and ksh93 honours that: in a UTF-8
# locale it collates "ç" INSIDE A-Za-z, so the same line lexes differently there
# than under LC_ALL=C. That matters beyond tidiness — build.sh renders HTML in the
# machine's own locale while the reader runs under compat.sh's LC_ALL=C, so a
# collation-dependent class would let the two renderers disagree about the very
# thing this module exists to keep identical. Enumeration is locale-proof and costs
# nothing: it is still one expansion.
#
# Each pass consumes at least one byte: if the identifier run is empty the string
# starts with punctuation, so the punctuation run cannot also be empty.
#
# NON-ASCII IS PUNCTUATION HERE. compat.sh pins LC_ALL=C, so a UTF-8 byte is not in
# [A-Za-z0-9_] and an accented identifier splits into operator-coloured runs
# ("acentuação" -> "acentua" + "çã" + "o"). Deliberately not worked around: prose in
# code blocks lives inside comments, strings or unlexed output fences, all of which
# are consumed whole before this function ever sees them, and the round-trip
# invariant holds either way — only the colour is odd, never the text.
_tuish_hl_text ()
{
	local _hlt_r="$1" _hlt_id _hlt_pn _hlt_sty
	while test -n "$_hlt_r"
	do
		_hlt_id="${_hlt_r%%[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_]*}"
		if test -n "$_hlt_id"
		then
			_hlt_r="${_hlt_r#"$_hlt_id"}"
			case $_hlt_id in
				[0-9]*) _hlt_sty=N ;;
				*)
					case $_hlt_r in
						'('*) _hlt_sty=F ;;
						*)
							case $TUISH_HL_KEYWORDS in
								*" $_hlt_id "*) _hlt_sty=K ;;
								*)              _hlt_sty=. ;;
							esac ;;
					esac ;;
			esac
			_tuish_hl_add "$_hlt_sty" "$_hlt_id"
		fi
		_hlt_pn="${_hlt_r%%[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_]*}"
		if test -n "$_hlt_pn"
		then
			_hlt_r="${_hlt_r#"$_hlt_pn"}"
			_tuish_hl_add O "$_hlt_pn"
		fi
	done
	return 0
}

# _tuish_hl_close DELIM REST ESCAPES
# Find DELIM in REST, honouring backslash escapes when ESCAPES is 1.
#   _tuish_hl_span -> the text up to AND INCLUDING the closing delimiter
#   _tuish_hl_rest -> what follows it
# Returns 1 when the delimiter never arrives (the whole of REST becomes the span).
#
# Call this in an `if`, never as a bare statement: under `set -e` the unterminated
# case would abort the caller.
_tuish_hl_close ()
{
	local _hlc_d="$1" _hlc_r="$2" _hlc_esc="$3" _hlc_acc='' _hlc_pre _hlc_bs
	while :
	do
		case $_hlc_r in
			*"$_hlc_d"*) : ;;
			*)
				_tuish_hl_span="${_hlc_acc}${_hlc_r}"
				_tuish_hl_rest=''
				return 1 ;;
		esac
		_hlc_pre="${_hlc_r%%"$_hlc_d"*}"
		_hlc_r="${_hlc_r#*"$_hlc_d"}"
		if test "$_hlc_esc" -eq 1
		then
			# The trailing run of backslashes before the delimiter. An ODD count means
			# the delimiter itself is escaped, so keep looking.
			_hlc_bs="${_hlc_pre##*[!\\]}"
			if test $(( ${#_hlc_bs} % 2 )) -eq 1
			then
				_hlc_acc="${_hlc_acc}${_hlc_pre}${_hlc_d}"
				continue
			fi
		fi
		_tuish_hl_span="${_hlc_acc}${_hlc_pre}${_hlc_d}"
		_tuish_hl_rest="$_hlc_r"
		return 0
	done
}

# tuish_hl_line LINE -> TUISH_HL_PAY
tuish_hl_line ()
{
	local _hll_r="$1" _hll_p _hll_k _hll_pre _hll_t _hll_n _hll_last

	TUISH_HL_PAY=''
	_tuish_hl_last=''

	if test "$_tuish_hl_off" -eq 1
	then
		_tuish_hl_add . "$_hll_r"
		return 0
	fi

	if test "$_tuish_hl_diff" -eq 1
	then
		case $_hll_r in
			'+'*) _tuish_hl_add '+' "$_hll_r" ;;
			'-'*) _tuish_hl_add '-' "$_hll_r" ;;
			*)    _tuish_hl_add . "$_hll_r" ;;
		esac
		return 0
	fi

	# Carried /* */ from an earlier line.
	if test "$_tuish_hl_st" -eq 1
	then
		if _tuish_hl_close '*/' "$_hll_r" 0
		then
			_tuish_hl_add C "$_tuish_hl_span"
			_hll_r="$_tuish_hl_rest"
			_tuish_hl_st=0
		else
			_tuish_hl_add C "$_tuish_hl_span"
			return 0
		fi
	fi

	while test -n "$_hll_r"
	do
		# Earliest opener wins. Each arm records the text before its marker so the
		# winner's prefix is already computed by the time the comparison ends.
		_hll_p=-1 _hll_k='' _hll_pre=''

		case $_hll_r in *\'*)
			_hll_t="${_hll_r%%\'*}"; _hll_n=${#_hll_t}
			if test "$_hll_p" -lt 0 || test "$_hll_n" -lt "$_hll_p"
			then _hll_p=$_hll_n _hll_k=sq _hll_pre="$_hll_t"; fi ;;
		esac
		case $_hll_r in *\"*)
			_hll_t="${_hll_r%%\"*}"; _hll_n=${#_hll_t}
			if test "$_hll_p" -lt 0 || test "$_hll_n" -lt "$_hll_p"
			then _hll_p=$_hll_n _hll_k=dq _hll_pre="$_hll_t"; fi ;;
		esac
		case $_hll_r in *\`*)
			_hll_t="${_hll_r%%\`*}"; _hll_n=${#_hll_t}
			if test "$_hll_p" -lt 0 || test "$_hll_n" -lt "$_hll_p"
			then _hll_p=$_hll_n _hll_k=bt _hll_pre="$_hll_t"; fi ;;
		esac
		if test "$_tuish_hl_hash" -eq 1
		then
			case $_hll_r in *'#'*)
				_hll_t="${_hll_r%%'#'*}"; _hll_n=${#_hll_t}
				if test "$_hll_p" -lt 0 || test "$_hll_n" -lt "$_hll_p"
				then _hll_p=$_hll_n _hll_k=hash _hll_pre="$_hll_t"; fi ;;
			esac
		fi
		if test "$_tuish_hl_slash" -eq 1
		then
			case $_hll_r in *'//'*)
				_hll_t="${_hll_r%%'//'*}"; _hll_n=${#_hll_t}
				if test "$_hll_p" -lt 0 || test "$_hll_n" -lt "$_hll_p"
				then _hll_p=$_hll_n _hll_k=slc _hll_pre="$_hll_t"; fi ;;
			esac
			case $_hll_r in *'/*'*)
				_hll_t="${_hll_r%%'/*'*}"; _hll_n=${#_hll_t}
				if test "$_hll_p" -lt 0 || test "$_hll_n" -lt "$_hll_p"
				then _hll_p=$_hll_n _hll_k=blk _hll_pre="$_hll_t"; fi ;;
			esac
		fi

		if test "$_hll_p" -lt 0
		then
			_tuish_hl_text "$_hll_r"
			return 0
		fi

		# The byte immediately before the marker, for the two context gates below.
		_hll_last="${_hll_pre#"${_hll_pre%?}"}"

		case $_hll_k in
			hash)
				# A comment only at line start or after whitespace, and never before '['
				# — otherwise PHP's #[Route(...)] attributes lose the rest of their line.
				_hll_t="${_hll_r#"$_hll_pre"#}"
				case $_hll_last in
					''|' '|'	') : ;;
					*)
						_tuish_hl_text "$_hll_pre"; _tuish_hl_add O '#'
						_hll_r="$_hll_t"; continue ;;
				esac
				case $_hll_t in
					'['*)
						_tuish_hl_text "$_hll_pre"; _tuish_hl_add O '#'
						_hll_r="$_hll_t"; continue ;;
				esac
				_tuish_hl_text "$_hll_pre"
				_tuish_hl_add C "#${_hll_t}"
				return 0 ;;
			slc)
				# Not a comment after ':' — otherwise every https:// in a code block
				# turns green from the colon onward.
				_hll_t="${_hll_r#"$_hll_pre"//}"
				case $_hll_last in
					':')
						_tuish_hl_text "$_hll_pre"; _tuish_hl_add O '//'
						_hll_r="$_hll_t"; continue ;;
				esac
				_tuish_hl_text "$_hll_pre"
				_tuish_hl_add C "//${_hll_t}"
				return 0 ;;
			blk)
				_tuish_hl_text "$_hll_pre"
				_hll_t="${_hll_r#"$_hll_pre"/\*}"
				if _tuish_hl_close '*/' "$_hll_t" 0
				then
					_tuish_hl_add C "/*${_tuish_hl_span}"
					_hll_r="$_tuish_hl_rest"
				else
					_tuish_hl_add C "/*${_tuish_hl_span}"
					_tuish_hl_st=1
					return 0
				fi ;;
			sq)
				_tuish_hl_text "$_hll_pre"
				_hll_t="${_hll_r#"$_hll_pre"\'}"
				if _tuish_hl_close "'" "$_hll_t" "$_tuish_hl_sqesc"
				then
					_tuish_hl_add S "'${_tuish_hl_span}"
					_hll_r="$_tuish_hl_rest"
				else
					# Unterminated at end of line. Emit what is left and STOP CARRYING:
					# multi-line strings are out of scope, and letting the state leak
					# would paint every following line of the block as one string.
					_tuish_hl_add S "'${_tuish_hl_span}"
					return 0
				fi ;;
			dq)
				_tuish_hl_text "$_hll_pre"
				_hll_t="${_hll_r#"$_hll_pre"\"}"
				if _tuish_hl_close '"' "$_hll_t" 1
				then
					_tuish_hl_add S "\"${_tuish_hl_span}"
					_hll_r="$_tuish_hl_rest"
				else
					_tuish_hl_add S "\"${_tuish_hl_span}"
					return 0
				fi ;;
			bt)
				_tuish_hl_text "$_hll_pre"
				_hll_t="${_hll_r#"$_hll_pre"\`}"
				if _tuish_hl_close '`' "$_hll_t" 1
				then
					_tuish_hl_add S "\`${_tuish_hl_span}"
					_hll_r="$_tuish_hl_rest"
				else
					_tuish_hl_add S "\`${_tuish_hl_span}"
					return 0
				fi ;;
		esac
	done
	return 0
}
