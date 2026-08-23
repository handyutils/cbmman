#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Integration tests: character input via tmux PTY

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"
. "$TESTS_DIR/lib/tmux_helpers.sh"

trap 'cleanup_session' EXIT

printf 'Integration tests: characters (%s)\n' "$TUISH_SHELL"

start_tuish_session

# --- Printable ASCII ---
# 'a' = 0x61
assert_event "61" "char a" "character a"

# 'z' = 0x7a
assert_event "7a" "char z" "character z"

# 'A' = 0x41
assert_event "41" "char A" "character A"

# '0' = 0x30
assert_event "30" "char 0" "character 0"

# '!' = 0x21
assert_event "21" "char !" "character !"

# '@' = 0x40
assert_event "40" "char @" "character @"

# '/' = 0x2f
assert_event "2f" "char /" "character /"

# Space = 0x20
assert_event "20" "space" "space"

quit_tuish
test_summary
