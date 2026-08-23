#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests: a framework local must STAY LOCAL.
#
# On ksh93 `local` is an alias for `typeset`, and typeset does not create a local variable
# in a POSIX `f () { ... }` function — only in a ksh-style `function f { ... }` one. Every
# function in this toolkit is POSIX-style. So without compat.sh's tuish_fnfix, every `local`
# in tuish declares a GLOBAL, and a framework helper's scratch variable silently overwrites
# whatever the caller happened to name the same way.
#
# It bit twice, and both were live:
#
#   draw.sh builds a box's top border into `local _top`. A host that keeps its layout row in
#   `_top` (examples/cooperative.sh) got its row replaced by the string "╭────────╮" and
#   handed it to tuish_text as a coordinate. The repo carried this for a while as "a
#   pre-existing ksh box-drawing bug" and test_hosting.sh skipped itself over it.
#
#   event.sh's _tuish_parse_event held the frame depth in `local _base`, and overwrote the
#   `_base` loop variable of the caller driving it — turning the byte sequence
#   "E 91 49 59 50 65" into "E 91 1 59 50 65" and taking 176 modifier tests with it.
#
# These tests call the real framework functions with callers whose variables carry the same
# names, and assert they come back untouched. They pass trivially on bash/zsh/mksh/busybox
# (where `local` works); on ksh93 they are the whole ballgame.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/ord.sh"
. "$TESTS_DIR/../src/tui.sh"
. "$TESTS_DIR/../src/term.sh"
. "$TESTS_DIR/../src/event.sh"
. "$TESTS_DIR/../src/hid.sh"
. "$TESTS_DIR/../src/viewport.sh"
. "$TESTS_DIR/../src/str.sh"
. "$TESTS_DIR/../src/draw.sh"
. "$TESTS_DIR/../src/keybind.sh"

printf 'Unit tests: framework locals stay local\n'

_tuish_write () { :; }
_tuish_out () { :; }

TUISH_LINES=24
TUISH_COLUMNS=80

# The fixup normally runs from tuish_init, which needs a device. Invoke it directly: this
# is exactly what an app gets, minus the terminal.
tuish_fnfix

tuish_ctx_create
TUISH_CTX_ROOT=$TUISH_CTX
tuish_ctx_activate "$TUISH_CTX_ROOT"
tuish_viewport fullscreen

# ─── The box-border leak (draw.sh `local _top` / `local _bot`) ───────────────────
# A host's layout row, named exactly what draw.sh names its border string.

_top=3
_bot=20
tuish_draw_box "$_top" 2 20 5 style=rounded
assert_eq "$_top" "3"  "draw_box does not overwrite the caller's _top"
assert_eq "$_bot" "20" "draw_box does not overwrite the caller's _bot"

# And the real sequence that broke: draw a box, then immediately use the same row for text.
# This is examples/cooperative.sh, line for line.
_top=3
tuish_draw_box "$_top" 2 30 6 style=rounded
tuish_text "$_top" 4 " clock "
assert_eq "$_top" "3" "the row survives draw_box -> text, the way a host uses it"

# ─── The event-parser leak (event.sh `local _base`) ──────────────────────────────
# A caller driving the parser in a loop, with a loop variable named `_base`.

tuish_on_event ':'
tuish_on_redraw ':'

_base=49
_tuish_parse_event "E 91 ${_base} 59 50 65"
assert_eq "$_base" "49" "_tuish_parse_event does not overwrite the caller's _base"
assert_eq "$TUISH_EVENT" "shift-up" "... and it still resolves the sequence"

# Drive it twice, as the modifier suite does: the second iteration is where it broke.
_base=49
for _m in 50 51 53
do
	TUISH_EVENT=''
	_tuish_parse_event "E 91 ${_base} 59 ${_m} 65"
	test -n "$TUISH_EVENT" || TUISH_EVENT='<MISS>'
done
assert_eq "$TUISH_EVENT" "ctrl-up" "the THIRD iteration still resolves — _base was not eaten"

# ─── The general contract ────────────────────────────────────────────────────────
# Common short names an app or a host is likely to use for a loop or a rectangle. None of
# them is reserved, and none of them may be touched.

_i=11 _c=12 _r=13 _w=14 _h=15 _n=16 _row=17 _cur=18 _fn=19 _id=20

tuish_begin
tuish_draw_fill 1 1 10 3
tuish_draw_box 5 5 10 4
tuish_text 2 2 "hello"
tuish_clear_region 1 1 5 2
tuish_end

assert_eq "$_i"   "11" "a framework frame leaves the caller's _i alone"
assert_eq "$_c"   "12" "... _c"
assert_eq "$_r"   "13" "... _r"
assert_eq "$_w"   "14" "... _w"
assert_eq "$_h"   "15" "... _h"
assert_eq "$_n"   "16" "... _n"
assert_eq "$_row" "17" "... _row"
assert_eq "$_cur" "18" "... _cur"
assert_eq "$_fn"  "19" "... _fn"
assert_eq "$_id"  "20" "... _id"

# ─── The name-passing idiom must still work ──────────────────────────────────────
# str.sh reads a variable NAME the caller hands it (docs/str.md — asking a question must not
# cost a fork). ksh-style functions are STATICALLY scoped, so a converted callee could not
# see the name it was given; that is why str.sh is on tuish_fnfix's skip list. Prove the
# idiom survives — including from inside a function, which is the case that broke.

_probe_str () {
	local _t='hello'
	tuish_str_width _t
	test "$TUISH_SWIDTH" -eq 5
}
_probe_str && assert_eq "1" "1" "str_width still reads a caller's LOCAL by name"
_probe_str || assert_eq "0" "1" "str_width still reads a caller's LOCAL by name"

_wide='中文'
tuish_str_width _wide
assert_eq "$TUISH_SWIDTH" "4" "... and still measures wide characters correctly"

# ─── The host table (host.sh's _th_* helpers) ────────────────────────────────────

. "$TESTS_DIR/../src/host.sh"
tuish_fnfix_done=0 2>/dev/null || :
_tuish_fnfix_done=0
tuish_fnfix

_i=1 _id='mine' _c='mine-too'
tuish_host_begin
tuish_host_commit
assert_eq "$_i"  "1"        "tuish_host_commit leaves the caller's _i alone"
assert_eq "$_id" "mine"     "... and _id"
assert_eq "$_c"  "mine-too" "... and _c"

test_summary
