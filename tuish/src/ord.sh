# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# src/ord.sh - ASCII ord/chr lookup tables
# Source after compat.sh.  Do not execute directly.
#
# Provides:
#   _tuish_ord()    - character → ASCII code (result in _tuish_code)
#   _tuish_chr_N    - code → character lookup variables (_tuish_chr_1 .. _tuish_chr_127)
#
# Dependencies: compat.sh (_tuish_printf, _tuish_out(), alias local=typeset)

# ─── ASCII lookup tables ─────────────────────────────────────────
# Precomputed chr (code→char) and ord (char→code) tables for codes 1-255.
# Avoids repeated subshell forks in event parsing and string width.
# Bytes 128-255 (UTF-8 lead/continuation) feed the fork-free _tuish_ord_hi
# fallback below; byte 0 is never stored (can't live in a shell variable).

_tuish_init_tables ()
{
	local _tuish_ord_i=1 _tuish_ord_chr='' _tuish_ord_d1 _tuish_ord_d2 _tuish_ord_d3
	local _tuish_ord_fmt='' _tuish_ord_esc='' _tuish_ord_all='' _tuish_ord_rest='' _tuish_ord_next=''
	if printf -v _tuish_ord_chr 'x' >/dev/null 2>&1 && test "$_tuish_ord_chr" = 'x'
	then
		# bash/zsh: printf -v avoids all subshells
		while test $_tuish_ord_i -le 255
		do
			_tuish_ord_d1=$((_tuish_ord_i / 64)); _tuish_ord_d2=$(( (_tuish_ord_i / 8) % 8 )); _tuish_ord_d3=$((_tuish_ord_i % 8))
			printf -v _tuish_ord_chr "\\${_tuish_ord_d1}${_tuish_ord_d2}${_tuish_ord_d3}"
			eval "_tuish_chr_$_tuish_ord_i=\"\$_tuish_ord_chr\""
			_tuish_ord_i=$((_tuish_ord_i + 1))
		done
	else
		# No `printf -v`: ONE subshell for the whole table.
		#
		# Which shells land here is a capability question, not a name — this build of
		# ksh93 has `printf -v` and takes the branch above, an older one would not.
		# Measured here: mksh and busybox take this path (and so does dash), mksh via
		# the echo -ne emitter below.
		#
		# It used to be one per character — 255 of them — and on a shell that has no
		# fork to make a subshell with (the wasm/browser target) that was 86% of the
		# time it took to load ALL of tuish: 32ms of a 37ms library load. A command
		# substitution there is not a call, it is a snapshot of the shell's state, so
		# it costs more the more state exists and it is never as cheap as it looks.
		#
		# So emit all 255 bytes in a single printf and slice them apart with parameter
		# expansion, which forks nothing. Same table, ~30ms cheaper at startup.
		#
		# Note what this does NOT need: a check that the payload came back 255 bytes
		# long. A shell whose printf stops at 127 (yash does) returns 127 bytes here
		# and produced exactly 127 usable entries the old way too — measured, both
		# routes degrade identically — so the batch emit introduces no failure mode
		# the per-character loop did not already have. Adding a length guard would
		# only turn that long-standing degradation into a new hard abort at load.
		# tests/unit/test_ord_table.sh is where a short table gets caught.
		#
		# Two things make the slicing safe, and neither is optional:
		#   * compat.sh pins LC_ALL=C, so `?` matches one BYTE. Under a UTF-8 locale it
		#     would match a CHARACTER and the high half of the table would misalign.
		#   * $_tuish_ord_next is a suffix of $_tuish_ord_rest by construction, and it
		#     is QUOTED inside the %-expansion, so it is matched literally — bytes that
		#     are pattern metacharacters (\ * ? [) cannot act as a pattern.
		#
		# The trailing 'X' sentinel is load-bearing: command substitution strips
		# TRAILING NEWLINES, so a bare $(printf '\012') yields the EMPTY STRING and
		# _tuish_chr_10 silently becomes ''. (Only byte 10 is affected — \r and the
		# rest survive.) Nothing read chr_10 until bracketed-paste capture needed a
		# newline, at which point pasted line breaks vanished on exactly the shells
		# that take this branch — busybox, which is the browser/wasm target. Append a
		# sentinel byte and strip it back off, and the character survives. The payload
		# now ends at byte 255 rather than at whatever character is being built, so
		# nothing is at risk today; it stays because the next person to change the
		# range should not have to rediscover this.
		#
		# An explicit `if`, not `test ... && assign`: the latter returns non-zero on
		# the branch not taken, which trips `set -euf` callers (same reason as in
		# _tuish_ord_hi below).
		if test $_tuish_printf -eq 0
		then _tuish_ord_esc='\0'   # no usable printf (mksh): echo -ne wants \0NNN
		else _tuish_ord_esc='\'    # printf wants \NNN
		fi
		while test $_tuish_ord_i -le 255
		do
			_tuish_ord_d1=$((_tuish_ord_i / 64)); _tuish_ord_d2=$(( (_tuish_ord_i / 8) % 8 )); _tuish_ord_d3=$((_tuish_ord_i % 8))
			_tuish_ord_fmt="${_tuish_ord_fmt}${_tuish_ord_esc}${_tuish_ord_d1}${_tuish_ord_d2}${_tuish_ord_d3}"
			_tuish_ord_i=$((_tuish_ord_i + 1))
		done
		if test $_tuish_printf -eq 0
		then _tuish_ord_all=$(echo -ne "${_tuish_ord_fmt}X")
		else _tuish_ord_all=$(printf "${_tuish_ord_fmt}X")
		fi
		_tuish_ord_rest="${_tuish_ord_all%X}"
		_tuish_ord_i=1
		while test $_tuish_ord_i -le 255
		do
			_tuish_ord_next="${_tuish_ord_rest#?}"
			eval "_tuish_chr_$_tuish_ord_i=\${_tuish_ord_rest%\"\$_tuish_ord_next\"}"
			_tuish_ord_rest="$_tuish_ord_next"
			_tuish_ord_i=$((_tuish_ord_i + 1))
		done
	fi
}
_tuish_init_tables

# ─── Fork-free high/non-printable byte lookup ────────────────────
# _tuish_ord's literal case (below) covers fast printable ASCII (0x20-0x7E).
# Every other byte — UTF-8 lead/continuation (0x80-0xFF) and control bytes
# — used to fall through to a `$(printf '%d' ...)` SUBSHELL FORK, paid once
# per non-ASCII byte (catastrophic for CJK/emoji width and UTF-8 input).
#
# Build a fork-free fallback once at init: a generated case keyed on the chr
# table. The generated source contains only the literal text
# "$_tuish_chr_NNN") — the value is substituted at match time, inside double
# quotes, where backslash/glob metacharacters match literally. So no byte
# ever appears raw in the eval'd source: zero escaping hazards.
#
# High bytes (128-255) are emitted first since they are the common path; the
# returned value is the true UNSIGNED 1-255 (the old fork could yield a
# negative on signed-char platforms — this is strictly more correct).
_tuish_build_ord_hi ()
{
	local _tuish_ord_i _tuish_ord_body=''
	_tuish_ord_i=128
	while test $_tuish_ord_i -le 255
	do
		_tuish_ord_body="${_tuish_ord_body}\"\$_tuish_chr_${_tuish_ord_i}\") _tuish_code=${_tuish_ord_i};; "
		_tuish_ord_i=$((_tuish_ord_i + 1))
	done
	_tuish_ord_i=1
	while test $_tuish_ord_i -le 127
	do
		_tuish_ord_body="${_tuish_ord_body}\"\$_tuish_chr_${_tuish_ord_i}\") _tuish_code=${_tuish_ord_i};; "
		_tuish_ord_i=$((_tuish_ord_i + 1))
	done
	eval "_tuish_ord_hi () { case \"\$1\" in ${_tuish_ord_body}*) _tuish_code=0;; esac; }"
}

# UTF-8 continuation-byte fast decoder (result in _tuish_c6 = the low 6 bits,
# 0-63). The str.sh width/window decode loops need ONLY `byte & 63` from every
# continuation byte, and they already know those bytes are continuations. Going
# through _tuish_ord for them wastes a whole scan of _tuish_ord's ~95-arm
# printable-ASCII case (all misses, since a continuation byte 0x80-0xBF is never
# printable ASCII) plus a second function call into _tuish_ord_hi. A dedicated
# 64-arm case keyed on the 0x80-0xBF chr vars returns the masked value in one
# call — cutting the per-continuation-byte cost roughly in half on the
# generated-case shells (busybox/ksh93/mksh). Same byte-substituted-at-match
# safety as _tuish_build_ord_hi above (no raw byte in eval'd source). Lead and
# ASCII first bytes still go through _tuish_ord, whose literal ASCII case keeps
# the common all-ASCII string fast.
_tuish_build_cont ()
{
	local _tuish_ord_i=128 _tuish_ord_body=''
	while test $_tuish_ord_i -le 191
	do
		_tuish_ord_body="${_tuish_ord_body}\"\$_tuish_chr_${_tuish_ord_i}\") _tuish_c6=$((_tuish_ord_i - 128));; "
		_tuish_ord_i=$((_tuish_ord_i + 1))
	done
	eval "_tuish_cont6 () { case \"\$1\" in ${_tuish_ord_body}*) _tuish_c6=0;; esac; }"
}

# bash/zsh have `printf -v` (a fork-free assignment) and can resolve any byte
# in O(1): `printf '%d' "'<byte>"` yields the char's value, signed on
# signed-char platforms, so correct back to unsigned 1-255. Shells without
# `printf -v` (ksh93/mksh/busybox) use the generated linear-scan case, which
# is still fork-free. Same capability probe as _tuish_init_tables.
if printf -v _tuish_pv_probe '%d' "'x" >/dev/null 2>&1 && test "${_tuish_pv_probe:-}" = '120'
then
	_tuish_ord_hi ()
	{
		printf -v _tuish_code '%d' "'$1"
		# Explicit `if` (not `test && assign`): the latter returns non-zero
		# when the byte is already positive, which trips `set -euf` callers.
		if test "$_tuish_code" -lt 0
		then
			_tuish_code=$((_tuish_code + 256))
		fi
	}
	# Masking the low 6 bits works on the signed value too (two's complement),
	# so no unsigned correction is needed here.
	_tuish_cont6 () { printf -v _tuish_c6 '%d' "'$1"; _tuish_c6=$((_tuish_c6 & 63)); }
	unset _tuish_pv_probe 2>/dev/null || _tuish_pv_probe=''
else
	_tuish_build_ord_hi
	_tuish_build_cont
fi

# Fast ord: literal case for printable ASCII (no var expansion — hot input
# path), fork-free _tuish_ord_hi for every other byte (UTF-8 + control).
_tuish_ord ()
{
	case "$1" in
		' ') _tuish_code=32;; '!') _tuish_code=33;;
		'"') _tuish_code=34;; '#') _tuish_code=35;;
		'$') _tuish_code=36;; '%') _tuish_code=37;;
		'&') _tuish_code=38;; "'") _tuish_code=39;;
		'(') _tuish_code=40;; ')') _tuish_code=41;;
		'*') _tuish_code=42;; '+') _tuish_code=43;;
		',') _tuish_code=44;; '-') _tuish_code=45;;
		'.') _tuish_code=46;; '/') _tuish_code=47;;
		0) _tuish_code=48;; 1) _tuish_code=49;;
		2) _tuish_code=50;; 3) _tuish_code=51;;
		4) _tuish_code=52;; 5) _tuish_code=53;;
		6) _tuish_code=54;; 7) _tuish_code=55;;
		8) _tuish_code=56;; 9) _tuish_code=57;;
		':') _tuish_code=58;; ';') _tuish_code=59;;
		'<') _tuish_code=60;; '=') _tuish_code=61;;
		'>') _tuish_code=62;; '?') _tuish_code=63;;
		'@') _tuish_code=64;;
		A) _tuish_code=65;; B) _tuish_code=66;;
		C) _tuish_code=67;; D) _tuish_code=68;;
		E) _tuish_code=69;; F) _tuish_code=70;;
		G) _tuish_code=71;; H) _tuish_code=72;;
		I) _tuish_code=73;; J) _tuish_code=74;;
		K) _tuish_code=75;; L) _tuish_code=76;;
		M) _tuish_code=77;; N) _tuish_code=78;;
		O) _tuish_code=79;; P) _tuish_code=80;;
		Q) _tuish_code=81;; R) _tuish_code=82;;
		S) _tuish_code=83;; T) _tuish_code=84;;
		U) _tuish_code=85;; V) _tuish_code=86;;
		W) _tuish_code=87;; X) _tuish_code=88;;
		Y) _tuish_code=89;; Z) _tuish_code=90;;
		'[') _tuish_code=91;; \\) _tuish_code=92;;
		']') _tuish_code=93;; '^') _tuish_code=94;;
		_) _tuish_code=95;; '`') _tuish_code=96;;
		a) _tuish_code=97;; b) _tuish_code=98;;
		c) _tuish_code=99;; d) _tuish_code=100;;
		e) _tuish_code=101;; f) _tuish_code=102;;
		g) _tuish_code=103;; h) _tuish_code=104;;
		i) _tuish_code=105;; j) _tuish_code=106;;
		k) _tuish_code=107;; l) _tuish_code=108;;
		m) _tuish_code=109;; n) _tuish_code=110;;
		o) _tuish_code=111;; p) _tuish_code=112;;
		q) _tuish_code=113;; r) _tuish_code=114;;
		s) _tuish_code=115;; t) _tuish_code=116;;
		u) _tuish_code=117;; v) _tuish_code=118;;
		w) _tuish_code=119;; x) _tuish_code=120;;
		y) _tuish_code=121;; z) _tuish_code=122;;
		'{') _tuish_code=123;; '|') _tuish_code=124;;
		'}') _tuish_code=125;; '~') _tuish_code=126;;
		*) _tuish_ord_hi "$1";;
	esac
}
