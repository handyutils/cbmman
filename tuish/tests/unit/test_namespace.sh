#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit test: tuish leaves NOTHING in a caller's namespace.
#
# The flip side of test_scope.sh. compat.sh's tuish_fnfix makes `local` mean local on ksh93,
# but it cannot cover everything: a handful of functions must stay POSIX (the skip list —
# the trap path, tuish_run, and the string readers that dereference a caller-supplied NAME),
# and a handful run at SOURCE time, before the fixup exists to be applied. On ksh their
# locals are globals, permanently.
#
# That is survivable only if every one of them lives inside a name tuish owns. It did not:
# tuish used to leave `_i`, `_n`, `_chr`, `_loc`, `_top` and `_bot` sitting in the caller's
# namespace — the exact names an app gives a loop counter or a layout row, and exactly the
# collision class that produced the box-border bug. They are prefixed now.
#
# This asserts the perimeter, and it is the test that would have caught it: source
# everything, snapshot the variables, exercise a representative slice of the API, and diff.
# Anything new that is not tuish's own name is a leak.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

# A BEFORE/AFTER diff done in-shell. No temp files and no `comm`: this runs on five shells,
# and a unit test that needs a writable /tmp is a portability bug waiting to happen.
_ns_names () { set | grep '^[A-Za-z_][A-Za-z0-9_]*=' | sed 's/=.*//' | sort -u | tr '\n' ' '; }

# Snapshot BEFORE tuish is sourced at all.
#
# That ordering is the whole point. Some of the leaks happen at SOURCE time — ord.sh builds
# its 256-entry character table, draw.sh probes the locale — and those functions run before
# tuish_fnfix exists to be applied to them, so their locals are globals on ksh no matter
# what. Snapshot after sourcing and they are already in the "before" set: invisible.
_ns_before=" $(_ns_names) "

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
. "$TESTS_DIR/../src/buf.sh"
. "$TESTS_DIR/../src/canvas.sh"
. "$TESTS_DIR/../src/host.sh"

printf 'Unit tests: namespace hygiene\n'

_tuish_write () { :; }
_tuish_out () { :; }

TUISH_LINES=24
TUISH_COLUMNS=80

# The SOURCE-TIME API, exercised BEFORE tuish_fnfix — because that is when an app calls it,
# and it is the half of the perimeter that is easiest to forget. examples/editor.sh declares
# its field set at source time; tuish_ctx_register is called at source time by every module.
# Neither can rely on the fixup, so both must be prefix-clean by hand. tuish_ctx_declare was
# not, and leaked `_set` and `_n` until this test grew a case for it.
_np_field=0
tuish_ctx_register _np_field
tuish_ctx_declare _np_set _np_field

tuish_fnfix
tuish_ctx_create
TUISH_CTX_ROOT=$TUISH_CTX
tuish_ctx_activate "$TUISH_CTX_ROOT"
tuish_ctx_fields _np_set
tuish_viewport fullscreen

# A representative slice: the drawing path, the string readers (which stay POSIX and so leak
# by construction on ksh), buffers, the bind table, and the host table.
_ns_probe='hello 中文 world'
tuish_str_width _ns_probe
tuish_str_window _ns_probe 1 5
tuish_str_len _ns_probe
tuish_begin
tuish_draw_box 4 4 12 4 style=rounded
tuish_draw_fill 2 2 6 2
tuish_text 3 3 'x'
tuish_clear_region 1 1 4 2
tuish_end
tuish_bind 'char q' ':'
tuish_buf_append NSBUF 'a line'
tuish_host_begin
tuish_host_commit

_ns_leaked=''
for _ns_v in $(_ns_names)
do
	case "$_ns_before" in *" $_ns_v "*) continue ;; esac                      # already existed
	case "$_ns_v" in _tuish*|TUISH_*|_TUISH_*|_th_*|_tx_*) continue ;; esac   # tuish's own
	case "$_ns_v" in _ns_*|_np_*) continue ;; esac                                # this test's
	# compat.sh forces the C locale on purpose, and says so (docs/compatibility.md): every
	# string operation in the toolkit is byte-oriented. It saves the caller's originals in
	# _tuish_orig_* first. Declared, not leaked.
	case "$_ns_v" in LC_ALL|LC_CTYPE) continue ;; esac
	_ns_leaked="${_ns_leaked}${_ns_leaked:+ }$_ns_v"
done

assert_eq "$_ns_leaked" "" "tuish leaves NOTHING outside its own namespace"

test_summary
