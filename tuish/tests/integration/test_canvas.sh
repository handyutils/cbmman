#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Integration tests: the canvas via examples/canvas_demo.sh — two boxed,
# independently scrollable panels in a fixed viewport.
#
# Confirms end-to-end that the canvas composes with the other primitives and
# that clipping is load-bearing: both panels render (multi-region), draw.sh
# boxes decorate them, content far down the list is clipped out of the canvas
# (vertical), and over-long lines are sliced to the panel width (horizontal via
# tuish_str_window) — none of it leaking outside the panels.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"
. "$TESTS_DIR/lib/tmux_helpers.sh"
. "$TESTS_DIR/lib/screen_helpers.sh"

EXAMPLES_DIR="$(cd "$(dirname "$0")/../.." && pwd)/examples"
trap 'cleanup_session' EXIT

printf 'Integration tests: canvas dual-pane demo (%s)\n' "$TUISH_SHELL"

start_example_session "$EXAMPLES_DIR/canvas_demo.sh" "LEFT" 60 14

# Both panels render (two independent canvases on one viewport).
assert_screen_match    "L00 item"      "left panel content rendered"
assert_screen_match    "R00 a fairly"  "right panel content rendered"
assert_screen_match    "RIGHT"         "second panel present (multi-canvas)"

# Vertical clipping is load-bearing: the list is 24 lines, the canvas shows 6,
# so a far line is drawn at an out-of-canvas row and must be clipped away.
assert_screen_no_match "L23"           "vertical: far list line clipped out of the canvas"

# Horizontal slice: the right lines overflow the panel width, so their tail is
# cut by tuish_str_window and never reaches the screen until panned.
assert_screen_no_match "END00"         "horizontal: long line sliced to panel width"

quit_tuish

test_summary
