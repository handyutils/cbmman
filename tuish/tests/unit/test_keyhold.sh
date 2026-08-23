#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for held-key inference: tuish_key_track / tuish_key_down / tuish_key_ttl,
# and the TUISH_KEY_REPEAT press/repeat split.
#
# A plain VT reports no key release, so "down" is inferred from recency: an event refills
# the key's window, an idle tick drains it by TUISH_TICK_US, and anything left means down.
# These drive _tuish_parse_event, because the stamp and decay hooks live on that path and
# testing the helpers directly would skip the thing that wires them to real events.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/ord.sh"
. "$TESTS_DIR/../src/tui.sh"
. "$TESTS_DIR/../src/term.sh"
. "$TESTS_DIR/../src/event.sh"
. "$TESTS_DIR/../src/hid.sh"
. "$TESTS_DIR/../src/keybind.sh"


# Exercise the SHIPPED configuration. tuish_fnfix normally fires from tuish_init, which unit
# tests deliberately never call (they stub the device) — so without this, every suite here
# would validate the framework with its ksh `local` still leaking, i.e. not the library that
# actually runs. It is a no-op on every shell whose `local` already works.
command -v tuish_fnfix >/dev/null 2>&1 && tuish_fnfix

_tuish_out () { :; }
tuish_on_event () { :; }

printf 'Unit tests: held-key inference (tuish_key_track / _down / TUISH_KEY_REPEAT)\n'

tuish_ctx_create; _root=$TUISH_CTX
tuish_ctx_activate "$_root"
# AFTER activating: TUISH_TICK_US is a context field, so a create/activate reseats it to the
# registered default. Set before, and the decay below silently runs at 260ms a tick and every
# window dies on the first one.
TUISH_TICK_US=20000        # a 20ms tick, as the platformer runs

_down () { tuish_key_down "$@" && echo yes || echo no; }

# --- Nothing is down until something arrives ------------------------------------
tuish_key_track 'char a' 'char d' 'left'
assert_eq "$(_down 'char a')" "no" "fresh: a tracked key starts up"

# --- A key event puts it down ---------------------------------------------------
_tuish_parse_event "C a"
assert_eq "$(_down 'char a')" "yes" "press: the key is down"
assert_eq "$(_down 'char d')" "no"  "press: only the key that arrived is down"

# --- The press/repeat split -----------------------------------------------------
# The whole point: a VT cannot say, so the window says for it. An empty slot means this is
# a fresh press; an open one means the key never came up.
tuish_key_track 'char a'
_tuish_parse_event "C a"
assert_eq "$TUISH_KEY_REPEAT" "0" "repeat: the first event on an empty slot is a PRESS"
_tuish_parse_event "C a"
assert_eq "$TUISH_KEY_REPEAT" "1" "repeat: the next one, inside the window, is a REPEAT"
_tuish_parse_event "C a"
assert_eq "$TUISH_KEY_REPEAT" "1" "repeat: and stays one while the key is held"

# An untracked key never reports a repeat, so an app cannot be fooled by a stale 1.
_tuish_parse_event "C z"
assert_eq "$TUISH_KEY_REPEAT" "0" "repeat: an untracked key reports 0"

# --- The window drains on the tick, not on the wall -----------------------------
# 150ms of window against a 20ms tick is 7.5 ticks, so it survives 7 and dies on the 8th.
# That the count is exact is what makes a tap a tap: the window has to outlast the ~33ms
# autorepeat gap and fall short of the ~500ms initial delay.
tuish_key_track 'char a'
tuish_key_ttl 0.15
_tuish_parse_event "C a"
_i=0
while test $_i -lt 7
do _tuish_parse_event "F"; _i=$((_i + 1)); done
assert_eq "$(_down 'char a')" "yes" "decay: still down after 7 of 7.5 ticks"
_tuish_parse_event "F"
assert_eq "$(_down 'char a')" "no"  "decay: released on the 8th — ceil(ttl/tick)"

# --- After the window lapses, the next event is a PRESS again -------------------
# This is what keeps a tap exact across the OS's initial repeat delay: the delay is longer
# than the window, so the first autorepeat reads as a press, not as a continuing hold.
_tuish_parse_event "C a"
assert_eq "$TUISH_KEY_REPEAT" "0" "repeat: an event after the window lapsed is a fresh press"

# --- A repeat refills the window ------------------------------------------------
# Without this a held key would decay out from under itself mid-hold.
tuish_key_track 'char a'
_tuish_parse_event "C a"
_tuish_parse_event "F"; _tuish_parse_event "F"; _tuish_parse_event "F"
_tuish_parse_event "C a"          # a repeat arrives, as autorepeat would deliver it
_i=0
while test $_i -lt 7
do _tuish_parse_event "F"; _i=$((_i + 1)); done
assert_eq "$(_down 'char a')" "yes" "refill: a repeat restarts the window from full"

# --- tuish_key_down ORs its arguments -------------------------------------------
# Aliasing is the normal case: `left` and `char a` are one action and deserve one question.
tuish_key_track 'char a' 'left'
_tuish_parse_event "C a"
assert_eq "$(_down 'left' 'char a')" "yes" "down: ORs several keys"
assert_eq "$(_down 'left')" "no" "down: and does not lie about the ones that are up"

# --- An untracked key is never down ---------------------------------------------
tuish_key_track 'char a'
_tuish_parse_event "C z"
assert_eq "$(_down 'char z')" "no" "down: an untracked key is never down, even when pressed"

# --- track REPLACES the set -----------------------------------------------------
tuish_key_track 'char a'
_tuish_parse_event "C a"
assert_eq "$(_down 'char a')" "yes" "track: sanity before re-declaring"
tuish_key_track 'char d'
assert_eq "$(_down 'char a')" "no" "track: re-declaring replaces the set, it does not append"

# --- Event names with spaces and specials survive the round trip -----------------
# The sanitizer is what makes `char a` a variable-safe token; the set is space-joined and
# colon-split, so a name that produced either byte would corrupt the whole string.
tuish_key_track 'char a' 'ctrl-alt-shift-up' 'shift.l' 'char *'
_tuish_parse_event "C a"
assert_eq "$(_down 'char a')" "yes" "sanitize: a name with a space round-trips"
_r=ok
for _tok in $_tuish_key_set
do
	# Exactly one colon per token, or the ${p%:*} split in the decay picks the wrong one.
	case "${_tok%:*}" in *:*) _r=broken;; esac
	# And exactly one token per tracked key: a name that kept its space would split in two.
	case "${_tok}" in *:*) ;; *) _r=broken;; esac
done
assert_eq "$_r" "ok" "sanitize: no key name smuggles a colon or a space into the set"
_n=0
for _tok in $_tuish_key_set; do _n=$((_n + 1)); done
assert_eq "$_n" "4" "sanitize: four tracked names stay four tokens"

# --- Idle decay is a no-op when nothing is tracked -------------------------------
# The guard is one glob and it has to answer BOTH "nothing tracked" and "nothing down".
tuish_key_track
assert_eq "$_tuish_key_set" "" "guard: tracking nothing leaves the set empty"
_tuish_parse_event "F"
assert_eq "$_tuish_key_set" "" "guard: an idle with nothing tracked stays a no-op"

# --- Hold state is PER-CONTEXT ---------------------------------------------------
# The twins.sh property: two mounts of one app must not share a keyboard. This is the
# assertion that would fail if the set were device-global for convenience.
tuish_ctx_create; _child=$TUISH_CTX
tuish_ctx_activate "$_root"
tuish_key_track 'char a'
_tuish_parse_event "C a"
assert_eq "$(_down 'char a')" "yes" "ctx: down in the root"

tuish_ctx_activate "$_child"
tuish_key_track 'char a'
assert_eq "$(_down 'char a')" "no" "ctx: the same key is NOT down in a sibling context"
_tuish_parse_event "C a"
assert_eq "$(_down 'char a')" "yes" "ctx: the sibling can hold it independently"

tuish_ctx_activate "$_root"
assert_eq "$(_down 'char a')" "yes" "ctx: the root's hold survived the sibling's"

# Each context keeps its own window, too — a game and a widget want different ones.
tuish_key_ttl 0.15
tuish_ctx_activate "$_child"
tuish_key_ttl 0.05
assert_eq "$_tuish_key_ttl_us" "50000" "ctx: the child's window is its own"
tuish_ctx_activate "$_root"
assert_eq "$_tuish_key_ttl_us" "150000" "ctx: and the root's is untouched"

# --- The decay unit is the CONTEXT's tick ----------------------------------------
# A hosted child is ticked at its own negotiated rate, so a coarser tick must drain the
# window in proportionally fewer ticks. This is why the feature cannot live in an app: the
# app does not know its own rate without asking whether it is hosted.
tuish_ctx_activate "$_child"
TUISH_TICK_US=50000
tuish_key_track 'char a'
tuish_key_ttl 0.15
_tuish_parse_event "C a"
_tuish_parse_event "F"; _tuish_parse_event "F"
assert_eq "$(_down 'char a')" "yes" "tick: 150ms outlives 2 ticks of 50ms"
_tuish_parse_event "F"
assert_eq "$(_down 'char a')" "no" "tick: and dies on the 3rd — decay follows the context's tick"
TUISH_TICK_US=20000
tuish_ctx_activate "$_root"

# --- Kitty sharpens it, and is never required ------------------------------------
# With detailed mode on the terminal reports the truth: a release must empty the window at
# once rather than waiting it out, and a repeat must land on the slot the press created.
# hid.sh spells a press `char a` but its repeat `a-rep` — believe the event, not the spelling.
_tuish_detailed=1
tuish_key_track 'char a'
tuish_key_ttl 0.15
_tuish_parse_event "C a"
assert_eq "$(_down 'char a')" "yes" "kitty: pressed"

TUISH_EVENT='a-rep'; TUISH_EVENT_KIND='key'; _tuish_key_stamp
assert_eq "$TUISH_KEY_REPEAT" "1" "kitty: -rep is a repeat, and finds the press's slot"
assert_eq "$(_down 'char a')" "yes" "kitty: -rep refills the window"

TUISH_EVENT='a-rel'; TUISH_EVENT_KIND='key'; _tuish_key_stamp
assert_eq "$(_down 'char a')" "no" "kitty: -rel releases at once — no waiting out the window"

# A modified key keeps its own name: ctrl-a-rep is ctrl-a, and must NOT become `char ctrl-a`.
tuish_key_track 'ctrl-a'
TUISH_EVENT='ctrl-a'; TUISH_EVENT_KIND='key'; _tuish_key_stamp
assert_eq "$(_down 'ctrl-a')" "yes" "kitty: a modified key presses"
TUISH_EVENT='ctrl-a-rep'; TUISH_EVENT_KIND='key'; _tuish_key_stamp
assert_eq "$TUISH_KEY_REPEAT" "1" 'kitty: ctrl-a-rep repeats ctrl-a — the char prefix is not re-added'
_tuish_detailed=0

test_summary
