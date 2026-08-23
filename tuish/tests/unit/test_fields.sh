#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for APP field sets (tuish_ctx_declare / tuish_ctx_fields).
#
# tuish_ctx_register is the framework tier: one global list, marshalled for every context.
# These are the second tier — state that belongs to an INSTANCE of an app, so that the same
# app can be mounted twice and the two copies do not share a cursor.
#
# The case that matters, and the reason the tier exists: mount two editors side by side,
# type in one, and the other must not move. Before this, examples/editor.sh held _cur_row
# and friends as plain globals and the two instances shared every one of them.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/ord.sh"
. "$TESTS_DIR/../src/tui.sh"
. "$TESTS_DIR/../src/term.sh"
. "$TESTS_DIR/../src/event.sh"
. "$TESTS_DIR/../src/hid.sh"
. "$TESTS_DIR/../src/viewport.sh"
. "$TESTS_DIR/../src/str.sh"
. "$TESTS_DIR/../src/keybind.sh"


# Exercise the SHIPPED configuration. tuish_fnfix normally fires from tuish_init, which unit
# tests deliberately never call (they stub the device) — so without this, every suite here
# would validate the framework with its ksh `local` still leaking, i.e. not the library that
# actually runs. It is a no-op on every shell whose `local` already works.
command -v tuish_fnfix >/dev/null 2>&1 && tuish_fnfix

printf 'Unit tests: app field sets (per-instance state)\n'

TUISH_LINES=30
TUISH_COLUMNS=100

# A toy app, written the way editor.sh is: state in plain globals, declared as a set at
# source time so every instance gets its own copy.
_w_row=1
_w_col=1
_w_label='untitled'

tuish_ctx_declare _w  _w_row _w_col _w_label

tuish_ctx_create
TUISH_CTX_ROOT=$TUISH_CTX
tuish_ctx_activate "$TUISH_CTX_ROOT"

# ─── Declaration captures the defaults, not whatever is live ─────────────────────

assert_eq "$_tuish_ctxd__w" "_w_row _w_col _w_label" "declare: the set remembers its fields"
assert_eq "$_tuish_ctxd_dflt__w_row"   "1"         "declare: defaults captured at source time"
assert_eq "$_tuish_ctxd_dflt__w_label" "untitled"  "declare: ... including strings"

# ─── Two instances of the SAME app ───────────────────────────────────────────────

tuish_ctx_create_region 1 1 20 10
_one=$TUISH_CTX
tuish_ctx_fields _w
_w_row=7; _w_col=3; _w_label='left'
tuish_ctx_activate "$TUISH_CTX_ROOT"

tuish_ctx_create_region 1 40 20 10
_two=$TUISH_CTX
tuish_ctx_fields _w

# THE BUG THIS FIXES. Without a per-instance tier, the globals still hold instance one's
# values here and the second widget opens on instance one's cursor. Attaching resets to the
# DECLARED defaults — which is why declaration has to happen at source time: capture the
# default at attach time and this assertion reads 7.
assert_eq "$_w_row"   "1"          "two instances: the second opens at its DEFAULT row"
assert_eq "$_w_col"   "1"          "two instances: ... and column"
assert_eq "$_w_label" "untitled"   "two instances: ... and label — not the first one's"

_w_row=2; _w_col=9; _w_label='right'

# Now switch between them and confirm neither sees the other's state.
tuish_ctx_activate "$_one"
assert_eq "$_w_row"   "7"      "instance one: keeps its own row across a switch"
assert_eq "$_w_col"   "3"      "instance one: keeps its own column"
assert_eq "$_w_label" "left"   "instance one: keeps its own label"

tuish_ctx_activate "$_two"
assert_eq "$_w_row"   "2"      "instance two: keeps its own row"
assert_eq "$_w_col"   "9"      "instance two: keeps its own column"
assert_eq "$_w_label" "right"  "instance two: keeps its own label"

# Type into one; the other must not move. This is the acceptance criterion.
_w_row=$(( _w_row + 1 ))
tuish_ctx_activate "$_one"
assert_eq "$_w_row" "7" "typing in instance two does NOT move instance one's cursor"
tuish_ctx_activate "$_two"
assert_eq "$_w_row" "3" "... and instance two's cursor did move"

# ─── Values survive marshalling intact ───────────────────────────────────────────
# The frames are eval'd, so anything the shell might re-interpret has to round-trip.

tuish_ctx_activate "$_one"
_w_label='a b  "c" $d *e* \f'"'"'g'
tuish_ctx_activate "$_two"
tuish_ctx_activate "$_one"
assert_eq "$_w_label" 'a b  "c" $d *e* \f'"'"'g' "marshal: spaces, quotes, \$, globs round-trip"

# ─── A context WITHOUT the set is unaffected ─────────────────────────────────────
# The root never attached _w. Switching through it must not corrupt either instance, and
# the root must not pay to marshal fields it does not own.

tuish_ctx_activate "$TUISH_CTX_ROOT"
_tuish_ctx_extras "$TUISH_CTX_ROOT"
assert_eq "$_tuish_ctx_extra" "" "the root marshals no app fields — it attached none"

tuish_ctx_activate "$_two"
assert_eq "$_w_row" "3" "instance two survives a round-trip through the root"

# ─── Attaching twice is idempotent (a remount must not double the list) ──────────

tuish_ctx_fields _w
_tuish_ctx_extras "$_two"
assert_eq "$_tuish_ctx_extra" "_w_row _w_col _w_label" \
	"re-attaching the same set does not duplicate its fields"
assert_eq "$_w_row" "1" "re-attaching resets to defaults (a fresh instance in a reused ctx)"

# ─── Destroy frees the instance state ────────────────────────────────────────────

tuish_ctx_activate "$TUISH_CTX_ROOT"
tuish_ctx_destroy "$_one"
eval "_leaked=\${_tuish_ctx_${_one}__w_row:-GONE}"
assert_eq "$_leaked" "GONE" "destroy: an unmounted app's fields do not outlive it"
eval "_leaked=\${_tuish_ctxf_${_one}:-GONE}"
assert_eq "$_leaked" "GONE" "destroy: ... nor the record of which sets it had"

# ─── An undeclared set FAILS. It is not a no-op ──────────────────────────────────
# This used to return 0 and quietly attach nothing, which is the worst possible answer: a
# typo'd set name means the fields never marshal, and two mounted instances go straight back
# to sharing their state — the exact bug this tier exists to fix, with nothing to show for
# it. Under the `set -euf` every app here runs with, returning 1 makes it a startup failure.

if tuish_ctx_fields _nosuchset
then assert_eq "0" "1" "attaching an UNKNOWN set fails loudly"
else assert_eq "1" "1" "attaching an UNKNOWN set fails loudly"
fi

# Declared-but-active-context-missing is the same answer, for the same reason: the app
# called us before tuish_init.
_ctx_save=$_tuish_ctx_active
_tuish_ctx_active=''
if tuish_ctx_fields _w
then assert_eq "0" "1" "attaching before tuish_init fails loudly"
else assert_eq "1" "1" "attaching before tuish_init fails loudly"
fi
_tuish_ctx_active=$_ctx_save

test_summary
