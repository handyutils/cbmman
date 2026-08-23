# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Load guard: skip re-definition if already sourced (see tui.sh).
if test -n "${_tuish_viewport_loaded:-}"; then return 0; fi
_tuish_viewport_loaded=1
# src/viewport.sh - Viewport modes (fullscreen, fixed, grow)
# Optional module. Source after tui.sh and term.sh.
#
# Provides:
#   tuish_viewport MODE [MAX] - set viewport mode
#   tuish_grow                - emit line in grow mode
#   tuish_clamp_scroll POS ORIGIN SPAN [MARGIN] - scroll-into-view origin
#
# Overrides:
#   _tuish_viewport_on_resize - resize handler (event.sh stub)
#   _tuish_on_fini            - viewport teardown (tui.sh stub)
#
# Variables (set by tuish_viewport, updated on resize):
#   TUISH_VIEW_MODE  - current mode: "fullscreen", "fixed", "grow", or ""
#   TUISH_VIEW_ROWS  - usable content rows in viewport
#   TUISH_VIEW_COLS  - usable content columns (= TUISH_COLUMNS)
#   TUISH_VIEW_TOP   - absolute terminal row where viewport starts (1-based)

# ─── Viewport state ───────────────────────────────────────────────
# _tuish_view_mode is initialized in tui.sh (viewport defaults).

_tuish_view_max=15
_tuish_view_origin=0
_tuish_view_anchor=0
_tuish_view_saved_origin=0
_tuish_view_saved_anchor=0
_tuish_view_altscreen=0
_tuish_view_phys=0
_tuish_view_grow_phase=0
_tuish_view_grow_count=0
_tuish_resize_cursor_row=0

# Viewport geometry is per-context. (_tuish_resize_cursor_row and the relayout
# out-vars below are transient scratch consumed within one call — device-global.)
tuish_ctx_register \
	_tuish_view_max _tuish_view_origin _tuish_view_anchor \
	_tuish_view_saved_origin _tuish_view_saved_anchor _tuish_view_altscreen \
	_tuish_view_phys _tuish_view_grow_phase _tuish_view_grow_count

# Outputs of _tuish_viewport_relayout / _tuish_grow_pin_origin (set before read;
# defaulted here for set -u). sr_top=0 means "no repair / no scroll region".
_tuish_relayout_rf=0
_tuish_relayout_rt=0
_tuish_relayout_sr_top=0
_tuish_relayout_sr_bot=0
_tuish_grow_bot=0

# ─── Scroll-into-view ─────────────────────────────────────────────

# tuish_clamp_scroll POS ORIGIN SPAN [MARGIN] -> TUISH_SCROLL
#
# Pure integer math: given a current scroll ORIGIN and a window SPAN units wide,
# return in TUISH_SCROLL the minimal new origin so POS lands inside the window
# [ORIGIN, ORIGIN+SPAN). Unit-agnostic — POS/ORIGIN/SPAN must share one unit
# (rows or display columns). MARGIN (default 0) keeps that many units of context
# between POS and the nearer edge (scroll-off); it is clamped so the window can
# still hold POS. The result is floored at 0. ORIGIN is returned unchanged when
# POS is already visible.
tuish_clamp_scroll ()
{
	local _pos=$1 _org=$2 _span=$3 _m=${4:-0}
	if test $((_m * 2)) -ge "$_span"
	then _m=$(( (_span - 1) / 2 )); fi
	test "$_m" -lt 0 && _m=0
	if test "$_pos" -lt $((_org + _m))
	then TUISH_SCROLL=$((_pos - _m))
	elif test "$_pos" -gt $((_org + _span - 1 - _m))
	then TUISH_SCROLL=$((_pos - _span + 1 + _m))
	else TUISH_SCROLL=$_org
	fi
	if test "$TUISH_SCROLL" -lt 0; then TUISH_SCROLL=0; fi
	return 0
}

# ─── Reserve space ───────────────────────────────────────────────

_tuish_viewport_reserve_space ()
{
	local _rows=${1:-$TUISH_VIEW_ROWS}
	local _needed=$((_tuish_view_origin + _rows - 1))
	if test $_needed -gt $TUISH_LINES
	then
		# Scroll by emitting _rows-1 newlines (reach bottom, then push)
		local _push=$((_rows - 1))
		local _i=0
		while test $_i -lt $_push
		do
			_tuish_write '\n'
			_i=$((_i + 1))
		done
		# Pin viewport to the bottom of the screen
		_tuish_view_origin=$((TUISH_LINES - _rows + 1))
		test $_tuish_view_origin -lt 1 && _tuish_view_origin=1
		TUISH_VIEW_TOP=$_tuish_view_origin
	fi
}

# Push content up so the invocation line (one row above the
# anchor) lands at terminal row 1, then pin origin to row 2.
_tuish_viewport_shrink_push ()
{
	# Compute auto-scroll from the queried post-resize cursor row.
	# Fall back to estimation when the DSR query returned no info.
	local _scroll=0
	local _post_row=$_tuish_resize_cursor_row
	test $_post_row -ge $_tuish_cursor_abs_row && _post_row=$TUISH_LINES
	test $_tuish_cursor_abs_row -gt $_post_row && \
		_scroll=$((_tuish_cursor_abs_row - _post_row))
	local _invoc=$((_tuish_view_anchor - 1 - _scroll))
	if test $_invoc -gt 1
	then
		tuish_move $TUISH_LINES 1
		local _i=0
		while test $_i -lt $((_invoc - 1))
		do
			_tuish_write '\n'
			_i=$((_i + 1))
		done
	fi
	if test $_invoc -le 0
	then
		# Invocation line was pushed into scrollback by terminal
		# auto-scroll — unrecoverable.  Use the full screen.
		_tuish_view_origin=1
	else
		_tuish_view_origin=2
		test $_tuish_view_origin -gt $TUISH_LINES && _tuish_view_origin=1
	fi
	_tuish_view_anchor=$_tuish_view_origin
}

# ─── Cursor-row query (DSR/CPR) ──────────────────────────────────
# Query the terminal for the cursor row via DSR (\033[6n) and parse the CPR
# reply \033[<row>;<col>R as a byte-at-a-time FSM. Result in
# _tuish_resize_cursor_row (defaults to the tracked row). Reads one byte at a
# time rather than init's `read -d R` because mid-event, in raw mode, the line
# reader is unreliable.
_tuish_query_cursor_row ()
{
	_tuish_resize_cursor_row=$_tuish_cursor_abs_row
	type _tuish_get_byte >/dev/null 2>&1 || return 0
	_tuish_write '\033[6n'
	local _qst=0 _qrow=''
	while _tuish_get_byte -t1
	do
		case $_qst in
			0)
				_tuish_ord "$_tuish_byte"
				test $_tuish_code -eq 27 && _qst=1
				;;
			1)
				case "$_tuish_byte" in
					'[') _qst=2 ;;
					*) _qst=0 ;;
				esac
				;;
			2)
				case "$_tuish_byte" in
					[0-9]) _qrow="${_qrow}${_tuish_byte}" ;;
					';') _qst=3 ;;
					*) _qst=0; _qrow='' ;;
				esac
				;;
			3)
				case "$_tuish_byte" in
					[0-9]) ;;
					R)
						test -n "$_qrow" && \
							_tuish_resize_cursor_row=$_qrow
						break
						;;
					*) _qst=0; _qrow='' ;;
				esac
				;;
		esac
	done
	return 0
}

# ─── Grow pin-origin ─────────────────────────────────────────────
# A grown viewport's bottom is INIT_ROW+grow_count. Compute it into
# _tuish_grow_bot, and when it runs past the screen, pin the block to the bottom
# (_tuish_view_origin = LINES - grow_count, floored at 1) so it stays visible.
# When it fits, _tuish_view_origin is left untouched — callers that want it reset
# to INIT_ROW do so themselves before calling. Shared by tuish_grow's phase
# transition and the fini gap calculation.
_tuish_grow_pin_origin ()
{
	_tuish_grow_bot=$((TUISH_INIT_ROW + _tuish_view_grow_count))
	if test $_tuish_grow_bot -gt $TUISH_LINES
	then
		_tuish_grow_bot=$TUISH_LINES
		_tuish_view_origin=$((TUISH_LINES - _tuish_view_grow_count))
		test $_tuish_view_origin -lt 1 && _tuish_view_origin=1
	fi
	return 0
}

# ─── Resize handler (overrides event.sh stub) ────────────────────

# Clear physical rows FROM..TO (clamped to the screen). The shared repair loop
# for both fixed and grow resizes.
_tuish_viewport_repair ()
{
	local _rp_r=$1
	while test $_rp_r -le $2 && test $_rp_r -le $TUISH_LINES
	do
		tuish_move $_rp_r 1
		tuish_clear_line
		_rp_r=$((_rp_r + 1))
	done
}

# Pure layout math for a resize. From the captured old dimensions and the shrunk
# flag (and the current view state), compute the new TUISH_VIEW_ROWS/VIEW_TOP and
# physical rows, plus the rows to repair (_tuish_relayout_rf.._rt) and the new
# scroll region (_tuish_relayout_sr_top.._sr_bot). _sr_top stays 0 when there is
# nothing to repair (fullscreen, or grow still in phase 0). No terminal I/O — so
# this is unit-testable without a real terminal. Call after any shrink-push has
# finalised _tuish_view_origin.
#   $1 old cols  $2 old lines  $3 old phys  $4 shrunk(0|1)
_tuish_viewport_relayout ()
{
	local _old_cols=$1 _old_phys=$3 _shrunk=$4
	_tuish_relayout_sr_top=0

	case "$_tuish_view_mode" in
		fullscreen)
			TUISH_VIEW_ROWS=$TUISH_LINES
			_tuish_view_phys=$TUISH_LINES
			;;
		fixed)
			# Logical VIEW_ROWS stays at max; physical rows clip to screen.
			TUISH_VIEW_ROWS=$_tuish_view_max
			local _rl_avail=$((TUISH_LINES - _tuish_view_origin + 1))
			test $_rl_avail -lt 1 && _rl_avail=1
			local _rl_phys=$_tuish_view_max
			test $_rl_phys -gt $_rl_avail && _rl_phys=$_rl_avail
			test $_rl_phys -lt 1 && _rl_phys=1
			_tuish_view_phys=$_rl_phys

			TUISH_VIEW_TOP=$_tuish_view_origin
			local _rl_bot=$((_tuish_view_origin + _rl_phys - 1))
			_tuish_viewport_clear_range $_shrunk "$_old_cols" $_old_phys \
				$((_rl_bot + 1)) $_tuish_view_origin
			_tuish_relayout_sr_top=$_tuish_view_origin
			_tuish_relayout_sr_bot=$_rl_bot
			;;
		grow)
			if test $_tuish_view_grow_phase -eq 1
			then
				local _rl_avail=$((TUISH_LINES - _tuish_view_origin))
				test $_rl_avail -gt $_tuish_view_grow_count && _rl_avail=$_tuish_view_grow_count
				test $_rl_avail -lt 1 && _rl_avail=1
				local _rl_bot=$((_tuish_view_origin + _rl_avail))
				test $_rl_bot -gt $TUISH_LINES && _rl_bot=$TUISH_LINES

				TUISH_VIEW_TOP=$((_tuish_view_origin + 1))
				TUISH_VIEW_ROWS=$((_rl_bot - _tuish_view_origin))
				_tuish_view_phys=$TUISH_VIEW_ROWS

				_tuish_viewport_clear_range $_shrunk "$_old_cols" $_old_phys \
					$((_rl_bot + 1)) $((_tuish_view_origin + 1))
				_tuish_relayout_sr_top=$((_tuish_view_origin + 1))
				_tuish_relayout_sr_bot=$_rl_bot
			fi
			;;
	esac
	return 0
}

# Compute the stale-row repair range into _tuish_relayout_rf/_rt. Three cases,
# shared by fixed and grow: on shrink clear from below the viewport to the
# bottom; on a width change clear from WIDE_FROM (the viewport's first row) to
# the bottom; otherwise clear just the strip the old viewport occupied below the
# new bottom (a few rows past, never fewer than 3).
#   $1 shrunk  $2 old cols  $3 old phys  $4 below-bottom row  $5 wide-from row
_tuish_viewport_clear_range ()
{
	if test $1 -eq 1
	then
		_tuish_relayout_rf=$4
		_tuish_relayout_rt=$TUISH_LINES
	elif test "$2" -ne "$TUISH_COLUMNS"
	then
		_tuish_relayout_rf=$5
		_tuish_relayout_rt=$TUISH_LINES
	else
		_tuish_relayout_rf=$4
		_tuish_relayout_rt=$((_tuish_view_origin + $3 + 2))
		test $_tuish_relayout_rt -lt $((_tuish_relayout_rf + 3)) && \
			_tuish_relayout_rt=$((_tuish_relayout_rf + 3))
	fi
	return 0
}

# ─── The device owner's region ───────────────────────────────────
# The root is seated too. Its region is the WHOLE TERMINAL — not its viewport.
#
# That distinction is the whole point. A child's region and viewport are the same
# rectangle, because a host hands it exactly one. The root's are not: it owns the screen,
# and its viewport is whatever band it asked for inside it. Seating the root by its
# viewport would be catastrophic for `grow`, whose TUISH_VIEW_ROWS is 0 until the first
# line is emitted — the clip would refuse every cell and the app would render nothing.
#
# So the region is the screen, and the base clip is the screen expressed in the root's own
# logical cells (the inverse of the tuish_vmove map: logical = absolute - VIEW_TOP + 1).
# It is deliberately INDEPENDENT of TUISH_VIEW_ROWS, which is why grow is safe.
#
# This reproduces what the root effectively did before — tuish_vmove already refused
# anything below the last screen row — and additionally refuses three ranges it used to
# wave through, emitting malformed escapes for them: rows above 1 (`ESC[0;1H`,
# `ESC[-1;1H`) and columns outside 1..COLUMNS (`ESC[1;0H`, `ESC[1;200H`). Same pixels,
# fewer bytes, and a root that can no longer scribble outside the screen.
#
# Call it wherever the device owner's VIEW_TOP or the terminal size settles.
_tuish_viewport_own_region ()
{
	test "${_tuish_owns_dev:-1}" -eq 1 || return 0
	local _lrmin=$(( 2 - TUISH_VIEW_TOP ))                 # absolute row 1
	local _lrmax=$(( TUISH_LINES - TUISH_VIEW_TOP + 1 ))   # absolute row TUISH_LINES
	_tuish_ctx_region 1 0 "$TUISH_COLUMNS" "$TUISH_LINES" \
		"$_lrmin" "$_lrmax" 1 "$TUISH_COLUMNS"
	# _tuish_ctx_region clears the flag — it is the hosted path's primitive, and being
	# seated normally means a host seated you. The root seats ITSELF, and still owns the
	# terminal. Put it back.
	_tuish_owns_dev=1
	return 0
}

_tuish_viewport_on_resize ()
{
	# Hosted: our region is owned by the host, not the terminal. A terminal resize
	# is the host's concern — it re-seats our region and drives our redraw. Running
	# the standalone relayout here would clobber our viewport to the full-terminal
	# size (TUISH_VIEW_COLS=TUISH_COLUMNS below) and emit device-global I/O (the
	# cursor query, the scroll region) that belongs to the host, not a sub-region.
	# So re-apply our current region bounds — mirroring tuish_viewport's hosted
	# branch — and return, touching neither the device nor the full-screen math.
	if test "${_tuish_owns_dev:-1}" -eq 0
	then
		TUISH_VIEW_TOP=$_tuish_rgn_top
		TUISH_VIEW_LEFT=$_tuish_rgn_left
		TUISH_VIEW_ROWS=$_tuish_rgn_rows
		TUISH_VIEW_COLS=$_tuish_rgn_cols
		_tuish_view_phys=$_tuish_rgn_rows
		_tuish_view_origin=$_tuish_rgn_top
		_tuish_tx_reset
		return 0
	fi

	local _old_cols=${_tuish_precols:-$TUISH_COLUMNS}
	local _old_lines=$TUISH_LINES
	local _old_phys=$_tuish_view_phys
	_tuish_precols=''

	# Query the actual cursor row after the terminal's resize auto-scroll
	# (emulators vary in scroll behaviour on resize).
	_tuish_query_cursor_row

	# Reset scroll region (some terminals clip it on resize).
	tuish_reset_scroll

	tuish_update_size
	TUISH_VIEW_COLS=$TUISH_COLUMNS

	# On shrink: push content so invocation line reaches row 1.
	local _shrunk=0
	test $TUISH_LINES -lt $_old_lines && _shrunk=1

	# The shrink-push does terminal I/O and moves the origin, so it runs before
	# the (pure) layout math reads the origin.
	if test $_shrunk -eq 1
	then
		case "$_tuish_view_mode" in
			fixed) _tuish_viewport_shrink_push;;
			grow)  test $_tuish_view_grow_phase -eq 1 && _tuish_viewport_shrink_push;;
		esac
	fi

	_tuish_viewport_relayout "$_old_cols" "$_old_lines" "$_old_phys" "$_shrunk"

	if test $_tuish_relayout_sr_top -gt 0
	then
		_tuish_viewport_repair $_tuish_relayout_rf $_tuish_relayout_rt
		tuish_scroll_region $_tuish_relayout_sr_top $_tuish_relayout_sr_bot
	fi

	# The screen changed size and the relayout may have moved VIEW_TOP, so our region and
	# its clip are both stale. Re-seat.
	_tuish_viewport_own_region
}

# ─── Viewport modes ──────────────────────────────────────────────

tuish_viewport ()
{
	local _new_mode="$1"
	local _new_max="${2:-$_tuish_view_max}"

	# Hosted: the viewport IS the region the host handed us, whatever mode the app
	# asks for. The mode distinctions (alt-screen / inline / grow) are about how an
	# app relates to the terminal's scrollback — meaningless for a sub-region. So
	# every mode maps to "fill my region"; no alt-screen, no scroll region, clear
	# only the region. This is what makes a full-screen example run unchanged
	# inside a host's content pane.
	if test "${_tuish_owns_dev:-1}" -eq 0
	then
		_tuish_view_mode="$_new_mode"
		_tuish_view_max=$_new_max
		TUISH_VIEW_MODE="$_new_mode"
		TUISH_VIEW_TOP=$_tuish_rgn_top
		TUISH_VIEW_LEFT=$_tuish_rgn_left
		TUISH_VIEW_ROWS=$_tuish_rgn_rows
		TUISH_VIEW_COLS=$_tuish_rgn_cols
		_tuish_view_phys=$_tuish_rgn_rows
		_tuish_view_origin=$_tuish_rgn_top
		_tuish_tx_reset
		tuish_clear_region 1 1 "$_tuish_rgn_cols" "$_tuish_rgn_rows"
		return 0
	fi

	# Structural sequences must reach the terminal immediately;
	# bypass event-loop buffering.
	local _vp_was_buffering=$_tuish_buffering
	test $_tuish_buffering -gt 0 && tuish_flush
	_tuish_buffering=0

	# Tear down previous mode
	case "$_tuish_view_mode" in
		fullscreen)
			tuish_altscreen_off
			_tuish_view_altscreen=0
			# ?1049h/l corrupt DECSC state; re-save at init position
			tuish_move $TUISH_INIT_ROW 1
			tuish_save_cursor
			;;
		fixed|grow)
			tuish_reset_scroll
			# Clear viewport and save origin for fullscreen return.
			if test "$_new_mode" = 'fullscreen'
			then
				_tuish_view_saved_origin=$_tuish_view_origin
				_tuish_view_saved_anchor=$_tuish_view_anchor
				local _vc=0 _vn=$_tuish_view_phys
				test "$_tuish_view_mode" = 'grow' && _vn=$((_tuish_view_grow_count + 1))
				while test $_vc -lt $_vn
				do
					tuish_move $((_tuish_view_origin + _vc)) 1
					tuish_clear_line
					_vc=$((_vc + 1))
				done
			fi
			;;
	esac

	_tuish_view_mode="$_new_mode"
	_tuish_view_max=$_new_max
	TUISH_VIEW_MODE="$_new_mode"

	# Set up new mode
	case "$_new_mode" in
		fullscreen)
			tuish_altscreen_on
			_tuish_view_altscreen=1
			tuish_clear_screen
			TUISH_VIEW_TOP=1
			TUISH_VIEW_ROWS=$TUISH_LINES
			_tuish_view_phys=$TUISH_LINES
			TUISH_VIEW_COLS=$TUISH_COLUMNS
			;;
		fixed)
			if test $_tuish_view_saved_origin -gt 0
			then
				# Returning from fullscreen: reuse saved origin
				_tuish_view_origin=$_tuish_view_saved_origin
				_tuish_view_anchor=$_tuish_view_saved_anchor
				_tuish_view_saved_origin=0
				_tuish_view_saved_anchor=0
			else
				_tuish_view_origin=$TUISH_INIT_ROW
			fi
			TUISH_VIEW_TOP=$_tuish_view_origin
			TUISH_VIEW_ROWS=$_tuish_view_max
			TUISH_VIEW_COLS=$TUISH_COLUMNS
			# Physical rows: clip to screen, preserve invocation line
			local _phys=$_tuish_view_max
			local _max_phys=$((TUISH_LINES - 1))
			test $_max_phys -lt 1 && _max_phys=1
			test $_phys -gt $_max_phys && _phys=$_max_phys
			if test $_tuish_view_origin -eq $TUISH_INIT_ROW
			then
				_tuish_viewport_reserve_space $_phys
				# Set anchor after push (or no-push) has finalised origin
				_tuish_view_anchor=$_tuish_view_origin
			fi
			local _bot=$((_tuish_view_origin + _phys - 1))
			# Clamp to screen if terminal shrank while on alt screen
			test $_bot -gt $TUISH_LINES && _bot=$TUISH_LINES && _phys=$((_bot - _tuish_view_origin + 1))
			_tuish_view_phys=$_phys
			tuish_scroll_region $_tuish_view_origin $_bot
			# Clear the viewport area
			local _r=$_tuish_view_origin
			while test $_r -le $_bot
			do
				tuish_move $_r 1
				tuish_clear_line
				_r=$((_r + 1))
			done
			;;
		grow)
			if test $_tuish_view_saved_origin -gt 0
			then
				_tuish_view_origin=$_tuish_view_saved_origin
				_tuish_view_anchor=$_tuish_view_saved_anchor
				_tuish_view_saved_origin=0
				_tuish_view_saved_anchor=0
			else
				_tuish_view_origin=$TUISH_INIT_ROW
				_tuish_view_anchor=$TUISH_INIT_ROW
			fi
			_tuish_view_grow_phase=0
			_tuish_view_grow_count=0
			TUISH_VIEW_TOP=$_tuish_view_origin
			TUISH_VIEW_ROWS=0
			_tuish_view_phys=0
			TUISH_VIEW_COLS=$TUISH_COLUMNS
			;;
	esac

	# The mode just decided where our viewport sits. The region is still the whole screen,
	# but its clip is expressed relative to VIEW_TOP, which has moved — so re-seat.
	_tuish_viewport_own_region

	_tuish_buffering=$_vp_was_buffering
}

tuish_grow ()
{
	# Phase 0: growing
	if test $_tuish_view_grow_phase -eq 0
	then
		if test $_tuish_view_grow_count -lt $_tuish_view_max &&
		   test $_tuish_view_grow_count -lt $TUISH_LINES
		then
			tuish_newline
			_tuish_view_grow_count=$((_tuish_view_grow_count + 1))
			TUISH_VIEW_ROWS=$_tuish_view_grow_count
			return
		fi

		# Transition to scrolling
		_tuish_view_grow_phase=1
		_tuish_view_origin=$TUISH_INIT_ROW
		_tuish_grow_pin_origin
		_tuish_view_anchor=$_tuish_view_origin
		TUISH_VIEW_TOP=$((_tuish_view_origin + 1))
		TUISH_VIEW_ROWS=$((_tuish_grow_bot - _tuish_view_origin))
		tuish_scroll_region $((_tuish_view_origin + 1)) $_tuish_grow_bot
		tuish_move $_tuish_grow_bot 1
		# Phase 0 -> 1 pins the block and moves VIEW_TOP down a row. The clip is relative
		# to VIEW_TOP, so it is now off by one until we re-seat. (Phase 0 itself does not
		# need this: it only grows VIEW_ROWS, which the region deliberately ignores.)
		_tuish_viewport_own_region
	fi

	# Phase 1: scrolling
	tuish_newline
}

# ─── Fini hook (overrides tui.sh stub) ───────────────────────────

_tuish_on_fini ()
{
	# Hosted: whatever mode we ran, we only ever drew inside our region and never
	# touched the alt-screen, scroll region, or terminal scrollback. So teardown is
	# just clearing the region (the host repaints over us on resume). No push-gap,
	# no scroll reset, no cursor games — those are all screen-owning operations.
	if test "${_tuish_owns_dev:-1}" -eq 0
	then
		if test -n "$_tuish_view_mode"
		then
			_tuish_tx_reset
			tuish_clear_region 1 1 "$_tuish_rgn_cols" "$_tuish_rgn_rows"
			_tuish_view_mode=''
		fi
		return 0
	fi

	# Compute push gap so cursor lands after the last history line.
	if test "$_tuish_view_mode" = 'fullscreen'
	then
		# Was previously in fixed/grow with pushed origin
		if test $_tuish_view_saved_origin -gt 0 &&
		   test $_tuish_view_saved_origin -lt $TUISH_INIT_ROW
		then
			_tuish_fini_push_gap=$((TUISH_INIT_ROW - _tuish_view_saved_origin))
		fi
	elif test "$_tuish_view_mode" = 'fixed' || test "$_tuish_view_mode" = 'grow'
	then
		# Grow phase 0: recompute origin (scrolled past bottom)
		if test "$_tuish_view_mode" = 'grow' && test $_tuish_view_grow_phase -eq 0
		then
			_tuish_grow_pin_origin
		fi
		if test $_tuish_view_origin -lt $TUISH_INIT_ROW
		then
			_tuish_fini_push_gap=$((TUISH_INIT_ROW - _tuish_view_origin))
		fi
	fi

	# Tear down active viewport mode
	if test "$_tuish_view_mode" = 'fullscreen'
	then
		tuish_clear_screen
		tuish_altscreen_off
		_tuish_view_altscreen=0
		# ?1049h/l corrupts DECSC state; re-save at init position
		tuish_move $TUISH_INIT_ROW 1
		tuish_save_cursor
		_tuish_view_mode=''
	fi
	if test "$_tuish_view_mode" = 'fixed' || test "$_tuish_view_mode" = 'grow'
	then
		tuish_reset_scroll
		case "$_tuish_quit_mode" in
			clear)
				local _vr=$_tuish_view_phys
				test "$_tuish_view_mode" = 'grow' && _vr=$((_tuish_view_grow_count + 1))
				if test $_vr -gt 0
				then
					local _r=0
					while test $_r -lt $_vr
					do
						tuish_move $((_tuish_view_origin + _r)) 1
						tuish_clear_line
						_r=$((_r + 1))
					done
				fi
				# Re-save cursor at viewport origin for correct DECRC
				tuish_move $_tuish_view_origin 1
				tuish_save_cursor
				_tuish_fini_push_gap=0
				;;
			main)
				if test "$_tuish_view_mode" = 'fixed'
				then
					TUISH_FINI_OFFSET=$_tuish_view_phys
				elif test $_tuish_view_grow_count -gt 0
				then
					TUISH_FINI_OFFSET=$((_tuish_view_grow_count + 1))
				fi
				;;
		esac
	fi
	_tuish_view_mode=''
}
