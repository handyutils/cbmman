#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Integration test: one tuish app running INSIDE another (in-process, no forks).
#
# host_demo.sh draws a full-screen page with a bordered content box. Pressing 'e'
# opens examples/canvas_demo.sh inside that box — a second complete tuish app in a
# region of the first, driven by a nested tuish_run over the same keyboard. This
# exercises the whole hosting stack: reentrant event loop, per-context bindings
# and handlers, region = viewport composition, and clean return to the host.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"
. "$TESTS_DIR/lib/tmux_helpers.sh"
. "$TESTS_DIR/lib/screen_helpers.sh"

TUISH_SCRIPT="$TESTS_DIR/lib/host_demo.sh"
trap 'cleanup_session' EXIT

printf 'Integration test: app-in-app hosting (%s)\n' "$TUISH_SHELL"

# This used to skip on ksh: the embedded guest is canvas_demo, and canvas_demo did not
# render under ksh — a "pre-existing box-drawing bug" nobody had gotten to the bottom of.
#
# It was not a box-drawing bug. On ksh93 `local` is `typeset`, and typeset does not create a
# local in a POSIX function — so draw.sh's `local _top`, which holds a box's TOP BORDER
# STRING, was overwriting the caller's `_top` layout row, and the border got handed back to
# tuish_text as a coordinate. compat.sh's tuish_fnfix now makes `local` mean local on ksh
# (see the comment there). The skip is gone, and ksh runs the same hosting tests as
# everybody else.

# Start the host page.
tmux new-session -d -s "$TUISH_SESSION" -x 80 -y 24 \
	$TUISH_SHELL "$TUISH_SCRIPT" 2>/dev/null
wait_for_output "HOST PAGE" 10 || {
	printf '  ERROR: host did not start\n'; capture_pane | sed 's/^/    | /'; exit 1; }
sleep 0.5

# Host chrome is up, example not yet opened.
assert_screen_match    "HOST PAGE"     "host page rendered"
assert_screen_no_match "L00 item"      "example not open yet"

# Press 'e' -> open canvas_demo inside the content region.
send_hex 65
assert_screen_match    "L00 item"      "example opened inside the region (left panel)"
assert_screen_match    "R00 a fairly"  "example right panel rendered in region"

# The host chrome must still frame the embedded app — it was never torn down.
assert_screen_match    "HOST PAGE"     "host chrome still present around the embedded app"

# Mouse reaches the embedded app with REGION-LOCAL coordinates: a left click on
# the right panel focuses it, a click on the left panel focuses that. SGR 1006
# press (ESC [ < 0 ; col ; row M); the region starts near column 3, so absolute
# col 30 lands in the right panel and col 10 in the left.
send_hex 1b 5b 3c 30 3b 33 30 3b 36 4d    # left press @ (30,6) -> right panel
assert_screen_match    "focus: RIGHT"  "mouse click focuses the right panel (embedded)"
send_hex 1b 5b 3c 30 3b 31 30 3b 36 4d    # left press @ (10,6) -> left panel
assert_screen_match    "focus: LEFT"   "mouse click focuses the left panel (embedded)"

# Drive the EMBEDDED app: Tab switches its focus, j scrolls its list. This input
# reaches the nested loop, not the host.
#
# It must scroll PAST THE FOLD to prove anything: the right panel is 6 rows tall and
# starts at the top, so R00-R05 are on screen from the outset and any assertion on
# R03 would pass with the keys going nowhere. 8 x j drives the selection to line 8,
# which forces top to 3 — so R08 appears and R00 scrolls out. Assert both ends.
send_hex 09            # Tab -> focus the right panel
sleep 0.3
send_chars 6a 6a 6a 6a 6a 6a 6a 6a    # j x8
assert_screen_match    "R08"           "keys reach the embedded app (scrolled past the fold)"
assert_screen_no_match "R00"           "the embedded app really scrolled (R00 is gone)"

# Ctrl+W quits the embedded app and returns to the host.
send_hex 17
sleep 0.5
assert_screen_no_match "L00 item"      "embedded app closed on Ctrl+W"
assert_screen_match    "HOST PAGE"     "host resumed after the embedded app returned"

# Host is live again: 'e' re-opens the example (context created/destroyed cleanly).
send_hex 65
assert_screen_match    "L00 item"      "host re-opens the example after return"

# A click OUTSIDE the embedded region belongs to the host: the app yields so the
# host's surrounding UI stays reachable. Click row 1 (the host title, above the
# region) — the example closes and the host resumes without a Ctrl+W.
send_hex 1b 5b 3c 30 3b 35 3b 31 4d    # SGR left press @ (col 5, row 1)
sleep 0.5
assert_screen_no_match "L00 item"      "click outside the region yields the embedded app"
assert_screen_match    "HOST PAGE"     "host resumed after an out-of-region click"

# Ctrl+W quits the host.
send_hex 17
sleep 0.3

test_summary
