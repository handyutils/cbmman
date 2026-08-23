#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for the line buffer (src/buf.sh)

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/buf.sh"


# Exercise the SHIPPED configuration. tuish_fnfix normally fires from tuish_init, which unit
# tests deliberately never call (they stub the device) — so without this, every suite here
# would validate the framework with its ksh `local` still leaking, i.e. not the library that
# actually runs. It is a no-op on every shell whose `local` already works.
command -v tuish_fnfix >/dev/null 2>&1 && tuish_fnfix

printf 'Unit tests: line buffer\n'

# --- init: one empty line, count 1 ---
tuish_buf_init _
assert_eq "$TUISH_BUF_COUNT" "1" "init: count is 1 after init"
tuish_buf_get _ 1
assert_eq "$TUISH_BLINE" "" "init: line 1 is empty"

# --- append + count register ---
tuish_buf_set _ 1 'first'
tuish_buf_append _ 'second'
assert_eq "$TUISH_BUF_COUNT" "2" "append: count register updated"
tuish_buf_append _ 'third'
assert_eq "$TUISH_BUF_COUNT" "3" "append: count register updated again"

# --- get / set ---
tuish_buf_get _ 1
assert_eq "$TUISH_BLINE" "first" "get: line 1"
tuish_buf_get _ 2
assert_eq "$TUISH_BLINE" "second" "get: line 2"
tuish_buf_get _ 3
assert_eq "$TUISH_BLINE" "third" "get: line 3"
tuish_buf_set _ 2 'SECOND'
tuish_buf_get _ 2
assert_eq "$TUISH_BLINE" "SECOND" "set: overwrite line 2"

# --- count query reloads the register ---
TUISH_BUF_COUNT=999
tuish_buf_count _
assert_eq "$TUISH_BUF_COUNT" "3" "count: reloads from storage"

# --- insert_at: shift down ---
# buffer: first / SECOND / third  -> insert 'X' at 2
tuish_buf_insert_at _ 2 'X'
assert_eq "$TUISH_BUF_COUNT" "4" "insert: count grew"
tuish_buf_get _ 1; assert_eq "$TUISH_BLINE" "first"  "insert: line 1 unchanged"
tuish_buf_get _ 2; assert_eq "$TUISH_BLINE" "X"      "insert: new line at 2"
tuish_buf_get _ 3; assert_eq "$TUISH_BLINE" "SECOND" "insert: old 2 shifted to 3"
tuish_buf_get _ 4; assert_eq "$TUISH_BLINE" "third"  "insert: old 3 shifted to 4"

# --- delete_at: shift up ---
# buffer: first / X / SECOND / third -> delete 2
tuish_buf_delete_at _ 2
assert_eq "$TUISH_BUF_COUNT" "3" "delete: count shrank"
tuish_buf_get _ 1; assert_eq "$TUISH_BLINE" "first"  "delete: line 1 unchanged"
tuish_buf_get _ 2; assert_eq "$TUISH_BLINE" "SECOND" "delete: line 3 shifted to 2"
tuish_buf_get _ 3; assert_eq "$TUISH_BLINE" "third"  "delete: line 4 shifted to 3"

# --- insert at end (idx == count+1 boundary via append-like) ---
tuish_buf_insert_at _ 4 'tail'
tuish_buf_get _ 4; assert_eq "$TUISH_BLINE" "tail" "insert: at the end"
assert_eq "$TUISH_BUF_COUNT" "4" "insert at end: count grew"

# --- Independent buffers: two buffers do not interfere ---
tuish_buf_init alpha
tuish_buf_init beta
tuish_buf_set alpha 1 'A1'
tuish_buf_append alpha 'A2'
tuish_buf_set beta 1 'B1'
tuish_buf_get alpha 1; assert_eq "$TUISH_BLINE" "A1" "independent: alpha 1"
tuish_buf_get alpha 2; assert_eq "$TUISH_BLINE" "A2" "independent: alpha 2"
tuish_buf_get beta 1;  assert_eq "$TUISH_BLINE" "B1" "independent: beta 1"
tuish_buf_count alpha; assert_eq "$TUISH_BUF_COUNT" "2" "independent: alpha count"
tuish_buf_count beta;  assert_eq "$TUISH_BUF_COUNT" "1" "independent: beta count"
# the '_' buffer is untouched by alpha/beta
tuish_buf_count _;     assert_eq "$TUISH_BUF_COUNT" "4" "independent: _ buffer preserved"

# --- Values with spaces survive (mandatory handle removes the old ambiguity) ---
tuish_buf_append _ 'two words'
tuish_buf_get _ 5; assert_eq "$TUISH_BLINE" "two words" "spaceful value preserved"

# --- Append auto-creates a fresh buffer (no init needed) ---
tuish_buf_append fresh 'only line'
assert_eq "$TUISH_BUF_COUNT" "1" "append: auto-create count is 1"
tuish_buf_get fresh 1; assert_eq "$TUISH_BLINE" "only line" "append: auto-create stored the line"

# --- Out-of-range reads are safe under set -u (regression) -------------------
# A get past the last line, or a count of a never-touched buffer, must yield
# empty/0 rather than aborting the whole app under `set -u` — the crash a mouse
# click/drag below the last editor line used to trigger (_tuish_buf_<b>_<idx>
# unset). This whole file runs under `set -euf`, so a regression aborts it here.
tuish_buf_get fresh 99;  assert_eq "$TUISH_BLINE" ""  "get: out-of-range index is empty, not an abort"
tuish_buf_get _ 0;       assert_eq "$TUISH_BLINE" ""  "get: index 0 is empty, not an abort"
tuish_buf_count never;   assert_eq "$TUISH_BUF_COUNT" "0" "count: untouched buffer is 0, not an abort"

test_summary
