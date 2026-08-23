#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Integration tests: editor.sh horizontal (column-based) scrolling
#
# Covers the column-aware horizontal scroll: typing past the viewport width
# scrolls the line so the cursor stays visible (tail shown, head clipped), and
# Home scrolls back to the start. Exercises tuish_str_window + tuish_clamp_scroll
# on the column axis, plus the cursor display-column placement.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"
. "$TESTS_DIR/lib/tmux_helpers.sh"
. "$TESTS_DIR/lib/screen_helpers.sh"

EXAMPLES_DIR="$(cd "$(dirname "$0")/../.." && pwd)/examples"
trap 'cleanup_session' EXIT

printf 'Integration tests: editor horizontal scroll (%s)\n' "$TUISH_SHELL"

# Narrow 20-column terminal so a short line overflows the viewport width.
start_example_session "$EXAMPLES_DIR/editor.sh" "Ln 1, Col 1" 20 12

# Type 24 chars 'abc...x' — longer than the 20-col viewport, so the cursor
# (col 25) forces a horizontal scroll. Visible window becomes cols [4,24) =
# characters 5..24, i.e. head 'abcd' is clipped, tail 'tuvwx' is shown.
send_chars 61 62 63 64 65 66 67 68 69 6a 6b 6c 6d 6e 6f 70 71 72 73 74 75 76 77 78
sleep 0.4

assert_screen_match    "Col 25" "hscroll: cursor at col 25 after 24 chars"
assert_screen_match    "tuvwx"  "hscroll: line tail is visible"
assert_screen_no_match "abcde"  "hscroll: line head is clipped off the left"

# Home (ESC O H) returns the cursor to col 1 and scrolls the view back.
send_hex 1b 4f 48
sleep 0.4

assert_screen_match "Col 1" "hscroll home: cursor back at col 1"
assert_screen_match "abcde" "hscroll home: line head scrolled back into view"

quit_tuish

test_summary
