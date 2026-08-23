#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for the context system (src/tui.sh): region seating, the region-safe
# erase, and the cooperative idle-tick negotiation.
#
# These run WITHOUT a terminal: tuish_init is never called, so no device comes up.
# We build contexts by hand (tuish_ctx_create + _tuish_ctx_seat via
# tuish_ctx_create_region) and drive the marshalling directly. The negotiation math
# is pure integer arithmetic on per-context registers, which is exactly what we want
# pinned — the live behaviour is covered by tests/integration/test_cooperative.sh.

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
. "$TESTS_DIR/../src/canvas.sh"
. "$TESTS_DIR/../src/str.sh"
. "$TESTS_DIR/../src/keybind.sh"


# Exercise the SHIPPED configuration. tuish_fnfix normally fires from tuish_init, which unit
# tests deliberately never call (they stub the device) — so without this, every suite here
# would validate the framework with its ksh `local` still leaking, i.e. not the library that
# actually runs. It is a no-op on every shell whose `local` already works.
command -v tuish_fnfix >/dev/null 2>&1 && tuish_fnfix

printf 'Unit tests: contexts, regions, idle negotiation\n'

TUISH_LINES=30
TUISH_COLUMNS=100

# The root context, without bringing up the device.
tuish_ctx_create
TUISH_CTX_ROOT=$TUISH_CTX
tuish_ctx_activate "$TUISH_CTX_ROOT"
tuish_viewport fullscreen >/dev/null 2>&1 || :

# --- Region seating ----------------------------------------------------------
# A child seated at row 5, col 20, 30x10 gets its own origin and bounds; the root
# is untouched. Column origin is 0-based (TUISH_VIEW_LEFT), row origin 1-based.
tuish_ctx_create_region 5 20 30 10
_child=$TUISH_CTX
assert_eq "$TUISH_VIEW_TOP"  "5"  "region: view top is the region row"
assert_eq "$TUISH_VIEW_LEFT" "19" "region: view left is the 0-based region column"
assert_eq "$TUISH_VIEW_COLS" "30" "region: view cols is the region width"
assert_eq "$TUISH_VIEW_ROWS" "10" "region: view rows is the region height"
assert_eq "$_tuish_owns_dev" "0"  "region: a seated child does NOT own the device"

tuish_ctx_activate "$TUISH_CTX_ROOT"
assert_eq "$_tuish_owns_dev" "1"  "region: the root DOES own the device"
assert_eq "$TUISH_VIEW_LEFT" "0"  "region: the root keeps column origin 0"

# --- Re-seating (tuish_ctx_reseat) -------------------------------------------
# The host moves the child's rectangle (a resize relayout). Formerly every host
# hand-copied this field poking; it now lives in the library.
tuish_ctx_reseat "$_child" 8 40 12 6
assert_eq "$_tuish_ctx_active" "$TUISH_CTX_ROOT" "reseat: the host stays active"
tuish_ctx_activate "$_child"
assert_eq "$TUISH_VIEW_TOP"  "8"  "reseat: new row origin"
assert_eq "$TUISH_VIEW_LEFT" "39" "reseat: new column origin"
assert_eq "$TUISH_VIEW_COLS" "12" "reseat: new width"
assert_eq "$TUISH_VIEW_ROWS" "6"  "reseat: new height"
assert_eq "$_tuish_rgn_cols" "12" "reseat: region width tracks the viewport"
tuish_ctx_activate "$TUISH_CTX_ROOT"

# --- Region-safe erase (tuish_clear_to_edge) ---------------------------------
# tuish_clear_to_eol emits ESC[K, which erases to the end of the PHYSICAL line and
# therefore punches out of a hosted region into the host's chrome. tuish_clear_to_edge
# is bounded by the drawable width. Capture what each one writes.
tuish_ctx_activate "$_child"      # a 12-wide region at column 40
_tuish_buffering=1; _tuish_buf=''
tuish_clear_to_eol
assert_eq "$_tuish_buf" '\033[K' "clear_to_eol: still the raw ESC[K (unbounded)"

_tuish_buf=''
tuish_clear_to_edge 1
# Expect: position at the region's first cell, then exactly VIEW_COLS spaces.
_spaces='            '                     # 12
assert_eq "$_tuish_buf" "\\033[8;40H${_spaces}" \
	"clear_to_edge: writes exactly VIEW_COLS spaces inside the region (no ESC[K)"

_tuish_buf=''
tuish_clear_to_edge 1 5
_spaces8='        '                        # 12 - 5 + 1 = 8
assert_eq "$_tuish_buf" "\\033[8;44H${_spaces8}" \
	"clear_to_edge: honours a start column, still bounded by the region"
_tuish_buffering=0; _tuish_buf=''
tuish_ctx_activate "$TUISH_CTX_ROOT"

# --- Clipped seating: a child scrolled under a pane edge ---------------------
# A live widget in a scrolling document must slide under the pane's edge. That works
# by keeping the child's LAYOUT SIZE while moving its ORIGIN off-pane and narrowing
# its VISIBLE CLIP — three things _tuish_ctx_seat keeps apart. The child must not
# reflow (it still thinks it is full size); it must simply be occluded.
#
# Pane: host rows 10..19 (10 tall). Widget: 8 rows tall, scrolled up by 3, so its
# virtual top is host row 7 and only its logical rows 4..8 are inside the pane.
tuish_ctx_create_region 1 1 20 8
_clip=$TUISH_CTX
tuish_ctx_activate "$TUISH_CTX_ROOT"
tuish_ctx_reseat "$_clip" 7 5 20 8   10 5 20 10

tuish_ctx_activate "$_clip"
assert_eq "$TUISH_VIEW_ROWS" "8" "clipped: layout height is UNCHANGED (the child does not reflow)"
assert_eq "$TUISH_VIEW_COLS" "20" "clipped: layout width is unchanged"
assert_eq "$TUISH_VIEW_TOP"  "7" "clipped: origin sits ABOVE the pane (row 7 < pane top 10)"
assert_eq "$_tuish_base_lrmin" "4" "clipped: first visible logical row is 4 (rows 1-3 scrolled out)"
assert_eq "$_tuish_base_lrmax" "8" "clipped: last visible logical row is 8 (the widget's own extent)"

# Rows 1-3 are scrolled out: tuish_vmove must REFUSE them (nothing reaches the host).
_tuish_buffering=1; _tuish_buf=''
tuish_vmove 1 1 && _bad=yes || _bad=no
assert_eq "$_bad" "no" "clipped: a scrolled-out row is refused by tuish_vmove"
assert_eq "$_tuish_buf" "" "clipped: a scrolled-out row emits NO bytes (host chrome is safe)"

# Row 4 is the first visible one, and it must land on the pane's top row (host 10).
_tuish_buf=''
tuish_vmove 4 1 && _ok=yes || _ok=no
assert_eq "$_ok" "yes" "clipped: the first visible row is accepted"
assert_eq "$_tuish_buf" '\033[10;5H' "clipped: it maps to the pane's top row, not the widget's"

# --- A canvas inside a clipped child cannot escape it (regression) ------------
# tuish_vmove clips a LOGICAL coordinate and only then maps it to an absolute cell —
# it never re-checks the result against the base clip. So a canvas that overwrote the
# clip (as it used to) could address cells outside its host's region entirely, and a
# partly-scrolled child would leak its hidden rows over the host's chrome.
tuish_canvas 1 1 20 8              # a canvas spanning the child's whole extent
assert_eq "$_tx_lrmin" "4" "canvas: clip is INTERSECTED with the base, not overwritten"
assert_eq "$_tx_lrmax" "8" "canvas: canvas extent still bounds the bottom"
_tuish_buf=''
tuish_vmove 1 1 && _bad=yes || _bad=no
assert_eq "$_bad" "no"     "canvas: a canvas cell in a scrolled-out row is still refused"
assert_eq "$_tuish_buf" "" "canvas: it emits no bytes — the canvas cannot escape the region"
tuish_canvas_off
_tuish_buffering=0; _tuish_buf=''
tuish_ctx_activate "$TUISH_CTX_ROOT"

# --- Idle-tick negotiation ---------------------------------------------------
# The rules: the host must poll at the FASTEST child's rate (so the fast child is not
# slowed), and each child must only be driven once ITS OWN interval has elapsed (so
# the slow child is not sped up).
TUISH_TIMING=sub

_fast_n=0
_slow_n=0
_mk () { tuish_idle_interval "$1"; tuish_bind 'idle' "$2"; tuish_bind '*' ':'; }

tuish_ctx_create_region 1 1 10 5
_fast=$TUISH_CTX
_mk 0.02 '_fast_n=$((_fast_n + 1))'          # a 50Hz game
tuish_ctx_activate "$TUISH_CTX_ROOT"

tuish_ctx_create_region 1 20 10 5
_slow=$TUISH_CTX
_mk 1 '_slow_n=$((_slow_n + 1))'             # a 1Hz clock
tuish_ctx_activate "$TUISH_CTX_ROOT"

eval "_fu=\$_tuish_ctx_${_fast}_TUISH_TICK_US"
eval "_su=\$_tuish_ctx_${_slow}_TUISH_TICK_US"
assert_eq "$_fu" "20000"   "negotiation: the fast child asked for 20ms"
assert_eq "$_su" "1000000" "negotiation: the slow child asked for 1s"

tuish_idle_interval 0.26                     # the host's own lazy default
tuish_ctx_sync_interval "$_fast" "$_slow"
assert_eq "$TUISH_TICK_US" "20000" \
	"negotiation: the host adopts the FASTEST child's tick (not its own, not the slowest)"

# Drive 100 host ticks = 2.0s of virtual time at the negotiated 20ms.
_i=0
while test $_i -lt 100
do
	TUISH_RAW='F'; TUISH_EVENT='idle'; TUISH_EVENT_KIND='idle'
	tuish_ctx_tick "$_fast"
	tuish_ctx_tick "$_slow"
	_i=$((_i + 1))
done
assert_eq "$_fast_n" "100" \
	"negotiation: the fast child fires every host tick (not slowed by a slow sibling)"
assert_eq "$_slow_n" "2" \
	"negotiation: the slow child fires once per second (not sped up by a fast sibling)"

# --- Did the child ACT on it? (TUISH_CTX_HANDLED / tuish_pass) ----------------
# A host that offers an event to a child needs to know whether the child took it, so
# that an event the child declined can CHAIN back to the host — the wheel over an
# inline widget with nothing left to scroll must still scroll the page.
tuish_ctx_activate "$TUISH_CTX_ROOT"

_child_n=0
_at_bottom=1                                   # the "cannot scroll any further" state

tuish_ctx_create_region 1 1 10 5
_kid=$TUISH_CTX
_tuish_mouse=1                                 # the child listens for the wheel
tuish_bind 'wdown' '_child_n=$((_child_n + 1)); test $_at_bottom -eq 1 && tuish_pass'
tuish_ctx_activate "$TUISH_CTX_ROOT"

TUISH_RAW='M 65 5 3'                           # wheel down, inside the child's region

tuish_ctx_dispatch "$_kid"
assert_eq "$TUISH_CTX_HANDLED" "0" \
	"chaining: a bound action that calls tuish_pass reports the event as NOT handled"
assert_eq "$_child_n" "1" \
	"chaining: ... and it did run — pass hands the event back, it does not skip the action"

_at_bottom=0                                   # now the child can actually scroll
tuish_ctx_dispatch "$_kid"
assert_eq "$TUISH_CTX_HANDLED" "1" \
	"chaining: the same binding, acting on the event, reports it handled"
assert_eq "$_child_n" "2" "chaining: the action ran again"

TUISH_RAW='C z'                                # the child has no binding for 'z'
tuish_ctx_dispatch "$_kid"
assert_eq "$TUISH_CTX_HANDLED" "0" \
	"chaining: an event with no binding at all is not handled"

# --- One host frame, one write -----------------------------------------------
# A host that repaints itself and then its children must not emit a write per child:
# the terminal draws each one, so the page lands at its new scroll offset a frame
# before the widgets do. tuish_ctx_render splices into the host's buffer instead.
tuish_ctx_activate "$TUISH_CTX_ROOT"

_writes=0
_tuish_out () { _writes=$((_writes + 1)); }     # count trips to the terminal

_paint () { tuish_text 1 1 "child"; }

tuish_ctx_create_region 2 2 8 3
_w1=$TUISH_CTX
tuish_on_redraw _paint
tuish_ctx_activate "$TUISH_CTX_ROOT"

tuish_ctx_create_region 6 2 8 3
_w2=$TUISH_CTX
tuish_on_redraw _paint
tuish_ctx_activate "$TUISH_CTX_ROOT"

tuish_begin                                    # the host opens a frame ...
tuish_text 1 1 'page'
tuish_ctx_render "$_w1"
tuish_ctx_render "$_w2"
assert_eq "$_writes" "0" \
	"frame: rendering children inside a host frame writes nothing yet"
case "$_tuish_buf" in
	*page*child*child*) assert_eq "spliced" "spliced" \
		"frame: the children's output is spliced into the host's buffer, after its own";;
	*) assert_eq "$_tuish_buf" "page...child...child" \
		"frame: the children's output is spliced into the host's buffer, after its own";;
esac
tuish_end
assert_eq "$_writes" "1" "frame: the host's flush is the ONE write for page + children"

# Unbuffered (a child repainting on its own tick), the child still writes for itself.
_writes=0
tuish_ctx_render "$_w1"
assert_eq "$_writes" "1" "frame: with no host frame open, a child render writes on its own"

# --- Frames NEST --------------------------------------------------------------
# The framework opens a frame before it calls your code and puts things in it — the caret
# hide that precedes every deferred render, for one. An app that buffers inside its own
# render handler (every host does) used to reset the buffer and throw those away.
_writes=0
_tuish_buffering=0; _tuish_buf=''

tuish_begin                                    # the framework's frame
tuish_text 1 1 'outer'
tuish_begin                                    # the app's own frame, inside it
tuish_text 2 1 'inner'
tuish_end                                      # ... does NOT flush, and does NOT reset
assert_eq "$_writes" "0" "nesting: an inner tuish_end does not write"
case "$_tuish_buf" in
	*outer*inner*) assert_eq ok ok "nesting: an inner tuish_begin does not discard the outer frame";;
	*) assert_eq "$_tuish_buf" "outer...inner" \
		"nesting: an inner tuish_begin does not discard the outer frame";;
esac
tuish_end
assert_eq "$_writes" "1" "nesting: the outermost tuish_end is the one that writes"

# End-without-begin is clamped, not an underflow: one unbalanced app must not wedge the
# loop into never flushing again (a permanently frozen screen).
_writes=0
tuish_end
tuish_end
assert_eq "$_tuish_buffering" "0" "nesting: tuish_end below depth 0 clamps rather than underflowing"
tuish_begin
tuish_text 1 1 'after'
tuish_end
assert_eq "$_writes" "1" "nesting: ... and the next frame still flushes"
_tuish_buffering=0; _tuish_buf=''

# --- A region seated past the screen edge cannot address cells that are not there ---
# The seat clip was the child's own extent, intersected with nothing else. A host is
# free to seat a region anywhere in ITS frame, and nothing downstream re-checks the
# ABSOLUTE result — tuish_vmove clips the LOGICAL cell and only then maps, and it
# bounds the absolute row against TUISH_LINES but the absolute column against nothing.
# So a 20-wide region at column 90 of a 100-column screen handed out 20 columns.
tuish_ctx_activate "$TUISH_CTX_ROOT"
tuish_ctx_create_region 1 90 20 4      # 20 wide starting at absolute column 90
_edge=$TUISH_CTX
assert_eq "$_tuish_base_lcmax" "11" "seat: the clip stops at column 100, not at the region's 20"
assert_eq "$TUISH_VIEW_COLS" "20"   "seat: the LAYOUT size is untouched (the child still lays out to 20)"

_tuish_buffering=1; _tuish_buf=''
tuish_vmove 1 11 && _in=yes || _in=no
assert_eq "$_in" "yes" "seat: the last on-screen cell is still reachable"
assert_eq "$_tuish_buf" '\033[1;100H' "seat: ... and it lands on the last physical column"

_tuish_buf=''
tuish_vmove 1 12 && _out=yes || _out=no
assert_eq "$_out" "no" "seat: a cell past the screen is refused"
assert_eq "$_tuish_buf" "" "seat: ... and it emits nothing"
_tuish_buffering=0; _tuish_buf=''

# A region seated ABOVE row 1 (a child scrolled up under a pane) is the row mirror of
# the same rule: logical rows that map to absolute row 0 or less are refused.
tuish_ctx_activate "$TUISH_CTX_ROOT"
tuish_ctx_create_region -2 0 10 8      # logical rows 1..3 land on absolute -2..0
_above=$TUISH_CTX
assert_eq "$_tuish_base_lrmin" "4" "seat: the clip starts at the first row on screen"
_tuish_buffering=1; _tuish_buf=''
tuish_vmove 3 1 && _hi=yes || _hi=no
assert_eq "$_hi" "no" "seat: a row above the screen is refused"
assert_eq "$_tuish_buf" "" "seat: ... and it emits nothing"
_tuish_buffering=0; _tuish_buf=''

tuish_ctx_activate "$TUISH_CTX_ROOT"
tuish_ctx_destroy "$_edge"
tuish_ctx_destroy "$_above"

test_summary
