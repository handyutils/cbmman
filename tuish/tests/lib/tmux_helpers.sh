#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# tmux session helpers for tui.sh integration tests

TUISH_SCRIPT="${TUISH_SCRIPT:-$(cd "$(dirname "$0")/.." && pwd)/lib/event_echo.sh}"
TUISH_SHELL="${TUISH_SHELL:-bash}"
TUISH_SESSION="tuish_test_$$"

start_tuish_session () {
	# Note: $TUISH_SHELL is intentionally unquoted to support multi-word
	# commands like "busybox sh"
	tmux new-session -d -s "$TUISH_SESSION" -x 80 -y 24 \
		$TUISH_SHELL "$TUISH_SCRIPT" 2>/dev/null
	# Wait for the script's first idle timeout output
	local _ready=0
	local _attempts=0
	while test $_ready -eq 0 && test $_attempts -lt 50
	do
		if capture_pane | grep -qE '^\[=1\]:|^[0-9]{2}:[0-9]{2}:'
		then
			_ready=1
		fi
		sleep 0.2
		_attempts=$((_attempts + 1))
	done
	# Warmup: zsh can lose first input after idle event
	send_hex 20
	sleep 0.5
}

send_hex () {
	tmux send-keys -t "$TUISH_SESSION" -H $@ 2>/dev/null
}

capture_pane () {
	tmux capture-pane -t "$TUISH_SESSION" -p 2>/dev/null
}

wait_for_output () {
	local pattern="$1"
	local timeout="${2:-5}"
	local elapsed=0
	while test $elapsed -lt $((timeout * 10))
	do
		if capture_pane | grep -qF "$pattern"
		then
			return 0
		fi
		sleep 0.1
		elapsed=$((elapsed + 1))
	done
	return 1
}

assert_event () {
	local hex_input="$1"
	local expected="$2"
	local label="$3"
	local wait_time="${4:-3}"

	send_hex $hex_input
	if wait_for_output "$expected" "$wait_time"
	then
		_test_pass=$((_test_pass + 1))
		_test_total=$((_test_total + 1))
		printf '  PASS: %s\n' "$label"
	else
		_test_fail=$((_test_fail + 1))
		_test_total=$((_test_total + 1))
		printf '  FAIL: %s (expected "%s" in output)\n' "$label" "$expected"
		printf '    captured output:\n'
		capture_pane | sed 's/^/    | /'
	fi
}

quit_tuish () {
	# Send Ctrl+W (0x17) to quit
	send_hex 17
	sleep 0.3
}

cleanup_session () {
	tmux kill-session -t "$TUISH_SESSION" 2>/dev/null || :
}
