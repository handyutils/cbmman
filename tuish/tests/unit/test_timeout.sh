#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for _tuish_timeout_us (TUISH_IDLE_TIMEOUT seconds -> microseconds).
# This is the single parser behind TUISH_TICK_US (the animation clock) and the
# zsh idle-chunk count.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/tui.sh"


# Exercise the SHIPPED configuration. tuish_fnfix normally fires from tuish_init, which unit
# tests deliberately never call (they stub the device) — so without this, every suite here
# would validate the framework with its ksh `local` still leaking, i.e. not the library that
# actually runs. It is a no-op on every shell whose `local` already works.
command -v tuish_fnfix >/dev/null 2>&1 && tuish_fnfix

printf 'Unit tests: _tuish_timeout_us (timeout seconds -> microseconds)\n'

# --- typical idle intervals ---
_tuish_timeout_us '0.02';     assert_eq "$_tuish_tick_us" "20000"    "us: 0.02 -> 20000"
_tuish_timeout_us '0.26';     assert_eq "$_tuish_tick_us" "260000"   "us: 0.26 -> 260000"
_tuish_timeout_us '1';        assert_eq "$_tuish_tick_us" "1000000"  "us: integer 1 -> 1000000"
_tuish_timeout_us '0.5';      assert_eq "$_tuish_tick_us" "500000"   "us: 0.5 -> 500000"
_tuish_timeout_us '0.001';    assert_eq "$_tuish_tick_us" "1000"     "us: 0.001 -> 1000"
_tuish_timeout_us '2';        assert_eq "$_tuish_tick_us" "2000000"  "us: integer 2 -> 2000000"
_tuish_timeout_us '1.5';      assert_eq "$_tuish_tick_us" "1500000"  "us: 1.5 -> 1500000"
_tuish_timeout_us '10';       assert_eq "$_tuish_tick_us" "10000000" "us: integer 10 -> 10000000"

# --- fractional precision (read to 6 digits = microseconds) ---
_tuish_timeout_us '0.000001'; assert_eq "$_tuish_tick_us" "1"        "us: 0.000001 -> 1 (full us)"
_tuish_timeout_us '0.123456'; assert_eq "$_tuish_tick_us" "123456"   "us: 0.123456 -> 123456"
_tuish_timeout_us '0.1234567';assert_eq "$_tuish_tick_us" "123456"   "us: extra digits truncated at us"

# --- leading-zero fraction must be base-10, not octal ---
_tuish_timeout_us '0.020';    assert_eq "$_tuish_tick_us" "20000"    "us: 0.020 base-10 (not octal)"
_tuish_timeout_us '0.08';     assert_eq "$_tuish_tick_us" "80000"    "us: 0.08 base-10 (8/9 not octal-invalid)"
_tuish_timeout_us '0.09';     assert_eq "$_tuish_tick_us" "90000"    "us: 0.09 base-10"

# --- zero / empty fall back to ~60 Hz ---
_tuish_timeout_us '0';        assert_eq "$_tuish_tick_us" "16667"    "us: 0 -> fallback 16667"
_tuish_timeout_us '0.0';      assert_eq "$_tuish_tick_us" "16667"    "us: 0.0 -> fallback 16667"
_tuish_timeout_us '';         assert_eq "$_tuish_tick_us" "16667"    "us: empty -> fallback 16667"

test_summary
