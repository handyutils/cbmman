#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for tuish_str_width display width

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/ord.sh"
. "$TESTS_DIR/../src/tui.sh"
. "$TESTS_DIR/../src/str.sh"


# Probes for the skip-list assertions at the bottom, defined HERE because they have to
# exist before the fixup runs to be converted by it — and named _tuish_* because that is
# the prefix _tuish_fnfix_emit converts. Each one holds the string in a `local` and hands
# the str helper its NAME, which is the shape the whole toolkit is built on.
_tuish_probe_pad ()    { local _s='hi';     tuish_str_pad    _s 5;   TUISH_SPADDED=$TUISH_SPADDED; }
_tuish_probe_left ()   { local _s='日本語'; tuish_str_left   _s 2;   TUISH_SLEFT=$TUISH_SLEFT; }
_tuish_probe_right ()  { local _s='日本語'; tuish_str_right  _s 2;   TUISH_SRIGHT=$TUISH_SRIGHT; }
_tuish_probe_char ()   { local _s='日本語'; tuish_str_char   _s 1;   TUISH_SCHAR=$TUISH_SCHAR; }
_tuish_probe_window () { local _s='日本語'; tuish_str_window _s 0 4; TUISH_SWINDOW=$TUISH_SWINDOW; }
_tuish_probe_width ()  { local _s='日本語'; tuish_str_width  _s;     TUISH_SWIDTH=$TUISH_SWIDTH; }

# Exercise the SHIPPED configuration. tuish_fnfix normally fires from tuish_init, which unit
# tests deliberately never call (they stub the device) — so without this, every suite here
# would validate the framework with its ksh `local` still leaking, i.e. not the library that
# actually runs. It is a no-op on every shell whose `local` already works.
command -v tuish_fnfix >/dev/null 2>&1 && tuish_fnfix

_tuish_write () { :; }
tuish_on_event () { :; }

printf 'Unit tests: tuish_str_width display width\n'

# --- ASCII ---
_t='hello'
tuish_str_width _t
assert_eq "$TUISH_SWIDTH" "5" "width: ASCII hello"

_t=''
tuish_str_width _t
assert_eq "$TUISH_SWIDTH" "0" "width: empty string"

_t='a'
tuish_str_width _t
assert_eq "$TUISH_SWIDTH" "1" "width: single ASCII"

_t='hello world'
tuish_str_width _t
assert_eq "$TUISH_SWIDTH" "11" "width: ASCII with space"

_t='@#%^&()+='
tuish_str_width _t
assert_eq "$TUISH_SWIDTH" "9" "width: ASCII punctuation"

# --- CJK ideographs (each 2 columns) ---
_t='中'
tuish_str_width _t
assert_eq "$TUISH_SWIDTH" "2" "width: single CJK"

_t='中文'
tuish_str_width _t
assert_eq "$TUISH_SWIDTH" "4" "width: two CJK"

_t='日本語'
tuish_str_width _t
assert_eq "$TUISH_SWIDTH" "6" "width: three CJK (Japanese)"

# --- Mixed ASCII + CJK ---
_t='hi中文'
tuish_str_width _t
assert_eq "$TUISH_SWIDTH" "6" "width: mixed ASCII+CJK"

_t='中a文b'
tuish_str_width _t
assert_eq "$TUISH_SWIDTH" "6" "width: interleaved CJK+ASCII"

# --- Fullwidth Latin (U+FF01-U+FF60) ---
_t='Ａ'
tuish_str_width _t
assert_eq "$TUISH_SWIDTH" "2" "width: fullwidth A"

# --- Hangul ---
_t='한'
tuish_str_width _t
assert_eq "$TUISH_SWIDTH" "2" "width: Hangul syllable"

_t='한글'
tuish_str_width _t
assert_eq "$TUISH_SWIDTH" "4" "width: two Hangul syllables"

# --- Latin accented (1 column each) ---
_t='café'
tuish_str_width _t
assert_eq "$TUISH_SWIDTH" "4" "width: Latin accented"

_t='über'
tuish_str_width _t
assert_eq "$TUISH_SWIDTH" "4" "width: Latin umlaut"

# --- Combining marks (zero width) ---
# Base letter + U+20DB (combining mark for symbols, U+20D0-U+20FF range)
_t='a⃛'
tuish_str_width _t
assert_eq "$TUISH_SWIDTH" "1" "width: base + combining mark for symbols"

# Base letter + U+1DC0 (combining diacritical marks supplement, U+1DC0-U+1DFF)
_t='a᷀'
tuish_str_width _t
assert_eq "$TUISH_SWIDTH" "1" "width: base + combining diacritical supplement"

# Decomposed Hangul syllable: leading U+1100 (width 2) + conjoining medial
# U+1161 (0) + conjoining final U+11A8 (0) = 2 columns total.
_t='각'
tuish_str_width _t
assert_eq "$TUISH_SWIDTH" "2" "width: decomposed Hangul (leading + conjoining jamo)"

# --- the skip list is not optional ---
# Every helper that dereferences a variable NAME must be in compat.sh's
# _tuish_fnfix_skip. Converted to ksh-style it gets its own scope, and the caller's
# local — the name it was just handed — becomes invisible: on ksh93 that is not a wrong
# answer but a hard `parameter not set`, which takes the app down. It reads as correct on
# every other shell, and on ksh only when the caller happens to be an APP function (whose
# `local` leaks to global there), so the trap is easy to walk into and cost-free to guard.
# The probes above the fixup call are converted, so a name dropped from the list fails here.
_tuish_probe_pad;    assert_eq "$TUISH_SPADDED" 'hi   ' "skip list: tuish_str_pad sees a converted caller's local"
_tuish_probe_left;   assert_eq "$TUISH_SLEFT"   '日本'  "skip list: tuish_str_left (via _tuish_char_byte_off) sees it"
_tuish_probe_right;  assert_eq "$TUISH_SRIGHT"  '語'    "skip list: tuish_str_right sees it"
_tuish_probe_char;   assert_eq "$TUISH_SCHAR"   '本'    "skip list: tuish_str_char sees it"
_tuish_probe_window; assert_eq "$TUISH_SWINDOW" '日本'  "skip list: tuish_str_window sees it"
_tuish_probe_width;  assert_eq "$TUISH_SWIDTH"  '6'     "skip list: tuish_str_width sees it"

test_summary
