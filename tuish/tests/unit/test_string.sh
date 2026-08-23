#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for tuish_str_* string utilities

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/ord.sh"
. "$TESTS_DIR/../src/tui.sh"
. "$TESTS_DIR/../src/str.sh"


# Exercise the SHIPPED configuration. tuish_fnfix normally fires from tuish_init, which unit
# tests deliberately never call (they stub the device) — so without this, every suite here
# would validate the framework with its ksh `local` still leaking, i.e. not the library that
# actually runs. It is a no-op on every shell whose `local` already works.
command -v tuish_fnfix >/dev/null 2>&1 && tuish_fnfix

_tuish_write () { :; }
tuish_on_event () { :; }

printf 'Unit tests: tuish_str_* string utilities\n'

# --- tuish_str_len ---
_t='hello'
tuish_str_len _t
assert_eq "$TUISH_SLEN" "5" "str_len: hello"

_t=''
tuish_str_len _t
assert_eq "$TUISH_SLEN" "0" "str_len: empty"

_t='a'
tuish_str_len _t
assert_eq "$TUISH_SLEN" "1" "str_len: single char"

_t='hello world'
tuish_str_len _t
assert_eq "$TUISH_SLEN" "11" "str_len: with space"

_t='abc/def.txt'
tuish_str_len _t
assert_eq "$TUISH_SLEN" "11" "str_len: with special chars"

# --- tuish_str_left ---
_t='hello world'
tuish_str_left _t 5
assert_eq "$TUISH_SLEFT" "hello" "str_left: first 5"

_t='hello'
tuish_str_left _t 0
assert_eq "$TUISH_SLEFT" "" "str_left: 0 chars"

_t='abc'
tuish_str_left _t 3
assert_eq "$TUISH_SLEFT" "abc" "str_left: full string"

_t='abc'
tuish_str_left _t 1
assert_eq "$TUISH_SLEFT" "a" "str_left: 1 char"

# --- tuish_str_right ---
_t='hello world'
tuish_str_right _t 6
assert_eq "$TUISH_SRIGHT" "world" "str_right: offset 6"

_t='hello'
tuish_str_right _t 0
assert_eq "$TUISH_SRIGHT" "hello" "str_right: offset 0"

_t='hello'
tuish_str_right _t 5
assert_eq "$TUISH_SRIGHT" "" "str_right: past end"

_t='abcdef'
tuish_str_right _t 3
assert_eq "$TUISH_SRIGHT" "def" "str_right: offset 3"

# --- tuish_str_char ---
_t='hello'
tuish_str_char _t 0
assert_eq "$TUISH_SCHAR" "h" "str_char: first"

_t='hello'
tuish_str_char _t 4
assert_eq "$TUISH_SCHAR" "o" "str_char: last"

_t='hello'
tuish_str_char _t 2
assert_eq "$TUISH_SCHAR" "l" "str_char: middle"

_t='a'
tuish_str_char _t 0
assert_eq "$TUISH_SCHAR" "a" "str_char: single char string"

# ─── Byte-mode ASCII fast path tests ─────────────────────────────
# Under LC_ALL=C (byte mode), pure ASCII strings should produce the
# same results as mixed UTF-8 strings.  These tests exercise both
# the fast path (printable ASCII) and slow path (non-ASCII bytes).

# Long ASCII string — exercises fast path for all operations
_t='abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'
tuish_str_len _t
assert_eq "$TUISH_SLEN" "62" "fast path: len of long ASCII"

tuish_str_left _t 10
assert_eq "$TUISH_SLEFT" "abcdefghij" "fast path: left 10 of long ASCII"

tuish_str_right _t 52
assert_eq "$TUISH_SRIGHT" "QRSTUVWXYZ" "fast path: right 52 of long ASCII"

tuish_str_char _t 26
assert_eq "$TUISH_SCHAR" "0" "fast path: char at 26 of long ASCII"

# String with tab (non-printable, triggers slow path)
_tab="$(printf '\t')"
_t="ab${_tab}cd"
tuish_str_len _t
assert_eq "$TUISH_SLEN" "5" "slow path: len with tab"

tuish_str_left _t 3
assert_eq "$TUISH_SLEFT" "ab${_tab}" "slow path: left 3 with tab"

tuish_str_right _t 3
assert_eq "$TUISH_SRIGHT" "cd" "slow path: right 3 with tab"

tuish_str_char _t 2
assert_eq "$TUISH_SCHAR" "${_tab}" "slow path: char at tab position"

# ASCII string with only printable chars and spaces
_t='hello world 12345 !@#'
tuish_str_len _t
assert_eq "$TUISH_SLEN" "21" "fast path: len with punctuation"

tuish_str_left _t 12
assert_eq "$TUISH_SLEFT" "hello world " "fast path: left 12 with spaces"

tuish_str_right _t 18
assert_eq "$TUISH_SRIGHT" "!@#" "fast path: right past spaces"

# Edge: empty string (fast path, trivial)
_t=''
tuish_str_len _t
assert_eq "$TUISH_SLEN" "0" "fast path: len of empty"

tuish_str_left _t 0
assert_eq "$TUISH_SLEFT" "" "fast path: left 0 of empty"

tuish_str_right _t 0
assert_eq "$TUISH_SRIGHT" "" "fast path: right 0 of empty"

# Edge: single char at boundary (printable vs non-printable)
_t='~'   # 0x7E, last printable ASCII
tuish_str_len _t
assert_eq "$TUISH_SLEN" "1" "fast path: tilde len"

tuish_str_char _t 0
assert_eq "$TUISH_SCHAR" "~" "fast path: tilde char"

# --- tuish_str_window (horizontal column-window) ---
# ASCII (fast path): column offset == byte offset.
_t='abcdefgh'
tuish_str_window _t 0 4;  assert_eq "$TUISH_SWINDOW" "abcd"     "window: ascii from start"
tuish_str_window _t 2 4;  assert_eq "$TUISH_SWINDOW" "cdef"     "window: ascii offset"
tuish_str_window _t 4 10; assert_eq "$TUISH_SWINDOW" "efgh"     "window: width past end -> tail"
tuish_str_window _t 8 4;  assert_eq "$TUISH_SWINDOW" ""         "window: offset == width -> empty"
tuish_str_window _t 10 4; assert_eq "$TUISH_SWINDOW" ""         "window: offset past end -> empty"
tuish_str_window _t 0 0;  assert_eq "$TUISH_SWINDOW" ""         "window: zero width -> empty"
tuish_str_window _t 0 8;  assert_eq "$TUISH_SWINDOW" "abcdefgh" "window: whole string"
tuish_str_window _t 1 3;  assert_eq "$TUISH_SWINDOW" "bcd"     "window: interior offset"

_t=''
tuish_str_window _t 0 5;  assert_eq "$TUISH_SWINDOW" ""         "window: empty string"

# Wide chars: 'a中b中c' -> columns a=0, 中=1-2, b=3, 中=4-5, c=6 (total width 7).
_t='a中b中c'
tuish_str_window _t 0 3;  assert_eq "$TUISH_SWINDOW" "a中"      "window: wide fully inside"
tuish_str_window _t 1 2;  assert_eq "$TUISH_SWINDOW" "中"       "window: wide aligned to edges"
tuish_str_window _t 0 2;  assert_eq "$TUISH_SWINDOW" "a"        "window: right-straddle wide dropped (result narrower)"
tuish_str_window _t 2 3;  assert_eq "$TUISH_SWINDOW" " b"       "window: left-straddle wide -> leading space"
tuish_str_window _t 3 2;  assert_eq "$TUISH_SWINDOW" "b"        "window: trailing wide right-straddle dropped"

# Combining mark (zero width) follows its visible base, dropped when base off-screen.
# 'a' + U+20DB combining, then 'bc' -> a=col0 (+mark), b=col1, c=col2.
_t='a⃛bc'
tuish_str_window _t 0 2;  assert_eq "$TUISH_SWINDOW" "a⃛b"      "window: combining mark kept with visible base"
tuish_str_window _t 1 2;  assert_eq "$TUISH_SWINDOW" "bc"       "window: combining mark dropped when base scrolled off"

# SGR escapes: zero display width, never split, carried through so a clipped colour
# row keeps correct state (used by the escape-aware path in tuish_text).
_e=$(printf '\033')
_t="${_e}[31mABCDEF${_e}[0m"
tuish_str_window _t 0 3;  assert_eq "$TUISH_SWINDOW" "${_e}[31mABC"          "window sgr: leading run kept, 3 cells"
tuish_str_window _t 0 6;  assert_eq "$TUISH_SWINDOW" "${_e}[31mABCDEF${_e}[0m" "window sgr: whole row, both runs"
tuish_str_window _t 2 2;  assert_eq "$TUISH_SWINDOW" "${_e}[31mCD"           "window sgr: leading run carried past offset"
# Two runs: colour state before the visible slice is preserved.
_t="${_e}[31mAB${_e}[32mCD${_e}[0mEF"
tuish_str_window _t 0 3;  assert_eq "$TUISH_SWINDOW" "${_e}[31mAB${_e}[32mC"  "window sgr: two runs, clip mid-second"
tuish_str_window _t 3 3;  assert_eq "$TUISH_SWINDOW" "${_e}[31m${_e}[32mD${_e}[0mEF" "window sgr: both leading runs carried to offset 3"
# A CSI is never counted as columns nor split (kept whole even a multi-param run). A
# run sitting just before a clipped cell is still carried through — harmless, as the
# escape-aware tuish_text force-closes with a trailing reset.
_t="X${_e}[1;33mY"
tuish_str_window _t 0 1;  assert_eq "$TUISH_SWINDOW" "X${_e}[1;33m"           "window sgr: CSI before clip carried (colour state), never split"
tuish_str_window _t 1 1;  assert_eq "$TUISH_SWINDOW" "${_e}[1;33mY"           "window sgr: multi-param CSI kept whole"

# --- decode memo ---
# The memo sits in front of the UTF-8 decoders (the ASCII fast paths never
# consult it). Every assertion below runs the SAME call twice: the first is the
# cold decode, the second is served from the memo and must agree exactly.
_memo_pair ()   # $1 = call, $2 = result var, $3 = expected, $4 = label
{
	eval "$1"; eval "_mp_a=\$$2"
	eval "$1"; eval "_mp_b=\$$2"
	assert_eq "$_mp_a" "$3" "memo: $4 (cold)"
	assert_eq "$_mp_b" "$3" "memo: $4 (hit)"
}

_t='日本語'
_memo_pair 'tuish_str_width _t'      TUISH_SWIDTH  '6'    'width, CJK'
_memo_pair 'tuish_str_left _t 2'     TUISH_SLEFT   '日本' 'left, CJK'
_memo_pair 'tuish_str_window _t 0 4' TUISH_SWINDOW '日本' 'window, CJK'

# The key is compared as a QUOTED case pattern, so a string of glob
# metacharacters must match only itself. Unquoted, '*' would hit every
# subsequent lookup and hand back the previous answer — silently wrong widths
# and a corrupted screen. These are the entries that would collide.
_t='┤*┤'   ; tuish_str_width _t; assert_eq "$TUISH_SWIDTH" "3" "memo: glob '*' seeded"
_t='┤?┤'   ; tuish_str_width _t; assert_eq "$TUISH_SWIDTH" "3" "memo: glob '?' not matched by '*' entry"
_t='┤ab┤'  ; tuish_str_width _t; assert_eq "$TUISH_SWIDTH" "4" "memo: literal not matched by '*' entry"
_t='┤[a-z]┤'; tuish_str_width _t; assert_eq "$TUISH_SWIDTH" "7" "memo: bracket expression matched literally"
_t='┤*┤'   ; tuish_str_width _t; assert_eq "$TUISH_SWIDTH" "3" "memo: original glob entry still correct"

# The count and the window bounds are part of the key: the same string must not
# answer a different offset from the entry cached for another one.
_t='日本語'
tuish_str_left _t 1;      assert_eq "$TUISH_SLEFT"   '日'     "memo: left 1 distinct from left 2"
tuish_str_left _t 2;      assert_eq "$TUISH_SLEFT"   '日本'   "memo: left 2 distinct from left 1"
tuish_str_window _t 0 2;  assert_eq "$TUISH_SWINDOW" '日'     "memo: window 0,2 distinct from 0,4"
tuish_str_window _t 0 4;  assert_eq "$TUISH_SWINDOW" '日本'   "memo: window 0,4 distinct from 0,2"

# An untouched slot is the empty string; a lookup of the empty string must not
# hit it and come back with an empty width.
_t=''; tuish_str_width _t; assert_eq "$TUISH_SWIDTH" "0" "memo: empty string is not an empty slot"

# --- tuish_str_pad ---
# Fits a string to exactly N display columns. The pad loop it replaces was
# hand-written in three examples, each counting characters.
_t='hi';    tuish_str_pad _t 5; assert_eq "$TUISH_SPADDED" 'hi   ' "pad: short string is padded to width"
_t='hello'; tuish_str_pad _t 5; assert_eq "$TUISH_SPADDED" 'hello' "pad: exact fit is untouched"
_t='hello'; tuish_str_pad _t 3; assert_eq "$TUISH_SPADDED" 'hel'   "pad: long string is sliced to width"
_t='';      tuish_str_pad _t 3; assert_eq "$TUISH_SPADDED" '   '   "pad: empty string becomes all padding"
_t='hi';    tuish_str_pad _t 0; assert_eq "$TUISH_SPADDED" ''      "pad: zero width is empty"

# Columns, not characters: two ideographs are four columns, so a width of 6 pads two.
_t='日本'; tuish_str_pad _t 6; assert_eq "$TUISH_SPADDED" '日本  ' "pad: wide chars count their columns"
# An odd budget cannot hold a 2-column glyph: it is dropped, and the pad makes up
# the gap, so the result is still exactly WIDTH columns.
_t='日本'; tuish_str_pad _t 3
_pw=$TUISH_SPADDED; tuish_str_width _pw
assert_eq "$TUISH_SWIDTH" "3" "pad: straddling glyph dropped, pad still fills the field"

test_summary
