#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# examples/game.sh — a tiny emoji platformer.
#
# Shows off the input/draw fast paths: a real-time game loop, the keybinding
# dispatcher, emoji sprites, and a DIRTY-SPRITE renderer — the static room is
# painted once and each tick only erases/redraws the cells that moved. Move with
# WASD or the arrow keys, jump with Space / W / Up. Reach 🏁, grab 🪙, dodge 👾
# and the 🌵 / 🔥. R restarts, Q quits.
#
# THE DELTA RENDERER IS NOT A WORKAROUND, and this was checked rather than
# assumed. Measured on a 100x30 room: _render_full 4772us, _render_delta 366us —
# 13x. Unlike the "repaint everything and let the framework sort it out" advice in
# docs/event.md, that gap is not about redundant OUTPUT that something downstream
# could drop; it is the cost of COMPOSING every cell of the board, which nothing
# downstream can give back. At a 0.02s tick a full frame is a quarter of the
# budget before physics runs, and the shell-WASM target is far slower again.
#
# Nor is it something the str.sh width memo relieves: this file paints through
# tuish_put_at, which skips the width pass by contract, so the memo measured no
# change here at all (4800us -> 4772us). Two different costs with the same
# symptom — worth telling apart before deleting anyone's bookkeeping.
#
# _hud_dirty is the same story in miniature: the HUD is a single tuish_text, but
# at 290us it is 44% of a delta frame, and it changes only when a coin or a life
# does. It stays too.
#
# INPUT: plain VT keyboard — no kitty, no press/release events. A movement key
# steps the player exactly one tile, immediately — one tap, one tile: precise,
# snappy fine movement. Gravity and jumps run on the idle tick. Works on ANY
# terminal, with dead-simple input handling.
#
# HOLDING a key leans on the terminal's autorepeat, whose RATE varies wildly
# across keyboards/OSes. Left alone it steps a tile per repeat, so the run speed
# would be the repeat rate — non-uniform, and fast enough to skim across a gap
# before the idle tick can apply gravity. So repeats are THROTTLED: a step is
# taken only once 1/RUN_SPEED of game-time (TUISH_TICK_US, banked in _step_acc)
# has elapsed, capping the held run at RUN_SPEED tiles/sec on every keyboard,
# whatever its autorepeat rate. Dropped repeats are cheap (no move, no draw) so
# the buffered byte stream drains at once — gravity keeps ticking between steps,
# so you fall off a ledge the moment you run off it instead of dashing the whole
# screen. Snappy, uniform, and dead-simple.
#
# That throttle only works while the idle tick keeps firing, and the tick is a
# read TIMEOUT, not a timer: hold a key whose autorepeat is faster than our
# interval and the read never times out, no idle fires, _step_acc never refills,
# and the player takes one step and stops until you let go. That is why the
# interval below is 0.02 — comfortably under a ~33ms autorepeat. The library also
# refuses to let the clock stop outright (see TUISH_BURST_MAX in docs/tui.md), but
# that guarantee is a floor, not a reason to pick a lazy interval.
#
# GAME SPEED IS DECOUPLED FROM THE TICK RATE, using TUISH_IDLE_TIMEOUT itself as
# the clock: each idle event means the input read timed out, i.e. ~one timeout
# elapsed, so physics advances by velocity × that dt. Since dt scales with the
# timeout while the number of ticks scales as 1/timeout, the game plays at the
# same speed for any TUISH_IDLE_TIMEOUT — smaller just buys smoother motion and
# snappier input (more CPU). Velocities below are in tiles-per-second.
#
# ...for anything the TICK integrates: gravity, jumps, enemies. NOT for a held
# run, which is paced by autorepeat arriving against that same clock — see above.
#
# The world is a grid of TILES; each tile is TW terminal columns so an emoji
# (drawn 2 cells wide) fills exactly one tile — the board stays aligned and
# collision is one tile == one cell.
#
# No wall clock is used — only TUISH_IDLE_TIMEOUT, which every shell's idle wait
# now honors (zsh included), so it doubles as the per-tick dt.

# Dual-mode: standalone (`sh examples/game.sh`) or embedded (a host sources it and
# calls _g_main in a region). Guard the bootstrap so sourcing only defines things.
if test -z "${_tuish_tui_loaded:-}"
then
	_g_standalone=1
	_game_dir="$(cd "$(dirname "$0")" && pwd)"
	_src="${_game_dir}/../src"
	. "${_src}/compat.sh"
	. "${_src}/ord.sh"
	. "${_src}/tui.sh"
	. "${_src}/term.sh"
	. "${_src}/event.sh"
	. "${_src}/hid.sh"
	. "${_src}/viewport.sh"
	. "${_src}/str.sh"
	. "${_src}/draw.sh"
	. "${_src}/keybind.sh"
	. "${_src}/buf.sh"
else
	_g_standalone=0
fi

# ─── Tunables ────────────────────────────────────────────────────
# Positions are fixed-point: one tile = FP units. Velocities are tiles/SECOND
# and accelerations tiles/second², integrated against real elapsed time, so the
# feel is independent of frame rate. Tweak these freely; they're physical.
FP=1000
GRAV=65         # gravity (tiles/sec²) — floaty but snappy
VYMAX=38        # terminal fall speed (tiles/sec)
JUMP=18         # jump take-off speed (tiles/sec) → ~5.2-tile, ~0.87s hang
STEP=1000       # horizontal distance per step, in FP units (1000 = one tile). A
                # keypress steps exactly one tile, instantly — one tap = one tile.
RUN_SPEED=12    # held run speed (tiles/sec). Autorepeat presses arriving sooner
                # than 1/RUN_SPEED of game-time apart are DROPPED, so holding moves
                # at RUN_SPEED on every keyboard — not the (wildly variable)
                # autorepeat rate. Keep it slow enough that several idle ticks (and
                # thus gravity) fall between steps, so a held run can't outrun the
                # fall. Raise for a snappier run, lower for finer control.
MOVE_TTL=0.15   # how long a movement keypress counts as "still moving" (seconds).
                # A plain VT autorepeats only the LAST key, so pressing jump stops
                # the movement key's repeats — we can't see it's still held. So at
                # take-off we carry momentum if a move happened within this window
                # (a running jump keeps moving; a standing jump goes straight up).
                # Keep it above the autorepeat interval so a held run stays "moving"
                # between repeats; it doubles as the coyote window after release.
                # We hand this to tuish_key_ttl and ask tuish_key_down — the library
                # keeps the window and ages it on OUR tick, which is the part we could
                # not do ourselves once a host started choosing the tick.
ENEMY_SPD=5     # enemy patrol speed (tiles/sec)
SUB_DT=20000    # max physics sub-step (µs): a coarse idle interval is split into
                # slices this big so gravity advances in fine increments (<1
                # tile/step, so _resolve_v can't tunnel) and a shell with a
                # chunkier idle still falls smoothly.
RENDER_DT=16667 # render at most ~60 fps regardless of tick rate, so low-timeout
                # ticks are cheap (physics only) — keeps speed accurate + CPU low

# ─── Tileset ─────────────────────────────────────────────────────
# TW = terminal columns per tile. Emoji render 2-wide, so TW=2 keeps tile N at
# terminal column (N-1)*TW+1 and everything lines up. ASCII falls back to TW=1.
if test "${TUISH_DRAW_BACKEND:-unicode}" = 'ascii'
then
	TW=1
	PLAYER='@' ENEMY='&' COIN='o' GOAL='>'
	G_WALL='#' G_PLAT='=' G_SPIKE='^' G_LAVA='~' G_AIR=' '
else
	TW=2
	PLAYER='🤖' ENEMY='👾' COIN='🪙' GOAL='🏁'
	G_WALL='██' G_PLAT='▓▓' G_SPIKE='🌵' G_LAVA='🔥' G_AIR='  '
fi

# Velocities/accelerations in fixed-point units (computed once).
VYMAX_U=$(( VYMAX * FP ))
JUMP_U=$(( JUMP * FP )); GRAV_U=$(( GRAV * FP )); ENEMY_U=$(( ENEMY_SPD * FP ))
# Min game-time between held auto-steps (µs): one tile per 1/RUN_SPEED second.
STEP_MIN_US=$(( 1000000 / RUN_SPEED ))

# Reserved viewport height (rows) for the game slab: the largest room (board)
# plus the HUD line. The game renders into this fixed partial area — a plain
# viewport feature — so the shell scrollback above and the prompt below stay
# live. (No canvas needed: the board never draws outside its own rows/cols.)
GAME_VIEW_H=14

# ─── Game state ──────────────────────────────────────────────────
_room=1
_room_count=3
_state=play          # play | win
_g_started=0
_too_small=0
_deaths=0

_map_rows=0 _map_cols=0

# player: _px/_py fixed-point position, _pvy vertical velocity (units/sec). _step
# integrates gravity/jumps; horizontal is discrete one-tile steps taken in _walk.
# _step_acc banks game-time since the last step so held autorepeat can't step
# faster than RUN_SPEED, whatever the keyboard's repeat rate.
#   _face     last horizontal direction pressed (-1/0/+1)
#   _air_run  direction the airborne player keeps stepping (latched at take-off);
#             0 = no horizontal carry. Lets a running jump keep moving even though
#             autorepeat switched to the jump key — see _jump / _walk / _step.
# Whether a movement key is still DOWN is not ours to track: the library keeps that
# window and ages it on our tick (tuish_key_track / tuish_key_down, set up in _g_setup).
_px=0 _py=0 _pvy=0
_step_acc=$STEP_MIN_US
_face=0 _air_run=0
_pcx=0 _pcy=0 _ppcx=0 _ppcy=0
_grounded=0
_start_cx=2 _start_cy=2

# The movement keys, named once. Declaring the set is also how it is CLEARED — every
# window goes back to empty — which is why the state resets below call it: respawning
# must not leave a stale hold for the next jump to carry.
#
# Only ever call this after tuish_init. The set is a context field, so before there is a
# context it lands on a global that the first activate throws away.
_g_track_keys () { tuish_key_track 'left' 'char a' 'right' 'char d'; }

_enemy_n=0 _coin_n=0 _coins_got=0
_goal_x=0 _goal_y=0
_hud_dirty=0
_need_full=0           # next frame must be a full repaint (room/death/resize)
_win_shown=0           # win banner already painted
_render_acc=0          # accumulated game-time since the last render (µs)

# Timestep: TUISH_IDLE_TIMEOUT *is* our clock. Each idle event means the input
# read timed out, i.e. ~one timeout-interval of wall-time elapsed — so that is
# the dt we advance physics by. TICK_DT (µs) is set from the engine's
# TUISH_TICK_US after tuish_init (see main); this is just a pre-init placeholder.
TICK_DT=16667

# ─── Level templates ─────────────────────────────────────────────
# Tiles: '#' wall  '=' platform  '^' spikes  '~' lava  ' ' air
# Markers (interior only; replaced by air on load): P start  E enemy
#         C coin  G goal.  An outer border is forced on load and off-map counts
# as solid, so ragged interiors are safe. Platforms live in the lower half so a
# floaty jump has headroom; spike gaps are small enough to clear in one jump.
_ROOM_1='
  P
           C

       =====
  C                      G
======== ^^ =====================
       E           ~~~
=========================
'

_ROOM_2='
  P
              C
      =====         =====
   C             E          G
======= ^^ ============= ~~ ======
         C
========              ============
        ^^
==============================
'

_ROOM_3='
   P
          C
                   =====      G
      =====                ========
   C            ^^           E
========= ~~ =======  ^^ =========
               E  C
=====        ========
    ^^   ====
==============================
'

# ─── Geometry helpers ────────────────────────────────────────────
_tcol ()  { _termcol=$(( ( $1 - 1 ) * TW + 1 )); }   # tile col -> terminal col

# Clear the reserved slab (board + HUD) in viewport coords — NOT the screen —
# so a room change leaves no stale rows and the shell history above and prompt
# below stay intact. (tuish_clear_screen would wipe the whole terminal.)
_clear_slab () { tuish_clear_region 1 1 "$TUISH_VIEW_COLS" "$TUISH_VIEW_ROWS"; }

_tile_at ()   # $1 row $2 col  -> _tile  (off-map = solid wall)
{
	if test "$1" -lt 1 || test "$1" -gt "$_map_rows" \
	   || test "$2" -lt 1 || test "$2" -gt "$_map_cols"
	then _tile='#'; return 0; fi
	tuish_buf_get map "$1"
	_tile="${TUISH_BLINE:$(( $2 - 1 )):1}"
	if test -z "$_tile"; then _tile=' '; fi
	return 0
}

_solid_at ()  # $1 row $2 col  -> exit 0 if solid
{
	_tile_at "$1" "$2"
	case "$_tile" in '#'|'=') return 0;; esac
	return 1
}

# ─── Level loading ───────────────────────────────────────────────
_add_enemy ()  # $1 col $2 row
{
	_enemy_n=$(( _enemy_n + 1 ))
	eval "_en_x_${_enemy_n}=$(( $1 * FP ))"
	eval "_en_y_${_enemy_n}=$2"
	eval "_en_dir_${_enemy_n}=1"
	eval "_en_ppcx_${_enemy_n}=$1"
	eval "_en_ppcy_${_enemy_n}=$2"
	return 0
}

_add_coin ()   # $1 col $2 row
{
	_coin_n=$(( _coin_n + 1 ))
	eval "_coin_x_${_coin_n}=$1"
	eval "_coin_y_${_coin_n}=$2"
	eval "_coin_alive_${_coin_n}=1"
	return 0
}

_load_room ()  # $1 = room number
{
	local _tpl _line _r _c _len _ch _clean _row _mid
	eval "_tpl=\"\$_ROOM_$1\""
	_enemy_n=0 _coin_n=0 _coins_got=0 _goal_x=0 _goal_y=0
	_map_rows=0 _map_cols=0
	_r=0
	# Pass 1: read rows, extract markers, remember cleaned rows + max width.
	while IFS= read -r _line
	do
		_r=$(( _r + 1 ))
		_len=${#_line}
		if test "$_len" -gt "$_map_cols"; then _map_cols=$_len; fi
		_c=1 _clean=''
		while test "$_c" -le "$_len"
		do
			_ch="${_line:$(( _c - 1 )):1}"
			case "$_ch" in
				P) _start_cx=$_c; _start_cy=$_r; _ch=' ';;
				E) _add_enemy "$_c" "$_r"; _ch=' ';;
				C) _add_coin "$_c" "$_r"; _ch=' ';;
				G) _goal_x=$_c; _goal_y=$_r; _ch=' ';;
			esac
			_clean="${_clean}${_ch}"
			_c=$(( _c + 1 ))
		done
		eval "_maptmp_${_r}=\"\$_clean\""
	done <<EOF
$_tpl
EOF
	_map_rows=$_r
	# Pass 2: pad to width and force a closed border, store into the buffer.
	_r=1
	while test "$_r" -le "$_map_rows"
	do
		eval "_row=\"\$_maptmp_$_r\""
		tuish_str_repeat ' ' "$(( _map_cols - ${#_row} ))"; _row="${_row}${TUISH_SREPEATED}"
		if test "$_r" -eq 1 || test "$_r" -eq "$_map_rows"
		then
			tuish_str_repeat '#' "$_map_cols"; _row="$TUISH_SREPEATED"
		else
			_mid="${_row#?}"; _mid="${_mid%?}"
			_row="#${_mid}#"
		fi
		tuish_buf_set map "$_r" "$_row"
		_r=$(( _r + 1 ))
	done
	_check_size
	# place player at the room start
	_px=$(( _start_cx * FP )); _py=$(( _start_cy * FP ))
	_pvy=0 _grounded=0 _step_acc=$STEP_MIN_US
	_face=0 _air_run=0; _g_track_keys
	_pcx=$_start_cx _pcy=$_start_cy _ppcx=$_start_cx _ppcy=$_start_cy
	return 0
}

# ─── Physics (real-time integration; displacements in fixed-point units) ──
_resolve_h ()  # $1 = horizontal displacement this step (units, < 1 tile)
{
	local _np _ncx _cy
	if test "$1" -eq 0; then return 0; fi
	_np=$(( _px + $1 )); _ncx=$(( _np / FP )); _cy=$(( _py / FP ))
	if test "$1" -gt 0
	then
		if _solid_at "$_cy" "$_ncx"; then _np=$(( _ncx * FP - 1 )); fi
	else
		if _solid_at "$_cy" "$_ncx"; then _np=$(( ( _ncx + 1 ) * FP )); fi
	fi
	_px=$_np
	return 0
}

_resolve_v ()  # $1 = vertical displacement this step (units, +down)
{
	local _cx _remain _cy _stepu
	_cx=$(( _px / FP ))
	_grounded=0
	_remain=$1
	if test "$1" -ge 0
	then
		while test "$_remain" -gt 0
		do
			_cy=$(( _py / FP ))
			if _solid_at "$(( _cy + 1 ))" "$_cx"
			then _py=$(( _cy * FP )); _pvy=0; _grounded=1; return 0; fi
			_stepu=$_remain
			if test "$_stepu" -gt "$FP"; then _stepu=$FP; fi
			_py=$(( _py + _stepu )); _remain=$(( _remain - _stepu ))
		done
	else
		while test "$_remain" -lt 0
		do
			_cy=$(( _py / FP ))
			if _solid_at "$(( _cy - 1 ))" "$_cx"
			then _py=$(( _cy * FP )); _pvy=0; return 0; fi
			_stepu=$_remain
			if test "$_stepu" -lt "$(( - FP ))"; then _stepu=$(( - FP )); fi
			_py=$(( _py + _stepu )); _remain=$(( _remain - _stepu ))
		done
	fi
	_cy=$(( _py / FP ))
	if _solid_at "$(( _cy + 1 ))" "$_cx"; then _grounded=1; fi
	return 0
}

_move_enemies ()  # $1 = dt (µs)
{
	local _dt=$1 _i _x _dir _y _disp _nx _ncx _rev
	_i=1
	while test "$_i" -le "$_enemy_n"
	do
		eval "_x=\$_en_x_$_i; _dir=\$_en_dir_$_i; _y=\$_en_y_$_i"
		_disp=$(( _dir * ENEMY_U * _dt / 1000000 ))
		_nx=$(( _x + _disp )); _ncx=$(( _nx / FP )); _rev=0
		# reverse at a wall ahead or a ledge (no ground under the next tile)
		if _solid_at "$_y" "$_ncx"; then _rev=1; fi
		if _solid_at "$(( _y + 1 ))" "$_ncx"; then :; else _rev=1; fi
		if test "$_rev" -eq 1
		then eval "_en_dir_$_i=$(( - _dir ))"
		else eval "_en_x_$_i=$_nx"
		fi
		_i=$(( _i + 1 ))
	done
	return 0
}

# Overlap against the player's swept rows [_lo.._hi] (set by _check_world).
_overlaps_swept ()  # $1 ecx $2 erow
{
	if test "$2" -lt "$_lo" || test "$2" -gt "$_hi"; then return 1; fi
	if test "$1" -eq "$_pcx"; then return 0; fi
	return 1
}

_check_world ()  # $1 = pre-move row (top of this step's vertical sweep)
{
	local _i _ry _ex _ey _kx _ky _alive _lo _hi
	if test "$1" -le "$_pcy"; then _lo=$1; _hi=$_pcy; else _lo=$_pcy; _hi=$1; fi
	_ry=$_lo
	while test "$_ry" -le "$_hi"
	do
		_tile_at "$_ry" "$_pcx"
		case "$_tile" in '^'|'~') _die; return 0;; esac
		_ry=$(( _ry + 1 ))
	done
	_i=1
	while test "$_i" -le "$_enemy_n"
	do
		eval "_ex=\$(( \$_en_x_$_i / FP )); _ey=\$_en_y_$_i"
		if _overlaps_swept "$_ex" "$_ey"; then _die; return 0; fi
		_i=$(( _i + 1 ))
	done
	_i=1
	while test "$_i" -le "$_coin_n"
	do
		eval "_alive=\$_coin_alive_$_i; _kx=\$_coin_x_$_i; _ky=\$_coin_y_$_i"
		if test "$_alive" -eq 1 && _overlaps_swept "$_kx" "$_ky"
		then
			eval "_coin_alive_$_i=0"
			_coins_got=$(( _coins_got + 1 ))
			_hud_dirty=1
		fi
		_i=$(( _i + 1 ))
	done
	if test "$_goal_x" -gt 0 && _overlaps_swept "$_goal_x" "$_goal_y"
	then _reach_goal; fi
	return 0
}

_die ()
{
	_deaths=$(( _deaths + 1 ))
	_px=$(( _start_cx * FP )); _py=$(( _start_cy * FP ))
	_pvy=0 _grounded=0 _step_acc=$STEP_MIN_US
	_face=0 _air_run=0; _g_track_keys
	_pcx=$_start_cx _pcy=$_start_cy
	_need_full=1
	return 0
}

_reach_goal ()
{
	_room=$(( _room + 1 ))
	if test "$_room" -gt "$_room_count"
	then _state=win
	else _load_room "$_room"
	fi
	_need_full=1
	return 0
}

# Take one throttled tile-step in direction $1 (-1/+1): spend the banked game-time
# and advance one tile (clamped by collision). Shared by the ground run (_walk)
# and the airborne momentum carry (_step) so the cadence/coordinate update lives
# in one place — callers gate it on _step_acc vs STEP_MIN_US.
_hstep ()  # $1 = direction (-1/+1)
{
	_step_acc=0
	_resolve_h "$(( $1 * STEP ))"
	_pcx=$(( _px / FP ))
	return 0
}

_step ()  # $1 = dt (µs) — advance time-based physics: gravity, fall, enemies
{
	local _dt=$1 _dy _ocy
	# gravity: v += a·dt   (capped at terminal velocity)
	_pvy=$(( _pvy + GRAV_U * _dt / 1000000 ))
	if test "$_pvy" -gt "$VYMAX_U"; then _pvy=$VYMAX_U; fi
	# vertical displacement this step: y += v·dt  (ground horizontal is event-driven
	# in _walk; the airborne carry below is the only horizontal motion run here)
	_dy=$(( _pvy * _dt / 1000000 ))
	_ocy=$(( _py / FP ))
	_resolve_v "$_dy"          # updates _grounded
	# Airborne horizontal carry: a held run can't autorepeat through a jump (the
	# terminal repeats only the last key — now the jump key), so the direction
	# latched at take-off keeps stepping in the air, throttled exactly like the
	# ground run. Landing clears it; on the ground _walk does the stepping.
	if test "$_grounded" -eq 1
	then _air_run=0
	elif test "$_air_run" -ne 0 && test "$_step_acc" -ge "$STEP_MIN_US"
	then _hstep "$_air_run"
	fi
	_move_enemies "$_dt"
	_pcy=$(( _py / FP ))
	_check_world "$_ocy"
	return 0
}

# ─── Rendering (tile col -> terminal col via _tcol) ──────────────
# Map char -> "colour glyph" appended to a row builder. Sets _tile_glyph and
# _tile_want (the fg colour the tile needs, or 'none'). Walls/platforms carry a
# colour; the spike/lava emoji are self-coloured, so 'none'. Keeping the tile
# table in one place for both the row builder and the single-cell restore.
_tile_glyph ()  # $1 tile char -> _tile_glyph, _tile_want
{
	case "$1" in
		'#') _tile_want=4;    _tile_glyph=$G_WALL;;
		'=') _tile_want=2;    _tile_glyph=$G_PLAT;;
		'^') _tile_want=none; _tile_glyph=$G_SPIKE;;
		'~') _tile_want=none; _tile_glyph=$G_LAVA;;
		*)   _tile_want=none; _tile_glyph=$G_AIR;;
	esac
}

_paint_cell ()  # $1 row $2 tile-col  (restore one full tile)
{
	_tcol "$2"
	if tuish_vmove "$1" "$_termcol"
	then
		_tile_at "$1" "$2"; _tile_glyph "$_tile"
		if test "$_tile_want" = none
		then tuish_print "$_tile_glyph"
		else
			tuish_fg_seq "$_tile_want"; local _pc="$TUISH_SEQ"
			tuish_sgr_reset_seq
			tuish_print "${_pc}${_tile_glyph}${TUISH_SEQ}"
		fi
	fi
	return 0
}

# Paint a whole map row as ONE string with run-length colour, emitted in a
# single tuish_print — instead of a tuish_fg/tuish_print/tuish_sgr_reset per
# cell. The row's cells are read from one tuish_buf_get (not one eval per cell),
# and an SGR sequence is appended only when the colour CHANGES from the previous
# cell. Cursor auto-advances across the wide glyphs from the single vmove, same
# as before. This is the game's hot path; see the batched-render note in term.sh.
_paint_row ()   # $1 row
{
	if tuish_vmove "$1" 1
	then
		tuish_buf_get map "$1"
		local _line="$TUISH_BLINE"
		local _c=1 _ch _cur=-1 _row=''
		while test "$_c" -le "$_map_cols"
		do
			_ch="${_line:$(( _c - 1 )):1}"
			test -z "$_ch" && _ch=' '
			_tile_glyph "$_ch"
			if test "$_tile_want" != "$_cur"
			then
				if test "$_tile_want" = none
				then tuish_sgr_reset_seq
				else tuish_fg_seq "$_tile_want"
				fi
				_row="${_row}${TUISH_SEQ}"
				_cur=$_tile_want
			fi
			_row="${_row}${_tile_glyph}"
			_c=$(( _c + 1 ))
		done
		# Close any open colour so sprites drawn afterward are not tinted.
		if test "$_cur" != none && test "$_cur" != -1
		then tuish_sgr_reset_seq; _row="${_row}${TUISH_SEQ}"; fi
		# The board is fitted to the viewport, so it normally fits the visible window
		# and the raw print (cursor already positioned above) is safe and skips the
		# per-row width scan — the hot path. Only when scrolled under a narrower pane
		# (visible clip < board width) do we fall to the SGR-aware clipping print.
		_tuish_clip_avail 1
		if test $(( _map_cols * TW )) -le $_tuish_avail
		then tuish_print "$_row"
		else tuish_text "$1" 1 "$_row"
		fi
	fi
	return 0
}

_draw_at ()  # $1 row $2 tile-col $3 sprite  (single-glyph guarded draw)
{
	_tcol "$2"
	# Sprites are exactly one tile (TW cols) wide and drawn inside the fitted
	# board, so no width-clip is needed — tuish_put_at skips tuish_str_width.
	tuish_put_at "$1" "$_termcol" "$3"
	return 0
}

_draw_player () { _draw_at "$_pcy" "$_pcx" "$PLAYER"; }
_draw_goal ()
{
	if test "$_goal_x" -gt 0; then _draw_at "$_goal_y" "$_goal_x" "$GOAL"; fi
	return 0
}

_draw_enemy ()  # $1 index
{
	local _ex _ey
	eval "_ex=\$(( \$_en_x_$1 / FP )); _ey=\$_en_y_$1"
	_draw_at "$_ey" "$_ex" "$ENEMY"
	return 0
}

_draw_coins ()
{
	local _i _alive _kx _ky
	_i=1
	while test "$_i" -le "$_coin_n"
	do
		eval "_alive=\$_coin_alive_$_i; _kx=\$_coin_x_$_i; _ky=\$_coin_y_$_i"
		if test "$_alive" -eq 1; then _draw_at "$_ky" "$_kx" "$COIN"; fi
		_i=$(( _i + 1 ))
	done
	return 0
}

_draw_hud ()
{
	local _hrow=$(( _map_rows + 1 ))
	tuish_sgr_reset
	tuish_clear_to_edge "$_hrow"   # bounded by our width; ESC[K would overrun a host
	# tuish_text clips the fixed-width HUD to the region (it overran a narrow host pane
	# as a raw print) and positions itself, so no separate tuish_vmove is needed.
	tuish_text "$_hrow" 1 "Room ${_room}/${_room_count}  🪙 ${_coins_got}/${_coin_n}  ☠ ${_deaths}   [WASD/←↑→] move  [R] restart  [Q] quit"
	return 0
}

_render_full ()
{
	local _r _i
	if test "$_too_small" -eq 1; then _render_toosmall; return 0; fi
	tuish_hide_cursor
	_clear_slab
	_r=1
	while test "$_r" -le "$_map_rows"; do _paint_row "$_r"; _r=$(( _r + 1 )); done
	_draw_goal
	_draw_coins
	_i=1
	while test "$_i" -le "$_enemy_n"
	do
		_draw_enemy "$_i"
		eval "_en_ppcx_$_i=\$(( \$_en_x_$_i / FP )); _en_ppcy_$_i=\$_en_y_$_i"
		_i=$(( _i + 1 ))
	done
	_draw_player
	_ppcx=$_pcx _ppcy=$_pcy
	_draw_hud
	_hud_dirty=0
	tuish_sgr_reset
	return 0
}

_render_delta ()
{
	local _i _pecx _pecy
	if test "$_too_small" -eq 1; then return 0; fi
	_paint_cell "$_ppcy" "$_ppcx"
	_i=1
	while test "$_i" -le "$_enemy_n"
	do
		eval "_pecx=\$_en_ppcx_$_i; _pecy=\$_en_ppcy_$_i"
		_paint_cell "$_pecy" "$_pecx"
		_i=$(( _i + 1 ))
	done
	_draw_goal
	_draw_coins
	_i=1
	while test "$_i" -le "$_enemy_n"
	do
		_draw_enemy "$_i"
		eval "_en_ppcx_$_i=\$(( \$_en_x_$_i / FP )); _en_ppcy_$_i=\$_en_y_$_i"
		_i=$(( _i + 1 ))
	done
	_draw_player
	_ppcx=$_pcx _ppcy=$_pcy
	if test "$_hud_dirty" -eq 1; then _draw_hud; _hud_dirty=0; fi
	return 0
}

_render_win ()
{
	_clear_slab
	tuish_overlay \
		"🏆  YOU WIN!" \
		"" \
		"Deaths: ${_deaths}" \
		"[R] play again    [Q] quit"
	return 0
}

_render_toosmall ()
{
	_clear_slab
	tuish_overlay \
		"Terminal too small" \
		"need at least $(( _map_cols * TW )) x $(( _map_rows + 1 ))" \
		"resize to continue"
	return 0
}

_check_size ()
{
	if test "$TUISH_VIEW_ROWS" -lt "$(( _map_rows + 1 ))" \
	   || test "$TUISH_VIEW_COLS" -lt "$(( _map_cols * TW ))"
	then _too_small=1; else _too_small=0; fi
	return 0
}

# ─── Frame rendering (direct, NOT via rAF) ───────────────────────
# A real-time game must paint every frame. The library's tuish_request_redraw is
# a coalesced (requestAnimationFrame) redraw that defers painting while input is
# pending — right for an editor, but it freezes a game while a key is held (the
# autorepeat byte stream keeps input "pending"). So we draw straight into the
# frame buffer; the event loop flushes it once per event (tuish_end).
_render_frame ()
{
	if test "$_state" = 'win'
	then
		if test "$_win_shown" -eq 0; then _render_win; _win_shown=1; fi
		return 0
	fi
	_win_shown=0
	if test "$_need_full" -eq 1; then _render_full; _need_full=0; else _render_delta; fi
	return 0
}

# Painting every frame ourselves does NOT excuse us from answering a host.
#
# A host repaints its children when it assembles a frame (it has to — its own background
# fill would otherwise land on top of us) and when it moves one. It does that through the
# registered render handler, and an app that registers none paints nothing: the reader is
# left looking at whatever the host had on screen underneath, with our sprites scribbled
# over it. So: a full repaint, on demand, for anyone who asks.
_g_repaint () { _need_full=1; _render_frame; }

# ─── Input handlers ──────────────────────────────────────────────
_tick ()
{
	local _dt _sd
	if test "$_g_started" -eq 0
	then _g_started=1 _need_full=1; _render_frame; return 0; fi
	if test "$_too_small" -eq 1; then return 0; fi
	# Each idle tick represents ~TICK_DT of wall-time (the read -t interval).
	# Advance gravity by that much, in <=SUB_DT slices so a coarse interval
	# (zsh) integrates smoothly. Because dt scales with the timeout while ticks
	# scale as 1/timeout, the fall SPEED is the same at any TUISH_IDLE_TIMEOUT —
	# only smoothness/latency change.
	if test "$_state" = 'play'
	then
		_dt=$TICK_DT
		while test "$_dt" -gt 0
		do
			_sd=$_dt
			if test "$_sd" -gt "$SUB_DT"; then _sd=$SUB_DT; fi
			_step "$_sd"
			_dt=$(( _dt - _sd ))
		done
		# Bank this tick's game-time toward the next held step, capped at the
		# threshold so an idle spell can't accrue credit for a burst of steps.
		_step_acc=$(( _step_acc + TICK_DT ))
		if test "$_step_acc" -gt "$STEP_MIN_US"; then _step_acc=$STEP_MIN_US; fi
	fi
	# Render at most ~60 fps: cheap physics-only ticks in between keep the
	# timeout-as-clock accurate (less per-tick processing it can't account for).
	_render_acc=$(( _render_acc + TICK_DT ))
	if test "$_render_acc" -ge "$RENDER_DT" || test "$_need_full" -eq 1
	then _render_acc=0; _render_frame; fi
	return 0
}

# A movement key steps the player exactly one tile, instantly, and redraws — one
# tap = one tile (snappy, precise fine movement). Holding leans on autorepeat:
# each repeat would step a tile, but repeats arriving before STEP_MIN_US of
# game-time has banked (in _step_acc, on the idle tick) are dropped, so the held
# run is RUN_SPEED on every keyboard, not the autorepeat rate. The drop is cheap
# (no move, no draw) so buffered repeats drain at once and the idle tick is never
# starved — gravity keeps ticking between steps, so you fall off a ledge instead
# of skimming across a gap. Gravity/jumps run on the idle tick regardless.
#
# In the air the player can't autorepeat (the jump key took over autorepeat), so
# _walk only records the intent (_face) and steers the latched carry; the tick does
# the moving (see _step). On the ground it takes the throttled step.
_walk ()  # $1 = direction (-1/+1)
{
	if test "$_state" != 'play' || test "$_g_started" -ne 1 || test "$_too_small" -eq 1
	then return 0; fi
	# No window to stamp: this event IS the stamp. tuish_key_track named these keys, so
	# the library refilled the window before this binding ran — which is why _jump can
	# ask tuish_key_down about a key whose event is still in flight.
	_face=$1
	if test "$_grounded" -eq 0; then _air_run=$1; return 0; fi   # airborne: steer only
	if test "$_step_acc" -lt "$STEP_MIN_US"; then return 0; fi   # throttle autorepeat
	_hstep "$1"
	_check_world "$_pcy"      # stepped into a hazard / coin / enemy / goal?
	_render_frame
	return 0
}
_move_left ()  { _walk -1; }
_move_right () { _walk 1; }
_jump ()
{
	if test "$_grounded" -eq 1
	then
		_pvy=$(( - JUMP_U )); _grounded=0
		# Carry horizontal momentum if a movement key is still down. A plain VT cannot
		# say so — pressing jump stops the movement key's repeats, and there is no
		# release event to miss — so "still down" is the library's recency window
		# (tuish_key_ttl MOVE_TTL, above): a running jump keeps moving, a standing one
		# goes straight up, and it doubles as the coyote window just after release.
		if tuish_key_down 'left' 'char a' 'right' 'char d'
		then _air_run=$_face; else _air_run=0; fi
	fi
	return 0
}
_restart ()
{
	_room=1 _state=play _deaths=0 _win_shown=0
	_load_room 1
	_need_full=1; _render_frame
	return 0
}
_on_resize ()
{
	_check_size
	_need_full=1; _render_frame
	return 0
}
# Bound as the catch-all. tuish_pass, not a bare no-op: "I did nothing with this"
# has to reach a HOST, or an event we ignore is an event it never sees.
_noop () { tuish_pass; return 0; }
_do_quit () { tuish_quit_clear; return 0; }

# ─── Main ────────────────────────────────────────────────────────
# Everything but the event loop. Split out of _g_main so a cooperative host can
# tuish_ctx_mount us and drive us from ITS loop (we never call tuish_run then).
# Keeps tuish_idle_interval here so a driven game still ASKS for its fast tick — the
# host adopts it via tuish_ctx_sync_interval and ticks us at it via tuish_ctx_tick.
_g_setup ()
{
	# Fresh game each launch (a host may run us more than once).
	_room=1 _state=play _deaths=0 _win_shown=0
	_g_started=0 _too_small=0 _need_full=0 _hud_dirty=0
	_render_acc=0 _step_acc=$STEP_MIN_US
	_face=0 _air_run=0 _grounded=0 _coins_got=0

	# Pick the idle interval — the game clock — for OUR context. Set it after init
	# via tuish_idle_interval so it works whether we own the device (standalone) or
	# are hosted (the device is already up, so the pre-init env var alone would be
	# ignored and we'd inherit the host's slow tick). It is per-context, so the host
	# gets its own tick back when we return. TUISH_TICK_US is our per-tick dt.
	tuish_init
	tuish_idle_interval "${TUISH_IDLE_TIMEOUT:-0.02}"
	TICK_DT=$TUISH_TICK_US

	tuish_on_redraw _g_repaint    # so a host can repaint us where it put us

	# Bindings must be registered while our context is active (after tuish_init) so
	# they land in its namespace — hence in here, not at file scope.
	tuish_bind 'idle'    '_tick'
	tuish_bind 'resize'  '_on_resize'
	tuish_bind 'ctrl-w'  '_do_quit'
	tuish_bind 'char q'  '_do_quit'   # q works everywhere; Ctrl+W is reserved by browsers
	tuish_bind 'char r'  '_restart'
	# movement — one tap = one tile; held autorepeat is throttled to RUN_SPEED
	# tiles/sec (uniform across keyboards), with gravity ticking between steps.
	tuish_bind 'left'    '_move_left'
	tuish_bind 'char a'  '_move_left'
	tuish_bind 'right'   '_move_right'
	tuish_bind 'char d'  '_move_right'
	# jump
	tuish_bind 'up'      '_jump'
	tuish_bind 'char w'  '_jump'
	tuish_bind '*'       '_noop'

	# Ask the library to track whether a movement key is still DOWN. A plain VT never
	# says so — it just repeats the last key — so it is inferred from recency, and the
	# window has to outlast the autorepeat gap without reaching the initial repeat delay.
	# _jump reads it (tuish_key_down) to decide whether a jump is a running one.
	#
	# This has to be here rather than in a constant of ours because the decay rides OUR
	# idle tick, and hosted, our tick is negotiated with the host — a number we do not
	# get to know. Track after tuish_init, like the binds, so it lands in our context.
	_g_track_keys
	tuish_key_ttl "$MOVE_TTL"

	# Render into a fixed partial slab, not the whole screen: the board and HUD
	# live in GAME_VIEW_H reserved rows. Hosted, this fills our region.
	tuish_viewport fixed "$GAME_VIEW_H"
	_load_room "$_room"
}

# Entry point for the BLOCKING form: standalone (the bootstrap below) or a modal host
# that runs us inside a region it created and gets control back when we quit.
_g_main ()
{
	_g_setup
	tuish_run || :
	tuish_fini
}

if test "${_g_standalone:-0}" -eq 1
then
	_g_main
fi
