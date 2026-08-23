#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Which examples are safe to MOUNT — a ratchet, not a gate.
#
# Some terminal primitives cannot be region-clipped, because they are one escape the
# TERMINAL applies to a whole physical line, the whole screen, or the device: ESC[2K,
# ESC[K, ESC[1K, ESC[2J, DECSTBM, ESC[S/T, the alt screen. From inside a hosted region
# they punch straight through into the host's chrome. src/term.sh says so, and
# docs/hosting.md says so, and the rule was still broken — prose cannot fail a build.
#
# So: mount each example for real, through src/host.sh, into an actual child region;
# then do the three things a host does to a child (commit, render, hand it a resize)
# and watch whether any of those primitives is reached. Recording the CALL rather than
# matching bytes, because DECSTBM has no byte pattern a buffer of user text could not
# forge.
#
# It records a known-unclean list instead of asserting everything is clean, because two
# examples are unclean today and their fixes are deliberately out of scope (see the
# list below for what each one does and where the fix goes). A newly unclean example
# fails here; the two known ones are pinned so nobody reads this file as a clean bill
# of health, and so removing one is a one-line edit when its fix lands.
#
# A text-grep lint would be the cheap version of this and it does not work: it fires on
# examples/debug.sh immediately, whose tuish_clear_to_eol calls are in its
# standalone-only half and are correct — debug.sh is the example that gets hosting
# RIGHT. A check that flags the best-behaved file teaches people to write suppression
# comments.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

SRC="$TESTS_DIR/../src"
. "$SRC/compat.sh"
. "$SRC/ord.sh"
. "$SRC/tui.sh"
. "$SRC/term.sh"
. "$SRC/event.sh"
. "$SRC/hid.sh"
. "$SRC/viewport.sh"
. "$SRC/str.sh"
. "$SRC/buf.sh"
. "$SRC/clip.sh"
. "$SRC/draw.sh"
. "$SRC/canvas.sh"
. "$SRC/keybind.sh"
. "$SRC/host.sh"


# Exercise the SHIPPED configuration. tuish_fnfix normally fires from tuish_init, which unit
# tests deliberately never call (they stub the device) — so without this, every suite here
# would validate the framework with its ksh `local` still leaking, i.e. not the library that
# actually runs. It is a no-op on every shell whose `local` already works.
command -v tuish_fnfix >/dev/null 2>&1 && tuish_fnfix

printf 'Unit tests: what a mounted example may reach (hosted-unsafe primitives)\n'

TUISH_LINES=30
TUISH_COLUMNS=100

_tuish_out () { :; }                 # nothing reaches a device
stty () { :; }                       # ... and no device is touched
# A mounted app calls tuish_init and ADOPTS the context the mount gave it, because the
# device is already up. Say so directly: there is no device here, and an init that tried
# to bring one up would take the context with it.
_tuish_initialized=1

tuish_ctx_create
TUISH_CTX_ROOT=$TUISH_CTX
tuish_ctx_activate "$TUISH_CTX_ROOT"
TUISH_VIEW_ROWS=$TUISH_LINES
TUISH_VIEW_COLS=$TUISH_COLUMNS

# The examples are dual-mode: _tuish_tui_loaded is set, so each one only DEFINES its
# functions and runs no bootstrap. twins.sh sources the editor when hosted and looks for
# it via TUISH_EXAMPLES (it cannot use $0's directory — hosted, $0 is the HOST).
TUISH_EXAMPLES="$TESTS_DIR/../examples"
for _hs_f in editor boxes canvas_demo game debug width
do . "$TESTS_DIR/../examples/${_hs_f}.sh"
done

# ─── The recorder ────────────────────────────────────────────────
# The twelve primitives with no region-safe behaviour. Installed AFTER term.sh so these
# are the definitions every example sees.
_hs_hit=''
_hs_note ()            { _hs_hit="${_hs_hit}${_hs_hit:+ }$1"; }
tuish_clear_line ()    { _hs_note clear_line; }
tuish_clear_to_eol ()  { _hs_note clear_to_eol; }
tuish_clear_to_bol ()  { _hs_note clear_to_bol; }
tuish_clear_screen ()  { _hs_note clear_screen; }
tuish_scroll_region () { _hs_note scroll_region; }
tuish_scroll_up ()     { _hs_note scroll_up; }
tuish_scroll_down ()   { _hs_note scroll_down; }
tuish_scroll_up_n ()   { _hs_note scroll_up_n; }
tuish_scroll_down_n () { _hs_note scroll_down_n; }
tuish_altscreen_on ()  { _hs_note altscreen_on; }
tuish_altscreen_off () { _hs_note altscreen_off; }
tuish_reset_scroll ()  { _hs_note reset_scroll; }

# Mount ID with setup FN into a 30x10 region, then commit / render / resize it. The
# resize goes in through tuish_ctx_dispatch rather than tuish_host_route, because route
# deliberately has no signal arm (a host re-declares its children instead) — but a
# MODALLY hosted child runs its own loop inside the host's rectangle, so SIGWINCH does
# land in the child's context with _tuish_owns_dev=0. That is the path that makes an
# unguarded erase in a resize handler reachable.
tuish_host_pane 4 6 30 10
_hs_drive ()   # $1 = id, $2 = setup fn
{
	_hs_hit=''
	tuish_host_begin
	tuish_host_slot "$1" "$2" '' 4 6 30 10
	tuish_host_commit
	tuish_host_render "$1"
	tuish_host_ctx "$1"
	TUISH_RAW='S resize'
	tuish_ctx_dispatch "$TUISH_HOST_CTX"
	tuish_host_drop "$1"
	return 0
}

# ─── Clean: assert they reach nothing ────────────────────────────
# These pass today. They are the point of the file — the next example that grows a
# tuish_clear_to_eol in its hosted half fails HERE rather than on someone's screen.
#
# examples/twins.sh is deliberately absent. It exposes _tw_setup, but it is a HOST (it
# mounts two editors of its own) and _tw_lay sizes them from TUISH_COLUMNS/TUISH_LINES
# rather than TUISH_VIEW_*, so mounted into a sub-region it lays its children out over
# the whole screen. Nesting it is not a supported shape, and no host in the tree does
# it — session.sh mounts leaf apps only.
for _hs_c in 'boxes:_bx_setup' 'canvas:_cd_setup' 'game:_g_setup' 'debug:_dbg_setup'
do
	_hs_id="${_hs_c%%:*}"
	_hs_drive "$_hs_id" "${_hs_c#*:}"
	assert_eq "$_hs_hit" "" "hosted ${_hs_id}: reaches no device-global primitive"
done

# ─── Known unclean: pinned, with the defect named ────────────────
# Asserted to stay EXACTLY this, so the list can only shrink. Delete an entry when its
# fix lands; if one of these changes shape, that is a new fact worth looking at.
#
# editor — _ed_resize (examples/editor.sh) clears the viewport a row at a time with
# tuish_clear_line, so a modally hosted editor erases TUISH_VIEW_ROWS full PHYSICAL
# lines through the host's chrome on both sides, on every resize. The fix is
# tuish_clear_to_edge, which positions itself and is bounded by the drawable width.
_hs_drive editor _ed_setup
_hs_expect='clear_line clear_line clear_line clear_line clear_line clear_line clear_line clear_line clear_line clear_line'
assert_eq "$_hs_hit" "$_hs_expect" \
	"hosted editor: still the known clear_line per region row (fix: tuish_clear_to_edge)"

# ─── The raw tier: unclipped by contract, so measure it instead ──
# tuish_print does no width clipping — deliberately, so a caller that already knows its
# text fits pays nothing (src/term.sh). Its only backstop is that tuish keeps autowrap
# off, so the TERMINAL stops at the physical screen edge — which is the region edge only
# when the app is fullscreen. The recorder cannot see this; measure the payloads.
#
# width — examples/width.sh renders a fixed-width alignment table through the raw tier
# (its fields are pre-padded, so a per-cell width scan would be the thing under test
# measuring itself). Mounted into a narrower pane, every row runs past the region to the
# screen edge. Safe to measure with a plain tuish_str_width here because width.sh emits
# its attributes as separate calls, so no payload carries embedded SGR.
_hs_wide=0
tuish_print () { _hs_p="$1"; tuish_str_width _hs_p
	test "$TUISH_SWIDTH" -gt "$_hs_wide" && _hs_wide=$TUISH_SWIDTH; return 0; }

tuish_host_pane 4 6 24 12
_hs_hit=''
tuish_host_begin
tuish_host_slot narrow _w_setup '' 4 6 24 12
tuish_host_commit
tuish_host_render narrow
tuish_host_drop narrow
assert_eq "$(test $_hs_wide -gt 24 && echo over || echo fits)" "over" \
	"hosted width.sh: still the known raw-tier overrun of its 24-column region"

test_summary
