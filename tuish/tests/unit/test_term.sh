#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for term.sh output primitives that are sensitive to how each
# shell's printf/echo parses escape sequences.
#
# Regression coverage for REPORT.md finding #8: DECSC/DECRC are ESC
# followed by a digit, and no single backslash escape survives every
# shell — `\x1b7` becomes hex 0x1b7 on ksh93, `\0337` becomes octal 337
# on mksh, both swallowing the digit. The fix emits a literal ESC byte.
# Run under every target shell to catch a per-shell regression.

set -uf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/ord.sh"
. "$TESTS_DIR/../src/tui.sh"
. "$TESTS_DIR/../src/term.sh"


# Exercise the SHIPPED configuration. tuish_fnfix normally fires from tuish_init, which unit
# tests deliberately never call (they stub the device) — so without this, every suite here
# would validate the framework with its ksh `local` still leaking, i.e. not the library that
# actually runs. It is a no-op on every shell whose `local` already works.
command -v tuish_fnfix >/dev/null 2>&1 && tuish_fnfix

printf 'Unit tests: term.sh output primitives\n'

# Independent reference ESC byte (not via the ord table the code uses).
_esc=$(printf '\033')

# ─── DECSC: ESC 7 ────────────────────────────────────────────────
_out=$( _tuish_buffering=0; tuish_save_cursor )
assert_eq "$_out" "${_esc}7" "save_cursor emits ESC 7 (DECSC)"

# ─── DECRC: ESC 8 ────────────────────────────────────────────────
_out=$( _tuish_buffering=0; tuish_restore_cursor )
assert_eq "$_out" "${_esc}8" "restore_cursor emits ESC 8 (DECRC)"

# ─── Same through the output buffer (begin/flush) ────────────────
# The buffer is flushed with one printf/echo, so the digit must still
# survive when the ESC byte is concatenated with later sequences.
tuish_begin
tuish_save_cursor
_tuish_write '\033[2K'
tuish_restore_cursor
_out=$( tuish_end )
assert_eq "$_out" "${_esc}7${_esc}[2K${_esc}8" "buffered save/clear/restore round-trips"

# ─── Sequence builders: build into TUISH_SEQ (literal ESC), write nothing ──
# The batched-render helpers must (a) use a raw ESC byte so the sequence can be
# embedded in a tuish_print row string, and (b) emit nothing themselves.
tuish_fg_seq 4;            assert_eq "$TUISH_SEQ" "${_esc}[34m"     "fg_seq 4 -> ESC[34m"
tuish_bg_seq 4;            assert_eq "$TUISH_SEQ" "${_esc}[44m"     "bg_seq 4 -> ESC[44m"
tuish_sgr_seq 7;           assert_eq "$TUISH_SEQ" "${_esc}[7m"      "sgr_seq 7 -> ESC[7m"
tuish_sgr_reset_seq;       assert_eq "$TUISH_SEQ" "${_esc}[0m"      "sgr_reset_seq -> ESC[0m"
tuish_style_seq bold fg=1; assert_eq "$TUISH_SEQ" "${_esc}[0;1;31m" "style_seq bold fg=1"
# The plain writer delegates to tuish_style_seq — same bytes, but written out.
_out=$( _tuish_buffering=0; tuish_style bold fg=1 )
assert_eq "$_out" "${_esc}[0;1;31m" "style (writer) emits the style_seq bytes"
_out=$( _tuish_buffering=0; tuish_fg_seq 4 )
assert_eq "$_out" "" "fg_seq writes nothing (only sets TUISH_SEQ)"

# The linchpin: an embedded seq + %-bearing text round-trips through tuish_print
# — the text's % is escaped for the flush printf while the raw-ESC seq passes
# through verbatim (so a batched row of colour + arbitrary text is correct).
tuish_fg_seq 2
_row="${TUISH_SEQ}50%done"
_out=$( _tuish_buffering=0; tuish_print "$_row" )
assert_eq "$_out" "${_esc}[32m50%done" "embedded seq + % text survives tuish_print"

# ─── tuish_put_at: place then print, no width computation ────────
TUISH_LINES=24
_out=$( _tuish_buffering=0; tuish_put_at 1 1 'hi' )
assert_eq "$_out" "${_esc}[1;1Hhi" "put_at places (vmove) then prints"

# ─── The caret's SHAPE is declared, and rides with the caret ─────
# Position and visibility have always been re-declared every frame. The shape used to be a
# single escape written once at setup — which works standalone and is silently thrown away
# when hosted, because a mount happens inside the host's event handler and the rAF path
# discards that frame's content. So the shape is a DECLARATION now, and tuish_cursor emits
# it: no caret, no shape, and the context that shows the caret last decides what it is.
_out=$( _tuish_buffering=0; tuish_cursor_shape 6 )
assert_eq "$_out" "" "cursor_shape writes NOTHING — it declares (this is the whole fix)"

tuish_cursor_shape 6
assert_eq "$_tuish_cursor_shape" "6" "cursor_shape 6 -> the context declares a steady bar"
tuish_cursor_shape 0
assert_eq "$_tuish_cursor_shape" "" "cursor_shape 0 means NO OPINION, not DECSCUSR 0"
tuish_cursor_shape
assert_eq "$_tuish_cursor_shape" "" "... and so does no argument at all"

# The shape goes out with the caret: place, shape, show — in that order.
# (tuish_end is captured in a subshell above, so the parent is still inside that frame —
# open ours from a clean depth.)
TUISH_VIEW_ROWS=24; TUISH_VIEW_COLS=80
_tuish_buffering=0; _tuish_cursor_shape_dev=''
tuish_cursor_shape 6
tuish_begin; tuish_cursor 1 1; _out=$( tuish_end )
assert_eq "$_out" "${_esc}[1;1H${_esc}[6 q${_esc}[?25h" "the shape rides out with the caret"

# ... but only when the device does not already have it. Re-sending DECSCUSR every frame
# re-arms a real terminal's blink phase, and xterm.js re-fires its option change with it.
_tuish_buffering=0
tuish_begin; tuish_cursor 2 3; _out=$( tuish_end )
assert_eq "$_out" "${_esc}[2;3H${_esc}[?25h" "an unchanged shape costs no bytes"

# A context with no opinion shows a caret and says nothing about its shape.
_tuish_buffering=0; _tuish_cursor_shape_dev=''
tuish_cursor_shape 0
tuish_begin; tuish_cursor 1 1; _out=$( tuish_end )
assert_eq "$_out" "${_esc}[1;1H${_esc}[?25h" "no declaration, no DECSCUSR — the caret is still shown"

# ─── Synchronized output (DECSET 2026) ───────────────────────────
# One buffer is one write, but one write is not one repaint: the browser lane hands
# stdout to xterm.js in ~4KiB chunks, so a frame can reach the eye as the erase first
# and the text a frame later. BSU/ESU makes the frame atomic at the far end.

# DEVICE state, off until tuish_init raises it — which is why every assertion above
# this line still sees exactly the bytes under test.
_tuish_buffering=0
assert_eq "$_tuish_sync" "0" "sync is off until the device comes up"
_out=$( _tuish_buffering=0; tuish_save_cursor )
assert_eq "$_out" "${_esc}7" "sync off: the write is untouched"

_tuish_sync=1
_out=$( _tuish_buffering=0; tuish_save_cursor )
assert_eq "$_out" "${_esc}[?2026h${_esc}7${_esc}[?2026l" "sync on: one BSU/ESU pair around the write"

# The pair wraps the whole frame, not each escape inside it. (Each frame here opens
# from a clean depth: the tuish_end that closes it runs in a subshell, so the parent
# is left holding the frame it opened.)
_tuish_buffering=0
tuish_begin; tuish_move 3 4; tuish_print 'hi'; _out=$( tuish_end )
assert_eq "$_out" "${_esc}[?2026h${_esc}[3;4Hhi${_esc}[?2026l" "one pair per frame, not per write"

# A held write is a CHILD's frame being spliced into its host's. It is not a device
# write yet, so wrapping it here would nest a pair inside the host's — and the host's
# tuish_end is what actually reaches the terminal.
_tuish_buffering=0; _tuish_holding=1; _tuish_hold=''
tuish_begin; tuish_print 'x'; tuish_end
assert_eq "$_tuish_hold" "x" "a held (child) frame is not wrapped — the host's write is"
_tuish_holding=0; _tuish_hold=''

# printf is the output lane on most shells, so the frame is a format string. A literal
# percent in app content must survive the added prefix.
_tuish_buffering=0
tuish_begin; tuish_print '100%'; _out=$( tuish_end )
assert_eq "$_out" "${_esc}[?2026h100%${_esc}[?2026l" "a literal percent survives the wrap"

_tuish_sync=0

test_summary
