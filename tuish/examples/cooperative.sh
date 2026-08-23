#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# cooperative.sh — one tuish loop driving TWO live apps at once.
#
# A single host event loop drives two mounted child contexts side by side, in one
# fork-free process, with NO nested tuish_run: a ticking CLOCK on the left and the
# interactive text EDITOR (examples/editor.sh) on the right. This is the cooperative,
# non-modal counterpart to the modal hosting in test_hosting.sh — here the host keeps
# its loop and feeds each event to the right child (tuish_ctx_dispatch), so both
# widgets stay live simultaneously: type in the editor while the clock keeps ticking.
#
#   Input model — host.sh routes it. Click a box to focus it; the keyboard goes to
#   whichever is focused; idle ticks BOTH children, each at its own negotiated rate (the
#   clock asks for 1Hz, the editor keeps the default, and the host polls at the faster of
#   the two). Ctrl+W reaches the editor, which quits itself; the host sees the id come
#   back in TUISH_HOST_QUIT and folds — it never has to know which key an embedded app
#   uses to exit.
#
# The children are ordinary examples: the editor is unchanged and does not know it is
# hosted; the clock is a tiny inline widget written the same way an example would be.
#
# The whole host is ~30 lines, because src/host.sh owns the child table and the rules.
# It used to hand-roll its own rect test, its own per-child mouse routing, its own tick
# loop and its own reseat-on-resize — and it still had no focus model at all.

# ─── Bootstrap ────────────────────────────────────────────────────
# Runs top-level (a host), but guard like the examples so it could itself be hosted
# one day: only bring up modules when tuish is not already loaded.
if test -z "${_tuish_tui_loaded:-}"
then
	_coop_standalone=1
	set -euf
	_coop_dir="$(cd "$(dirname "$0")" && pwd)"
	_src="${_coop_dir}/../src"
	. "${_src}/compat.sh"
	. "${_src}/ord.sh"
	. "${_src}/tui.sh"
	. "${_src}/term.sh"
	. "${_src}/event.sh"
	. "${_src}/hid.sh"
	. "${_src}/viewport.sh"
	. "${_src}/str.sh"
	. "${_src}/buf.sh"
	. "${_src}/draw.sh"
	. "${_src}/keybind.sh"
	. "${_src}/host.sh"
	_coop_ex="${_coop_dir}"
else
	_coop_standalone=0
	_coop_ex="${TUISH_EXAMPLES:-.}"
fi

# The editor, SOURCED (tuish is loaded, so it only defines its _ed_* functions,
# including _ed_setup — the non-blocking half of _ed_main we drive here).
. "${_coop_ex}/editor.sh"

# ─── Palette ──────────────────────────────────────────────────────
C_BG='13:17:23'
C_BORDER='40:52:74'
C_ACCENT='125:211:222'
C_ACCENT2='181:160:255'
C_DIM='120:132:150'
C_HEAD='236:240:248'

# ─── Clock widget ─────────────────────────────────────────────────
# A minimal hostable widget: register a render handler by name, fill its region, and
# re-render on every idle tick so the time stays live. It never calls tuish_run — it
# is designed to be driven by a host, exactly like an example's _setup half.
_clk_render ()
{
	tuish_draw_fill 1 1 "$TUISH_VIEW_COLS" "$TUISH_VIEW_ROWS" bg=$C_BG
	local _t; _t="$(date '+%H:%M:%S')"
	tuish_str_width _t; local _tw=$TUISH_SWIDTH
	local _row=$(( (TUISH_VIEW_ROWS + 1) / 2 ))
	local _col=$(( (TUISH_VIEW_COLS - _tw) / 2 + 1 ))
	test $_col -lt 1 && _col=1
	tuish_text $(( _row - 1 )) "$_col" "$_t" fg=$C_ACCENT bg=$C_BG
	local _lbl='live · idle-driven'
	tuish_str_width _lbl; local _lw=$TUISH_SWIDTH
	local _lc=$(( (TUISH_VIEW_COLS - _lw) / 2 + 1 ))
	test $_lc -lt 1 && _lc=1
	tuish_text $(( _row + 1 )) "$_lc" "$_lbl" fg=$C_DIM bg=$C_BG
}

_clk_setup ()
{
	tuish_init
	# A clock displaying whole seconds needs a 1Hz tick, not the host's default ~4Hz —
	# so it ASKS for one. The host still polls at its own (faster) rate for the sake of
	# the editor; tuish_ctx_tick divides that down and only wakes us once a second. This
	# is the point of the negotiation: neither child imposes its clock on the other.
	tuish_idle_interval 1
	tuish_on_redraw _clk_render
	# Re-render each idle tick so the seconds advance without any input.
	tuish_bind 'idle'   'tuish_request_redraw'
	tuish_bind 'resize' 'tuish_request_redraw'
	# tuish_pass, not ':' — a clock acts on nothing, and ':' would silently EAT every
	# event the host offers it, so the wheel over the clock would kill the host's
	# scrolling instead of chaining back to it. Say "not mine", not "mine, ignored".
	tuish_bind '*'      'tuish_pass'
	tuish_viewport fullscreen     # hosted → fills our region (no alt-screen)
	_clk_render
}

# ─── Host layout / chrome ─────────────────────────────────────────
_coop_lay ()
{
	_W=$TUISH_COLUMNS; _H=$TUISH_LINES
	_top=3
	_bot=$(( _H - 1 ))
	_bh=$(( _bot - _top + 1 ))
	_half=$(( (_W - 3) / 2 ))
	_lc=2
	_rc=$(( _lc + _half + 1 ))
	# Region interiors (inside each box border), in absolute host cells.
	_li_r=$(( _top + 1 )); _li_c=$(( _lc + 1 )); _li_w=$(( _half - 2 )); _li_h=$(( _bh - 2 ))
	_ri_r=$(( _top + 1 )); _ri_c=$(( _rc + 1 )); _ri_w=$(( _half - 2 )); _ri_h=$(( _bh - 2 ))
}

# Declare where the two children go. Called on first paint and on every resize — the
# rectangles change, the ids do not, and that is exactly what tuish_host_commit keys on:
# it reseats the children it already has rather than tearing them down and remounting.
_coop_slots ()
{
	tuish_host_begin
	tuish_host_slot clock  _clk_setup '' "$_li_r" "$_li_c" "$_li_w" "$_li_h"
	tuish_host_slot editor _ed_setup  '' "$_ri_r" "$_ri_c" "$_ri_w" "$_ri_h"
	tuish_host_commit
}

# The whole repaint: chrome, then the children, in ONE frame. tuish_host_paint renders
# each child into this frame (so it is one write, not three) and paints the FOCUSED one
# last, so the terminal's caret ends up where the editor put it rather than wherever the
# clock's last cell happened to be.
_coop_render ()
{
	_coop_lay
	tuish_begin
	tuish_draw_fill 1 1 "$_W" "$_H" bg=$C_BG
	tuish_text 1 2 "cooperative — one loop, two live apps" fg=$C_ACCENT bg=$C_BG
	local _hint='click a box to focus it · Ctrl+W: quit'
	tuish_str_width _hint; local _hw=$TUISH_SWIDTH
	tuish_text 1 $(( _W - _hw )) "$_hint" fg=$C_DIM bg=$C_BG

	# The focused box gets the bright border — the whole point of having a focus model.
	local _clkfg=$C_BORDER _edfg=$C_BORDER
	case "$TUISH_HOST_FOCUS" in
		clock)  _clkfg=$C_ACCENT;;
		editor) _edfg=$C_ACCENT;;
	esac
	tuish_draw_box "$_top" "$_lc" "$_half" "$_bh" fg=$_clkfg bg=$C_BG style=rounded
	tuish_text "$_top" $(( _lc + 2 )) " clock " fg=$C_ACCENT2 bg=$C_BG
	tuish_draw_box "$_top" "$_rc" "$_half" "$_bh" fg=$_edfg bg=$C_BG style=rounded
	tuish_text "$_top" $(( _rc + 2 )) " editor " fg=$C_ACCENT bg=$C_BG

	tuish_host_paint
	tuish_end
}

# ─── The cooperative router ───────────────────────────────────────
# tuish_host_route is the whole router: mouse → the child under the pointer (a click
# focuses it), keys → the focused child, idle → tick every child at its own rate. It
# returns 1 when nothing took the event, which is when the host's own bindings run.
#
# We do not intercept the editor's quit key. It quits by its own means, and route hands
# back the id in TUISH_HOST_QUIT — so the host never has to know which key an embedded
# app exits on.
_coop_on_event ()
{
	if test "$TUISH_EVENT_KIND" = 'signal'
	then _coop_lay; _coop_slots; _coop_render; return 0; fi

	tuish_host_route || :
	test -n "$TUISH_HOST_QUIT" && { tuish_quit_clear; return 0; }
	case "$TUISH_EVENT" in
		*clik) tuish_request_redraw;;      # the focus ring moved
	esac
	tuish_dispatch || :
	return 0
}

# ─── Host entry ───────────────────────────────────────────────────
_coop_main ()
{
	tuish_init
	tuish_mouse_on
	tuish_viewport fullscreen
	_coop_lay

	tuish_on_redraw _coop_render
	tuish_on_event  _coop_on_event

	_coop_slots                     # mounts both children, adopts the fastest tick
	tuish_host_focus editor         # the editor starts with the keyboard
	_coop_render

	tuish_run || :

	tuish_host_clear                # the editor's own fini hook restores the cursor
	tuish_fini
}

if test "${_coop_standalone:-0}" -eq 1
then
	_coop_main
fi
