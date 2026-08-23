#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Integration tests: viewport exit cursor positioning via tmux PTY

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"
. "$TESTS_DIR/lib/tmux_helpers.sh"

_src_dir="$(cd "$(dirname "$0")/../.." && pwd)/src"
_vp_helper="$(mktemp)"
trap 'cleanup_session; rm -f "$_vp_helper"' EXIT

printf 'Integration tests: viewport (%s)\n' "$TUISH_SHELL"

# --- Helper: minimal fixed-mode TUI that exits on first event ---
# Prints INVOCATION_TAG before the TUI, then after fini prints the
# push_gap value and EXIT_TAG so the test can verify cursor placement.
cat > "$_vp_helper" << HELPEREOF
#!/bin/sh
. "${_src_dir}/compat.sh"
. "${_src_dir}/ord.sh"
. "${_src_dir}/tui.sh"
. "${_src_dir}/term.sh"
. "${_src_dir}/event.sh"
. "${_src_dir}/hid.sh"
. "${_src_dir}/viewport.sh"

tuish_on_event () { tuish_quit_clear; }
tuish_on_redraw () { :; }

# Simulate shell history: push cursor down before starting the TUI
_i=0; while test \$_i -lt 6; do printf '\\n'; _i=\$((_i + 1)); done
printf 'INVOCATION_TAG\\n'

tuish_init
tuish_viewport fixed 10
tuish_run || :
tuish_fini

printf 'PUSH_GAP=%d\\n' "\$_tuish_fini_push_gap"
printf 'EXIT_TAG\\n'
sleep 60
HELPEREOF
chmod +x "$_vp_helper"

# --- Test: fixed-mode clear exit cursor position ---
# When a fixed-mode viewport pushes content up (via reserve_space
# newlines) and the app quits with tuish_quit_clear, the cursor
# must land right below the invocation line — not above it.
#
# The fix re-saves the cursor at the viewport origin during
# teardown and resets _tuish_fini_push_gap to 0, avoiding
# double-correction on terminals where DECRC adjusts for
# scrollback.

tmux new-session -d -s "$TUISH_SESSION" -x 80 -y 14 \
	$TUISH_SHELL "$_vp_helper" 2>/dev/null

if ! wait_for_output 'EXIT_TAG' 10
then
	_test_fail=$((_test_fail + 1))
	_test_total=$((_test_total + 1))
	printf '  FAIL: fixed-mode clear exit (script did not complete)\n'
	printf '    captured output:\n'
	capture_pane | sed 's/^/    | /'
	test_summary
	exit
fi

_captured="$(capture_pane)"

# Test 1: push_gap must be reset to 0 by the clear teardown.
# This is the core of the fix — without it, DECRC + push_gap
# double-corrects on terminals with scrollback adjustment.
_push_gap_line="$(printf '%s\n' "$_captured" | grep 'PUSH_GAP=' | head -1)"
_push_gap="${_push_gap_line#PUSH_GAP=}"
assert_eq "$_push_gap" "0" "fixed-mode clear exit resets push_gap"

test_summary
