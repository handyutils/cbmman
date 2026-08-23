# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# src/hid.sh - Human interface device: keyboard/mouse event resolution
# Optional module. Source after event.sh.
#
# Provides:
#   tuish_kitty_on/off      - enable/disable kitty keyboard protocol
#   tuish_mouse_on/off      - enable/disable mouse tracking
#   tuish_detailed_on/off   - enable/disable press/release/repeat reporting
#   tuish_modkeys_on/off    - enable/disable physical modifier key events
#   tuish_wrap_on/off       - enable/disable auto-wrap (DECAWM)
#
# Internal:
#   _tuish_resolve_event    - overrides event.sh stub with full resolution

# ─── HID state ────────────────────────────────────────────────────
# _tuish_kitty_raw, _tuish_mouse, _tuish_detailed, _tuish_modkeys,
# _tuish_wrap are initialized in tui.sh (HID state defaults).

if test -n "${_tuish_hid_loaded:-}"; then return 0; fi
_tuish_hid_loaded=1

_tuish_held=''

# Mouse press→release tracking is per-context.
tuish_ctx_register _tuish_held

# Teardown hook called by tuish_fini (stubbed in tui.sh): put back whatever HID state
# was ever switched on, so fini need not read HID-private state directly.
#
# Every test here gates on the DEVICE flag, never on the active context's field. By the
# time we run, the app that asked for the escape may be long gone — a child enables mouse
# tracking, the host unmounts it, its frame is destroyed, and the root (whose _tuish_mouse
# was always 0) is active. Consulting the context field would emit nothing and leak SGR
# mouse reports into the user's shell after exit. The _dev flag remembers.
_tuish_hid_fini ()
{
	if test "${_tuish_mouse_dev:-0}" -eq 1; then tuish_mouse_off; fi

	# The escape, not tuish_detailed_off: that one re-checks TUISH_PROTOCOL, and by the
	# time we run tuish_fini has already restored the protocol to 'vt' — so the call
	# would silently do nothing. _tuish_detailed_dev is only ever set under kitty in the
	# first place, so it IS the guard.
	if test "${_tuish_detailed_dev:-0}" -eq 1
	then
		_tuish_write '\033[=9u'
		_tuish_detailed_dev=0
		_tuish_detailed=0
	fi
}

# ─── Keyboard protocol ──────────────────────────────────────────

tuish_kitty_on ()
{
	test "$TUISH_PROTOCOL" = 'kitty' && return 0
	# Probe kitty protocol; skip non-matching CSI sequences
	_tuish_out '\033[?u'
	while _tuish_get_byte "$_tuish_esc_timeout"
	do
		_tuish_ord "$_tuish_byte"
		if test "$_tuish_code" -ne 27
		then
			_tuish_pending_byte="$_tuish_byte"
			return 1
		fi
		_tuish_get_byte "$_tuish_esc_timeout" || return 1
		test "$_tuish_byte" != '[' && return 1
		_tuish_get_byte "$_tuish_esc_timeout" || return 1
		if test "$_tuish_byte" = '?'
		then
			while _tuish_get_byte "$_tuish_esc_timeout"
			do
				test "$_tuish_byte" = 'u' && break
			done
			_tuish_write '\033[>9u'
			TUISH_PROTOCOL='kitty'
			return 0
		fi
		# Not the probe response — skip to end of this CSI sequence
		_tuish_ord "$_tuish_byte"
		while test "$_tuish_code" -lt 64 || test "$_tuish_code" -gt 126
		do
			_tuish_get_byte "$_tuish_esc_timeout" || return 1
			_tuish_ord "$_tuish_byte"
		done
	done
	return 1
}

tuish_kitty_off ()
{
	test "$TUISH_PROTOCOL" != 'kitty' && return 0
	_tuish_write '\033[<u'
	_tuish_write '\033[>0u'
	TUISH_PROTOCOL='vt'
	_tuish_kitty_raw='letter'
}

# ─── Event tracking toggles ──────────────────────────────────────

tuish_mouse_on ()
{
	_tuish_mouse=1        # per-context: this app wants mouse events
	_tuish_mouse_dev=1    # device: mouse escapes are now live on the terminal
	_tuish_write '\033[?1002h'   # button event tracking
	_tuish_write '\033[?1003h'   # any event tracking
	_tuish_write '\033[?1006h'   # SGR mouse mode
}

tuish_mouse_off ()
{
	_tuish_write '\033[?1006l'   # SGR mouse off
	_tuish_write '\033[?1003l'   # any event tracking off
	_tuish_write '\033[?1002l'   # button event tracking off
	_tuish_mouse=0
	_tuish_mouse_dev=0
}

tuish_detailed_on ()
{
	_tuish_detailed=1
	if test "$TUISH_PROTOCOL" = 'kitty'
	then
		_tuish_write '\033[=11u'
		_tuish_detailed_dev=1   # device: the kitty flag is now set on the terminal
	fi
}

tuish_detailed_off ()
{
	if test "$TUISH_PROTOCOL" = 'kitty'
	then
		_tuish_write '\033[=9u'
		_tuish_detailed_dev=0
	fi
	_tuish_detailed=0
}

tuish_modkeys_on ()
{
	_tuish_modkeys=1
}

tuish_modkeys_off ()
{
	_tuish_modkeys=0
}

tuish_wrap_on ()
{
	_tuish_write '\033[?7h'   # DECAWM on: enable auto-wrap
	_tuish_wrap=1
}

tuish_wrap_off ()
{
	_tuish_write '\033[?7l'   # DECAWM off: disable auto-wrap (clip)
	_tuish_wrap=0
}

# ─── Event name resolution ────────────────────────────────────────
# Overrides the stub in event.sh.  Resolves M/m (mouse), E (keyboard),
# C (character), and K (CSI u / kitty protocol) event classes into
# human-readable TUISH_EVENT names.

# Mouse (SGR 1006): decode the button byte arithmetically instead of
# enumerating every button x modifier combination. Bits 2/3/4 are shift/alt/
# ctrl; clearing them leaves the base action (0-2 click, 3 release, 32-34 hold,
# 35 move, 64/65 wheel). Some terminals send 96/97/98 for a ctrl-click, so those
# are normalized first. _tuish_held carries the unprefixed drop name from a
# press/hold to its matching release.
_tuish_resolve_mouse ()   # $1=class(M|m) $2=button $3=x $4=y
{
	TUISH_EVENT_KIND='mouse'
	local _b=${2:-0} _pfx='' _base _btn _mouse=''
	case $_b in 96) _b=16;; 97) _b=17;; 98) _b=18;; esac
	test $((_b & 16)) -ne 0 && _pfx='ctrl-'
	test $((_b & 8)) -ne 0 && _pfx="${_pfx}alt-"
	test $((_b & 4)) -ne 0 && _pfx="${_pfx}shift-"
	_base=$((_b & ~28))

	if test "$1" = 'm'
	then
		# SGR release: a drop for button 0/1/2, else absorbed. A quick click with
		# no drag is absorbed unless detailed reporting is on.
		if test -z "$_tuish_held" && test $_tuish_detailed -eq 0
		then return; fi
		_tuish_held=''
		case $_base in
			0) _mouse="${_pfx}ldrop";;
			1) _mouse="${_pfx}mdrop";;
			2) _mouse="${_pfx}rdrop";;
			*) return;;
		esac
	else
		case $_base in
			0|1|2)
				case $_base in 0) _btn=l;; 1) _btn=m;; 2) _btn=r;; esac
				if test -n "$_tuish_held"
				then _mouse="${_pfx}drop"; _tuish_held=''
				else _mouse="${_pfx}${_btn}clik"
				fi;;
			3)  test -n "$_tuish_held" && _mouse="$_tuish_held" && _tuish_held='';;
			32|33|34)
				case $_base in 32) _btn=l;; 33) _btn=m;; 34) _btn=r;; esac
				_mouse="${_pfx}${_btn}hold"; _tuish_held="${_btn}drop";;
			35) _mouse="${_pfx}move"; _tuish_held='';;
			64) _mouse="${_pfx}whup";;
			65) _mouse="${_pfx}wdown";;
			*)  _mouse="${2:-}"; _tuish_held='';;
		esac
	fi

	TUISH_MOUSE_X=$3
	TUISH_MOUSE_Y=$4
	TUISH_MOUSE_ABS_Y=$4
	# Report the click in the app's own coordinate system — the inverse of the
	# tuish_vmove transform: viewport-relative row, and (now that a hosted region
	# can be column-offset) region-relative column. For the root both origins are
	# 1/0, so standalone coordinates are unchanged.
	if test -n "$_tuish_view_mode"
	then
		TUISH_MOUSE_Y=$(($4 - TUISH_VIEW_TOP + 1))
		TUISH_MOUSE_X=$(($3 - TUISH_VIEW_LEFT))
	fi
	TUISH_EVENT="$_mouse"
}

# alt-/ctrl- fallback for ESC-prefixed bytes left unresolved by the exact and
# modified-key matches. One body for both protocols: kitty adds the codes VT
# never reaches here (8/9/10/13 and 23 ctrl bytes; 100 → ctrl-del), which VT
# resolves earlier via the exact-match case, so gating them on kitty leaves VT
# behaviour unchanged. _tuish_kitty_raw: 'letter' = raw bytes are ctrl+letter
# (some terminals leak them despite kitty mode), 'func' = functional keys.
_tuish_resolve_esc_char ()
{
	local _ec_kitty=0
	test "$TUISH_PROTOCOL" = 'kitty' && _ec_kitty=1
	if test "$#" -eq 1
	then
		if test $1 -ge 32 && test $1 -le 126
		then
			eval "TUISH_EVENT=\"alt-\$_tuish_chr_$1\""
		elif test $1 -ge 1 && test $1 -le 26
		then
			if test $_ec_kitty -eq 1
			then
				case $1 in
					8) TUISH_EVENT='ctrl-bksp';;
					9) TUISH_EVENT='tab';;
					10|13) TUISH_EVENT='enter';;
					23)
						if test "$_tuish_kitty_raw" = 'letter'
						then eval "TUISH_EVENT=\"ctrl-\$_tuish_chr_$(($1 + 96))\""
						else TUISH_EVENT='ctrl-bksp'
						fi;;
					*) eval "TUISH_EVENT=\"ctrl-\$_tuish_chr_$(($1 + 96))\"";;
				esac
			else
				eval "TUISH_EVENT=\"ctrl-\$_tuish_chr_$(($1 + 96))\""
			fi
		else
			TUISH_EVENT="MISS ${*:-27}"
		fi
	elif test "$#" -eq 2 && test "$1" -eq 27
	then
		if test "$2" -ge 32 && test "$2" -le 126
		then
			if test $_ec_kitty -eq 1 && test "$2" -eq 100
			then TUISH_EVENT='ctrl-del'
			else eval "TUISH_EVENT=\"alt-\$_tuish_chr_$2\""
			fi
		elif test "$2" -ge 1 && test "$2" -le 26
		then
			eval "TUISH_EVENT=\"ctrl-alt-\$_tuish_chr_$(($2 + 96))\""
		else
			TUISH_EVENT="MISS ${*:-27}"
		fi
	else
		TUISH_EVENT="MISS ${*:-27}"
	fi
}

# Resolve a VT-style (legacy escape) key event from its raw bytes ($@).
_tuish_resolve_vt ()
{
	TUISH_EVENT_KIND='key'
	TUISH_EVENT=''

	# Extract event type sub-parameter (:1=press :2=repeat :3=release)
	local _e_seq="${*:-27}"
	local _e_suffix=''
	case "$_e_seq" in
		*' 58 50 '*) _e_suffix='-rep'; _e_seq="${_e_seq%% 58 50 *} ${_e_seq##* 58 50 }";;
		*' 58 50')   _e_suffix='-rep'; _e_seq="${_e_seq% 58 50}";;
		*' 58 51 '*) _e_suffix='-rel'; _e_seq="${_e_seq%% 58 51 *} ${_e_seq##* 58 51 }";;
		*' 58 51')   _e_suffix='-rel'; _e_seq="${_e_seq% 58 51}";;
		*' 58 49 '*) _e_seq="${_e_seq%% 58 49 *} ${_e_seq##* 58 49 }";;
		*' 58 49')   _e_seq="${_e_seq% 58 49}";;
	esac

	case "$_e_seq" in
		'8'   ) TUISH_EVENT='ctrl-bksp';;
		'9'   ) TUISH_EVENT='tab';;
		'10'|'13' ) TUISH_EVENT='enter';;
		'27'  ) TUISH_EVENT='esc';;
		'28'  ) TUISH_EVENT='ctrl-bslash';;
		'29'  ) TUISH_EVENT='ctrl-]';;
		'30'  ) TUISH_EVENT='ctrl-^';;
		'31'  ) TUISH_EVENT='ctrl-_';;
		'127' ) TUISH_EVENT='bksp';;

		'27 8'  ) TUISH_EVENT='alt-bksp';;
		'27 9'  ) TUISH_EVENT='alt-tab';;
		'27 10'|'27 13' ) TUISH_EVENT='alt-enter';;
		'27 127') TUISH_EVENT='alt-bksp';;

		'91 90' ) TUISH_EVENT='shift-tab';;
		'91 73' ) TUISH_EVENT='focus-in';;
		'91 79' ) TUISH_EVENT='focus-out';;
		'91 50 48 48 126' ) TUISH_EVENT='paste-start';;
		'91 50 48 49 126' ) TUISH_EVENT='paste-end';;

		'79 65' | '91 65' ) TUISH_EVENT='up';;
		'79 66' | '91 66' ) TUISH_EVENT='down';;
		'79 67' | '91 67' ) TUISH_EVENT='right';;
		'79 68' | '91 68' ) TUISH_EVENT='left';;

		# f1-f4: SS3 (ESC O P..S) and CSI (ESC [ P..S) forms.
		'79 80' | '91 80' ) TUISH_EVENT='f1';;
		'79 81' | '91 81' ) TUISH_EVENT='f2';;
		'79 82' | '91 82' ) TUISH_EVENT='f3';;
		'79 83' | '91 83' ) TUISH_EVENT='f4';;
		# f1-f5 on the LINUX CONSOLE: ESC [ [ A..E (the double-'[' form). The
		# console has no SS3/CSI f1-f4 and uses [15~ for none of these, so these
		# are the only way f1-f5 arrive on a bare VT. (event.sh keeps the second
		# '[' from mis-dispatching as a CSI final.)
		'91 91 65' ) TUISH_EVENT='f1';;
		'91 91 66' ) TUISH_EVENT='f2';;
		'91 91 67' ) TUISH_EVENT='f3';;
		'91 91 68' ) TUISH_EVENT='f4';;
		'91 91 69' ) TUISH_EVENT='f5';;
		'91 49 53 126' ) TUISH_EVENT='f5' ;;
		'91 49 55 126' ) TUISH_EVENT='f6' ;;
		'91 49 56 126' ) TUISH_EVENT='f7' ;;
		'91 49 57 126' ) TUISH_EVENT='f8' ;;
		'91 50 48 126' ) TUISH_EVENT='f9' ;;
		'91 50 49 126' ) TUISH_EVENT='f10' ;;
		'91 50 51 126' ) TUISH_EVENT='f11' ;;
		'91 50 52 126' ) TUISH_EVENT='f12' ;;

		'79 72' | '91 72' | '91 49 126' ) TUISH_EVENT='home';;
		'79 70' | '91 70' | '91 52 126' ) TUISH_EVENT='end';;
		'91 50 126' ) TUISH_EVENT='ins';;
		'91 51 126' ) TUISH_EVENT='del';;
		'91 53 126' ) TUISH_EVENT='pgup';;
		'91 54 126' ) TUISH_EVENT='pgdn';;
	esac

	# Modified nav/function keys. Single-pass replacement for what used
	# to be up to 24 sequential per-key case matches: map (base sequence,
	# final) → base name in one case, then (modifier param) → prefix. Two
	# shapes after event-type stripping above:
	#   5-code: "91 <base> 59 <mod> <final>"
	#   6-code: "91 <base> <extra> 59 <mod> 126"
	# The modifier slot is matched as digit byte code(s) [0-9]*[0-9]: one token
	# for params 1-9 ("49".."57"), two for the macOS Cmd combos 10-16 ("49 48"
	# = "10" …). Each arm anchors the head fully up to " 59 ": this rejects
	# sequences with extra parameters and keeps f5/f6/… from prefix-colliding.
	# The param is decoded numerically below, so a non-modifier slot (e.g. "99")
	# stays unresolved and falls through to the kitty/MISS path.
	if test -z "$TUISH_EVENT"
	then
		local _em_base=''
		case "$_e_seq" in
			'91 49 59 '[0-9]*[0-9]' 65')   _em_base='up';;
			'91 49 59 '[0-9]*[0-9]' 66')   _em_base='down';;
			'91 49 59 '[0-9]*[0-9]' 67')   _em_base='right';;
			'91 49 59 '[0-9]*[0-9]' 68')   _em_base='left';;
			'91 49 59 '[0-9]*[0-9]' 80')   _em_base='f1';;
			'91 49 59 '[0-9]*[0-9]' 81')   _em_base='f2';;
			'91 49 59 '[0-9]*[0-9]' 82')   _em_base='f3';;
			'91 49 59 '[0-9]*[0-9]' 83')   _em_base='f4';;
			'91 49 59 '[0-9]*[0-9]' 72')   _em_base='home';;
			'91 49 59 '[0-9]*[0-9]' 70')   _em_base='end';;
			'91 50 59 '[0-9]*[0-9]' 126')  _em_base='ins';;
			'91 51 59 '[0-9]*[0-9]' 126')  _em_base='del';;
			'91 53 59 '[0-9]*[0-9]' 126')  _em_base='pgup';;
			'91 54 59 '[0-9]*[0-9]' 126')  _em_base='pgdn';;
			'91 49 53 59 '[0-9]*[0-9]' 126') _em_base='f5';;
			'91 49 55 59 '[0-9]*[0-9]' 126') _em_base='f6';;
			'91 49 56 59 '[0-9]*[0-9]' 126') _em_base='f7';;
			'91 49 57 59 '[0-9]*[0-9]' 126') _em_base='f8';;
			'91 50 48 59 '[0-9]*[0-9]' 126') _em_base='f9';;
			'91 50 49 59 '[0-9]*[0-9]' 126') _em_base='f10';;
			'91 50 51 59 '[0-9]*[0-9]' 126') _em_base='f11';;
			'91 50 52 59 '[0-9]*[0-9]' 126') _em_base='f12';;
		esac
		if test -n "$_em_base"
		then
			# Modifier param byte code(s) between " 59 " and the final: one
			# token for params 1-9, two for the macOS Cmd combos 10-16. The
			# meta bit (params 9-16) is reported as super- to match kitty.
			local _em_mod="${_e_seq##* 59 }"
			_em_mod="${_em_mod% *}"
			case "$_em_mod" in
				49) TUISH_EVENT="$_em_base";;
				50) TUISH_EVENT="shift-$_em_base";;
				51) TUISH_EVENT="alt-$_em_base";;
				52) TUISH_EVENT="alt-shift-$_em_base";;
				53) TUISH_EVENT="ctrl-$_em_base";;
				54) TUISH_EVENT="ctrl-shift-$_em_base";;
				55) TUISH_EVENT="ctrl-alt-$_em_base";;
				56) TUISH_EVENT="ctrl-alt-shift-$_em_base";;
				57)      TUISH_EVENT="super-$_em_base";;
				'49 48') TUISH_EVENT="shift-super-$_em_base";;
				'49 49') TUISH_EVENT="alt-super-$_em_base";;
				'49 50') TUISH_EVENT="alt-shift-super-$_em_base";;
				'49 51') TUISH_EVENT="ctrl-super-$_em_base";;
				'49 52') TUISH_EVENT="ctrl-shift-super-$_em_base";;
				'49 53') TUISH_EVENT="ctrl-alt-super-$_em_base";;
				'49 54') TUISH_EVENT="ctrl-alt-shift-super-$_em_base";;
			esac
		fi
	fi

	if test -z "${TUISH_EVENT}"
	then
		_tuish_resolve_esc_char "$@"
	fi

	# Apply event type suffix
	test -n "$_e_suffix" && test -n "$TUISH_EVENT" && TUISH_EVENT="${TUISH_EVENT}${_e_suffix}"

	# Override kind for non-keyboard escape sequences
	case "$TUISH_EVENT" in
		focus-*) TUISH_EVENT_KIND='focus';;
		paste-*) TUISH_EVENT_KIND='paste';;
	esac
}

# Resolve a CSI u (kitty keyboard protocol) key event. $1 = parameter string.
_tuish_resolve_kitty ()
{
	TUISH_EVENT_KIND='key'
	local _ku_keycode="${1%%[;:]*}"
	local _ku_mod=1
	local _ku_type=1
	local _ku_rest="${1#"$_ku_keycode"}"
	if test -n "$_ku_rest"
	then
		_ku_rest="${_ku_rest#;}"
		_ku_mod="${_ku_rest%%[:]*}"
		local _ku_t="${_ku_rest#"$_ku_mod"}"
		test "${_ku_t}" != "${_ku_t#:}" && _ku_type="${_ku_t#:}"
	fi

	local _ku_bits=$((_ku_mod - 1))

	# For modifier keycodes, clear the self-referential modifier bit
	case "$_ku_keycode" in
		57441|57447) _ku_bits=$((_ku_bits & ~1));;
		57443|57449) _ku_bits=$((_ku_bits & ~2));;
		57442|57448) _ku_bits=$((_ku_bits & ~4));;
		57444|57450) _ku_bits=$((_ku_bits & ~8));;
		57445|57451) _ku_bits=$((_ku_bits & ~16));;
		57446|57452) _ku_bits=$((_ku_bits & ~32));;
	esac

	local _ku_prefix=''
	test $((_ku_bits & 4)) -ne 0 && _ku_prefix="${_ku_prefix}ctrl-"
	test $((_ku_bits & 2)) -ne 0 && _ku_prefix="${_ku_prefix}alt-"
	test $((_ku_bits & 1)) -ne 0 && _ku_prefix="${_ku_prefix}shift-"
	test $((_ku_bits & 8)) -ne 0 && _ku_prefix="${_ku_prefix}super-"
	test $((_ku_bits & 16)) -ne 0 && _ku_prefix="${_ku_prefix}hyper-"
	test $((_ku_bits & 32)) -ne 0 && _ku_prefix="${_ku_prefix}meta-"

	local _ku_key=''
	case "$_ku_keycode" in
		9) _ku_key='tab';;
		13) _ku_key='enter';;
		27) _ku_key='esc';;
		32) _ku_key='space';;
		92) _ku_key='bslash';;
		127) _ku_key='bksp';;
		57358) _ku_key='caps-lock';;
		57359) _ku_key='scroll-lock';;
		57360) _ku_key='num-lock';;
		57361) _ku_key='prtsc';;
		57362) _ku_key='pause';;
		57363) _ku_key='menu';;
		57409) _ku_key='kp-.';;
		57410) _ku_key='kp-/';;
		57411) _ku_key='kp-*';;
		57412) _ku_key='kp--';;
		57413) _ku_key='kp-+';;
		57414) _ku_key='kp-enter';;
		57415) _ku_key='kp-=';;
		57416) _ku_key='kp-sep';;
		57417) _ku_key='kp-left';;
		57418) _ku_key='kp-right';;
		57419) _ku_key='kp-up';;
		57420) _ku_key='kp-down';;
		57421) _ku_key='kp-pgup';;
		57422) _ku_key='kp-pgdn';;
		57423) _ku_key='kp-home';;
		57424) _ku_key='kp-end';;
		57425) _ku_key='kp-ins';;
		57426) _ku_key='kp-del';;
		57427) _ku_key='kp-begin';;
		57428) _ku_key='media-play';;
		57429) _ku_key='media-pause';;
		57430) _ku_key='media-play-pause';;
		57431) _ku_key='media-reverse';;
		57432) _ku_key='media-stop';;
		57433) _ku_key='media-ff';;
		57434) _ku_key='media-rw';;
		57435) _ku_key='media-next';;
		57436) _ku_key='media-prev';;
		57437) _ku_key='media-rec';;
		57438) _ku_key='vol-down';;
		57439) _ku_key='vol-up';;
		57440) _ku_key='vol-mute';;
		57441) _ku_key='shift.l';;
		57442) _ku_key='ctrl.l';;
		57443) _ku_key='alt.l';;
		57444) _ku_key='super.l';;
		57445) _ku_key='hyper.l';;
		57446) _ku_key='meta.l';;
		57447) _ku_key='shift.r';;
		57448) _ku_key='ctrl.r';;
		57449) _ku_key='alt.r';;
		57450) _ku_key='super.r';;
		57451) _ku_key='hyper.r';;
		57452) _ku_key='meta.r';;
		57453) _ku_key='iso-level3';;
		57454) _ku_key='iso-level5';;
		*)
			if test "$_ku_keycode" -ge 57376 2>/dev/null && test "$_ku_keycode" -le 57398
			then
				_ku_key="f$((_ku_keycode - 57363))"
			elif test "$_ku_keycode" -ge 57399 2>/dev/null && test "$_ku_keycode" -le 57408
			then
				_ku_key="kp-$((_ku_keycode - 57399))"
			elif test "$_ku_keycode" -ge 57348 2>/dev/null && test "$_ku_keycode" -le 57357
			then
				case "$((_ku_keycode - 57348))" in
					0) _ku_key='ins';; 1) _ku_key='del';;
					2) _ku_key='left';; 3) _ku_key='right';;
					4) _ku_key='up';; 5) _ku_key='down';;
					6) _ku_key='pgup';; 7) _ku_key='pgdn';;
					8) _ku_key='home';; 9) _ku_key='end';;
				esac
			elif test "$_ku_keycode" -ge 33 2>/dev/null && test "$_ku_keycode" -le 126
			then
				eval "_ku_key=\"\$_tuish_chr_$_ku_keycode\""
			else
				_ku_key="key-${_ku_keycode}"
			fi
			;;
	esac

	# ctrl+letter via CSI u → terminal has full flag 8 support
	if test "$_tuish_kitty_raw" = 'letter' &&
	   test $((_ku_bits & 4)) -ne 0 &&
	   test "$_ku_keycode" -ge 97 2>/dev/null && test "$_ku_keycode" -le 122
	then
		_tuish_kitty_raw='func'
	fi

	local _ku_suffix=''
	case "$_ku_type" in
		2) _ku_suffix='-rep';;
		3) _ku_suffix='-rel';;
	esac

	# Unmodified printable press: match C handler format
	if test -z "$_ku_prefix" && test -z "$_ku_suffix" &&
	   test "$_ku_keycode" -ge 33 2>/dev/null && test "$_ku_keycode" -le 126
	then
		TUISH_EVENT="char ${_ku_key}"
	else
		TUISH_EVENT="${_ku_prefix}${_ku_key}${_ku_suffix}"
	fi
}

_tuish_resolve_event ()
{
	local _class=$1

	# Class C (printable typing) is by far the most frequent event: resolve
	# it first and return, so it never falls through the mouse/keyboard
	# branches. Reaching it last was a large per-keystroke cost (~7x in bash).
	if test "$_class" = 'C'
	then
		TUISH_EVENT_KIND='key'
		if test "${2:-}" != '\'
		then
			TUISH_EVENT="${2:+char }${2:-space}"
		else
			TUISH_EVENT="char bslash"
		fi
		return
	fi

	if test "${_class}" = 'M' || test "${_class}" = 'm'
	then
		_tuish_resolve_mouse "$@"
	elif test "$_class" = 'E'
	then
		shift
		_tuish_resolve_vt "$@"
	elif test "$_class" = 'K'
	then
		shift
		_tuish_resolve_kitty "$@"
	fi
}
