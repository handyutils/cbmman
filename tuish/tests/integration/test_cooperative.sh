#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Integration test: the COOPERATIVE (non-modal) driver — one host loop driving two
# live children at once, in-process, no forks.
#
# examples/cooperative.sh draws a full-screen page with two bordered boxes: a ticking
# clock on the left and the interactive editor on the right. Unlike modal hosting
# (test_hosting.sh), no child runs its own tuish_run — the host keeps its single loop
# and feeds each event to the right child via tuish_ctx_dispatch. This exercises the
# whole cooperative stack: tuish_ctx_mount, per-event context activation, region-local
# input, idle broadcast to multiple children, and clean unmount.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"
. "$TESTS_DIR/lib/tmux_helpers.sh"
. "$TESTS_DIR/lib/screen_helpers.sh"

TUISH_SCRIPT="$TESTS_DIR/../examples/cooperative.sh"
trap 'cleanup_session' EXIT

printf 'Integration test: cooperative non-modal driver (%s)\n' "$TUISH_SHELL"

# Wide terminal so both boxes fit side by side.
tmux new-session -d -s "$TUISH_SESSION" -x 100 -y 30 \
	$TUISH_SHELL "$TUISH_SCRIPT" 2>/dev/null
wait_for_output "editor" 10 || {
	printf '  ERROR: cooperative host did not start\n'; capture_pane | sed 's/^/    | /'; exit 1; }
sleep 0.8

# Both widgets and the host chrome are up together.
assert_screen_match "one loop, two live apps" "host chrome rendered"
assert_screen_match "clock"  "clock box present"
assert_screen_match "editor" "editor box present"
assert_screen_match "live · idle-driven" "clock widget rendered its label"

# The clock advances on its own — proof that idle events are driving a child while the
# loop is otherwise idle (a modal host could not tick a sibling like this).
_c1="$(capture_pane | grep -oE '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' | head -1)"
sleep 2.2
_c2="$(capture_pane | grep -oE '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' | head -1)"
_test_total=$((_test_total + 1))
if test -n "$_c1" && test -n "$_c2" && test "$_c1" != "$_c2"
then
	_test_pass=$((_test_pass + 1))
	printf '  PASS: %s\n' "clock advances from idle ($_c1 -> $_c2) while host is idle"
else
	_test_fail=$((_test_fail + 1))
	printf '  FAIL: %s (t1=%s t2=%s)\n' "clock did not advance on idle" "$_c1" "$_c2"
	capture_pane | sed 's/^/    | /'
fi

# Keyboard goes to the editor: type a word, the editor's status line advances its
# column and the text appears. This reaches the editor child, not the host or clock.
send_hex 63 6f 6f 70    # c o o p
assert_screen_match "coop"          "typing reaches the editor (text inserted)"
assert_screen_match "Col 5"         "editor cursor advanced (keys drive the editor child)"

# Mouse routes by region: an SGR left-press inside the RIGHT box focuses the editor
# there. Click near the top-left of the editor interior (~col 54, row 5), then type —
# the character lands in the editor at the clicked position's line.
send_hex 1b 5b 3c 30 3b 35 34 3b 35 4d    # ESC [ < 0 ; 54 ; 5 M  (left press @ 54,5)
send_hex 5a                                # Z
assert_screen_match "Z"             "mouse click focuses the editor region, key lands there"

# The clock kept ticking through all that interaction (still labeled, still a time).
assert_screen_match "live · idle-driven" "clock still live after editor interaction"

# Ctrl+W quits the host; both children unmount and the terminal is restored.
send_hex 17
sleep 0.5
assert_screen_no_match "one loop, two live apps" "Ctrl+W quits the cooperative host"

test_summary
