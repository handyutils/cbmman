#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for _tuish_parse_event class C (character events)

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

printf 'Unit tests: _tuish_parse_event class C (character)\n'

# --- Printable ASCII ---
reset_state
_tuish_parse_event "C a"
assert_eq "$TUISH_EVENT" "char a" "character a"
assert_eq "$TUISH_EVENT_KIND" "key" "character a kind"

reset_state
_tuish_parse_event "C z"
assert_eq "$TUISH_EVENT" "char z" "character z"

reset_state
_tuish_parse_event "C A"
assert_eq "$TUISH_EVENT" "char A" "character A"

reset_state
_tuish_parse_event "C 0"
assert_eq "$TUISH_EVENT" "char 0" "character 0"

reset_state
_tuish_parse_event "C !"
assert_eq "$TUISH_EVENT" "char !" "character !"

reset_state
_tuish_parse_event "C @"
assert_eq "$TUISH_EVENT" "char @" "character @"

# --- Space (empty second argument) ---
reset_state
_tuish_parse_event "C"
assert_eq "$TUISH_EVENT" "space" "space character"

# --- Backslash ---
reset_state
_tuish_parse_event 'C \'
assert_eq "$TUISH_EVENT" 'char bslash' "backslash character"

# --- Various punctuation ---
reset_state
_tuish_parse_event "C /"
assert_eq "$TUISH_EVENT" "char /" "character /"

reset_state
_tuish_parse_event "C ."
assert_eq "$TUISH_EVENT" "char ." "character ."

reset_state
_tuish_parse_event "C -"
assert_eq "$TUISH_EVENT" "char -" "character -"

reset_state
_tuish_parse_event "C _"
assert_eq "$TUISH_EVENT" "char _" "character _"

test_summary
