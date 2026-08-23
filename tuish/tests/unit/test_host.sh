#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for src/host.sh — hosting several live children in one loop.
#
# No terminal: tuish_init is never called, and _tuish_out is stubbed, so nothing reaches a
# device. The children are two-line fakes that record what they were asked to do; what is
# under test is the HOST's behaviour — reconciliation, clipping, hit testing, focus,
# paint ordering and scroll chaining.

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
. "$TESTS_DIR/../src/keybind.sh"
. "$TESTS_DIR/../src/host.sh"


# Exercise the SHIPPED configuration. tuish_fnfix normally fires from tuish_init, which unit
# tests deliberately never call (they stub the device) — so without this, every suite here
# would validate the framework with its ksh `local` still leaking, i.e. not the library that
# actually runs. It is a no-op on every shell whose `local` already works.
command -v tuish_fnfix >/dev/null 2>&1 && tuish_fnfix

printf 'Unit tests: hosting (src/host.sh)\n'

TUISH_LINES=30
TUISH_COLUMNS=100

_tuish_out () { :; }                 # nothing reaches a device
stty () { :; }                       # ... and no device is touched

tuish_ctx_create
TUISH_CTX_ROOT=$TUISH_CTX
tuish_ctx_activate "$TUISH_CTX_ROOT"
TUISH_VIEW_ROWS=$TUISH_LINES
TUISH_VIEW_COLS=$TUISH_COLUMNS

# --- The children -------------------------------------------------------------
# _mounts counts how many times each was MOUNTED, which is the thing reconciliation is
# supposed to avoid; _paints records paint ORDER, which is what the caret depends on.
_mounts_a=0; _mounts_b=0
_paints=''
_wheel_a=0
_a_can_scroll=1                       # flip to 0 to make child A decline the wheel

_a_paint () { _paints="$_paints a"; }
_b_paint () { _paints="$_paints b"; }

# NOTE: no tuish_init. A real hosted app calls it (it ADOPTS the context the mount made,
# because the device is already up); here there is no device, and tuish_init would bring
# one up and take the context with it. These are fakes — they just register themselves in
# whatever context host.sh mounted them into.
_a_setup ()
{
	_mounts_a=$(( _mounts_a + 1 ))
	_tuish_mouse=1
	tuish_on_redraw _a_paint
	tuish_bind 'wdown' '_wheel_a=$((_wheel_a + 1)); test $_a_can_scroll -eq 0 && tuish_pass'
	tuish_bind 'char x' ':'
}

_b_setup ()
{
	_mounts_b=$(( _mounts_b + 1 ))
	_tuish_mouse=1
	tuish_on_redraw _b_paint
	tuish_bind '*' 'tuish_pass'        # a picture: acts on nothing
}

# --- Reconciliation -----------------------------------------------------------
# The point of an id: it survives a rebuild, so a host that re-declares its children for a
# reason that has nothing to do with most of them does not tear them all down. Remounting
# is not free — a mount PAINTS.
tuish_host_pane 3 2 40 10

tuish_host_begin
tuish_host_slot alpha _a_setup '' 3 2 20 4
tuish_host_commit
assert_eq "$_mounts_a" "1" "reconcile: a new child is mounted"

tuish_host_begin
tuish_host_slot alpha _a_setup '' 3 2 20 4     # same id, same rect
tuish_host_commit
assert_eq "$_mounts_a" "1" "reconcile: an unchanged child is NOT remounted"

tuish_host_begin
tuish_host_slot alpha _a_setup '' 6 2 20 4     # same id, MOVED (a scroll)
tuish_host_commit
assert_eq "$_mounts_a" "1" \
	"reconcile: a child that only MOVED is reseated, not remounted (the rect is not its identity)"

tuish_host_begin
tuish_host_slot alpha _a_setup '' 6 2 20 4
tuish_host_slot beta  _b_setup '' 3 24 12 4    # a second child appears
tuish_host_commit
assert_eq "$_mounts_a" "1" "reconcile: adding a sibling does not remount the first"
assert_eq "$_mounts_b" "1" "reconcile: ... and the new one mounts"

tuish_host_ctx alpha; _ctx_a=$TUISH_HOST_CTX
assert_eq "$(test -n "$_ctx_a" && echo yes)" "yes" "reconcile: the surviving child kept its context"

tuish_host_begin
tuish_host_slot beta _b_setup '' 3 24 12 4     # alpha is gone from the declaration
tuish_host_commit
tuish_host_ctx alpha
assert_eq "$TUISH_HOST_CTX" "" "reconcile: a child that vanished from the list is unmounted"

# --- Off-pane children unmount, half-visible ones clip -------------------------
tuish_host_begin
tuish_host_slot beta  _b_setup '' 3 24 12 4
tuish_host_slot alpha _a_setup '' 40 2 20 4    # scrolled far below the pane (rows 3..12)
tuish_host_commit
tuish_host_ctx alpha
assert_eq "$TUISH_HOST_CTX" "" "offpane: a child scrolled wholly out of sight is unmounted"

tuish_host_begin
tuish_host_slot beta  _b_setup '' 3 24 12 4
tuish_host_slot alpha _a_setup '' 1 2 20 4     # top two rows above the pane
tuish_host_commit
tuish_host_ctx alpha; _ctx_a=$TUISH_HOST_CTX
assert_eq "$(test -n "$_ctx_a" && echo yes)" "yes" "clip: a HALF-visible child stays mounted"

# It is occluded, not resized: it still thinks it is 4 rows tall, or it would reflow as
# you scrolled past it.
tuish_ctx_activate "$_ctx_a"
_rows=$TUISH_VIEW_ROWS
_lrmin=$_tuish_base_lrmin
tuish_ctx_activate "$TUISH_CTX_ROOT"
assert_eq "$_rows" "4" "clip: ... and keeps its full height — occluded, not reflowed"
assert_eq "$_lrmin" "3" "clip: ... with its first two rows clipped away (pane starts at row 3)"

# --- Hit testing is clip-aware ------------------------------------------------
# You cannot click what you cannot see. alpha spans screen rows 1..4, but rows 1-2 are
# behind the host's chrome.
tuish_host_at 5 2
assert_eq "$TUISH_HOST_HIT" "" "hit: the hidden half of a clipped child is not clickable"
tuish_host_at 5 3
assert_eq "$TUISH_HOST_HIT" "alpha" "hit: its visible half is"
tuish_host_at 5 20
assert_eq "$TUISH_HOST_HIT" "" "hit: empty pane is nobody's"

assert_eq "$(tuish_host_owns_row 3 && echo yes || echo no)" "yes" \
	"rows: a host asking what to paint around is told row 3 belongs to a child"
assert_eq "$(tuish_host_owns_row 2 && echo yes || echo no)" "no" \
	"rows: ... but not the row above the pane"

# --- Paint order: the focused child LAST --------------------------------------
# The caret depends on it: a child shows the cursor where it wants it, and the next child
# to paint would drag the terminal's cursor off into the middle of its own box.
tuish_host_begin
tuish_host_slot alpha _a_setup '' 3 2 20 4
tuish_host_slot beta  _b_setup '' 3 24 12 4
tuish_host_commit

_paints=''
tuish_host_focus alpha
tuish_begin; tuish_host_paint; tuish_end
assert_eq "$_paints" " b a" "paint: the FOCUSED child is painted last"

_paints=''
tuish_host_focus beta
tuish_begin; tuish_host_paint; tuish_end
assert_eq "$_paints" " a b" "paint: ... whichever one it is"

_paints=''
tuish_host_focus ''
tuish_begin; tuish_host_paint; tuish_end
assert_eq "$_paints" " a b" "paint: with nothing focused, declaration order"

# --- Routing and scroll chaining ----------------------------------------------
tuish_host_focus ''

TUISH_RAW='M 0 5 4'                            # a click inside alpha
_tuish_parse_event "$TUISH_RAW"                # decode it in the host's frame
tuish_host_route || :
assert_eq "$TUISH_HOST_FOCUS" "alpha" "route: a click focuses the child under the pointer"

TUISH_RAW='M 65 5 4'                           # wheel down, over alpha
_tuish_parse_event "$TUISH_RAW"
_a_can_scroll=1
if tuish_host_route; then _took=1; else _took=0; fi
assert_eq "$_wheel_a" "1" "chain: the wheel reaches the child under the pointer"
assert_eq "$_took" "1"    "chain: a child that ACTS on the wheel consumes it"

TUISH_RAW='M 65 5 4'
_tuish_parse_event "$TUISH_RAW"
_a_can_scroll=0                                # already at the bottom: it passes
if tuish_host_route; then _took=1; else _took=0; fi
assert_eq "$_wheel_a" "2" "chain: the binding still runs"
assert_eq "$_took" "0"    "chain: ... but a child that DECLINES hands the event back to the host"

# The same wheel over a child that has no wheel binding at all.
TUISH_RAW='M 65 30 4'                          # over beta
_tuish_parse_event "$TUISH_RAW"
if tuish_host_route; then _took=1; else _took=0; fi
assert_eq "$_took" "0" "chain: a child with no binding for it never swallows it"

# A MODAL child owns its region: there is nothing behind it to scroll, so it consumes.
tuish_host_begin
tuish_host_slot solo _a_setup '' 3 2 40 10 modal
tuish_host_commit
tuish_host_focus solo
TUISH_RAW='M 65 5 4'
_tuish_parse_event "$TUISH_RAW"
_a_can_scroll=0                                # it declines...
if tuish_host_route; then _took=1; else _took=0; fi
assert_eq "$_took" "1" "chain: ... but a MODAL child consumes the event anyway"

# A modal child declared the way the DOCS said to declare it. The flag was documented as 1
# and compared against the string 'modal', so the documented form quietly produced a child
# that was not modal at all.
tuish_host_begin
tuish_host_slot solo _a_setup '' 3 2 40 10 1
tuish_host_commit
tuish_host_focus solo
TUISH_RAW='M 65 5 4'
_tuish_parse_event "$TUISH_RAW"
_a_can_scroll=0
if tuish_host_route; then _took=1; else _took=0; fi
assert_eq "$_took" "1" "modal: the documented '1' spelling means modal, like the word does"

# --- Painting around the children ---------------------------------------------
# What a host actually needs to know before it paints a row is not "does a child own this
# row" but "which CELLS of it are still mine". Two children side by side leave a GAP
# between them, and that gap is the host's: a host told only the outer bounds of the
# children never repaints it, and last frame's text stands there for good.
tuish_host_pane 3 2 40 10
tuish_host_begin
tuish_host_slot alpha _a_setup '' 3 2  20 4    # cols 2..21
tuish_host_slot beta  _b_setup '' 3 24 12 4    # cols 24..35
tuish_host_commit

tuish_host_row_free 3 2 40 && _free=$TUISH_HOST_SEGS || _free='(none)'
assert_eq "$_free" "22 2 36 6" \
	"free: the GAP between two children is the host's, and so is the tail past them"

tuish_host_row_free 8 2 40 && _free=$TUISH_HOST_SEGS || _free='(none)'
assert_eq "$_free" "2 40" "free: a row with no children on it is the host's outright"

tuish_host_row_free 3 2 20 && _free=$TUISH_HOST_SEGS || _free='(none)'
assert_eq "$_free" "(none)" \
	"free: a span a child covers outright leaves nothing to paint (and says so)"

# Clip-aware, like everything else here: a child scrolled above the pane owns nothing on
# the rows it nominally covers, because it cannot be seen there.
tuish_host_begin
tuish_host_slot alpha _a_setup '' 1 2 20 4     # rows 1..4, pane starts at 3
tuish_host_commit
tuish_host_row_free 3 2 40 && _free=$TUISH_HOST_SEGS || _free='(none)'
assert_eq "$_free" "22 20" "free: a half-clipped child still owns its visible half"

# --- Focus is a variable, not a fork ------------------------------------------
tuish_host_begin
tuish_host_slot alpha _a_setup '' 3 2  20 4
tuish_host_slot beta  _b_setup '' 3 24 12 4
tuish_host_commit

tuish_host_focus alpha
assert_eq "$TUISH_HOST_FOCUS" "alpha" "focus: the id is readable as a plain variable"
tuish_host_focus
assert_eq "$TUISH_HOST_FOCUS" "" "focus: no argument means nobody — the host has it"

# The caret path: a focused child that goes away must not leave the focus pointing at it.
tuish_host_focus alpha
tuish_host_begin
tuish_host_slot beta _b_setup '' 3 24 12 4     # alpha is gone
tuish_host_commit
assert_eq "$TUISH_HOST_FOCUS" "" "focus: unmounting the focused child hands the keyboard back"

# --- Repainting ONE child ------------------------------------------------------
tuish_host_begin
tuish_host_slot alpha _a_setup '' 3 2  20 4
tuish_host_slot beta  _b_setup '' 3 24 12 4
tuish_host_commit

_paints=''
tuish_begin; tuish_host_render beta; tuish_end
assert_eq "$_paints" " b" "render: one child, by id — nobody else repaints"

tuish_host_render nosuch && _r=0 || _r=1
assert_eq "$_r" "1" "render: an id nobody has is a no-op, and says so"

# --- The pane can be taken away ------------------------------------------------
# No args means no pane, the way tuish_ctx_clip means it. It used to store three spaces,
# which is not empty — so every later query parsed garbage out of it.
tuish_host_pane
tuish_host_begin
tuish_host_slot alpha _a_setup '' 40 2 20 4    # far below where the pane used to be
tuish_host_commit
tuish_host_ctx alpha; _ctx_a=$TUISH_HOST_CTX
assert_eq "$(test -n "$_ctx_a" && echo yes)" "yes" \
	"pane: with no pane there is nothing to be off the edge of — the child stays"

# --- The caret's shape is negotiated by PAINT ORDER ---------------------------
# The focused child paints last so the caret ends the frame where you are typing. The shape
# rides with the caret, so it inherits that ordering for nothing: whichever child shows the
# caret last says what it looks like. No host API is involved, and that is the point.
_captured=''
_tuish_out () { _captured="${_captured}${1:-}"; }

_a_paint () { _paints="$_paints a"; tuish_cursor_shape 2; tuish_cursor 1 1; }   # block
_b_paint () { _paints="$_paints b"; tuish_cursor_shape 6; tuish_cursor 1 1; }   # bar

tuish_host_begin
tuish_host_slot alpha _a_setup '' 3 2  20 4
tuish_host_slot beta  _b_setup '' 3 24 12 4
tuish_host_commit

_last_shape ()   # the DECSCUSR the frame LEAVES the terminal in -> _shape
{
	local _rest="$1" _seg
	_shape=''
	while test -n "$_rest"
	do
		case "$_rest" in
			*" q"*) _seg="${_rest%%" q"*}"      # everything before the next DECSCUSR
			        _shape="${_seg#"${_seg%?}"}"   # ... its last char: the shape digit
			        _rest="${_rest#*" q"}";;
			*) break;;
		esac
	done
}

_captured=''; _tuish_cursor_shape_dev=''
tuish_host_focus beta
tuish_begin; tuish_host_paint; tuish_end
_last_shape "$_captured"
assert_eq "$_shape" "6" "caret: the FOCUSED child's shape is the one the frame ends with"

_captured=''; _tuish_cursor_shape_dev=''
tuish_host_focus alpha
tuish_begin; tuish_host_paint; tuish_end
_last_shape "$_captured"
assert_eq "$_shape" "2" "caret: ... and it follows the focus"

# A child that unmounts must not reset the caret DEVICE-WIDE. It used to: the editor put a
# shape reset in its fini hook, and host.sh runs that hook on every unmount — so leaving one
# snippet's editor turned the caret to a block under another one still being typed into.
_captured=''
tuish_host_begin
tuish_host_slot alpha _a_setup '' 3 2 20 4     # beta is gone
tuish_host_commit
case "$_captured" in
	*" q"*) _r=reset;;
	*) _r=quiet;;
esac
assert_eq "$_r" "quiet" "caret: unmounting a child touches nobody else's caret"

test_summary
