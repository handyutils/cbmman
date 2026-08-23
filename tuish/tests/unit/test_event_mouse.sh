#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for _tuish_parse_event class M (mouse events)

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

printf 'Unit tests: _tuish_parse_event class M (mouse)\n'

# --- Basic clicks ---
reset_state
_tuish_parse_event "M 0 10 20"
assert_eq "$TUISH_EVENT" "lclik" "left click"
assert_eq "$TUISH_EVENT_KIND" "mouse" "left click kind"
assert_eq "$TUISH_MOUSE_X" "10" "left click column"
assert_eq "$TUISH_MOUSE_Y" "20" "left click line"

reset_state
_tuish_parse_event "M 1 5 5"
assert_eq "$TUISH_EVENT" "mclik" "middle click"

reset_state
_tuish_parse_event "M 2 15 30"
assert_eq "$TUISH_EVENT" "rclik" "right click"

# --- Release after hold ---
reset_state
_tuish_held='ldrop'
_tuish_parse_event "M 3 10 20"
assert_eq "$TUISH_EVENT" "ldrop" "left release (drop after hold)"
assert_eq "$_tuish_held" "" "held cleared after drop"

reset_state
_tuish_held='mdrop'
_tuish_parse_event "M 3 10 20"
assert_eq "$TUISH_EVENT" "mdrop" "middle release"

reset_state
_tuish_held='rdrop'
_tuish_parse_event "M 3 10 20"
assert_eq "$TUISH_EVENT" "rdrop" "right release"

# --- Release with no hold (code 3, no _tuish_held) ---
reset_state
_tuish_parse_event "M 3 10 20"
assert_eq "$TUISH_EVENT" "" "release with no held state"

# --- Hold events ---
reset_state
_tuish_parse_event "M 32 10 20"
assert_eq "$TUISH_EVENT" "lhold" "left hold"
assert_eq "$_tuish_held" "ldrop" "held set to ldrop"

reset_state
_tuish_parse_event "M 33 10 20"
assert_eq "$TUISH_EVENT" "mhold" "middle hold"
assert_eq "$_tuish_held" "mdrop" "held set to mdrop"

reset_state
_tuish_parse_event "M 34 10 20"
assert_eq "$TUISH_EVENT" "rhold" "right hold"
assert_eq "$_tuish_held" "rdrop" "held set to rdrop"

# --- Move ---
reset_state
_tuish_parse_event "M 35 50 25"
assert_eq "$TUISH_EVENT" "move" "mouse move"
assert_eq "$_tuish_held" "" "held cleared on move"

# --- Drop (click while held) ---
reset_state
_tuish_held='ldrop'
_tuish_parse_event "M 0 10 20"
assert_eq "$TUISH_EVENT" "drop" "drop on click while held"

# --- Scroll ---
reset_state
_tuish_parse_event "M 64 1 1"
assert_eq "$TUISH_EVENT" "whup" "scroll up"

reset_state
_tuish_parse_event "M 65 1 1"
assert_eq "$TUISH_EVENT" "wdown" "scroll down"

# --- Ctrl+click ---
reset_state
_tuish_parse_event "M 16 10 20"
assert_eq "$TUISH_EVENT" "ctrl-lclik" "ctrl left click (code 16)"

reset_state
_tuish_parse_event "M 96 10 20"
assert_eq "$TUISH_EVENT" "ctrl-lclik" "ctrl left click (code 96)"

reset_state
_tuish_parse_event "M 17 10 20"
assert_eq "$TUISH_EVENT" "ctrl-mclik" "ctrl middle click (code 17)"

reset_state
_tuish_parse_event "M 97 10 20"
assert_eq "$TUISH_EVENT" "ctrl-mclik" "ctrl middle click (code 97)"

reset_state
_tuish_parse_event "M 18 10 20"
assert_eq "$TUISH_EVENT" "ctrl-rclik" "ctrl right click (code 18)"

reset_state
_tuish_parse_event "M 98 10 20"
assert_eq "$TUISH_EVENT" "ctrl-rclik" "ctrl right click (code 98)"

# --- Ctrl+scroll ---
reset_state
_tuish_parse_event "M 80 1 1"
assert_eq "$TUISH_EVENT" "ctrl-whup" "ctrl scroll up"

reset_state
_tuish_parse_event "M 81 1 1"
assert_eq "$TUISH_EVENT" "ctrl-wdown" "ctrl scroll down"

# --- Alt+click ---
reset_state
_tuish_parse_event "M 8 10 20"
assert_eq "$TUISH_EVENT" "alt-lclik" "alt left click"

reset_state
_tuish_parse_event "M 9 10 20"
assert_eq "$TUISH_EVENT" "alt-mclik" "alt middle click"

# --- Alt+scroll ---
reset_state
_tuish_parse_event "M 72 1 1"
assert_eq "$TUISH_EVENT" "alt-whup" "alt scroll up"

reset_state
_tuish_parse_event "M 73 1 1"
assert_eq "$TUISH_EVENT" "alt-wdown" "alt scroll down"

# --- Alt+hold ---
reset_state
_tuish_parse_event "M 40 10 20"
assert_eq "$TUISH_EVENT" "alt-lhold" "alt left hold"

reset_state
_tuish_parse_event "M 41 10 20"
assert_eq "$TUISH_EVENT" "alt-mhold" "alt middle hold"

reset_state
_tuish_parse_event "M 42 10 20"
assert_eq "$TUISH_EVENT" "alt-rhold" "alt right hold"

reset_state
_tuish_parse_event "M 43 10 20"
assert_eq "$TUISH_EVENT" "alt-move" "alt move"

# --- Ctrl+hold ---
reset_state
_tuish_parse_event "M 48 10 20"
assert_eq "$TUISH_EVENT" "ctrl-lhold" "ctrl left hold"

reset_state
_tuish_parse_event "M 49 10 20"
assert_eq "$TUISH_EVENT" "ctrl-mhold" "ctrl middle hold"

reset_state
_tuish_parse_event "M 50 10 20"
assert_eq "$TUISH_EVENT" "ctrl-rhold" "ctrl right hold"

reset_state
_tuish_parse_event "M 51 10 20"
assert_eq "$TUISH_EVENT" "ctrl-move" "ctrl move"

# --- Alt+right click (code 10, fixed from bug) ---
reset_state
_tuish_parse_event "M 10 10 20"
assert_eq "$TUISH_EVENT" "alt-rclik" "alt right click"

# --- Shift+click ---
reset_state
_tuish_parse_event "M 4 10 20"
assert_eq "$TUISH_EVENT" "shift-lclik" "shift left click"

reset_state
_tuish_parse_event "M 5 10 20"
assert_eq "$TUISH_EVENT" "shift-mclik" "shift middle click"

reset_state
_tuish_parse_event "M 6 10 20"
assert_eq "$TUISH_EVENT" "shift-rclik" "shift right click"

# --- Shift+scroll ---
reset_state
_tuish_parse_event "M 68 1 1"
assert_eq "$TUISH_EVENT" "shift-whup" "shift scroll up"

reset_state
_tuish_parse_event "M 69 1 1"
assert_eq "$TUISH_EVENT" "shift-wdown" "shift scroll down"

# --- Shift+hold ---
reset_state
_tuish_parse_event "M 36 10 20"
assert_eq "$TUISH_EVENT" "shift-lhold" "shift left hold"

reset_state
_tuish_parse_event "M 37 10 20"
assert_eq "$TUISH_EVENT" "shift-mhold" "shift middle hold"

reset_state
_tuish_parse_event "M 38 10 20"
assert_eq "$TUISH_EVENT" "shift-rhold" "shift right hold"

reset_state
_tuish_parse_event "M 39 10 20"
assert_eq "$TUISH_EVENT" "shift-move" "shift move"

# --- Ctrl+Alt+click ---
reset_state
_tuish_parse_event "M 24 10 20"
assert_eq "$TUISH_EVENT" "ctrl-alt-lclik" "ctrl-alt left click"

reset_state
_tuish_parse_event "M 25 10 20"
assert_eq "$TUISH_EVENT" "ctrl-alt-mclik" "ctrl-alt middle click"

reset_state
_tuish_parse_event "M 26 10 20"
assert_eq "$TUISH_EVENT" "ctrl-alt-rclik" "ctrl-alt right click"

# --- Ctrl+Alt+scroll ---
reset_state
_tuish_parse_event "M 88 1 1"
assert_eq "$TUISH_EVENT" "ctrl-alt-whup" "ctrl-alt scroll up"

reset_state
_tuish_parse_event "M 89 1 1"
assert_eq "$TUISH_EVENT" "ctrl-alt-wdown" "ctrl-alt scroll down"

# --- Ctrl+Alt+hold ---
reset_state
_tuish_parse_event "M 56 10 20"
assert_eq "$TUISH_EVENT" "ctrl-alt-lhold" "ctrl-alt left hold"

reset_state
_tuish_parse_event "M 57 10 20"
assert_eq "$TUISH_EVENT" "ctrl-alt-mhold" "ctrl-alt middle hold"

reset_state
_tuish_parse_event "M 58 10 20"
assert_eq "$TUISH_EVENT" "ctrl-alt-rhold" "ctrl-alt right hold"

reset_state
_tuish_parse_event "M 59 10 20"
assert_eq "$TUISH_EVENT" "ctrl-alt-move" "ctrl-alt move"

# --- TUISH_EVENT and coordinate variables ---
reset_state
_tuish_parse_event "M 0 42 17"
assert_eq "$TUISH_EVENT" "lclik" "TUISH_EVENT contains event name"
assert_eq "$TUISH_MOUSE_X" "42" "TUISH_MOUSE_X has column"
assert_eq "$TUISH_MOUSE_Y" "17" "TUISH_MOUSE_Y has row"

# --- SGR release (class 'm'): quick click → absorbed when not detailed ---
reset_state
_tuish_parse_event "m 0 10 20"
assert_eq "$TUISH_EVENT" "" "SGR release absorbed (no drag, no detailed)"

# --- SGR release after drag → fires drop ---
reset_state
_tuish_held='ldrop'
_tuish_parse_event "m 0 10 20"
assert_eq "$TUISH_EVENT" "ldrop" "SGR release fires ldrop after drag"
assert_eq "$_tuish_held" "" "SGR release clears held"

# --- SGR release with modifiers after drag ---
reset_state
_tuish_held='ldrop'
_tuish_parse_event "m 16 10 20"
assert_eq "$TUISH_EVENT" "ctrl-ldrop" "SGR ctrl-release fires ctrl-ldrop"

# --- SGR release in detailed mode → fires even without drag ---
reset_state
_tuish_detailed=1
_tuish_parse_event "m 0 10 20"
assert_eq "$TUISH_EVENT" "ldrop" "SGR release fires in detailed mode"
_tuish_detailed=0

reset_state
_tuish_detailed=1
_tuish_parse_event "m 1 10 20"
assert_eq "$TUISH_EVENT" "mdrop" "SGR middle release in detailed mode"
_tuish_detailed=0

reset_state
_tuish_detailed=1
_tuish_parse_event "m 2 10 20"
assert_eq "$TUISH_EVENT" "rdrop" "SGR right release in detailed mode"
_tuish_detailed=0

# --- SGR release coordinates ---
reset_state
_tuish_held='ldrop'
_tuish_parse_event "m 0 25 12"
assert_eq "$TUISH_MOUSE_X" "25" "SGR release TUISH_MOUSE_X"
assert_eq "$TUISH_MOUSE_Y" "12" "SGR release TUISH_MOUSE_Y"

test_summary
