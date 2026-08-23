#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for _tuish_parse_event class E (keyboard/escape events)

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/ord.sh"
. "$TESTS_DIR/../src/tui.sh"
. "$TESTS_DIR/../src/event.sh"
. "$TESTS_DIR/../src/hid.sh"


# Exercise the SHIPPED configuration. tuish_fnfix normally fires from tuish_init, which unit
# tests deliberately never call (they stub the device) — so without this, every suite here
# would validate the framework with its ksh `local` still leaking, i.e. not the library that
# actually runs. It is a no-op on every shell whose `local` already works.
command -v tuish_fnfix >/dev/null 2>&1 && tuish_fnfix

_tuish_write () { :; }

reset_state () {
	TUISH_EVENT=''
	TUISH_EVENT_KIND=''
	TUISH_RAW=''
	TUISH_MOUSE_X=0
	TUISH_MOUSE_Y=0
	_tuish_held=''
}

printf 'Unit tests: _tuish_parse_event class E (keyboard)\n'

# --- Bare escape ---
reset_state
_tuish_parse_event "E 27"
assert_eq "$TUISH_EVENT" "esc" "bare ESC"
assert_eq "$TUISH_EVENT_KIND" "key" "bare ESC kind"

# --- Named special keys ---
reset_state
_tuish_parse_event "E 9"
assert_eq "$TUISH_EVENT" "tab" "tab (byte 9)"

reset_state
_tuish_parse_event "E 13"
assert_eq "$TUISH_EVENT" "enter" "enter (byte 13)"

reset_state
_tuish_parse_event "E 28"
assert_eq "$TUISH_EVENT" "ctrl-bslash" "ctrl-bslash (byte 28)"

reset_state
_tuish_parse_event "E 29"
assert_eq "$TUISH_EVENT" "ctrl-]" "ctrl-] (byte 29)"

reset_state
_tuish_parse_event "E 30"
assert_eq "$TUISH_EVENT" "ctrl-^" "ctrl-^ (byte 30)"

reset_state
_tuish_parse_event "E 31"
assert_eq "$TUISH_EVENT" "ctrl-_" "ctrl-_ (byte 31)"

reset_state
_tuish_parse_event "E 127"
assert_eq "$TUISH_EVENT" "bksp" "backspace (byte 127)"

reset_state
_tuish_parse_event "E 91 90"
assert_eq "$TUISH_EVENT" "shift-tab" "shift-tab"

# --- Arrow keys (application mode: ESC O A/B/C/D -> 79 65/66/67/68) ---
reset_state
_tuish_parse_event "E 79 65"
assert_eq "$TUISH_EVENT" "up" "up arrow"

reset_state
_tuish_parse_event "E 79 66"
assert_eq "$TUISH_EVENT" "down" "down arrow"

reset_state
_tuish_parse_event "E 79 67"
assert_eq "$TUISH_EVENT" "right" "right arrow"

reset_state
_tuish_parse_event "E 79 68"
assert_eq "$TUISH_EVENT" "left" "left arrow"

# --- Function keys F1-F4 (ESC O P/Q/R/S -> 79 80/81/82/83) ---
reset_state
_tuish_parse_event "E 79 80"
assert_eq "$TUISH_EVENT" "f1" "F1"

reset_state
_tuish_parse_event "E 79 81"
assert_eq "$TUISH_EVENT" "f2" "F2"

reset_state
_tuish_parse_event "E 79 82"
assert_eq "$TUISH_EVENT" "f3" "F3"

reset_state
_tuish_parse_event "E 79 83"
assert_eq "$TUISH_EVENT" "f4" "F4"

# --- Function keys F5-F12 ---
reset_state
_tuish_parse_event "E 91 49 53 126"
assert_eq "$TUISH_EVENT" "f5" "F5"

reset_state
_tuish_parse_event "E 91 49 55 126"
assert_eq "$TUISH_EVENT" "f6" "F6"

reset_state
_tuish_parse_event "E 91 49 56 126"
assert_eq "$TUISH_EVENT" "f7" "F7"

reset_state
_tuish_parse_event "E 91 49 57 126"
assert_eq "$TUISH_EVENT" "f8" "F8"

reset_state
_tuish_parse_event "E 91 50 48 126"
assert_eq "$TUISH_EVENT" "f9" "F9"

reset_state
_tuish_parse_event "E 91 50 49 126"
assert_eq "$TUISH_EVENT" "f10" "F10"

reset_state
_tuish_parse_event "E 91 50 51 126"
assert_eq "$TUISH_EVENT" "f11" "F11"

reset_state
_tuish_parse_event "E 91 50 52 126"
assert_eq "$TUISH_EVENT" "f12" "F12"

# --- Navigation keys ---
reset_state
_tuish_parse_event "E 79 72"
assert_eq "$TUISH_EVENT" "home" "Home (ESC O H)"

reset_state
_tuish_parse_event "E 91 49 126"
assert_eq "$TUISH_EVENT" "home" "Home (ESC [ 1 ~)"

reset_state
_tuish_parse_event "E 79 70"
assert_eq "$TUISH_EVENT" "end" "End (ESC O F)"

reset_state
_tuish_parse_event "E 91 52 126"
assert_eq "$TUISH_EVENT" "end" "End (ESC [ 4 ~)"

reset_state
_tuish_parse_event "E 91 50 126"
assert_eq "$TUISH_EVENT" "ins" "Insert"

reset_state
_tuish_parse_event "E 91 51 126"
assert_eq "$TUISH_EVENT" "del" "Delete"

reset_state
_tuish_parse_event "E 91 53 126"
assert_eq "$TUISH_EVENT" "pgup" "Page Up"

reset_state
_tuish_parse_event "E 91 54 126"
assert_eq "$TUISH_EVENT" "pgdn" "Page Down"

# --- Ctrl+letter fallback (codes 1-26) ---
reset_state
_tuish_parse_event "E 1"
assert_eq "$TUISH_EVENT" "ctrl-a" "ctrl-a (byte 1)"

reset_state
_tuish_parse_event "E 2"
assert_eq "$TUISH_EVENT" "ctrl-b" "ctrl-b (byte 2)"

reset_state
_tuish_parse_event "E 26"
assert_eq "$TUISH_EVENT" "ctrl-z" "ctrl-z (byte 26)"

# --- Alt+character (ESC followed by printable byte) ---
reset_state
_tuish_parse_event "E 97"
assert_eq "$TUISH_EVENT" "alt-a" "alt-a (ESC + 'a')"

reset_state
_tuish_parse_event "E 65"
assert_eq "$TUISH_EVENT" "alt-A" "alt-A (ESC + 'A')"

reset_state
_tuish_parse_event "E 49"
assert_eq "$TUISH_EVENT" "alt-1" "alt-1 (ESC + '1')"

reset_state
_tuish_parse_event "E 47"
assert_eq "$TUISH_EVENT" "alt-/" "alt-/ (ESC + '/')"

# --- Alt+Ctrl+letter (ESC followed by control byte) ---
reset_state
_tuish_parse_event "E 27 1"
assert_eq "$TUISH_EVENT" "ctrl-alt-a" "ctrl-alt-a"

reset_state
_tuish_parse_event "E 27 26"
assert_eq "$TUISH_EVENT" "ctrl-alt-z" "ctrl-alt-z"

# --- Focus events ---
reset_state
_tuish_parse_event "E 91 73"
assert_eq "$TUISH_EVENT" "focus-in" "focus in"
assert_eq "$TUISH_EVENT_KIND" "focus" "focus-in kind"

reset_state
_tuish_parse_event "E 91 79"
assert_eq "$TUISH_EVENT" "focus-out" "focus out"

# --- Paste events ---
reset_state
_tuish_parse_event "E 91 50 48 48 126"
assert_eq "$TUISH_EVENT" "paste-start" "paste start"
assert_eq "$TUISH_EVENT_KIND" "paste" "paste-start kind"

reset_state
_tuish_parse_event "E 91 50 48 49 126"
assert_eq "$TUISH_EVENT" "paste-end" "paste end"

# --- Insert with modifiers (fixed from del) ---
reset_state
_tuish_parse_event "E 91 50 59 53 126"
assert_eq "$TUISH_EVENT" "ctrl-ins" "ctrl-ins"

reset_state
_tuish_parse_event "E 91 50 59 50 126"
assert_eq "$TUISH_EVENT" "shift-ins" "shift-ins"

# --- Unknown sequence ---
reset_state
_tuish_parse_event "E 91 99 99"
assert_eq "$TUISH_EVENT" "MISS 91 99 99" "unknown escape sequence"

# --- CSI u / kitty keyboard protocol (class K) ---
reset_state
_tuish_parse_event "K 97"
assert_eq "$TUISH_EVENT" "char a" "CSI u: plain 'a'"

reset_state
_tuish_parse_event "K 97;5"
assert_eq "$TUISH_EVENT" "ctrl-a" "CSI u: ctrl-a"

reset_state
_tuish_parse_event "K 122;6"
assert_eq "$TUISH_EVENT" "ctrl-shift-z" "CSI u: ctrl-shift-z"

reset_state
_tuish_parse_event "K 97;3"
assert_eq "$TUISH_EVENT" "alt-a" "CSI u: alt-a"

reset_state
_tuish_parse_event "K 97;7"
assert_eq "$TUISH_EVENT" "ctrl-alt-a" "CSI u: ctrl-alt-a"

reset_state
_tuish_parse_event "K 97;9"
assert_eq "$TUISH_EVENT" "super-a" "CSI u: super-a (Cmd, mod 9)"

reset_state
_tuish_parse_event "K 97;10"
assert_eq "$TUISH_EVENT" "shift-super-a" "CSI u: shift-super-a (mod 10)"

reset_state
_tuish_parse_event "K 27"
assert_eq "$TUISH_EVENT" "esc" "CSI u: escape"

reset_state
_tuish_parse_event "K 9"
assert_eq "$TUISH_EVENT" "tab" "CSI u: tab"

reset_state
_tuish_parse_event "K 13"
assert_eq "$TUISH_EVENT" "enter" "CSI u: enter"

reset_state
_tuish_parse_event "K 127"
assert_eq "$TUISH_EVENT" "bksp" "CSI u: backspace"

reset_state
_tuish_parse_event "K 9;5"
assert_eq "$TUISH_EVENT" "ctrl-tab" "CSI u: ctrl-tab"

reset_state
_tuish_parse_event "K 13;2"
assert_eq "$TUISH_EVENT" "shift-enter" "CSI u: shift-enter"

reset_state
_tuish_parse_event "K 97;5:3"
assert_eq "$TUISH_EVENT" "ctrl-a-rel" "CSI u: ctrl-a release"

reset_state
_tuish_parse_event "K 97;5:2"
assert_eq "$TUISH_EVENT" "ctrl-a-rep" "CSI u: ctrl-a repeat"

# --- CSI format arrows (ESC [ A/B/C/D -> 91 65/66/67/68) ---
reset_state
_tuish_parse_event "E 91 65"
assert_eq "$TUISH_EVENT" "up" "up arrow (CSI)"

reset_state
_tuish_parse_event "E 91 66"
assert_eq "$TUISH_EVENT" "down" "down arrow (CSI)"

reset_state
_tuish_parse_event "E 91 67"
assert_eq "$TUISH_EVENT" "right" "right arrow (CSI)"

reset_state
_tuish_parse_event "E 91 68"
assert_eq "$TUISH_EVENT" "left" "left arrow (CSI)"

# --- CSI format F1-F4 ---
reset_state
_tuish_parse_event "E 91 80"
assert_eq "$TUISH_EVENT" "f1" "F1 (CSI)"

reset_state
_tuish_parse_event "E 91 81"
assert_eq "$TUISH_EVENT" "f2" "F2 (CSI)"

reset_state
_tuish_parse_event "E 91 82"
assert_eq "$TUISH_EVENT" "f3" "F3 (CSI)"

reset_state
_tuish_parse_event "E 91 83"
assert_eq "$TUISH_EVENT" "f4" "F4 (CSI)"

# --- CSI format Home/End ---
reset_state
_tuish_parse_event "E 91 72"
assert_eq "$TUISH_EVENT" "home" "Home (CSI H)"

reset_state
_tuish_parse_event "E 91 70"
assert_eq "$TUISH_EVENT" "end" "End (CSI F)"

# --- Event type stripping in E handler ---
# up repeat: CSI 1 ; 1 : 2 A -> bytes 91 49 59 49 58 50 65
reset_state
_tuish_parse_event "E 91 49 59 49 58 50 65"
assert_eq "$TUISH_EVENT" "up-rep" "up repeat (event type :2)"

# ctrl-up release: CSI 1 ; 5 : 3 A -> bytes 91 49 59 53 58 51 65
reset_state
_tuish_parse_event "E 91 49 59 53 58 51 65"
assert_eq "$TUISH_EVENT" "ctrl-up-rel" "ctrl-up release (event type :3)"

# F5 repeat: CSI 15 ; 1 : 2 ~ -> bytes 91 49 53 59 49 58 50 126
reset_state
_tuish_parse_event "E 91 49 53 59 49 58 50 126"
assert_eq "$TUISH_EVENT" "f5-rep" "F5 repeat (event type :2)"

# super (Cmd) with event type: CSI 1 ; 9 : 3 D -> super-left release
reset_state
_tuish_parse_event "E 91 49 59 57 58 51 68"
assert_eq "$TUISH_EVENT" "super-left-rel" "super-left release (event type :3)"

# press event type stripped cleanly: CSI 1 ; 5 : 1 A -> ctrl-up
reset_state
_tuish_parse_event "E 91 49 59 53 58 49 65"
assert_eq "$TUISH_EVENT" "ctrl-up" "ctrl-up press (event type :1 stripped)"

# --- Modifier-1 entries (unmodified key with explicit ;1) ---
# CSI 1 ; 1 A -> up with modifier 1 (no modifier)
reset_state
_tuish_parse_event "E 91 49 59 49 65"
assert_eq "$TUISH_EVENT" "up" "modifier-1 up (5code)"

# CSI 15 ; 1 ~ -> F5 with modifier 1
reset_state
_tuish_parse_event "E 91 49 53 59 49 126"
assert_eq "$TUISH_EVENT" "f5" "modifier-1 F5 (6code)"

# --- CSI u: printable characters produce char prefix ---
reset_state
_tuish_parse_event "K 90"
assert_eq "$TUISH_EVENT" "char Z" "CSI u: plain 'Z'"

reset_state
_tuish_parse_event "K 47"
assert_eq "$TUISH_EVENT" "char /" "CSI u: plain '/'"

reset_state
_tuish_parse_event "K 92"
assert_eq "$TUISH_EVENT" "char bslash" "CSI u: plain backslash"

# Modified printable: no char prefix
reset_state
_tuish_parse_event "K 97;5"
assert_eq "$TUISH_EVENT" "ctrl-a" "CSI u: ctrl-a (no char prefix)"

# Repeat printable: no char prefix
reset_state
_tuish_parse_event "K 97;1:2"
assert_eq "$TUISH_EVENT" "a-rep" "CSI u: a repeat (no char prefix)"

# Release printable: no char prefix
reset_state
_tuish_parse_event "K 97;1:3"
assert_eq "$TUISH_EVENT" "a-rel" "CSI u: a release (no char prefix)"

# --- CSI u: space ---
reset_state
_tuish_parse_event "K 32"
assert_eq "$TUISH_EVENT" "space" "CSI u: space"

reset_state
_tuish_parse_event "K 32;2"
assert_eq "$TUISH_EVENT" "shift-space" "CSI u: shift-space"

# --- CSI u: bitmask modifier decomposition ---
reset_state
_tuish_parse_event "K 97;9"
assert_eq "$TUISH_EVENT" "super-a" "CSI u: super-a (mod 9)"

reset_state
_tuish_parse_event "K 97;13"
assert_eq "$TUISH_EVENT" "ctrl-super-a" "CSI u: ctrl-super-a (mod 13)"

reset_state
_tuish_parse_event "K 97;17"
assert_eq "$TUISH_EVENT" "hyper-a" "CSI u: hyper-a (mod 17)"

reset_state
_tuish_parse_event "K 97;33"
assert_eq "$TUISH_EVENT" "meta-a" "CSI u: meta-a (mod 33)"

# --- CSI u: modifier keys (physical) ---
reset_state
_tuish_parse_event "K 57441;2"
assert_eq "$TUISH_EVENT" "shift.l" "CSI u: left shift (self-mod stripped)"

reset_state
_tuish_parse_event "K 57447;2"
assert_eq "$TUISH_EVENT" "shift.r" "CSI u: right shift (self-mod stripped)"

reset_state
_tuish_parse_event "K 57442;5"
assert_eq "$TUISH_EVENT" "ctrl.l" "CSI u: left ctrl (self-mod stripped)"

reset_state
_tuish_parse_event "K 57448;5"
assert_eq "$TUISH_EVENT" "ctrl.r" "CSI u: right ctrl (self-mod stripped)"

reset_state
_tuish_parse_event "K 57443;3"
assert_eq "$TUISH_EVENT" "alt.l" "CSI u: left alt (self-mod stripped)"

reset_state
_tuish_parse_event "K 57449;3"
assert_eq "$TUISH_EVENT" "alt.r" "CSI u: right alt (self-mod stripped)"

reset_state
_tuish_parse_event "K 57444;9"
assert_eq "$TUISH_EVENT" "super.l" "CSI u: left super (self-mod stripped)"

reset_state
_tuish_parse_event "K 57450;9"
assert_eq "$TUISH_EVENT" "super.r" "CSI u: right super (self-mod stripped)"

# Modifier key with OTHER modifier held
reset_state
_tuish_parse_event "K 57442;7"
assert_eq "$TUISH_EVENT" "alt-ctrl.l" "CSI u: alt + left ctrl"

reset_state
_tuish_parse_event "K 57441;6"
assert_eq "$TUISH_EVENT" "ctrl-shift.l" "CSI u: ctrl + left shift"

# Modifier key release
reset_state
_tuish_parse_event "K 57442;5:3"
assert_eq "$TUISH_EVENT" "ctrl.l-rel" "CSI u: left ctrl release"

reset_state
_tuish_parse_event "K 57441;2:2"
assert_eq "$TUISH_EVENT" "shift.l-rep" "CSI u: left shift repeat"

# --- CSI u: lock keys ---
reset_state
_tuish_parse_event "K 57358"
assert_eq "$TUISH_EVENT" "caps-lock" "CSI u: caps lock"

reset_state
_tuish_parse_event "K 57359"
assert_eq "$TUISH_EVENT" "scroll-lock" "CSI u: scroll lock"

reset_state
_tuish_parse_event "K 57360"
assert_eq "$TUISH_EVENT" "num-lock" "CSI u: num lock"

# --- CSI u: system keys ---
reset_state
_tuish_parse_event "K 57361"
assert_eq "$TUISH_EVENT" "prtsc" "CSI u: print screen"

reset_state
_tuish_parse_event "K 57362"
assert_eq "$TUISH_EVENT" "pause" "CSI u: pause"

reset_state
_tuish_parse_event "K 57363"
assert_eq "$TUISH_EVENT" "menu" "CSI u: menu"

# --- CSI u: function keys F13-F35 ---
reset_state
_tuish_parse_event "K 57376"
assert_eq "$TUISH_EVENT" "f13" "CSI u: F13"

reset_state
_tuish_parse_event "K 57387"
assert_eq "$TUISH_EVENT" "f24" "CSI u: F24"

reset_state
_tuish_parse_event "K 57398"
assert_eq "$TUISH_EVENT" "f35" "CSI u: F35"

# --- CSI u: keypad ---
reset_state
_tuish_parse_event "K 57399"
assert_eq "$TUISH_EVENT" "kp-0" "CSI u: keypad 0"

reset_state
_tuish_parse_event "K 57408"
assert_eq "$TUISH_EVENT" "kp-9" "CSI u: keypad 9"

reset_state
_tuish_parse_event "K 57414"
assert_eq "$TUISH_EVENT" "kp-enter" "CSI u: keypad enter"

reset_state
_tuish_parse_event "K 57413"
assert_eq "$TUISH_EVENT" "kp-+" "CSI u: keypad plus"

reset_state
_tuish_parse_event "K 57412"
assert_eq "$TUISH_EVENT" "kp--" "CSI u: keypad minus"

# --- CSI u: navigation keycodes ---
reset_state
_tuish_parse_event "K 57352"
assert_eq "$TUISH_EVENT" "up" "CSI u: up (keycode 57352)"

reset_state
_tuish_parse_event "K 57350"
assert_eq "$TUISH_EVENT" "left" "CSI u: left (keycode 57350)"

reset_state
_tuish_parse_event "K 57348"
assert_eq "$TUISH_EVENT" "ins" "CSI u: insert (keycode 57348)"

reset_state
_tuish_parse_event "K 57349"
assert_eq "$TUISH_EVENT" "del" "CSI u: delete (keycode 57349)"

reset_state
_tuish_parse_event "K 57356"
assert_eq "$TUISH_EVENT" "home" "CSI u: home (keycode 57356)"

reset_state
_tuish_parse_event "K 57357"
assert_eq "$TUISH_EVENT" "end" "CSI u: end (keycode 57357)"

# --- CSI u: media keys ---
reset_state
_tuish_parse_event "K 57430"
assert_eq "$TUISH_EVENT" "media-play-pause" "CSI u: media play/pause"

reset_state
_tuish_parse_event "K 57439"
assert_eq "$TUISH_EVENT" "vol-up" "CSI u: volume up"

reset_state
_tuish_parse_event "K 57440"
assert_eq "$TUISH_EVENT" "vol-mute" "CSI u: volume mute"

# --- CSI u: ISO level keys ---
reset_state
_tuish_parse_event "K 57453"
assert_eq "$TUISH_EVENT" "iso-level3" "CSI u: ISO level 3 shift"

reset_state
_tuish_parse_event "K 57454"
assert_eq "$TUISH_EVENT" "iso-level5" "CSI u: ISO level 5 shift"

# --- Signal events (class S) ---
reset_state
_tuish_parse_event "S resize"
assert_eq "$TUISH_EVENT" "resize" "signal: resize"
assert_eq "$TUISH_EVENT_KIND" "signal" "signal: resize kind"

reset_state
_tuish_parse_event "S cont"
assert_eq "$TUISH_EVENT" "cont" "signal: cont"

# --- Linux console F1-F5: the double-'[' form, ESC [ [ A..E ---------------------
# The bare console has no SS3 F1-F4 and no [15~ here, so ESC [ [ A..E is the only
# way these arrive on tty1 — the target for a shell-driven console distro.
reset_state
_tuish_parse_event "E 91 91 65"
assert_eq "$TUISH_EVENT" "f1" "F1 (linux console, ESC [ [ A)"

reset_state
_tuish_parse_event "E 91 91 66"
assert_eq "$TUISH_EVENT" "f2" "F2 (linux console)"

reset_state
_tuish_parse_event "E 91 91 67"
assert_eq "$TUISH_EVENT" "f3" "F3 (linux console)"

reset_state
_tuish_parse_event "E 91 91 68"
assert_eq "$TUISH_EVENT" "f4" "F4 (linux console)"

reset_state
_tuish_parse_event "E 91 91 69"
assert_eq "$TUISH_EVENT" "f5" "F5 (linux console)"

# The resolve table above only matters if the READER hands it '91 91 65' whole.
# The second '[' is an INTRODUCER, but 0x5B sits inside the CSI final-byte range
# 0x40-0x7E — so without the introducer branch the reader dispatches on it and
# leaks the trailing letter as a separate keystroke. Drive the real loop.
_feed=''
_log=''
_tuish_idle_wait ()
{
	if test -z "$_feed"; then _tuish_quit=yes; return 1; fi
	_tuish_byte="${_feed%"${_feed#?}"}"
	_feed="${_feed#?}"
	return 0
}
_tuish_get_byte ()
{
	test -n "$_feed" || return 1
	_tuish_byte="${_feed%"${_feed#?}"}"
	_feed="${_feed#?}"
	return 0
}
_tuish_peek_byte () { return 1; }
tuish_on_event ()
{
	case "$TUISH_EVENT_KIND" in
		idle) ;;
		*) _log="${_log}${TUISH_EVENT} ";;
	esac
}

_esc=$(printf '\033')
_feed="${_esc}[[A"; _log=''; _tuish_pending_byte=''; _tuish_noinput=no
tuish_run
assert_eq "$_log" "f1 " "reader: ESC [ [ A is ONE f1 — the second '[' never dispatches"

_feed="${_esc}[[E${_esc}[B"; _log=''; _tuish_pending_byte=''; _tuish_noinput=no
tuish_run
assert_eq "$_log" "f5 down " "reader: a console F5 does not disturb the CSI after it"

test_summary
