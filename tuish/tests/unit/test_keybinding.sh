#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for tuish_bind / tuish_unbind / tuish_dispatch

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/ord.sh"
. "$TESTS_DIR/../src/tui.sh"
. "$TESTS_DIR/../src/keybind.sh"


# Exercise the SHIPPED configuration. tuish_fnfix normally fires from tuish_init, which unit
# tests deliberately never call (they stub the device) — so without this, every suite here
# would validate the framework with its ksh `local` still leaking, i.e. not the library that
# actually runs. It is a no-op on every shell whose `local` already works.
command -v tuish_fnfix >/dev/null 2>&1 && tuish_fnfix

_tuish_write () { :; }
tuish_on_event () { :; }

printf 'Unit tests: key bindings\n'

# --- Basic bind and dispatch ---
_action_result=''
_test_action () { _action_result='fired'; }

tuish_bind 'ctrl-w' '_test_action'
TUISH_EVENT='ctrl-w'
tuish_dispatch
assert_eq "$_action_result" "fired" "bind: basic dispatch"

# --- Dispatch returns 1 on no match ---
TUISH_EVENT='ctrl-q'
tuish_dispatch && _dr=0 || _dr=$?
assert_eq "$_dr" "1" "bind: no match returns 1"

# --- Multiple bindings ---
_r1='' _r2=''
tuish_bind 'up' '_r1=up'
tuish_bind 'down' '_r2=down'

TUISH_EVENT='up'
tuish_dispatch
assert_eq "$_r1" "up" "bind: multiple - up"

TUISH_EVENT='down'
tuish_dispatch
assert_eq "$_r2" "down" "bind: multiple - down"

# --- Unbind ---
tuish_unbind 'up'
TUISH_EVENT='up'
tuish_dispatch && _dr=0 || _dr=$?
assert_eq "$_dr" "1" "unbind: removed binding"

# down should still work
_r2=''
TUISH_EVENT='down'
tuish_dispatch
assert_eq "$_r2" "down" "unbind: other binding preserved"

# --- Glob pattern: "char *" ---
_char_result=''
tuish_bind 'char *' '_char_result=$TUISH_EVENT'

TUISH_EVENT='char a'
tuish_dispatch
assert_eq "$_char_result" "char a" "bind: char * matches char a"

TUISH_EVENT='char z'
tuish_dispatch
assert_eq "$_char_result" "char z" "bind: char * matches char z"

# --- Exact match takes priority over glob ---
_exact=''
tuish_bind 'char x' '_exact=exact'

TUISH_EVENT='char x'
tuish_dispatch
assert_eq "$_exact" "exact" "bind: exact match over glob"

# char a still hits the glob
_char_result=''
TUISH_EVENT='char a'
tuish_dispatch
assert_eq "$_char_result" "char a" "bind: glob still works for non-exact"

# --- Wildcard catch-all "*" ---
_catch=''
tuish_bind '*' '_catch=$TUISH_EVENT'

TUISH_EVENT='f5'
tuish_dispatch
assert_eq "$_catch" "f5" "bind: catch-all *"

# Exact match still takes priority
_exact=''
TUISH_EVENT='char x'
tuish_dispatch
assert_eq "$_exact" "exact" "bind: exact over catch-all"

# --- Events with dots (modifier keys) ---
_mod=''
tuish_bind 'shift.l' '_mod=shift-left'
TUISH_EVENT='shift.l'
tuish_dispatch
assert_eq "$_mod" "shift-left" "bind: event with dot"

# --- Events with dashes (modifiers) ---
_ctrl_a=''
tuish_bind 'ctrl-alt-a' '_ctrl_a=yes'
TUISH_EVENT='ctrl-alt-a'
tuish_dispatch
assert_eq "$_ctrl_a" "yes" "bind: event with dashes"

# --- Rebind (overwrite) ---
_over=''
tuish_bind 'enter' '_over=first'
tuish_bind 'enter' '_over=second'
TUISH_EVENT='enter'
tuish_dispatch
assert_eq "$_over" "second" "bind: rebind overwrites"

# --- Injective encoding: an event must not collide with another event whose
# literal name resembles the first's escaped form. (Old scheme: 'a-b' -> a_Db
# collided with a literal 'a_Db'.)
_inj1='' _inj2=''
tuish_bind 'a-b' '_inj1=dash'
tuish_bind 'a_45_b' '_inj2=literal'
TUISH_EVENT='a-b'
tuish_dispatch
assert_eq "$_inj1" "dash" "inject: a-b fires its own action"
assert_eq "$_inj2" "" "inject: a-b does not trigger literal a_45_b"
TUISH_EVENT='a_45_b'
tuish_dispatch
assert_eq "$_inj2" "literal" "inject: literal a_45_b fires its own action"

test_summary
