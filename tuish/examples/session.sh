#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# session.sh — a pure-TUI "desktop" for the bare console.
#
# One host event loop, no forks, no nested tuish_run: a status bar with a live
# clock, a LAUNCHER menu down the left, and a MAIN region that mounts a whole
# tuish app (the editor, boxes, canvas, the platformer) into itself. Pick an app
# in the launcher and it comes up in the region, live, while the clock keeps
# ticking beside it — the same cooperative model as examples/cooperative.sh, but
# with the mounted child chosen at runtime instead of fixed at two.
#
# This is the "desktop" of a tuish-driven console distro: run it as the login
# shell on tty1 (no X, no Wayland) and it IS the session. It needs nothing the
# framework does not already give it — src/host.sh owns the child table, the
# focus model, and the per-child tick negotiation; this file is layout + a menu.
#
#   Input model
#     ↑/↓        move the launcher selection
#     Enter      launch the selected app into the main region (focus follows)
#     Tab        toggle focus between the launcher and the running app
#     Ctrl+W     close the running app, back to the launcher
#     Ctrl+Q     quit the session
#     click      a launcher row launches it; the app region focuses the app
#
# The apps are ordinary, unmodified examples: each is dual-mode (it only defines
# its functions when tuish is already loaded) and exposes a non-blocking _setup
# half — exactly what a host mounts. The launcher swaps the running app by giving
# each a slot id that changes with the app ("app:editor" → "app:boxes"): the old
# id vanishes from the declared list so host_commit unmounts it, and the new id
# mounts fresh. Same reconciliation cooperative.sh leans on, one app at a time.

# ─── Bootstrap ────────────────────────────────────────────────────
# Runs top-level (it is the host). Guard like the examples so it could itself be
# hosted one day: only bring up the modules when tuish is not already loaded.
if test -z "${_tuish_tui_loaded:-}"
then
	_sess_standalone=1
	set -euf
	_sess_dir="$(cd "$(dirname "$0")" && pwd)"
	_src="${_sess_dir}/../src"
	. "${_src}/compat.sh"
	. "${_src}/ord.sh"
	. "${_src}/tui.sh"
	. "${_src}/term.sh"
	. "${_src}/event.sh"
	. "${_src}/hid.sh"
	. "${_src}/viewport.sh"
	. "${_src}/str.sh"
	. "${_src}/buf.sh"
	. "${_src}/canvas.sh"
	. "${_src}/draw.sh"
	. "${_src}/keybind.sh"
	. "${_src}/host.sh"
	_sess_ex="${_sess_dir}"
else
	_sess_standalone=0
	_sess_ex="${TUISH_EXAMPLES:-.}"
fi

# The launchable apps, SOURCED (tuish is loaded, so each only defines its _*_
# functions — including the non-blocking _setup half this host mounts). If an
# example is missing its row simply never appears.
for _sess_f in editor boxes canvas_demo game debug
do
	test -f "${_sess_ex}/${_sess_f}.sh" && . "${_sess_ex}/${_sess_f}.sh"
done

# ─── The app catalog ──────────────────────────────────────────────
# One entry per launchable app: "name|setup_fn|Label". name is the slot-id stem
# (identity host_commit reconciles on), setup_fn is the mount target, Label is
# what the launcher shows. Kept as a newline-free list so a `for` splits it.
_SESS_APPS='editor|_ed_setup|Editor boxes|_bx_setup|Boxes canvas|_cd_setup|Canvas game|_g_setup|Platformer debug|_dbg_setup|Debug'

# Keep only the apps whose setup function actually got defined (the example was
# present and sourced). tuish_dispatch-style feature test, not a guess.
_sess_catalog=''
_sess_count=0
for _sess_e in $_SESS_APPS
do
	_sess_fn="${_sess_e#*|}"; _sess_fn="${_sess_fn%%|*}"
	if type "$_sess_fn" >/dev/null 2>&1
	then
		_sess_catalog="${_sess_catalog}${_sess_e} "
		_sess_count=$(( _sess_count + 1 ))
	fi
done

# nth catalog entry (1-based) -> _sess_name / _sess_setup / _sess_label
_sess_entry ()   # $1 = index
{
	local _i=0 _e
	_sess_name=''; _sess_setup=''; _sess_label=''
	for _e in $_sess_catalog
	do
		_i=$(( _i + 1 ))
		if test "$_i" -eq "$1"
		then
			_sess_name="${_e%%|*}"
			_sess_setup="${_e#*|}"; _sess_setup="${_sess_setup%%|*}"
			_sess_label="${_e##*|}"
			return 0
		fi
	done
	return 1
}

# ─── State ────────────────────────────────────────────────────────
_sess_sel=1            # highlighted launcher row (1-based)
_sess_app=''           # name of the running app ('' = none)
_sess_app_setup=''     # its setup fn
_sess_zone='menu'      # where the keyboard goes: 'menu' or 'app'
_sess_full=1           # 1 = the next render repaints the whole background
_sess_last_sec=''      # last clock second painted (idle-repaint throttle)
_sess_hover=0          # launcher row under the mouse (0 = none), a painted highlight
_sess_mx=0 _sess_my=0  # last mouse cell — where the pointer caret goes (menu zone)

# The mouse pointer IS the hardware caret. This runs on the bare Linux VT, where
# no terminal emulator draws an OS pointer and the caret is the one glyph the
# console always paints on top of everything, for free, at any cell. So we use it
# — but COOPERATIVELY, only while the launcher owns the keyboard (menu zone). Focus
# into an app and the app owns the caret instead: the editor shows its text caret,
# the game keeps it hidden (see tuish_host_paint). That is why the pointer vanishes
# when you Tab into an app — the one caret went to the thing you are now driving.
#
# It must be RE-ASSERTED as the last write of every frame, INCLUDING after a running
# app's per-tick direct paint. The game writes cells without moving the caret back,
# so a pointer left un-reasserted gets dragged to the last sprite drawn — the old
# caret-stuck-to-the-character bug. Cheap: one CUP (+ show) per frame. The event
# handler is already inside tuish_begin/tuish_end, so this just appends to the frame.
_sess_point ()
{
	test "$_sess_zone" = 'menu' || return 0     # an app owns the caret; hands off
	test "${_sess_mx:-0}" -ge 1 || return 0     # mouse never moved yet
	# tuish_cursor (not a raw move+show) so the pointer carries a SHAPE: a steady
	# block (tuish_cursor_shape 2, declared at setup) — easy to spot, and it rides
	# the framework's device cache so the escape only goes out when the shape
	# actually changed (e.g. after a focused editor left its bar behind).
	tuish_cursor "$_sess_my" "$_sess_mx"
	return 0
}

# The launcher row under the mouse gets a painted highlight too — a hover affordance
# distinct from the caret, so a launchable row lights up under the pointer. Repaints
# only when the hovered row CHANGES (cheap on high-frequency motion), and only over
# the menu column — the app region is the child's to draw.
_sess_hover_at ()
{
	local _c=${TUISH_MOUSE_X:-0} _y=${TUISH_MOUSE_Y:-0} _nh=0
	if test "$_c" -ge "$_mc" && test "$_c" -lt "$_ac"
	then
		local _row=$(( _y - _top ))
		test "$_row" -ge 1 && test "$_row" -le "$_sess_count" && _nh=$_row
	fi
	if test "$_nh" -ne "$_sess_hover"
	then _sess_hover=$_nh; tuish_request_redraw; fi
	return 0
}

# ─── Palette ──────────────────────────────────────────────────────
C_BG='13:17:23'
C_BORDER='40:52:74'
C_ACCENT='125:211:222'
C_ACCENT2='181:160:255'
C_DIM='120:132:150'
C_HEAD='236:240:248'
C_SEL='30:41:59'
C_HOVER='22:27:38'      # mouse hover: a subtler fill than the selection

# ─── Layout ───────────────────────────────────────────────────────
# Menu column on the left, app region filling the rest. Recomputed on every
# paint and resize; the rectangles change, the app's slot id does not, so
# host_commit reseats the running app rather than remounting it.
_MENU_W=22
_sess_lay ()
{
	_W=$TUISH_COLUMNS; _H=$TUISH_LINES
	_top=3
	_bot=$(( _H - 1 ))
	_bh=$(( _bot - _top + 1 ))

	_mc=2                       # menu box column
	_mw=$_MENU_W
	_ac=$(( _mc + _mw + 1 ))    # app box column
	_aw=$(( _W - _ac ))         # app box width (to one cell shy of the edge)
	test $_aw -lt 8 && _aw=8

	# App interior (inside the box border), in absolute host cells.
	_ai_r=$(( _top + 1 )); _ai_c=$(( _ac + 1 ))
	_ai_w=$(( _aw - 2 ));  _ai_h=$(( _bh - 2 ))
	test $_ai_w -lt 1 && _ai_w=1
	test $_ai_h -lt 1 && _ai_h=1
	return 0        # never let a false `test &&` above be _sess_lay's exit status (set -e)
}

# Declare the children. Only the running app is a child; the launcher is host
# chrome. Re-run on launch, close, and resize.
_sess_slots ()
{
	_sess_lay
	tuish_host_begin
	if test -n "$_sess_app"
	then
		tuish_host_slot "app:$_sess_app" "$_sess_app_setup" '' \
			"$_ai_r" "$_ai_c" "$_ai_w" "$_ai_h"
	fi
	tuish_host_commit
}

# ─── Launcher actions ─────────────────────────────────────────────
_sess_launch ()   # mount the selected app, hand it the keyboard
{
	_sess_entry "$_sess_sel" || return 0
	_sess_full=1
	_sess_app="$_sess_name"
	_sess_app_setup="$_sess_setup"
	_sess_slots
	_sess_zone='app'
	tuish_host_focus "app:$_sess_app"
	tuish_request_redraw
}

_sess_close ()    # unmount the running app, back to the launcher
{
	test -n "$_sess_app" || return 0
	_sess_full=1
	_sess_app=''
	_sess_app_setup=''
	_sess_slots                 # the vanished id gets unmounted here
	_sess_zone='menu'
	TUISH_HOST_FOCUS=''
	tuish_request_redraw
}

_sess_move ()     # $1 = -1 | +1 : move the selection, wrapping
{
	test "$_sess_count" -gt 0 || return 0
	_sess_sel=$(( _sess_sel + $1 ))
	test "$_sess_sel" -lt 1            && _sess_sel=$_sess_count
	test "$_sess_sel" -gt "$_sess_count" && _sess_sel=1
	tuish_request_redraw
}

# ─── Render ───────────────────────────────────────────────────────
_sess_render ()
{
	_sess_lay
	tuish_begin
	# The background is filled only on a STRUCTURAL change (launch/close/resize);
	# routine repaints overwrite in place.
	#
	# This guard was kept deliberately, and measured. Dropping it costs 4434 ->
	# 7655 bytes per frame, because every frame then erases the whole screen and
	# paints over it. Under synchronized output (tui.sh) that is invisible and the
	# guard would be pure waste — but THIS app's target is the bare Linux VT, which
	# has no synchronized output at all, and there a frame that blanks the screen
	# before repainting it is a frame you watch happen.
	#
	# So it is not "flicker avoidance" any more, it is the VT concession. What would
	# retire it is the framework knowing what is already on screen and declining to
	# write it again; until then this stays, and it stays HERE rather than in the
	# framework because only the app knows a repaint was structural.
	if test "$_sess_full" -eq 1
	then tuish_draw_fill 1 1 "$_W" "$_H" bg=$C_BG; _sess_full=0; fi

	# Status bar: title left, live clock right.
	tuish_text 1 2 'tuish · session' fg=$C_ACCENT bg=$C_BG
	local _t; _t="$(date '+%H:%M:%S' 2>/dev/null)" || _t=''
	if test -n "$_t"
	then
		tuish_str_width _t; local _tw=$TUISH_SWIDTH
		tuish_text 1 $(( _W - _tw - 1 )) "$_t" fg=$C_DIM bg=$C_BG
	fi

	# The focused zone gets the bright border.
	local _mfg=$C_BORDER _afg=$C_BORDER
	case "$_sess_zone" in menu) _mfg=$C_ACCENT;; app) _afg=$C_ACCENT;; esac

	# Launcher box + rows.
	tuish_draw_box "$_top" "$_mc" "$_mw" "$_bh" fg=$_mfg bg=$C_BG style=rounded
	tuish_text "$_top" $(( _mc + 2 )) ' apps ' fg=$C_ACCENT2 bg=$C_BG
	local _i=1 _rr=$(( _top + 1 ))
	while test "$_i" -le "$_sess_count"
	do
		_sess_entry "$_i" || break
		local _fg=$C_HEAD _bg=$C_BG _mark='  '
		if test "$_i" -eq "$_sess_sel"
		then _bg=$C_SEL; _fg=$C_ACCENT; _mark='▸ '
		     test "$TUISH_DRAW_BACKEND" = ascii && _mark='> '
		elif test "$_i" -eq "$_sess_hover"
		then _bg=$C_HOVER      # painted pointer: subtler than selection, no marker
		fi
		test "$_sess_name" = "$_sess_app" && _fg=$C_ACCENT2
		# One write for the whole row: width= pads the label out to the box interior,
		# and the padding carries bg=, so the selection highlight fills the row. The
		# clear_region that used to precede this walked the same cells a second time
		# and left them blank in between — which the bare console shows you.
		tuish_text "$_rr" $(( _mc + 1 )) "${_mark}${_sess_label}" \
		           fg=$_fg bg=$_bg width=$(( _mw - 2 ))
		_i=$(( _i + 1 )); _rr=$(( _rr + 1 ))
	done

	# App region box + (when empty) a hint.
	tuish_draw_box "$_top" "$_ac" "$_aw" "$_bh" fg=$_afg bg=$C_BG style=rounded
	local _title=' app '
	test -n "$_sess_app" && _title=" $_sess_app "
	tuish_text "$_top" $(( _ac + 2 )) "$_title" fg=$C_ACCENT bg=$C_BG
	if test -z "$_sess_app"
	then
		local _hint='Select an app · press Enter'
		tuish_str_width _hint; local _hw=$TUISH_SWIDTH
		tuish_text $(( _top + (_bh / 2) )) $(( _ac + (_aw - _hw) / 2 )) \
			"$_hint" fg=$C_DIM bg=$C_BG
	fi

	# Footer hints.
	local _keys='↑↓ select · Enter launch · Tab focus · Ctrl+W close · q quit'
	test "$TUISH_DRAW_BACKEND" = ascii \
		&& _keys='up/dn select . Enter launch . Tab focus . Ctrl+W close . q quit'
	tuish_text "$_H" 2 "$_keys" fg=$C_DIM bg=$C_BG

	# The children last, focused one on top: it owns the caret (the editor shows its
	# text caret here, the game keeps it hidden). In the menu zone no child owns it,
	# so the mouse pointer caret goes on top, as the frame's last write.
	tuish_host_paint
	_sess_point
	tuish_end
}

# ─── The router ───────────────────────────────────────────────────
# Signals relayout. Idle ticks every child (so a mounted game/clock stays live)
# and refreshes the status clock. Keys go to the launcher or, when an app is
# focused, through host_route to that app — except the session's own hotkeys.
_sess_on_event ()
{
	if test "$TUISH_EVENT_KIND" = 'signal'
	then _sess_full=1; _sess_slots; _sess_render; return 0; fi

	if test "$TUISH_EVENT" = 'idle'
	then
		tuish_host_route || :          # tick the running app at its own rate
		# A running app that animates (the game) paints itself straight into the
		# frame, flushed by the event loop — so it does NOT need a host repaint.
		# The host only repaints to advance the STATUS CLOCK, i.e. once a second,
		# not every idle tick: dropping this doubles the frame count to redraw a
		# clock that did not change. That is a STATE test — "has the second ticked"
		# — which is the kind the framework cannot make for you and the kind worth
		# keeping (see docs/event.md). It is not about blink.
		# But the app's paint moved the hardware caret, so put the pointer back at
		# the mouse as the LAST write of this frame — else it trails the sprite.
		_sess_point
		local _now; _now="$(date '+%H:%M:%S' 2>/dev/null)" || _now=''
		if test "$_now" != "$_sess_last_sec"
		then _sess_last_sec="$_now"; tuish_request_redraw; fi
		return 0
	fi

	# Track the mouse: move the pointer caret to it (cheap — one escape, no repaint,
	# so it follows even on motion we don't repaint the desktop for) and update the
	# launcher hover highlight (repaints only when the hovered row changes).
	case "$TUISH_EVENT_KIND" in
		mouse) _sess_mx=$TUISH_MOUSE_X; _sess_my=$TUISH_MOUSE_Y
		       _sess_point; _sess_hover_at;;
	esac

	# Session-wide hotkey.
	case "$TUISH_EVENT" in
		ctrl-q) tuish_quit; return 0;;
	esac

	# Keyboard goes to the focused app (cooperative — the launcher stays live, so a
	# mouse hover/click on it still works), except the session's own keys.
	if test "$_sess_zone" = 'app' && test -n "$_sess_app"
	then
		case "$TUISH_EVENT" in
			tab)    _sess_zone='menu'; TUISH_HOST_FOCUS=''; tuish_request_redraw; return 0;;
			ctrl-w) _sess_close; return 0;;
			*)
				tuish_host_route || :
				# Repaint so a hosted app that coalesces its redraw (debug, editor)
				# updates on THIS event — but NOT on high-frequency mouse motion.
				# Measured at 356 -> 1163 bytes per frame with this dropped: motion
				# arrives far faster than anything on screen changes, so each of those
				# frames re-sends a desktop that is already correct. Motion still
				# reaches the app; it shows on the next discrete event or clock tick.
				# A framework that remembered the screen would make this unnecessary.
				case "$TUISH_EVENT" in
					*move|*hold) : ;;
					*)           tuish_request_redraw ;;
				esac
				# The app may quit itself (its own quit key) — host_route hands its
				# id back in TUISH_HOST_QUIT.
				if test -n "$TUISH_HOST_QUIT"
				then tuish_quit_clear; _sess_close; fi
				return 0;;
		esac
	fi

	# Launcher zone.
	case "$TUISH_EVENT" in
		up)     _sess_move -1;;
		down)   _sess_move 1;;
		enter)  _sess_launch;;
		# `q` quits from the launcher: Ctrl+Q is unreliable on busybox (the distro's
		# own shell), so the primary quit must be a plain byte. A focused app owns
		# `q` itself, so this only fires at the launcher.
		'char q') tuish_quit;;
		tab)    test -n "$_sess_app" && { _sess_zone='app'; tuish_host_focus "app:$_sess_app"; tuish_request_redraw; };;
		lclik)  _sess_click;;
		*)      : ;;
	esac
	return 0
}

# A click in the launcher column selects (and launches) that row; a click in the
# app region focuses the running app. TUISH_MOUSE_ROW/COL are absolute cells.
_sess_click ()
{
	local _r=${TUISH_MOUSE_Y:-0} _c=${TUISH_MOUSE_X:-0}
	if test "$_c" -ge "$_mc" && test "$_c" -lt "$_ac"
	then
		local _row=$(( _r - _top ))       # 1-based row inside the menu list
		if test "$_row" -ge 1 && test "$_row" -le "$_sess_count"
		then _sess_sel=$_row; _sess_launch; fi
		return 0
	fi
	if test -n "$_sess_app" && test "$_c" -ge "$_ac"
	then _sess_zone='app'; tuish_host_focus "app:$_sess_app"; tuish_request_redraw; fi
	return 0
}

# ─── Entry ────────────────────────────────────────────────────────
_sess_main ()
{
	tuish_init
	tuish_mouse_on
	tuish_viewport fullscreen
	tuish_cursor_shape 2   # the mouse pointer is a STEADY BLOCK caret — easy to find

	tuish_on_redraw _sess_render
	tuish_on_event  _sess_on_event

	_sess_slots
	_sess_render
	tuish_run || :

	tuish_host_clear
	tuish_fini
}

if test "${_sess_standalone:-0}" -eq 1
then
	_sess_main
fi
