#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for the chr/ord lookup tables (src/ord.sh).
#
# ord.sh builds _tuish_chr_1.._tuish_chr_255 by one of two routes, chosen by whether
# the shell has `printf -v`: a fork-free per-character loop, or a single command
# substitution for the whole table which is then sliced apart with parameter
# expansion. Both must produce byte N at index N, on every shell.
#
# Nothing tested the table as a whole until now, and that is precisely how the last
# bug in it shipped: command substitution strips TRAILING NEWLINES, so _tuish_chr_10
# was silently '' on the substitution shells. It went unnoticed because the only
# readers were assertions comparing '' to '' (see test_paste.sh, which now asserts
# chr_10 is real before using it). A table this mechanical deserves to be checked
# mechanically, all 255 of it, rather than at the three indices someone happened to
# need.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/ord.sh"

printf 'Unit tests: chr/ord lookup tables\n'

# --- Every entry is exactly one byte ----------------------------------------
# The failure this catches is an entry going EMPTY (the newline bug) or a
# multi-byte entry from a locale that made `?` match a character.
_bad='' _n=0 _i=1
while test $_i -le 255
do
	eval "_c=\$_tuish_chr_$_i"
	if test "${#_c}" -ne 1
	then _n=$((_n + 1)); test $_n -le 8 && _bad="${_bad} ${_i}(len=${#_c})"
	fi
	_i=$((_i + 1))
done
assert_eq "$_n" "0" "chr: all 255 entries are exactly one byte long${_bad:+ — bad:${_bad}}"

# --- Every entry holds its OWN byte value ------------------------------------
# Length alone would pass a table that was correct but shifted by one, which is the
# way the slicing loop would fail if it ever got out of step.
_bad='' _n=0 _i=1
while test $_i -le 255
do
	eval "_c=\$_tuish_chr_$_i"
	_tuish_ord "$_c"
	if test "$_tuish_code" -ne "$_i"
	then _n=$((_n + 1)); test $_n -le 8 && _bad="${_bad} ${_i}->${_tuish_code}"
	fi
	_i=$((_i + 1))
done
assert_eq "$_n" "0" "ord: every chr_N maps back to N${_bad:+ — bad:${_bad}}"

# There is deliberately no separate distinctness check. The round-trip above
# already forces it: _tuish_ord is built FROM this table and returns the first
# arm that matches, so if two entries held the same byte, one of them would come
# back with the other's index and fail there. An extra loop would restate the
# same property in weaker terms.

# --- The bytes that have actually broken before ------------------------------
# Named individually so a failure says which one, rather than "one of 255".
assert_eq "${#_tuish_chr_10}" "1" "chr_10 is a real newline (trailing-newline stripping)"
assert_eq "${#_tuish_chr_13}" "1" "chr_13 is a real carriage return"
assert_eq "${#_tuish_chr_27}" "1" "chr_27 is a real ESC"
assert_eq "${#_tuish_chr_92}" "1" "chr_92 is a real backslash (pattern metacharacter)"
assert_eq "${#_tuish_chr_255}" "1" "chr_255 is a real byte (last entry, sentinel boundary)"

# --- The high half, which feeds the UTF-8 decoders ---------------------------
# _tuish_ord_hi and _tuish_cont6 are generated FROM this table, so a hole in the
# high half would take UTF-8 width and input decoding down with it.
_tuish_ord "$_tuish_chr_128"
assert_eq "$_tuish_code" "128" "ord: byte 128 resolves unsigned, not negative"
_tuish_ord "$_tuish_chr_255"
assert_eq "$_tuish_code" "255" "ord: byte 255 resolves unsigned, not negative"

# Continuation bytes 0x80-0xBF must yield their low 6 bits.
_bad='' _n=0 _i=128
while test $_i -le 191
do
	eval "_c=\$_tuish_chr_$_i"
	_tuish_cont6 "$_c"
	if test "$_tuish_c6" -ne $((_i - 128))
	then _n=$((_n + 1)); test $_n -le 8 && _bad="${_bad} ${_i}->${_tuish_c6}"
	fi
	_i=$((_i + 1))
done
assert_eq "$_n" "0" "cont6: every continuation byte yields its low 6 bits${_bad:+ — bad:${_bad}}"

test_summary
