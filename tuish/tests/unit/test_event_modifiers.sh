#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Resolver-level golden test for modified keys: drives _tuish_parse_event
# "E <seq>" across the FULL cross product of {nav/function keys} ×
# {8 modifier combinations}, locking byte-identical TUISH_EVENT. This pins
# the behavior the single-pass modifier collapse must preserve (the 24
# _tuish_5code/6code helper calls it replaces).

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

printf 'Unit tests: modified-key resolution (full cross product)\n'

# Modifier code → event-name prefix (49 = no modifier → bare name). Code 57 is
# param 9, the xterm meta bit (macOS Cmd), reported as super-. Params 10-16
# (Cmd + other modifiers) are two byte-code tokens, covered separately below.
_mods='49: 50:shift- 51:alt- 52:alt-shift- 53:ctrl- 54:ctrl-shift- 55:ctrl-alt- 56:ctrl-alt-shift- 57:super-'

# 5-code keys: "name base final"  → seq "91 <base> 59 <mod> <final>"
_keys5='up:49:65 down:49:66 right:49:67 left:49:68
f1:49:80 f2:49:81 f3:49:82 f4:49:83
home:49:72 end:49:70 ins:50:126 del:51:126 pgup:53:126 pgdn:54:126'

# 6-code keys: "name base extra"  → seq "91 <base> <extra> 59 <mod> 126"
_keys6='f5:49:53 f6:49:55 f7:49:56 f8:49:57
f9:50:48 f10:50:49 f11:50:51 f12:50:52'

for _k in $_keys5
do
	_name="${_k%%:*}"; _rest="${_k#*:}"
	_base="${_rest%%:*}"; _final="${_rest#*:}"
	for _m in $_mods
	do
		_mod="${_m%%:*}"; _pref="${_m#*:}"
		test "$_pref" = "$_mod" && _pref=''   # bare "49" entry has no prefix
		TUISH_EVENT=''
		_tuish_parse_event "E 91 ${_base} 59 ${_mod} ${_final}"
		assert_eq "$TUISH_EVENT" "${_pref}${_name}" "${_pref}${_name}"
	done
done

for _k in $_keys6
do
	_name="${_k%%:*}"; _rest="${_k#*:}"
	_base="${_rest%%:*}"; _extra="${_rest#*:}"
	for _m in $_mods
	do
		_mod="${_m%%:*}"; _pref="${_m#*:}"
		test "$_pref" = "$_mod" && _pref=''
		TUISH_EVENT=''
		_tuish_parse_event "E 91 ${_base} ${_extra} 59 ${_mod} 126"
		assert_eq "$TUISH_EVENT" "${_pref}${_name}" "${_pref}${_name}"
	done
done

# Two-token modifier params 10-16 (macOS Cmd + other modifiers). The byte
# codes are "49 4X"/"49 5X" ("1""0".."1""6"); each adds super- to the lower bits.
printf '\n--- two-token super combos (params 10-16) ---\n'
# param:prefix — left arrow (base 49, final 68)
_supers='48:shift-super- 49:alt-super- 50:alt-shift-super- 51:ctrl-super- 52:ctrl-shift-super- 53:ctrl-alt-super- 54:ctrl-alt-shift-super-'
for _s in $_supers
do
	_lo="${_s%%:*}"; _pref="${_s#*:}"
	TUISH_EVENT=''
	_tuish_parse_event "E 91 49 59 49 ${_lo} 68"
	assert_eq "$TUISH_EVENT" "${_pref}left" "${_pref}left (two-token mod)"
done

# Two-token super also resolves on a 6-code key (Cmd+Shift+F5)
TUISH_EVENT=''
_tuish_parse_event "E 91 49 53 59 49 48 126"
assert_eq "$TUISH_EVENT" "shift-super-f5" "shift-super-f5 (6-code, param 10)"

# Unknown modifier code → unresolved (falls through to kitty/MISS path).
TUISH_EVENT=''
_tuish_parse_event "E 91 49 59 99 65"
assert_eq "$TUISH_EVENT" "MISS 91 49 59 99 65" "unknown modifier 99 → MISS"

test_summary
