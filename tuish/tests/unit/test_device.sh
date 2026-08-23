#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for DEVICE state vs CONTEXT state.
#
# The terminal is singular; contexts are not. Every escape an app can switch on
# (mouse tracking, kitty detailed mode, autowrap) therefore has TWO facts behind it:
# what the active app WANTS (a per-context field) and what the terminal is currently
# SET TO (a device-global `_dev` mirror). These tests pin the seam between them.
#
# The bug class they exist for: a child enables something, the host unmounts it, the
# child's frame is destroyed — and now the context field says one thing while the
# terminal says another. Consulting the context field at that point is always wrong.
#
# No terminal here: _tuish_write is captured into a string so we can assert on the
# exact escapes emitted.

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


# Exercise the SHIPPED configuration. tuish_fnfix normally fires from tuish_init, which unit
# tests deliberately never call (they stub the device) — so without this, every suite here
# would validate the framework with its ksh `local` still leaking, i.e. not the library that
# actually runs. It is a no-op on every shell whose `local` already works.
command -v tuish_fnfix >/dev/null 2>&1 && tuish_fnfix

printf 'Unit tests: device state vs context state\n'

TUISH_LINES=30
TUISH_COLUMNS=100

# Capture what reaches the terminal.
#
# We stub _tuish_out — the ONE door to the device — and not _tuish_write, deliberately.
# Stubbing _tuish_write would bypass the buffer/hold machinery entirely, and the last test
# in this file exists precisely to prove an escape survives that machinery. Stub the door,
# and everything above it stays real.
_DEV_OUT=''
_tuish_out () { _DEV_OUT="${_DEV_OUT}$1"; }
_dev_reset () { _DEV_OUT=''; }

# Did the captured output contain this escape? The literal backslash-033 form is what
# the source passes to _tuish_write, so we match on that directly.
_emitted () { case "$_DEV_OUT" in *"$1"*) return 0;; esac; return 1; }

tuish_ctx_create
TUISH_CTX_ROOT=$TUISH_CTX
tuish_ctx_activate "$TUISH_CTX_ROOT"

# ─── Mouse: a child enables it, teardown must still turn it off ──────────────────

_dev_reset
tuish_ctx_create_region 5 5 20 10
_child=$TUISH_CTX
tuish_mouse_on

assert_eq "$_tuish_mouse"     "1" "mouse: the child wants mouse events"
assert_eq "$_tuish_mouse_dev" "1" "mouse: the device has tracking live"

# Back to the root and destroy the child's frame — exactly what an unmount does.
tuish_ctx_activate "$TUISH_CTX_ROOT"
tuish_ctx_destroy "$_child"

assert_eq "$_tuish_mouse"     "0" "mouse: the root never wanted mouse events"
assert_eq "$_tuish_mouse_dev" "1" "mouse: but the terminal is still tracking"

# THE BUG: teardown that consulted _tuish_mouse (0) would emit nothing and leak SGR
# mouse reports into the user's shell. _tuish_hid_fini consults the device flag.
_dev_reset
_tuish_hid_fini
_emitted '\033[?1003l' && assert_eq "1" "1" "mouse: teardown turns off tracking the child enabled"
_emitted '\033[?1003l' || assert_eq "0" "1" "mouse: teardown turns off tracking the child enabled"
assert_eq "$_tuish_mouse_dev" "0" "mouse: device flag cleared after teardown"

# ─── Kitty detailed: was never restored at all before ────────────────────────────

TUISH_PROTOCOL='kitty'
_dev_reset
tuish_detailed_on
assert_eq "$_tuish_detailed_dev" "1" "detailed: device flag set under kitty"

# tuish_fini restores the protocol to 'vt' BEFORE it calls _tuish_hid_fini, so a
# teardown that re-checked TUISH_PROTOCOL would silently do nothing. Reproduce that
# ordering exactly.
TUISH_PROTOCOL='vt'
_dev_reset
_tuish_hid_fini
_emitted '\033[=9u' && assert_eq "1" "1" "detailed: teardown restores it even after the protocol reset"
_emitted '\033[=9u' || assert_eq "0" "1" "detailed: teardown restores it even after the protocol reset"
assert_eq "$_tuish_detailed_dev" "0" "detailed: device flag cleared after teardown"

# Not under kitty, the flag is never claimed — so teardown emits nothing.
TUISH_PROTOCOL='vt'
tuish_detailed_on
assert_eq "$_tuish_detailed_dev" "0" "detailed: no device claim outside kitty"

# ─── Autowrap: NOT device-mirrored, and that is the point ───────────────────────
# The symmetry is tempting and wrong. _tuish_wrap looks like it needs a device mirror and a
# reconcile on every context switch — a child turns DECAWM on, the host resumes thinking it
# is off. But look at what the flag gates (term.sh): wrap=0 makes tuish_text TRIM to the
# columns that fit, so a wrap=0 context never lets a glyph reach the right edge and cannot
# be harmed by what DECAWM is set to. The stale device is inert.
#
# Pin that, because an earlier version of this file asserted the opposite and a reconcile
# was built on it — one that emitted an escape from inside tuish_ctx_activate, where
# _tuish_write routes by the per-context _tuish_buffering and so landed in whichever buffer
# happened to be swapped in. It broke the one-write-per-frame invariant to fix a hazard that
# does not exist.

tuish_ctx_activate "$TUISH_CTX_ROOT"
tuish_wrap_off
assert_eq "$_tuish_wrap" "0" "wrap: a wrap=0 context clips by TRIMMING, in software"

_dev_reset
tuish_ctx_create_region 5 5 20 10
_kid=$TUISH_CTX
tuish_wrap_on
assert_eq "$_tuish_wrap" "1" "wrap: the child asked the terminal to wrap"
_emitted '\033[?7h' && assert_eq "1" "1" "wrap: ... and the escape went out when it asked"
_emitted '\033[?7h' || assert_eq "0" "1" "wrap: ... and the escape went out when it asked"

# Back to the host. NOTHING is emitted: the host trims in software, so it does not care
# what DECAWM is, and a switch must not put bytes in the middle of somebody's frame.
_dev_reset
tuish_ctx_activate "$TUISH_CTX_ROOT"
assert_eq "$_tuish_wrap" "0"  "wrap: the resumed host is back to trimming"
assert_eq "$_DEV_OUT"    ""   "wrap: and a context switch writes NOTHING to the terminal"

tuish_ctx_destroy "$_kid"

# ─── One write per frame, with a child in it ─────────────────────────────────────
# The invariant the removed reconcile was breaking. A host that opens a frame, draws chrome
# and drives a child must reach the terminal exactly ONCE — tuish_ctx_dispatch holds, so
# everything the child emits folds into the host's frame instead of escaping it.

tuish_ctx_activate "$TUISH_CTX_ROOT"
tuish_viewport fullscreen
tuish_on_redraw ':'
tuish_on_event ':'

_kid_paint () { tuish_text 1 1 'KID'; }
tuish_ctx_create_region 2 2 20 5
_kid2=$TUISH_CTX
tuish_on_redraw _kid_paint
tuish_on_event  _kid_paint
tuish_wrap_on                      # the child emits a device escape during dispatch
tuish_ctx_activate "$TUISH_CTX_ROOT"

_WRITES=0
_tuish_out () { _WRITES=$(( _WRITES + 1 )); _DEV_OUT="${_DEV_OUT}$1"; }

_dev_reset
tuish_begin
tuish_text 1 1 'host chrome'
TUISH_RAW='C x'
tuish_ctx_dispatch "$_kid2"
tuish_end
assert_eq "$_WRITES" "1" "one frame with a driven child in it = ONE terminal write"

case "$_DEV_OUT" in
	*'host chrome'*KID*) assert_eq "1" "1" "... and the child's paint is INSIDE it, after the chrome" ;;
	*)                   assert_eq "0" "1" "... and the child's paint is INSIDE it, after the chrome" ;;
esac

tuish_ctx_activate "$TUISH_CTX_ROOT"
tuish_ctx_destroy "$_kid2"

test_summary
