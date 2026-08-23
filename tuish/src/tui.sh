#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# src/tui.sh - Terminal UI core: setup, teardown, traps, IO stubs
# Source compat.sh and ord.sh first, then this file.  Do not execute directly.
#
# Provides:
#   tuish_init             - set up terminal for TUI (raw mode, protocol detection)
#   tuish_fini             - restore terminal to previous state
#   tuish_quit             - signal event loop to stop
#   tuish_quit_main        - quit, leave viewport content visible, cursor below
#   tuish_quit_clear       - quit, clear viewport, restore cursor position
#   tuish_update_size      - refresh TUISH_LINES / TUISH_COLUMNS
#   tuish_begin            - start output buffering
#   tuish_end              - flush buffer and stop buffering
#   tuish_flush            - flush buffer (keep buffering active)
#   tuish_show_cursor      - show cursor
#   tuish_hide_cursor      - hide cursor
#   tuish_save_cursor      - save cursor position (DECSC)
#   tuish_restore_cursor   - restore cursor position (DECRC)
#   tuish_reset_scroll     - reset scroll region to full screen
#
# Variables (set after tuish_init):
#   TUISH_LINES            - terminal height
#   TUISH_COLUMNS          - terminal width
#   TUISH_INIT_ROW         - cursor row when init was called
#   TUISH_PROTOCOL         - keyboard protocol: "vt" or "kitty"
#   TUISH_TIMING           - timeout resolution: "sub" or "second"
#   TUISH_TICK_US          - idle interval in microseconds (for time-based animation)
#
# Configuration (set before tuish_init):
#   TUISH_TABSIZE          - tab stop interval (default: 4)
#   TUISH_FINI_OFFSET      - lines below init position to place cursor after fini (default: 0)
#   TUISH_IDLE_TIMEOUT     - idle event interval in seconds (default: 0.26, or 1 for second timing)
#   TUISH_ESC_TIMEOUT      - max wait (seconds) for an escape sequence to continue
#                            (default: 0.02, or 1 for second timing). Well-formed
#                            CSI/SS3 sequences dispatch on their final byte without
#                            waiting; this only bounds a lone ESC or an Alt-<key>.
#   TUISH_SYNC             - wrap device writes in synchronized output, DECSET 2026
#                            (default: 1). Set to 0 when debugging a renderer: an
#                            atomic frame also hides a frame that draws half of itself.

# ─── Dependencies ─────────────────────────────────────────────────
# Source compat.sh before this file.  It provides:
#   _tuish_printf, _tuish_out(), alias local=typeset (ksh93)

# ─── Load guard ──────────────────────────────────────────────────
# Sourcing tui.sh twice would reset all state and re-stub the overridable
# functions, silently clobbering any optional module sourced in between.
if test -n "${_tuish_tui_loaded:-}"; then return 0; fi
_tuish_tui_loaded=1

# ─── IO stubs (overridden by term.sh) ────────────────────────────
# Minimal buffered-write and cursor primitives used by init/fini
# and event.sh.  term.sh redefines these with the same behavior
# plus full drawing primitives, colors, and style.

_tuish_buf=''
_tuish_buffering=0

# The one door to the terminal. _tuish_buf is a per-context frame, so a host cannot
# simply buffer "everything that happens" — the moment it activates a child, it is
# looking at the CHILD's buffer, and the child's own tuish_end writes straight out.
# That is fine for a child running its own loop, and wrong for a host assembling one
# frame: mounting three widgets inside a host repaint would emit three extra writes,
# and the terminal would draw each one.
#
# HOLD catches every flush, from any context, into one string. It is device-global on
# purpose: it is about the output stream, which there is only one of. tuish_ctx_mount
# uses it to fold a child's first paint into the host's frame.
_tuish_holding=0
_tuish_hold=''

# One buffer, one write — but one write is NOT one repaint, and that gap is where the
# blink lives. Nothing promises the terminal draws a write atomically: the browser lane
# hands stdout to xterm.js in ~4KiB postMessages, so a full-screen frame arrives as the
# erase first and the text a frame later; tmux and a loaded emulator can split one the
# same way. What you see is the app blinking, and the reflex is to paint less, which is
# how an app ends up hand-tracking what changed for a reason that was never about
# change.
#
# DECSET 2026 (BSU/ESU) says "hold the screen until I say go". Wrapping the write costs
# 12 bytes and makes the frame atomic at the far end, so repainting everything stops
# being visible as repainting.
#
# It goes HERE, around each actual device write, rather than around tuish_begin/end:
# tuish_flush deliberately emits a PARTIAL frame mid-handler (the editor echoing a
# keystroke ahead of its deferred redraw), and that partial still wants to land whole.
# Per sink write means every chunk the terminal receives is atomic, whichever way the
# frame was cut.
#
# _tuish_sync is DEVICE state, and off until tuish_init turns it on: unknown DEC private
# modes are ignored by every terminal that does not know them, but a unit test that
# stubs the device and reads back bytes should see exactly the bytes under test. The
# bare Linux VT has no synchronized output at all and ignores it too.
_tuish_sync=0
_tuish_sink ()
{
	if test $_tuish_holding -eq 1
	then _tuish_hold="${_tuish_hold}${1:-}"
	elif test $_tuish_sync -eq 1
	then _tuish_out "\033[?2026h${1:-}\033[?2026l"
	else _tuish_out "${1:-}"
	fi
}

_tuish_write ()
{
	if test $_tuish_buffering -ge 1
	then
		_tuish_buf="${_tuish_buf}${1:-}"
	else
		_tuish_sink "${1:-}"
	fi
}

# Frames NEST. _tuish_buffering is a depth, not a flag: tuish_begin only clears the
# buffer when it OPENS the frame, and tuish_end only writes when it closes it.
#
# This matters because the framework opens a frame before it calls your code, and puts
# things in it — the caret hide that precedes every deferred render, for one. An app
# that buffers inside its own render handler (any host does) used to reset the buffer
# and throw those away, silently: the caret stayed on, blinking wherever the last cell
# was drawn. Nesting means whoever opened the frame owns it, and nobody inside can cut
# it in half by accident.
#
# tuish_flush still writes what has accumulated so far and leaves the frame open — an
# editor echoing a keystroke ahead of its deferred redraw wants exactly that.
tuish_begin ()
{
	test $_tuish_buffering -eq 0 && _tuish_buf=''
	_tuish_buffering=$(( _tuish_buffering + 1 ))
	return 0
}
tuish_end ()
{
	test $_tuish_buffering -le 1 || { _tuish_buffering=$(( _tuish_buffering - 1 )); return 0; }
	test -n "$_tuish_buf" && _tuish_sink "$_tuish_buf"
	_tuish_buf=''
	_tuish_buffering=0
	return 0
}
tuish_flush ()          { test -n "$_tuish_buf" && _tuish_sink "$_tuish_buf"; _tuish_buf=''; return 0; }

# Repeat string $1 exactly $2 times into _tuish_rep. O(log n) via doubling.
# Shared primitive in the base module: str.sh (tuish_str_repeat) and term.sh
# (tuish_clear_region) both build repeated strings and depend only on tui.sh,
# so this lets them share one implementation instead of each inlining the loop.
_tuish_repeat ()
{
	local _rp_s="$1" _rp_n=$2
	_tuish_rep=''
	while test $_rp_n -gt 0
	do
		test $((_rp_n & 1)) -ne 0 && _tuish_rep="${_tuish_rep}${_rp_s}"
		_rp_s="${_rp_s}${_rp_s}"
		_rp_n=$((_rp_n >> 1))
	done
}

# DECSC/DECRC are ESC followed by a digit. Emit a literal ESC byte (from
# the ord table) rather than a backslash escape, because no single escape
# form survives every shell's printf/echo: `\x1b7` reads as hex 0x1b7 on
# ksh93, and `\0337` reads as octal 337 on mksh — both swallow the digit.
tuish_save_cursor ()    { _tuish_write "${_tuish_chr_27}7"; }
tuish_restore_cursor () { _tuish_write "${_tuish_chr_27}8"; }
tuish_show_cursor ()    { _tuish_write '\033[?25h'; }
tuish_hide_cursor ()    { _tuish_write '\033[?25l'; }
tuish_cursor ()         { :; }
tuish_reset_scroll ()   { _tuish_write '\033[r'; }

# ─── HID state defaults (ABI seam) ───────────────────────────────
# event.sh reads these on the per-event hot path, so they live in the base and
# must exist even when hid.sh is not sourced. Keeping them as plain globals (vs.
# a hid.sh predicate call per event) is a deliberate hot-path choice. Toggle
# functions and teardown (_tuish_hid_fini) are provided by hid.sh.

_tuish_mouse=0
_tuish_detailed=0
_tuish_modkeys=0
_tuish_wrap=0
_tuish_kitty_raw='letter'

# ─── Tracked key holds ───────────────────────────────────────────
# " <sanitized>:<µs left> <sanitized>:<µs left> ... " — the keys this context asked to
# track (tuish_key_track, in keybind.sh) and how much of each one's window is left.
#
# A plain VT reports no key release: holding a key is just the same event arriving again at
# the OS autorepeat rate. So "down" is inferred by RECENCY — each matching event refills the
# window, each idle tick drains it by TUISH_TICK_US, and anything left means the key is
# still down. Empty here is the norm, and both hot-path hooks in event.sh test this string
# first so an app that tracks nothing pays one comparison.
#
# The window lives per-context, not as one device setting, because it is a property of the
# app doing the inferring: a game wants a tight one, a hosted widget may want another. Both
# are here at the seam rather than in keybind.sh for the reason above them — event.sh reads
# them per event, and keybind.sh is optional.
_tuish_key_set=''
_tuish_key_ttl_us=150000

# Whether mouse-tracking escapes are currently active ON THE TERMINAL. This is
# DEVICE state (the terminal is singular), so — unlike _tuish_mouse, which is a
# per-context "does THIS app want mouse events" flag — it is NOT registered as a
# context field. A child that enables mouse sets this; at final teardown, fini
# reads THIS (not the by-then-inactive child's _tuish_mouse) to know it must emit
# the mouse-off escape. Without it, a child that enabled mouse leaks tracking
# into the shell after exit (the root context's _tuish_mouse is still 0).
_tuish_mouse_dev=0

# The same argument holds for kitty's detailed mode, which was never turned off at all:
# tuish_detailed_on emits `[=11u` and nothing ever put it back, so a child that enabled it
# leaked repeat/release reports into the shell after exit.
#
# The rule both encode: an app REQUESTS device state; only the device layer restores it. An
# app that puts the terminal back is reaching outside the rectangle it owns.
_tuish_detailed_dev=0

# AUTOWRAP has no device mirror, and that is deliberate — the obvious symmetry here is a
# trap I fell into and had to back out of.
#
# _tuish_wrap is per-context, and it looks like it needs reconciling on every context
# switch: a child turns DECAWM on, the host resumes with _tuish_wrap=0, and the terminal is
# left wrapping while the host thinks it clips. But look at what the flag actually gates
# (term.sh): wrap=0 makes tuish_text TRIM the text to the columns that fit. A context with
# wrap=0 never lets a glyph reach the right edge, so what DECAWM is set to cannot affect it.
# The stale device is inert.
#
# The one real mismatch is the other direction — a context with wrap=1 (which does NOT trim,
# by definition) running while DECAWM is off, so the terminal clips where the app wanted it
# to wrap. That needs a device toggle, and tuish_wrap_on already emits one. It only goes
# stale if some OTHER context calls tuish_wrap_off in between.
#
# Reconciling that on every tuish_ctx_activate is what I tried, and it is worse than the
# disease: _tuish_write routes by _tuish_buffering, which is itself a per-context register,
# so an escape emitted mid-switch lands in whichever buffer happens to be swapped in — and
# the toolkit's one-buffer-one-write-one-frame invariant (see _tuish_sink) goes with it.
# A narrow hazard nothing in-tree can trigger is not worth breaking the frame for.
#
# So: if you write a widget that calls tuish_wrap_on, do not also expect a sibling to call
# tuish_wrap_off and leave you correct. Re-assert it in your render, the way the caret shape
# is re-asserted (term.sh).

# ─── Control ────────────────────────────────────────────────────────

_tuish_quit=''
_tuish_quit_mode=''

tuish_quit ()       { _tuish_quit=yes; _tuish_quit_mode=''; }
tuish_quit_main ()  { _tuish_quit=yes; _tuish_quit_mode=main; }
tuish_quit_clear () { _tuish_quit=yes; _tuish_quit_mode=clear; }

# ─── Internal state ─────────────────────────────────────────────────

_tuish_byte=''
_tuish_signal=''
_tuish_precols=''
_tuish_previous_stty=''
_tuish_stty=''
_tuish_esc_timeout=''
_tuish_idle_timeout=''
_tuish_idle_chunk='-t0.03'
_tuish_idle_chunks=1
_tuish_interval_s='0.26'   # the interval (seconds string) the active context runs at
TUISH_TICK_US=260000       # _tuish_interval_s in µs; real value derived at tuish_init
_tuish_pending_byte=''
_tuish_initialized=0

# Set by the EXIT trap (device-global, NOT a context field) so tuish_fini can
# tell "the process is exiting" from "a host is unmounting a child". On a real
# exit with a child context still active, the device MUST be restored (stty,
# alt-screen, mouse, traps) — the child-unmount path deliberately skips that, so
# without this flag a signal mid-embed leaves the terminal wedged.
_tuish_exiting=0

# Set to 1 by tuish_ctx_dispatch while a cooperatively-driven child processes an
# event (device-global, not a context field). The out-of-region-click handler
# (event.sh) reads it to suppress its self-quit for driven children — see
# tuish_ctx_dispatch.
_tuish_driven=0

# Default byte reader (overridden by tuish_init with shell-specific version)
_tuish_get_byte () { return 1; }
_tuish_idle_wait () { return 1; }
_tuish_peek_byte () { return 1; }

# Overridable hooks declared in the base so the override arrow always points
# base -> optional module: each module below just redefines its hook. Declaring
# them in a sibling optional module instead risked a re-source resetting one
# after another module had already overridden it.
_tuish_resolve_event ()      { :; }        # hid.sh
_tuish_viewport_on_resize () { :; }        # viewport.sh
tuish_dispatch ()            { return 1; } # keybind.sh
_tuish_hid_fini ()           { :; }        # hid.sh (mouse/kitty teardown)

TUISH_EVENT=''
TUISH_EVENT_KIND=''
TUISH_MOUSE_X=0
TUISH_MOUSE_Y=0
TUISH_RAW=''
TUISH_LINES=0
TUISH_COLUMNS=0
TUISH_INIT_ROW=0
_tuish_cursor_abs_row=0
_tuish_cursor_vrow=0
_tuish_cursor_vcol=0

# The caret's SHAPE, alongside its position — it is caret state, and it marshals with the
# rest of it. term.sh owns the setter and the emit; the variables live here because the two
# that describe the DEVICE are needed by code that cannot assume term.sh was sourced:
# event.sh has to forget the cache wherever it throws frame content away, and tuish_fini has
# to know whether anybody ever had an opinion about the caret at all.
#
#   _tuish_cursor_shape      PER-CONTEXT declaration. '' = no opinion.
#   _tuish_cursor_shape_dev  DEVICE: the last DECSCUSR that actually reached the terminal.
#   _tuish_cursor_shape_set  DEVICE: did we ever change it? Only then is there a restore.
_tuish_cursor_shape=''
_tuish_cursor_shape_dev=''
_tuish_cursor_shape_set=0
TUISH_PROTOCOL=''
TUISH_TIMING="${TUISH_TIMING:-}"   # preserve a launcher-declared value (fast-path)
TUISH_TABSIZE="${TUISH_TABSIZE:-4}"
TUISH_FINI_OFFSET="${TUISH_FINI_OFFSET:-0}"
TUISH_MOUSE_ABS_Y=0

# ─── Viewport defaults (ABI seam) ────────────────────────────────
# TUISH_VIEW_TOP / TUISH_VIEW_COLS / _tuish_view_mode are read by term.sh
# (vmove, draw clipping), event.sh and hid.sh on hot paths, so they default
# here and must exist even when viewport.sh is not sourced. viewport.sh updates
# them; _tuish_on_fini is its teardown hook.

TUISH_VIEW_MODE=''
TUISH_VIEW_ROWS=0
TUISH_VIEW_COLS=0
TUISH_VIEW_TOP=1
# Column origin of the viewport (0-based), mirror of TUISH_VIEW_TOP for rows.
# 0 for the root (viewport starts at column 1); a hosted child gets the absolute
# column of its region, so its logical column 1 lands at the region's left edge.
TUISH_VIEW_LEFT=0

_tuish_view_mode=''
_tuish_fini_push_gap=0
_tuish_on_fini () { :; }

# Per-context APP fini handler, referenced by name (same model as the render/
# event handlers in event.sh). An app that changes device state mid-run (cursor
# shape, a draw backend, ...) registers its restore here; tuish_fini runs it on
# EVERY exit path — standalone teardown, modal return, and cooperative unmount —
# so the cleanup an app used to place after tuish_run (which a driven app never
# reaches) has a first-class home.
# Setter only (unlike the polymorphic tuish_on_redraw / tuish_on_event, which the
# framework also CALLS as a fallback — this one is never called, only registered).
# Not to be confused with _tuish_on_fini, the framework's internal viewport-teardown
# hook one underscore away.
_tuish_fini_fn=''
tuish_on_fini () { _tuish_fini_fn="${1:-}"; }

# ─── Transform state (the tuish_vmove origin/scale/clip) ─────────
# tuish_vmove maps a logical (row,col) onto an absolute terminal cell through a
# single affine+clip transform. The default below is the viewport identity: no
# column shift, unit cells, and a clip only at the physical bottom. canvas.sh
# overwrites _tx_* to address a bounded sub-region (4-edge clipped, optionally
# CWxCH-scaled). The row origin folds in TUISH_VIEW_TOP live (read in vmove), so
# the transform survives a resize.

_tx_off_r=0
_tx_off_c=0
_tx_ch=1
_tx_cw=1
_tx_lrmin=-99999
_tx_lrmax=99999
_tx_lcmin=-99999
_tx_lcmax=99999

# Base clip that _tuish_tx_reset returns to (i.e. what "canvas off" means). For
# the root this is the whole screen (the historical constants); a hosted child's
# context seeds these to its region bounds, so its tuish_canvas_off falls back to
# the region rather than escaping to the full terminal.
_tuish_base_lrmin=-99999
_tuish_base_lrmax=99999
_tuish_base_lcmin=-99999
_tuish_base_lcmax=99999

# Reset the transform to the context's base region (canvas off).
_tuish_tx_reset ()
{
	_tx_off_r=0; _tx_off_c=0; _tx_ch=1; _tx_cw=1
	_tx_lrmin=$_tuish_base_lrmin; _tx_lrmax=$_tuish_base_lrmax
	_tx_lcmin=$_tuish_base_lcmin; _tx_lcmax=$_tuish_base_lcmax
}

# ─── Canvas state (public flags; geometry lives in _tx_* above) ──
TUISH_CANVAS=0
TUISH_CANVAS_W=0
TUISH_CANVAS_H=0
TUISH_CANVAS_CW=1
TUISH_CANVAS_CH=1

_tuish_canvas_on=0
_tuish_canvas_r=1
_tuish_canvas_c=1

# ─── Context / instance management ───────────────────────────────
# tuish's logical state is owned by per-app CONTEXTS, so multiple apps can
# coexist in one process (a host running another app inside a region of itself).
# The active context's fields live in the plain working globals declared above
# (the "registers", read on the hot paths); inactive contexts are spilled to
# namespaced _tuish_ctx_<id>_<field> vars (the "saved frames"). A context switch
# marshals a fixed, registered field list and happens only at modal boundaries
# (a host entering/leaving a child) — never per byte or per frame — so the hot
# paths pay nothing. The terminal DEVICE (stty, traps, byte reader, size,
# protocol, ord tables) is singular and is NOT part of any context.

_tuish_ctx_active=''
_tuish_ctx_next=0
TUISH_CTX=0
TUISH_CTX_ROOT=0
_tuish_ctx_parent=''
_tuish_ctx_names=''

# A context's region: the absolute terminal rectangle it draws inside. EVERY context has
# one — the root's is the whole terminal, a child's is what its host handed it — so the
# transform math is the same for everybody and nothing has to ask "am I in a region?".
#
# What differs between them is not the region. It is who owns the DEVICE.
_tuish_rgn_top=1
_tuish_rgn_left=0
_tuish_rgn_rows=0
_tuish_rgn_cols=0

# Do I own the terminal device? A PREDICATE: call it in a condition.
#
# This used to be `_tuish_hosted`, which conflated two facts that are not the same fact:
#
#   "I draw into a region"     — true for EVERYONE, including the root
#   "I own the terminal"       — true for exactly one context per process
#
# Only the second one is worth branching on, and only the framework should ever branch on
# it. An app that asks is almost always about to touch the device — the alt-screen, the
# scroll region, a caret shape — which is precisely what it must not do: a host unmounts a
# child for its own reasons, and a child putting the terminal back on its way out of a
# rectangle it never owned changes the screen for everybody. Apps REQUEST device state; the
# device layer restores it. See docs/hosting.md.
#
# The default is 1, not 0, and that is deliberate: a context that was never seated into a
# region owns the terminal by definition. (It also keeps the unit tests that never call
# tuish_ctx_create on the right branch.)
_tuish_owns_dev=1

# The public predicate. Its polarity reads backwards from the field, and that is on purpose:
# `tuish_hosted` is the documented, historical spelling and every doc and any user code that
# calls it keeps working byte-identically. The framework itself branches on the raw field.
#
# In APP code this is a smell — if you are asking, you are about to touch the device, which
# is the one thing an app must not do. No example in this repo needs it any more.
tuish_hosted () { test "$_tuish_owns_dev" -eq 0; }

# Register working vars as marshalled context fields. Each field's DEFAULT is
# captured live from its current value, so a register call must follow the var's
# own declaration (no default is duplicated here). Optional modules register
# their own fields the same way; only sourced modules contribute, so the marshal
# never references an unset var under set -u.
tuish_ctx_register ()
{
	local _tuish_ctx_rn
	for _tuish_ctx_rn in "$@"
	do
		_tuish_ctx_names="${_tuish_ctx_names} ${_tuish_ctx_rn}"
	done
	_tuish_ctx_recapture "$@"
}

# Capture the default of already-registered fields from their CURRENT values — the
# second half of tuish_ctx_register, on its own because some state only takes its
# real value at device init (the idle timing). Re-running it after init refreshes
# those defaults, so contexts created later inherit the live host value instead of
# the pre-init placeholder captured at source time.
_tuish_ctx_recapture ()
{
	local _tuish_ctx_rn
	for _tuish_ctx_rn in "$@"
	do
		eval "_tuish_ctx_dflt_${_tuish_ctx_rn}=\$${_tuish_ctx_rn}"
	done
}

# Reset every registered working var to its captured default. Straight per-field
# loop in a helper (its control var is local and dies on return) — safe under the
# event.sh zsh loop-var invariant, which concerns tuish_run's own frame only.
_tuish_ctx_defaults ()
{
	local _f
	for _f in $_tuish_ctx_names
	do
		eval "${_f}=\$_tuish_ctx_dflt_${_f}"
	done
}

# ─── App field sets: state that belongs to an INSTANCE ───────────
# tuish_ctx_register above is the FRAMEWORK tier: one global list, marshalled for every
# context that exists. That is right for framework state (every context has a viewport)
# and wrong for an app's, for two reasons — every context would pay to marshal the
# editor's cursor row, and worse, an app that wants to be mounted TWICE has nowhere to put
# the second instance's state.
#
# That was a real limit, not a theoretical one: examples/editor.sh kept _cur_row, _view_top
# and the rest as plain globals, so two editors in one page shared a cursor. The website
# only ever opens one at a time, which is how it got away with it.
#
# So: a second tier. An app DECLARES a named set of fields once, at source time, and
# ATTACHES it to whichever context it is running in.
#
#   tuish_ctx_declare _ed _cur_row _cur_col _view_top ...   # once, at source time
#   _ed_setup () { tuish_init; tuish_ctx_fields _ed; ... }  # per instance
#
# DECLARATION IS AT SOURCE TIME, AND THAT IS THE WHOLE TRICK. The obvious design — capture
# each field's default when it is attached — breaks on the exact case the feature exists
# for: when editor #2 attaches, the live _cur_row is editor #1's cursor row, and #2 would
# start life holding it. Declaring at source time captures the value the app itself wrote
# in its own declarations, which is what a default IS.
#
# It also means _tuish_ctx_defaults never sees these fields, so unlike the framework tier
# they cannot be wiped by a context creation that happens after registration.
#
# Storage: _tuish_ctxd_<SET> is the set's field list, _tuish_ctxf_<id> the sets attached to
# context <id>. (Not _tuish_ctx_<id>__fields — that could collide with a field genuinely
# named _fields.)
# The prefixed locals are not fussiness. This runs at SOURCE time — that is the whole point
# of it — which is before tuish_init, and therefore before compat.sh's tuish_fnfix has made
# `local` mean local. On ksh93 these two ARE globals, and `_set` and `_n` are exactly the
# names an app gives a loop counter. tuish_ctx_register (above) has the same constraint for
# the same reason. See tests/unit/test_namespace.sh.
tuish_ctx_declare ()   # $1 = set name, $2.. = field names
{
	local _tuish_cd_set=$1 _tuish_cd_n
	shift
	eval "_tuish_ctxd_${_tuish_cd_set}=\"\$*\""
	for _tuish_cd_n in "$@"
	do
		eval "_tuish_ctxd_dflt_${_tuish_cd_n}=\$${_tuish_cd_n}"
	done
	return 0
}

# Attach declared set $1 to the ACTIVE context and reset its fields to their declared
# defaults. Call it in your setup, after tuish_init has settled which context you are.
#
# Resetting on attach is not a convenience, it is required: the globals currently hold
# whatever the LAST instance of this app left in them, and a fresh instance must not
# inherit them. It is also what lets an app delete its own hand-written "fresh state each
# launch" block — the framework knows the defaults, because the app declared them.
tuish_ctx_fields ()   # $1 = set name
{
	local _cur='' _names='' _n
	# An unknown set is an ERROR, not a no-op. Returning 0 here would mean a typo'd or
	# not-yet-declared name silently attaches nothing: the fields never marshal, and two
	# mounted instances of the app quietly go back to sharing their state — reproducing
	# exactly the bug this tier exists to fix, with nothing on screen to say so. Under the
	# `set -euf` every app in this repo runs with, returning 1 turns that into a startup
	# failure, which is what it is.
	eval "_names=\${_tuish_ctxd_${1}:-}"
	test -n "$_names" || return 1
	# No active context: the app called this before tuish_init. Same reasoning — and
	# eval'ing the empty id would write to a variable literally named `_tuish_ctxf_`, which
	# no save or load would ever read.
	test -n "$_tuish_ctx_active" || return 1
	eval "_cur=\${_tuish_ctxf_${_tuish_ctx_active}:-}"
	case " $_cur " in
		*" $1 "*) : ;;                                   # already attached; just reset
		*) eval "_tuish_ctxf_${_tuish_ctx_active}=\"\${_cur:+\$_cur }\$1\"" ;;
	esac
	for _n in $_names
	do
		eval "${_n}=\$_tuish_ctxd_dflt_${_n}"
	done
	return 0
}

# The field names attached to context $1, flattened -> _tuish_ctx_extra ('' if none).
# Out-var, not stdout: asking a question must not cost a fork.
_tuish_ctx_extra=''
_tuish_ctx_extras ()   # $1 = ctx id
{
	local _sets='' _s
	_tuish_ctx_extra=''
	eval "_sets=\${_tuish_ctxf_${1}:-}"
	test -n "$_sets" || return 0
	for _s in $_sets
	do
		eval "_tuish_ctx_extra=\"\${_tuish_ctx_extra:+\$_tuish_ctx_extra }\$_tuish_ctxd_${_s}\""
	done
	return 0
}

# Spill the active working set into frame $1 / fill the working set from frame $1.
#
# Both walk the base list AND whatever sets context $1 has attached. Both key off $1, so a
# switch from A to B saves A's fields and loads B's — each context marshals exactly what it
# owns, and a context that owns nothing extra pays one variable read.
_tuish_ctx_save ()
{
	local _f
	for _f in $_tuish_ctx_names
	do
		eval "_tuish_ctx_${1}_${_f}=\$${_f}"
	done
	_tuish_ctx_extras "$1"
	for _f in $_tuish_ctx_extra
	do
		eval "_tuish_ctx_${1}_${_f}=\$${_f}"
	done
}
_tuish_ctx_load ()
{
	local _f
	for _f in $_tuish_ctx_names
	do
		eval "${_f}=\$_tuish_ctx_${1}_${_f}"
	done
	_tuish_ctx_extras "$1"
	for _f in $_tuish_ctx_extra
	do
		eval "${_f}=\$_tuish_ctx_${1}_${_f}"
	done
}

# Allocate a fresh context seeded with default field values; its id lands in
# TUISH_CTX. Does not change which context is active.
tuish_ctx_create ()
{
	_tuish_ctx_next=$(( _tuish_ctx_next + 1 ))
	TUISH_CTX=$_tuish_ctx_next
	local _prev="$_tuish_ctx_active"
	test -n "$_prev" && _tuish_ctx_save "$_prev"
	_tuish_ctx_defaults
	_tuish_ctx_parent="$_prev"
	# Give each context its own bind-table namespace so coexisting apps can't
	# collide. The first context (the root) keeps the empty prefix, so its keys
	# are byte-identical to the historical flat table.
	if test -n "${_tuish_kb_ns+x}"
	then
		if test "$TUISH_CTX" -eq 1
		then _tuish_kb_ns=''
		else _tuish_kb_ns="c${TUISH_CTX}_"
		fi
	fi
	_tuish_ctx_save "$TUISH_CTX"
	test -n "$_prev" && _tuish_ctx_load "$_prev"
	return 0
}

# ─── Region vs viewport ──────────────────────────────────────────
# These are two different rectangles, and collapsing them is the mistake that made the
# root a special case in the first place.
#
#   REGION    the rectangle you OWN. Nothing you draw may leave it.
#   VIEWPORT  the band you LAY OUT in. TUISH_VIEW_*.
#
# For a hosted child they coincide — a host hands you exactly one rectangle and it is both.
# For the ROOT they do not: its region is the whole terminal, while its viewport is
# whatever mode it asked for (a 10-row `fixed` band, a `grow` block that starts at zero
# rows and lengthens a line at a time). A root that took its region from its viewport would
# clip itself to nothing the moment it asked for `grow`, whose TUISH_VIEW_ROWS is 0 until
# the first line is emitted.
#
# So the primitive underneath takes the clip EXPLICITLY, in logical cells, and never infers
# it from the viewport.
#
# Seat the ACTIVE context into the absolute rectangle (abs_row, abs_col0, W, H), with a
# base clip given in the context's own logical cells. The one place that knows which fields
# a region is made of.
_tuish_ctx_region ()   # $1=abs_row $2=abs_col0 $3=W $4=H $5=lrmin $6=lrmax $7=lcmin $8=lcmax
{
	_tuish_owns_dev=0        # seated into a region: by default the terminal is not ours
	_tuish_rgn_top=$1
	_tuish_rgn_left=$2
	_tuish_rgn_rows=$4
	_tuish_rgn_cols=$3
	_tuish_base_lrmin=$5; _tuish_base_lrmax=$6
	_tuish_base_lcmin=$7; _tuish_base_lcmax=$8
	_tuish_tx_reset
}

# Seat the ACTIVE context into a region AND make that region its viewport — the hosted
# case, where the two are the same rectangle. Shared by tuish_ctx_create_region (first
# seating) and tuish_ctx_reseat (re-seating) so the field list is never duplicated; hosts
# used to hand-copy this block.
#
# A hosted region is THREE independent things, and keeping them apart is what lets a host
# scroll a live child under the edge of a pane:
#
#   layout size  TUISH_VIEW_ROWS/COLS  — how big the child THINKS it is. The child
#                                        lays out to fill this, so it must not change
#                                        just because part of the child is off-screen,
#                                        or the child reflows instead of sliding.
#   origin       TUISH_VIEW_TOP/LEFT   — where the child's logical (1,1) lands. May be
#                                        OUTSIDE the visible pane (even above row 1):
#                                        that is a child scrolled partly out of view.
#   visible clip _tuish_base_l*        — what may actually reach the terminal. Cells
#                                        outside it are dropped by tuish_vmove.
#
# $5..$8 give the clip window in ABSOLUTE cells (row, 0-based col, W, H); omitted, it
# is the region itself, which is the historical behaviour every existing caller gets.
_tuish_ctx_seat ()   # $1=abs_row $2=abs_col0 $3=W $4=H [$5=clip_row $6=clip_col0 $7=clip_w $8=clip_h]
{
	TUISH_VIEW_TOP=$1
	TUISH_VIEW_LEFT=$2
	TUISH_VIEW_ROWS=$4
	TUISH_VIEW_COLS=$3

	local _r0=1 _r1=$4 _c0=1 _c1=$3
	if test $# -ge 8
	then
		# Express the clip window in the CHILD's logical cells (the inverse of the
		# tuish_vmove map: row = abs - VIEW_TOP + 1, col = abs - VIEW_LEFT), then
		# intersect with the child's own extent. An empty intersection is fine — the
		# child is entirely off-pane and simply draws nothing.
		_r0=$(( $5 - $1 + 1 ))          # first visible logical row
		_r1=$(( $5 + $8 - 1 - $1 + 1 )) # last  visible logical row
		_c0=$(( $6 + 1 - $2 ))          # first visible logical col
		_c1=$(( $6 + $7 - $2 ))         # last  visible logical col
		test $_r0 -lt 1 && _r0=1
		test $_c0 -lt 1 && _c0=1
		test $_r1 -gt $4 && _r1=$4
		test $_c1 -gt $3 && _c1=$3
	fi
	# Intersect with the SCREEN, in this context's logical cells (same pullback). A
	# host may seat a child anywhere in ITS frame, and the clip above is the child's
	# own extent intersected with nothing else — so a region seated near an edge
	# handed out cells that are not on the terminal at all. Nothing downstream
	# re-checks: tuish_vmove clips the LOGICAL cell and only then maps, and it bounds
	# the absolute ROW against TUISH_LINES but the absolute COLUMN against nothing.
	#
	# Here rather than in tuish_vmove: this runs once per seat, vmove runs once per
	# drawn cell, and its success path is a single test today. The root already gets
	# this for free — _tuish_viewport_own_region seats it to exactly 1..LINES x
	# 1..COLUMNS pulled back the same way — so this is the hosted half of that.
	#
	# Guarded on nonzero dimensions: TUISH_LINES/COLUMNS are 0 until tuish_update_size
	# runs (a term.sh-only profile, and every unit suite that stubs the device), and
	# clamping to 0 there would refuse every cell.
	local _s0=$(( 2 - $1 ))
	test $_r0 -lt $_s0 && _r0=$_s0
	_s0=$(( 1 - $2 ))
	test $_c0 -lt $_s0 && _c0=$_s0
	if test $TUISH_LINES -gt 0
	then _s0=$(( TUISH_LINES - $1 + 1 )); test $_r1 -gt $_s0 && _r1=$_s0; fi
	if test $TUISH_COLUMNS -gt 0
	then _s0=$(( TUISH_COLUMNS - $2 )); test $_c1 -gt $_s0 && _c1=$_s0; fi
	_tuish_ctx_region "$1" "$2" "$3" "$4" "$_r0" "$_r1" "$_c0" "$_c1"
}

# Create AND activate a child context bound to a region of the CURRENTLY ACTIVE
# (parent) context: R C are the region's top-left in the parent's logical coords,
# W H its size. The parent's live transform resolves the origin to absolute cells,
# so regions compose to any depth (page > example > overlay). The child's logical
# (1,1) is the region's top-left; its drawing clips to the region; a hosted
# "fullscreen" fills the region. On return the id is in TUISH_CTX; the caller runs
# the child, then tuish_ctx_activate <parent> + tuish_ctx_destroy <child>.
tuish_ctx_create_region ()
{
	local _abs_r=$(( TUISH_VIEW_TOP + _tx_off_r + ($1 - 1) * _tx_ch ))
	local _abs_c=$(( TUISH_VIEW_LEFT + _tx_off_c + ($2 - 1) * _tx_cw ))
	tuish_ctx_create
	tuish_ctx_activate "$TUISH_CTX"
	_tuish_ctx_seat "$_abs_r" "$_abs_c" "$3" "$4"
	return 0
}

# Move mounted child $1 to a new region of the CURRENTLY ACTIVE (host) context —
# R C W H in the host's logical coords, same frame as tuish_ctx_create_region. A
# host calls this from its resize handler so the child relayouts into the moved
# rectangle instead of stale geometry; the child then re-renders on the resize
# event it is forwarded. The host stays active on return.
#
# CR CC CW CH (optional, same coordinate frame) is the WINDOW the child may draw
# through — "here is your rectangle, and here is the hole you are seen through".
# Omitted, it falls back to this context's tuish_ctx_clip, and failing that to the
# region itself. This is what lets a host SCROLL a live child: pass a region whose top
# is above the pane (R may be <= 0), and the child slides under the pane's edge, clipped
# per cell. Its layout size stays W x H throughout, so it never reflows — it is genuinely
# occluded, not resized. See _tuish_ctx_seat.
tuish_ctx_reseat ()   # $1=ctx $2=R $3=C $4=W $5=H [$6=CR $7=CC $8=CW $9=CH]
{
	local _abs_r=$(( TUISH_VIEW_TOP + _tx_off_r + ($2 - 1) * _tx_ch ))
	local _abs_c=$(( TUISH_VIEW_LEFT + _tx_off_c + ($3 - 1) * _tx_cw ))
	local _host=$_tuish_ctx_active
	if test $# -ge 9
	then _tuish_clip_abs "$6" "$7" "$8" "$9"
	else _tuish_clip_abs
	fi
	if test "$_tuish_clipped" -eq 1
	then
		local _cr=$_tuish_clip_r _cc=$_tuish_clip_c _cw=$_tuish_clip_w _ch=$_tuish_clip_h
		tuish_ctx_activate "$1"
		_tuish_ctx_seat "$_abs_r" "$_abs_c" "$4" "$5" "$_cr" "$_cc" "$_cw" "$_ch"
		tuish_ctx_activate "$_host"
		return 0
	fi
	tuish_ctx_activate "$1"
	_tuish_ctx_seat "$_abs_r" "$_abs_c" "$4" "$5"
	tuish_ctx_activate "$_host"
	return 0
}

# ─── The clip window ─────────────────────────────────────────────
# A host that shows children through a PANE — a scrolling document, a viewport with a
# border — has to clip every one of them to it, on mount and on every reseat. Saying so
# once beats saying it at each call site and silently corrupting a frame when you forget:
# a child mounted un-clipped paints over the host's chrome before any reseat can bound it.
#
#   tuish_ctx_clip R C W H    # children of this context are seen through this window
#   tuish_ctx_clip            # no args: they are not clipped (the default)
#
# R C W H are the ACTIVE context's logical coords, the same frame as tuish_ctx_mount and
# tuish_ctx_reseat. It is a per-context field, so a host declares its pane once (in its
# layout) and every child it mounts or moves is bounded by it. An explicit clip passed to
# tuish_ctx_reseat still wins.
_tuish_clip_win=''
tuish_ctx_register _tuish_clip_win

tuish_ctx_clip ()   # [$1=R $2=C $3=W $4=H]
{
	if test $# -ge 4
	then _tuish_clip_win="$1 $2 $3 $4"
	else _tuish_clip_win=''
	fi
	return 0
}

# Resolve a clip window to ABSOLUTE cells in the active (host) context's frame:
# args if given, else the context's tuish_ctx_clip, else none.
# Out: _tuish_clipped (0/1) and _tuish_clip_r/_c/_w/_h.
_tuish_clipped=0
_tuish_clip_r=0; _tuish_clip_c=0; _tuish_clip_w=0; _tuish_clip_h=0
_tuish_clip_abs ()   # [$1=R $2=C $3=W $4=H]
{
	local _q
	if test $# -ge 4
	then _q="$1 $2 $3 $4"
	else _q="$_tuish_clip_win"
	fi
	if test -z "$_q"
	then _tuish_clipped=0; return 0; fi

	local _qr _qc
	_qr="${_q%% *}"; _q="${_q#* }"
	_qc="${_q%% *}"; _q="${_q#* }"
	_tuish_clip_w="${_q%% *}"; _tuish_clip_h="${_q##* }"
	_tuish_clip_r=$(( TUISH_VIEW_TOP + _tx_off_r + (_qr - 1) * _tx_ch ))
	_tuish_clip_c=$(( TUISH_VIEW_LEFT + _tx_off_c + (_qc - 1) * _tx_cw ))
	_tuish_clipped=1
	return 0
}

# Make context $1 active: spill the current one, fill from $1's frame.
tuish_ctx_activate ()
{
	test -n "$_tuish_ctx_active" && _tuish_ctx_save "$_tuish_ctx_active"
	_tuish_ctx_load "$1"
	_tuish_ctx_active="$1"
}

# Destroy context $1: free its bindings, then unset its saved frame.
tuish_ctx_destroy ()
{
	# Bindings first, while the frame still holds the context's namespace and its
	# list of bound keys (shell cannot unset by glob, so we unset each explicitly).
	local _ns='' _keys='' _k
	eval "_ns=\${_tuish_ctx_${1}__tuish_kb_ns:-}"
	eval "_keys=\${_tuish_ctx_${1}__tuish_kb_keys:-}"
	for _k in $_keys
	do
		eval "unset _tuish_kb_${_ns}${_k} 2>/dev/null" || :
	done

	local _f
	for _f in $_tuish_ctx_names
	do
		eval "unset _tuish_ctx_${1}_${_f} 2>/dev/null" || :
	done

	# The app's own fields, and the record of which sets it had. Without this a mounted
	# app's instance state outlives the app — and since ids are monotonic that is a slow
	# leak in a host that mounts and drops children all day (the website does).
	_tuish_ctx_extras "$1"
	for _f in $_tuish_ctx_extra
	do
		eval "unset _tuish_ctx_${1}_${_f} 2>/dev/null" || :
	done
	eval "unset _tuish_ctxf_${1} 2>/dev/null" || :
}

# ─── Cooperative driving (non-modal hosting) ─────────────────────
# A host keeps its single tuish_run loop and DRIVES mounted children one event at
# a time, instead of each child running its own (blocking) tuish_run. When a child
# context is active the whole event pipeline already targets it — hid.sh decodes
# mouse into the child's region-local frame, tuish_dispatch uses the child's bind
# table, and the render path calls the child's handler — so driving a child is just
# "activate it, feed it the raw event, restore the host". Modal hosting (the child
# owning a nested tuish_run) still works; this is the alternative for live host
# chrome + simultaneous widgets.

# Set by tuish_ctx_dispatch to 1 when the child it just drove requested quit
# (the dispatched event ran the child's own tuish_quit / tuish_quit_clear — e.g.
# its bound 'q' or ctrl-w). Device-global, NOT a context field: it is the host's
# signal to unmount a child that ended ITSELF. This is the non-fragile
# cooperative-quit model — a driven app quits by its own means and the host
# detects it, instead of the host having to intercept the app's quit key (which a
# terminal or browser may reserve, e.g. Ctrl+W). A host checks it after each
# tuish_ctx_dispatch and calls tuish_ctx_unmount when set.
TUISH_CTX_QUIT=0

# Did the child ACT on the event we just handed it? Copied out of TUISH_HANDLED
# (event.sh) by _tuish_ctx_drive. A host uses it to CHAIN an event the child
# declined: the wheel over an inline widget that has nothing left to scroll should
# scroll the page, not vanish into the widget.
TUISH_CTX_HANDLED=0

# Feed raw descriptor $1 to the ALREADY-ACTIVE child and record whether it quit.
# The shared core of tuish_ctx_dispatch and tuish_ctx_tick.
#
# _tuish_driven marks "this child is being cooperatively driven, not running its own
# loop". The out-of-region-click handler (event.sh) uses it to stay quiet: in MODAL
# hosting an outside click self-quits the child to hand control back, but a DRIVEN
# child's host already routes out-of-region clicks itself (it only forwards what
# lands inside), so the child self-quitting would be a spurious quit — which
# TUISH_CTX_QUIT would then read as "the app ended" and unmount it.
_tuish_ctx_drive ()
{
	_tuish_driven=1
	_tuish_parse_event "$1"
	_tuish_driven=0
	TUISH_CTX_HANDLED=${TUISH_HANDLED:-0}
	# Surface a child-initiated quit to the host. The child is still active here, so
	# _tuish_quit is its value (its own quit binding set it to 'yes'); once we restore
	# the host it lives in the child's saved frame. The host reads TUISH_CTX_QUIT.
	if test "$_tuish_quit" = 'yes'
	then TUISH_CTX_QUIT=1
	else TUISH_CTX_QUIT=0
	fi
}

# Drive mounted child $1 with the event currently decoded in the active (host)
# context: TUISH_RAW holds the raw descriptor (event.sh:_tuish_parse_event), which
# the child re-resolves in its own region and dispatches/renders. Buffering and the
# redraw scheduler are per-context registers, so the child's tuish_begin/end and
# rAF render stay isolated from the host's. Requires event.sh (a cooperative host
# always sources it). No loop variable here — the zsh loop-var invariant is intact.
#
# Use this for INPUT (keys, mouse, resize). For idle, use tuish_ctx_tick, which
# honours each child's own tick rate instead of firing on every host tick.
# A host routes events from INSIDE its own event handler, which the framework already runs
# inside a frame (_tuish_parse_event's tuish_begin/tuish_end). So the host has a frame open
# the whole time we are down in the child — and _tuish_buffering, the flag that decides
# whether a write is buffered or goes straight to the terminal, is a per-context register.
# The moment we activate the child, it reads 0, and everything the child emits leaves the
# host's frame as a write of its own: the child's echoed keystroke, any device escape it
# switches on, the autowrap reconcile in tuish_ctx_activate. Two writes, sometimes more,
# where the toolkit promises one — and the escapes land ahead of chrome that was buffered
# before them.
#
# HOLD is the answer to exactly this, and tuish_ctx_render and tuish_ctx_mount already use
# it: it is device-global (there is one output stream), so it catches a flush from any
# context, at any depth. Hold across the whole dispatch and every byte the child produces
# folds into the host's frame, in order, and the repaint stays one write.
tuish_ctx_dispatch ()
{
	local _host=$_tuish_ctx_active _raw=$TUISH_RAW
	local _hostbuf=$_tuish_buffering
	local _hold=0
	if test "$_hostbuf" -gt 0 && test "$_tuish_holding" -eq 0
	then _tuish_holding=1; _tuish_hold=''; _hold=1
	fi

	tuish_ctx_activate "$1"
	_tuish_ctx_drive "$_raw"
	tuish_ctx_activate "$_host"

	if test "$_hold" -eq 1
	then
		_tuish_holding=0
		_tuish_buf="${_tuish_buf}${_tuish_hold}"
		_tuish_hold=''
	fi
	return 0
}

# Repaint mounted child $1 NOW: run its registered render handler at level -1 (full)
# inside its own context, so its transform and clip apply. A cooperative host calls
# this straight after tuish_ctx_reseat, so a child that just MOVED redraws into its new
# rectangle immediately instead of waiting for its next idle tick — at a lazy interval
# that would leave a visibly stale or torn widget on screen for a whole tick while the
# user scrolls. Requires event.sh (the render-handler indirection lives there).
#
# If the HOST is buffering when it calls this, the child's output is spliced into the
# host's frame rather than written on its own. That is what makes a host repaint atomic:
# a page with four live widgets otherwise emits five separate writes, and the terminal
# draws each one — you see the prose land at the new scroll offset while the widgets are
# still at the old, a frame at a time. One buffer, one write, one frame.
#
# The child's output goes in at the point the host called from, so a host that fills its
# background first and renders its children last still gets that order.
#
# Buffering the child is not enough on its own: a child is free to tuish_flush inside its
# own render (canvas_demo does, to get its panels out before its status line), and a flush
# writes whatever has accumulated no matter how deep the frame is. So HOLD as well — then
# begin/end children, flushing children and plain children all fold into the host's frame
# alike, and none of them can escape it.
tuish_ctx_render ()
{
	local _host=$_tuish_ctx_active _hostbuf=$_tuish_buffering
	local _hold=0
	if test "$_hostbuf" -gt 0 && test "$_tuish_holding" -eq 0
	then _tuish_holding=1; _tuish_hold=''; _hold=1
	fi

	tuish_ctx_activate "$1"
	tuish_begin
	"${_tuish_render_fn:-tuish_on_redraw}" -1
	local _out=$_tuish_buf
	_tuish_buf=''; _tuish_buffering=0
	tuish_ctx_activate "$_host"

	if test "$_hold" -eq 1
	then _tuish_holding=0; _out="${_tuish_hold}${_out}"; _tuish_hold=''
	fi
	if test "$_hostbuf" -gt 0
	then _tuish_buf="${_tuish_buf}${_out}"
	else test -n "$_out" && _tuish_sink "$_out"
	fi
	return 0
}

# ─── Idle-tick negotiation ───────────────────────────────────────
# Children can want different clocks: a game at 50Hz next to a clock at 1Hz. Two
# rules make that work, and they pull in opposite directions:
#
#   the fast child must not be SLOWED  -> the host loop runs at the FASTEST tick
#                                         among itself and its children
#                                         (tuish_ctx_sync_interval)
#   the slow child must not be SPED UP -> each child accumulates the host's tick
#                                         and only fires an idle once ITS OWN
#                                         interval has elapsed (tuish_ctx_tick)
#
# So the host polls fast enough for the fastest child, and divides that down per
# child. A 50Hz game and a 1Hz clock hosted together each animate at their own
# rate, in one loop, with no forks and no wall-clock reads.
#
# Accumulated host-tick time (µs) since this context's last idle. Per-context.
_tuish_tick_acc=0

# Deliver an idle tick to mounted child $1 AT ITS OWN RATE. Call it where a
# cooperative host would otherwise tuish_ctx_dispatch an idle event: it adds the
# host's tick to the child's accumulator and only drives the child once the child's
# own interval (TUISH_TICK_US, set by its tuish_idle_interval) has elapsed.
tuish_ctx_tick ()   # $1 = ctx
{
	local _host=$_tuish_ctx_active _host_us=$TUISH_TICK_US _raw=$TUISH_RAW
	tuish_ctx_activate "$1"
	_tuish_tick_acc=$(( _tuish_tick_acc + _host_us ))
	if test "$_tuish_tick_acc" -ge "$TUISH_TICK_US"
	then
		_tuish_tick_acc=$(( _tuish_tick_acc - TUISH_TICK_US ))
		# Never bank more than one interval of credit: if the host tick is coarser
		# than the child's (the child asked for a rate the host cannot poll at), the
		# child runs as fast as the host can go rather than firing a catch-up burst.
		test "$_tuish_tick_acc" -ge "$TUISH_TICK_US" && _tuish_tick_acc=0
		_tuish_ctx_drive "$_raw"
	else
		TUISH_CTX_QUIT=0
	fi
	tuish_ctx_activate "$_host"
}

# Set the ACTIVE (host) loop to the fastest tick among itself and children $@, so no
# child is starved by a host that idles lazily. Each child is still ticked at its own
# rate by tuish_ctx_tick, so the slower ones do not speed up. Call it once, after
# mounting. Reads the children's saved frames directly — no activation round-trips.
tuish_ctx_sync_interval ()   # $@ = child ctx ids
{
	local _c _cu _min=$TUISH_TICK_US _s=''
	for _c in "$@"
	do
		eval "_cu=\${_tuish_ctx_${_c}_TUISH_TICK_US:-0}"
		if test "$_cu" -gt 0 && test "$_cu" -lt "$_min"
		then
			_min=$_cu
			eval "_s=\${_tuish_ctx_${_c}__tuish_interval_s:-}"
		fi
	done
	test -n "$_s" && tuish_idle_interval "$_s"
	return 0
}

# Mount a child in a region and run its (non-blocking) setup, leaving the host
# active. $1..$4 = region R C W H in the host's logical coords; $5 = the child's
# setup function (everything an example's _main does EXCEPT tuish_run/tuish_fini);
# $6.. = extra args passed to it. On return the child id is in TUISH_CTX. The child's
# setup calls tuish_init, which adopts the context created here (device already up),
# so the example is unchanged.
#
# The child's chosen tick (its tuish_idle_interval) is left in its own frame; after
# mounting all children, the host calls tuish_ctx_sync_interval to adopt the fastest.
#
# The child is clipped from its VERY FIRST paint to this context's tuish_ctx_clip, if it
# has one. That is not a detail: a mount is not bookkeeping, it runs the child's setup and
# PAINTS it, so a child mounted partly outside its host's pane would draw over the host's
# chrome once, before any tuish_ctx_reseat could bound it.
tuish_ctx_mount ()
{
	local _r=$1 _c=$2 _w=$3 _h=$4 _fn=$5
	shift 5
	local _host=$_tuish_ctx_active

	# If the host is mid-frame, the child's setup paint belongs IN that frame, not in a
	# write of its own — otherwise the widget appears a frame before the page around it,
	# which is exactly the flash you see when a host mounts something in response to a
	# click. Hold everything the child emits and hand it to the host below. (Only the
	# outermost mount holds: a nested one must not reset the buffer it is accumulating
	# into.)
	local _hold=0
	if test "$_tuish_buffering" -gt 0 && test "$_tuish_holding" -eq 0
	then _tuish_holding=1; _tuish_hold=''; _hold=1
	fi

	# Resolve the clip window in the HOST's frame — it has to happen here, before
	# create_region switches us into the child's.
	_tuish_clip_abs
	local _clip=$_tuish_clipped
	local _cab_r=$_tuish_clip_r _cab_c=$_tuish_clip_c
	local _ccw=$_tuish_clip_w   _cch=$_tuish_clip_h

	tuish_ctx_create_region "$_r" "$_c" "$_w" "$_h"
	local _child=$TUISH_CTX
	test "$_clip" -eq 1 && _tuish_ctx_seat \
		"$TUISH_VIEW_TOP" "$TUISH_VIEW_LEFT" "$_w" "$_h" \
		"$_cab_r" "$_cab_c" "$_ccw" "$_cch"
	"$_fn" "$@"
	# Bootstrap idle: the exact first event tuish_run gives a standalone app, so
	# an idle-first app (one that paints on its first idle) renders NOW, at mount,
	# instead of waiting for the host's next idle tick. The child is still active,
	# so the paint lands in its region.
	_tuish_parse_event "F"
	tuish_ctx_activate "$_host"

	if test "$_hold" -eq 1
	then
		_tuish_holding=0
		_tuish_buf="${_tuish_buf}${_tuish_hold}"
		_tuish_hold=''
	fi

	TUISH_CTX=$_child
	return 0
}

# Unmount a mounted child: fold its viewport and drop its context, resuming the
# host. tuish_fini's nested-child branch does exactly this (it never touches the
# shared device), and reactivates the parent (the host) on return.
tuish_ctx_unmount ()
{
	tuish_ctx_activate "$1"
	tuish_fini
}

# Register the base (tui.sh) context fields. Optional modules add their own.
tuish_ctx_register \
	_tuish_quit _tuish_quit_mode \
	_tuish_buf _tuish_buffering \
	_tx_off_r _tx_off_c _tx_ch _tx_cw \
	_tx_lrmin _tx_lrmax _tx_lcmin _tx_lcmax \
	TUISH_VIEW_MODE TUISH_VIEW_ROWS TUISH_VIEW_COLS TUISH_VIEW_TOP TUISH_VIEW_LEFT \
	_tuish_base_lrmin _tuish_base_lrmax _tuish_base_lcmin _tuish_base_lcmax \
	_tuish_view_mode _tuish_fini_push_gap TUISH_FINI_OFFSET _tuish_fini_fn \
	TUISH_CANVAS TUISH_CANVAS_W TUISH_CANVAS_H TUISH_CANVAS_CW TUISH_CANVAS_CH \
	_tuish_canvas_on _tuish_canvas_r _tuish_canvas_c \
	_tuish_mouse _tuish_detailed _tuish_modkeys _tuish_wrap \
	_tuish_key_set _tuish_key_ttl_us \
	_tuish_cursor_abs_row _tuish_cursor_vrow _tuish_cursor_vcol _tuish_cursor_shape \
	TUISH_EVENT TUISH_EVENT_KIND TUISH_RAW \
	TUISH_MOUSE_X TUISH_MOUSE_Y TUISH_MOUSE_ABS_Y \
	_tuish_owns_dev _tuish_rgn_top _tuish_rgn_left _tuish_rgn_rows _tuish_rgn_cols \
	_tuish_idle_timeout _tuish_idle_chunk _tuish_idle_chunks TUISH_TICK_US _tuish_tick_acc \
	_tuish_interval_s \
	_tuish_ctx_parent

# ─── Size management ────────────────────────────────────────────────

tuish_update_size ()
{
	local _ts
	_ts="$(stty size 2>/dev/null)"
	# `stty size` returns "ROWS COLS" on a normal tty, but some WASIX/browser ttys
	# report nothing (no TIOCGWINSZ), leaving both fields empty. Empty values then
	# feed the many unquoted numeric tests downstream (the tab-stop loop below,
	# viewport.sh, …) as `test -lt` with a missing operand — "argument expected",
	# and init collapses. Guard it: only accept a real "<int> <int>", else fall
	# back to $LINES/$COLUMNS (a launcher can export the terminal's real size) and
	# finally a sane 24x80. Native is unaffected (stty size matches the first arm).
	case "$_ts" in
		*[0-9]" "[0-9]*)
			TUISH_LINES="${_ts%% *}"
			TUISH_COLUMNS="${_ts##* }" ;;
		*)
			TUISH_LINES="${LINES:-24}"
			TUISH_COLUMNS="${COLUMNS:-80}" ;;
	esac
	# Never leave a non-numeric value in place.
	case "$TUISH_LINES"   in ''|*[!0-9]*) TUISH_LINES=24;;   esac
	case "$TUISH_COLUMNS" in ''|*[!0-9]*) TUISH_COLUMNS=80;;  esac
}

# ─── Timeout parsing ─────────────────────────────────────────────────
# _tuish_timeout_us TIMEOUT -> _tuish_tick_us
# Convert a seconds timeout string ("0.02", "0.26", "1", "0.5") to integer
# microseconds. The single parser behind both TUISH_TICK_US (animation clock)
# and the zsh idle-chunk count. Fractional part is read to 6 digits (µs); the
# whole and fraction are forced base-10 (10#) so leading-zero fractions like
# "020" are not misread as octal. Zero/empty falls back to ~60 Hz.
_tuish_timeout_us ()
{
	case "$1" in
		*.*) local _w="${1%.*}" _f="${1#*.}000000"
		     _f="${_f%"${_f#??????}"}"
		     _tuish_tick_us=$(( ${_w:-0} * 1000000 + 10#$_f ));;
		*)   _tuish_tick_us=$(( ${1:-0} * 1000000 ));;
	esac
	test "$_tuish_tick_us" -le 0 && _tuish_tick_us=16667
	return 0
}

# ─── Lifecycle ──────────────────────────────────────────────────────

# Detect the shell's byte-reading capability and define the input primitives
# (_tuish_get_byte / _tuish_idle_wait / _tuish_peek_byte) accordingly. Returns 1
# if the shell supports neither read -k (zsh) nor read -n (bash/ksh/busybox).
_tuish_init_io ()
{
	# Detect byte-reading capability. Both probes are fed from a heredoc (fd 9),
	# NOT a pipe: a pipe forks a subshell, and on fork-constrained runtimes
	# (browser/WASIX wasm, where fork is stubbed) that aborts init before raw
	# mode. A heredoc's data is in place with no fork, and detection is identical
	# (does the shell accept read -k / read -n). Native behaviour is unchanged.
	if { read -s -k1 -u9 2>/dev/null ;} 9<<'_TUISH_RK'
1
_TUISH_RK
	then
		_tuish_get_byte ()
		{
			IFS= read -r -k1 -u0 ${@:-} _tuish_byte 2>/dev/null || return 1
		}
		# Poll for input up to TUISH_IDLE_TIMEOUT, in <=30ms chunks: zsh defers
		# signals (traps) inside the read builtin, so each chunk boundary is a
		# delivery point and the trailing subshell fork forces any pending trap
		# to run. The chunk COUNT is derived from TUISH_IDLE_TIMEOUT in init
		# (_tuish_idle_chunks/_tuish_idle_chunk), so the idle interval honors the
		# configured timeout instead of a fixed 270ms.
		_tuish_idle_wait ()
		{
			local _i=$_tuish_idle_chunks
			while test $_i -gt 0
			do
				IFS= read -r -k1 -u0 $_tuish_idle_chunk _tuish_byte 2>/dev/null && return 0
				_i=$((_i - 1))
			done
			eval "$(:)" 2>/dev/null
			return 1
		}
		# zsh read -t0 reads a byte when one is available (unlike bash which
		# only checks). One call is enough to peek at the next pending byte.
		_tuish_peek_byte () { _tuish_get_byte -t0; }
	elif { read -r -t'0.1' -n 1 -u9 2>/dev/null ;} 9<<'_TUISH_RN'
1
_TUISH_RN
	then
		_tuish_get_byte ()
		{
			IFS= read -r -d '' -n 1 ${@:-} _tuish_byte 2>/dev/null || return 1
		}
		_tuish_idle_wait ()
		{
			_tuish_get_byte "$_tuish_idle_timeout"
		}
		# read -t0 semantics differ: bash/busybox only check availability
		# and need a second read to consume; ksh93/mksh consume the byte
		# on the spot (like zsh). Assuming the wrong one either loses
		# every other byte and blocks mid-burst (ksh93/mksh) or leaks
		# sequence bytes (zsh, see 258e6a4).
		#
		# ksh93 and mksh both set KSH_VERSION and both consume on -t0, so
		# select by shell identity. A runtime probe is unreliable here:
		# mksh's own `read -d '' -n 1 -t0` on a heredoc is non-deterministic
		# (it intermittently reports no data), which would sometimes pick the
		# two-read variant and then drop one byte on every peek that finds
		# input — the source of mksh's burst-event flakiness.
		if test -n "${KSH_VERSION:-}"
		then
			_tuish_peek_byte () { _tuish_get_byte -t0; }
		else
			# bash/busybox: probe with a heredoc — its data is in place
			# before read runs, so a zero timeout can't race the writer
			# the way a pipeline would. (Stable: both report no data, so
			# both take the two-read consume path.)
			_tuish_probe=''
			if { IFS= read -r -d '' -n 1 -t0 -u9 _tuish_probe 2>/dev/null &&
				test -n "${_tuish_probe}" ;} 9<<_tuish_heredoc
1
_tuish_heredoc
			then
				_tuish_peek_byte () { _tuish_get_byte -t0; }
			else
				_tuish_peek_byte () { _tuish_get_byte -t0 && _tuish_get_byte; }
			fi
		fi
	else
		echo 'Shell does not support interactive features (requires read -n or read -k)' 1>&2
		return 1
	fi
	return 0
}

# Derive the idle timeout, the zsh idle-chunk count, and TUISH_TICK_US (the µs
# per idle tick, used as the time-based-animation clock) from $1 (interval in
# seconds; empty = the timing-based default) and the already-detected
# TUISH_TIMING. Split out of _tuish_init_timing so it can be re-run at runtime by
# tuish_idle_interval — these values are per-context, so a hosted app can pick its
# own tick rate without disturbing its host. Takes the interval as a PARAMETER:
# TUISH_IDLE_TIMEOUT is pure launcher config, read once at init and never written
# by the framework (writing it back leaked one context's tick choice into the
# `${TUISH_IDLE_TIMEOUT:-...}` defaults of apps mounted later).
_tuish_derive_idle ()
{
	local _default='0.26'
	test "$TUISH_TIMING" = 'second' && _default='1'
	_tuish_interval_s="${1:-$_default}"
	_tuish_idle_timeout="-t${_tuish_interval_s}"

	# The idle interval in microseconds: the wall-time one idle tick spans.
	_tuish_timeout_us "$_tuish_interval_s"
	TUISH_TICK_US=$_tuish_tick_us

	# Chunked idle wait (zsh): poll in slices of at most 30ms up to the full
	# timeout so the idle interval tracks TUISH_IDLE_TIMEOUT. One read when it is
	# already <=30ms; otherwise ceil(timeout/30ms) slices of 30ms.
	_tuish_idle_chunk="$_tuish_idle_timeout"
	_tuish_idle_chunks=1
	if test "$TUISH_TIMING" != 'second'
	then
		local _itms=$(( TUISH_TICK_US / 1000 ))
		if test "$_itms" -gt 30
		then
			_tuish_idle_chunk='-t0.03'
			_tuish_idle_chunks=$(( (_itms + 29) / 30 ))
		fi
	fi
}

# Change the idle interval (the animation/tick clock) at runtime for the ACTIVE
# context — e.g. a hosted real-time app that wants a fast tick regardless of its
# host's. Per-context, so it is restored to the host's on return. SECS is a
# seconds value like 0.02 (sub-second needs a sub-timing terminal). Never touches
# TUISH_IDLE_TIMEOUT — that is launcher config, not state.
tuish_idle_interval ()
{
	_tuish_derive_idle "$1"
}

# Detect the timer resolution and derive the escape/idle timeouts and the zsh
# idle-chunk count from TUISH_IDLE_TIMEOUT.
_tuish_init_timing ()
{
	# Detect timeout resolution — whether `read -t` honors sub-second values. A
	# launcher can declare it (TUISH_TIMING=sub|second) to skip these two extra
	# pipe-forks; unset falls through to the probe, so native behaviour is unchanged.
	case "${TUISH_TIMING:-}" in
		sub|second) : ;;
		*)
			TUISH_TIMING='second'
			if { echo 1 | read -r -t'0.01' -n 1 2>/dev/null ;} ||
			   { echo 1 | read -r -t'0.01' -k1 -u0 2>/dev/null ;}
			then
				TUISH_TIMING='sub'
			fi ;;
	esac

	_tuish_esc_timeout="-t${TUISH_ESC_TIMEOUT:-0.02}"
	test "$TUISH_TIMING" = 'second' && _tuish_esc_timeout="-t${TUISH_ESC_TIMEOUT:-1}"
	_tuish_derive_idle "${TUISH_IDLE_TIMEOUT:-}"
	return 0
}

# Configure the terminal: variable init, stty + signal traps, setup escape
# sequences, cursor-position query, and tab stops.
_tuish_init_term ()
{
	_tuish_code=''
	_tuish_held=''
	_tuish_noinput=''

	# Save and configure terminal
	_tuish_previous_stty="$(stty -g)"
	_tuish_initialized=1
	trap '[ "${BASH_SUBSHELL:-${ZSH_SUBSHELL:-0}}" -eq 0 ] && { _tuish_exiting=1; tuish_fini; }' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 129' HUP
	# NOTE: busybox stty validates the WHOLE argument list before applying any of
	# it, and it has no `discard` control char — so a single `discard undef` makes
	# the entire call fail and (with the 2>/dev/null) silently leave the terminal
	# in cooked mode: echo on, canonical on, arrows echoing as ^[OA. On a dev box
	# `stty` is GNU coreutils and accepts it, so this only bites a busybox-only
	# system (the exact target for a shell-driven console distro). Keep the raw
	# setup in one call every stty accepts; disable VDISCARD (Ctrl-O) as a
	# best-effort follow-up. `raw` already clears IEXTEN, so VDISCARD is inert
	# regardless — the second call is belt-and-suspenders where it is supported.
	stty raw -echo -ctlecho -isig -icanon -ixon -ixoff -tostop -ocrnl \
		-icrnl -inlcr -igncr \
		intr undef quit undef werase undef time 0 2>/dev/null
	stty discard undef 2>/dev/null || :
	_tuish_stty="$(stty -g)"

	trap '_tuish_signal=resize; _tuish_precols=$TUISH_COLUMNS' WINCH 2>/dev/null || :
	trap ':' TSTP 2>/dev/null || :
	trap '_tuish_signal=cont; stty "$_tuish_stty"' CONT 2>/dev/null || :

	# Terminal setup sequences
	tuish_save_cursor
	_tuish_write '\033[?2004h\033[2K'   # bracketed paste, clear line
	_tuish_write '\033[22;0;0t'          # push title
	_tuish_write '\033[?1h'              # application cursor keys
	_tuish_write '\033[20l'              # LNM (ANSI mode 20) reset for the TUI
	tuish_hide_cursor

	# Get terminal size and cursor position via DSR. The CPR reply
	# (\033[<row>;<col>R) can arrive LATE relative to a single read window —
	# markedly so on a slow terminal (busybox under a multiplexer, and the
	# browser/wasm target, where the round-trip crosses a worker boundary). A
	# missed reply is not merely a lost row: the bytes leak into the first event
	# loop iteration, where \033[1;1R decodes as a spurious `f3` key. A line read
	# (`read -d R -t`) can also split the atomic reply across its timeout, dropping
	# it. So drain a byte at a time with the same FSM the mid-run cursor query uses
	# (viewport.sh:_tuish_query_cursor_row): once the reply starts it arrives
	# contiguously, so only the first byte waits; a tty that never answers (a pipe,
	# CI) gives up after one per-byte timeout. Native startup is unchanged.
	tuish_update_size
	local _tuish_it_newx=0 _tuish_it_newy=0
	_tuish_write '\033[6n\r'
	if type _tuish_get_byte >/dev/null 2>&1
	then
		local _tuish_it_cst=0 _tuish_it_crow='' _tuish_it_ccol=''
		while _tuish_get_byte -t0.5
		do
			case $_tuish_it_cst in
				0) _tuish_ord "$_tuish_byte"
				   test $_tuish_code -eq 27 && _tuish_it_cst=1 ;;
				1) case "$_tuish_byte" in '[') _tuish_it_cst=2 ;; *) _tuish_it_cst=0 ;; esac ;;
				2) case "$_tuish_byte" in
				       [0-9]) _tuish_it_crow="${_tuish_it_crow}${_tuish_byte}" ;;
				       ';') _tuish_it_cst=3 ;;
				       *) _tuish_it_cst=0; _tuish_it_crow='' ;;
				   esac ;;
				3) case "$_tuish_byte" in
				       [0-9]) _tuish_it_ccol="${_tuish_it_ccol}${_tuish_byte}" ;;
				       R) test -n "$_tuish_it_crow" && _tuish_it_newx=$_tuish_it_crow; test -n "$_tuish_it_ccol" && _tuish_it_newy=$_tuish_it_ccol; break ;;
				       *) _tuish_it_cst=0; _tuish_it_crow=''; _tuish_it_ccol='' ;;
				   esac ;;
			esac
		done
	fi
	TUISH_INIT_ROW=$_tuish_it_newx

	# Focus events (mouse tracking is off by default; use tuish_mouse_on)
	_tuish_write '\033[?1004h'   # focus events
	_tuish_write '\033[777h'     # ambiguous width
	_tuish_write '\033[?7l'      # DECAWM off: clip at right edge

	# Frames become atomic from here on (see _tuish_sink). Launcher config, like
	# TUISH_IDLE_TIMEOUT above it: read once, never written back. Set TUISH_SYNC=0 to
	# opt out — worth having because BSU/ESU is the one setting that can HIDE a
	# rendering bug, by making a half-drawn frame invisible instead of merely brief.
	#
	# A `case`, not `test -eq`: this reads a value a human typed, and `-eq` on a
	# non-number ("no", "false") writes "integer expression expected" to the one
	# stream the app is about to draw on. Anything that is not exactly 0 opts in.
	case "${TUISH_SYNC:-1}" in 0) ;; *) _tuish_sync=1;; esac

	TUISH_PROTOCOL='vt'

	# Set tab stops
	_tuish_write '\033[3g'
	local _tuish_it_tcont=0
	while test $_tuish_it_tcont -lt ${TUISH_COLUMNS}
	do
		_tuish_write '\033['"${TUISH_TABSIZE}"'C\033H'
		_tuish_it_tcont=$((_tuish_it_tcont + TUISH_TABSIZE))
	done
	_tuish_write '\r'
}

# Bring up the shared terminal DEVICE (raw mode, timing, setup sequences). Runs
# exactly once per process; nested apps skip it (the device is already up).
_tuish_device_init ()
{
	_tuish_init_io || return 1
	_tuish_init_timing
	_tuish_init_term
}

tuish_init ()
{
	# Make `local` mean local (compat.sh). A no-op on every shell but ksh93, where it is
	# what stops a framework helper's scratch variable from overwriting a caller's.
	#
	# HERE, and not at the bottom of a module, because it has to run once EVERYTHING is
	# defined — every tuish module the app chose to source, and the app's own functions
	# too. tuish_init is the first moment that is guaranteed to be true, and it is on the
	# fixup's own skip list, so it can safely rewrite the others while it is running.
	tuish_fnfix

	if test "$_tuish_initialized" -eq 1
	then
		# Device already up — we are nested inside a host. Adopt the context the
		# host activated for us; create+activate one if the host did not.
		if test -z "$_tuish_ctx_active"
		then
			tuish_ctx_create
			tuish_ctx_activate "$TUISH_CTX"
		fi
		return 0
	fi
	_tuish_device_init || return 1
	# The idle timing only takes its real value here, in device init. Refresh its
	# registered defaults so contexts created later inherit the live host tick
	# (not the source-time placeholder), then build the root context from them.
	_tuish_ctx_recapture _tuish_idle_timeout _tuish_idle_chunk _tuish_idle_chunks TUISH_TICK_US _tuish_interval_s
	tuish_ctx_create
	TUISH_CTX_ROOT=$TUISH_CTX
	tuish_ctx_activate "$TUISH_CTX_ROOT"
	return 0
}

tuish_fini ()
{
	# Nested child being UNMOUNTED by its host (explicit tuish_fini / modal return,
	# not process exit): fold only its own viewport, drop its context, and resume
	# the parent. The shared device (stty/traps) stays up for the host — a child
	# must never restore the terminal out from under its host. But on a real exit
	# (_tuish_exiting, set by the EXIT trap) we fall through to device teardown even
	# with a child active — otherwise a signal mid-embed leaves the terminal in raw
	# mode / alt-screen. The child's own cleanup still runs, below, in the device
	# path (it reads the active context's _tuish_fini_fn, which is the child's).
	if test "${_tuish_exiting:-0}" -eq 0 \
		&& test -n "$_tuish_ctx_active" && test "$_tuish_ctx_active" != "$TUISH_CTX_ROOT"
	then
		_tuish_buffering=0
		_tuish_buf=''
		# The app's own registered cleanup (device state it changed: cursor
		# shape, ...) — the code after a driven app's tuish_run never runs, so
		# this is its one reliable teardown point.
		test -n "$_tuish_fini_fn" && { "$_tuish_fini_fn" || :; }
		_tuish_on_fini
		local _tuish_f_cur="$_tuish_ctx_active" _tuish_f_p="$_tuish_ctx_parent"
		test -n "$_tuish_f_p" && tuish_ctx_activate "$_tuish_f_p"
		tuish_ctx_destroy "$_tuish_f_cur"
		return 0
	fi

	# Idempotent: safe to call from both explicit call and EXIT trap
	test "$_tuish_initialized" -eq 0 && return 0
	_tuish_initialized=0
	trap - EXIT INT TERM HUP 2>/dev/null || :
	trap - WINCH TSTP CONT 2>/dev/null || :

	# Bypass buffering so cleanup sequences reach the terminal
	_tuish_buffering=0
	_tuish_buf=''

	# Hide cursor during cleanup to avoid flicker
	tuish_hide_cursor

	# The app's registered cleanup, then the viewport teardown.
	test -n "${_tuish_fini_fn:-}" && { "$_tuish_fini_fn" || :; }
	_tuish_fini_push_gap=0
	_tuish_on_fini

	# Restore keyboard protocol
	if test "$TUISH_PROTOCOL" = 'kitty'
	then
		_tuish_write '\033[<u'
		_tuish_write '\033[>0u'
		TUISH_PROTOCOL='vt'
	fi

	# Restore terminal
	tuish_reset_scroll
	_tuish_hid_fini              # hid.sh: disable mouse tracking if it was on
	_tuish_write '\033[?1004l'   # focus events off
	_tuish_write '\033[777l'
	_tuish_write '\033[?2004l'   # bracketed paste off
	_tuish_write '\033[?1l'      # normal cursor keys
	_tuish_write '\033>'         # normal keypad
	tuish_restore_cursor
	# DECAWM must be restored AFTER DECRC (tuish_restore_cursor): the viewport
	# teardown's DECSC saved cursor state while autowrap was off (init sets
	# \033[?7l), and on conpty/Windows Terminal DECRC restores DECAWM to that
	# saved-off value — reverting an earlier \033[?7h. (xterm/tmux don't, which
	# is why this only bit some terminals.) Re-assert it here, last.
	_tuish_write '\033[?7h'      # DECAWM on: restore auto-wrap
	if test "${TUISH_FINI_OFFSET:-0}" -gt 0
	then
		_tuish_write '\033['"${TUISH_FINI_OFFSET}"'B'
	fi
	# Move cursor up past empty space left by viewport push
	if test $_tuish_fini_push_gap -gt 0 && test "$_tuish_quit_mode" != 'main'
	then
		_tuish_write '\033['"$_tuish_fini_push_gap"'A'
	fi
	_tuish_write '\033[20h'      # LNM (ANSI mode 20) set: restore newline mode
	_tuish_write '\033[23;0;0t'  # pop title
	# DECSCUSR: put the caret back, but only if we ever took it. A reader who configured a
	# bar caret in their own terminal should not get a block back from an app that never had
	# an opinion about it — and this is the ONE place that emits DECSCUSR 0, because it is
	# the one place where "restore the default" is what it means.
	if test "$_tuish_cursor_shape_set" -eq 1
	then _tuish_write '\033[0 q'
	fi
	_tuish_cursor_shape_dev=''
	_tuish_cursor_shape_set=0
	tuish_show_cursor
	# Stop wrapping writes before the last one goes out, so teardown leaves the stream
	# exactly as it found it. BSU is self-closing per write, so there is no unbalanced
	# ESU to worry about — this only stops NEW ones.
	_tuish_sync=0

	# Restore stty: prefer the exact saved state so a faithful snapshot
	# (e.g. IUTF8, and any terminal-specific flags) is preserved. Fall back
	# to sane only if we never captured one (init aborted) or the restore
	# fails — otherwise `stty sane` clobbers the just-restored original.
	if test -n "${_tuish_previous_stty:-}" && stty "$_tuish_previous_stty" 2>/dev/null
	then :
	else stty sane echo icanon 2>/dev/null || :
	fi

	# Drain stdin
	while read -r -t'0.1' 2>/dev/null
	do
		:
	done

	if test "$_tuish_quit_mode" = 'main'
	then
		# Position cursor below last content row
		test $_tuish_fini_push_gap -gt 0 && _tuish_write '\n' || :
	else
		_tuish_write '\r\033[2K'
	fi

	# Drop the root context now that the device is down.
	if test -n "$_tuish_ctx_active"
	then
		tuish_ctx_destroy "$_tuish_ctx_active"
		_tuish_ctx_active=''
	fi
}
