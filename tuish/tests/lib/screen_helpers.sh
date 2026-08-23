#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Screen capture, fixture comparison, and visual display utilities
# for tui.sh integration tests.
#
# Dependencies: test_framework.sh and tmux_helpers.sh must be sourced first.
#
# Fixture workflow:
#   1. Write tests using assert_screen "fixture_name" "label"
#   2. Generate fixtures:  TUISH_UPDATE_FIXTURES=1 bash tests/run_tests.sh --integration
#   3. Review fixtures:    tests/view_fixture.sh tests/fixtures/<name>.screen
#   4. Commit fixtures to git
#   5. CI validates screens match fixtures on every run
#
# Environment variables:
#   TUISH_UPDATE_FIXTURES=1   Save captures as fixtures instead of comparing

FIXTURES_DIR="${FIXTURES_DIR:-$(cd "$(dirname "$0")/.." && pwd)/fixtures}"

# ─── Capture ──────────────────────────────────────────────────────

# Capture the tmux pane with trailing whitespace stripped per line.
capture_screen () {
	capture_pane | sed 's/[[:space:]]*$//'
}

# ─── Example session management ──────────────────────────────────

# Launch an example script in a tmux session and wait for readiness.
#   $1 = script path
#   $2 = grep pattern to wait for (indicates script is ready)
#   $3 = width  (default 80)
#   $4 = height (default 24)
start_example_session () {
	local script="$1"
	local wait_pattern="$2"
	local width="${3:-80}"
	local height="${4:-24}"

	tmux new-session -d -s "$TUISH_SESSION" -x "$width" -y "$height" \
		$TUISH_SHELL "$script" 2>/dev/null

	if ! wait_for_output "$wait_pattern" 10
	then
		printf '  ERROR: example did not start (waiting for "%s")\n' "$wait_pattern"
		capture_pane | sed 's/^/    | /'
		return 1
	fi
	# Let rendering settle after the wait pattern appears
	sleep 0.5
}

# Send hex bytes one at a time with a delay between each.
# Necessary for shells like zsh that can drop chars during rapid input.
# The delay allows the TUI event loop to fully process each character
# before the next arrives.
#   $@ = hex bytes (e.g. 48 65 6c 6c 6f)
send_chars () {
	local _byte
	for _byte in "$@"
	do
		send_hex "$_byte"
		sleep 0.25
	done
}

# ─── Screen assertions ───────────────────────────────────────────

# Compare captured screen against a stored fixture file.
#   $1 = fixture name (without .screen extension)
#   $2 = test label
assert_screen () {
	local fixture_name="$1"
	local label="$2"
	local fixture_file="${FIXTURES_DIR}/${fixture_name}.screen"

	local captured
	captured="$(capture_screen)"

	# Update mode: save capture as the new fixture
	if test "${TUISH_UPDATE_FIXTURES:-}" = "1"
	then
		mkdir -p "$(dirname "$fixture_file")"
		printf '%s\n' "$captured" > "$fixture_file"
		_test_pass=$((_test_pass + 1))
		_test_total=$((_test_total + 1))
		printf '  SAVE: %s -> %s\n' "$label" "${fixture_name}.screen"
		return 0
	fi

	# Fixture missing: fail with instructions
	if ! test -f "$fixture_file"
	then
		_test_fail=$((_test_fail + 1))
		_test_total=$((_test_total + 1))
		printf '  FAIL: %s (fixture missing: %s)\n' "$label" "${fixture_name}.screen"
		printf '    Run with TUISH_UPDATE_FIXTURES=1 to generate it.\n'
		show_screen "$captured" "captured"
		return 0
	fi

	local expected
	expected="$(sed 's/[[:space:]]*$//' "$fixture_file")"

	if test "$captured" = "$expected"
	then
		_test_pass=$((_test_pass + 1))
		_test_total=$((_test_total + 1))
		printf '  PASS: %s\n' "$label"
	else
		_test_fail=$((_test_fail + 1))
		_test_total=$((_test_total + 1))
		printf '  FAIL: %s (screen mismatch)\n' "$label"
		show_screen "$expected" "expected (fixture)"
		show_screen "$captured" "actual (captured)"
		printf '    diff:\n'
		diff <(printf '%s\n' "$expected") <(printf '%s\n' "$captured") \
			| head -30 | sed 's/^/    /'
		printf '\n'
	fi
}

# Assert that a specific line of the screen matches.
#   $1 = line number (1-based)
#   $2 = expected content (trailing whitespace ignored)
#   $3 = test label
assert_screen_line () {
	local line_num=$1
	local expected="$2"
	local label="$3"

	local actual
	actual="$(capture_screen | sed -n "${line_num}p")"
	expected="$(printf '%s' "$expected" | sed 's/[[:space:]]*$//')"

	assert_eq "$actual" "$expected" "$label"
}

# Assert that a pattern appears on screen within a timeout.
#   $1 = pattern (fixed string for grep -F)
#   $2 = test label
#   $3 = timeout in seconds (default 3)
assert_screen_match () {
	local pattern="$1"
	local label="$2"
	local timeout="${3:-3}"

	if wait_for_output "$pattern" "$timeout"
	then
		_test_pass=$((_test_pass + 1))
		_test_total=$((_test_total + 1))
		printf '  PASS: %s\n' "$label"
	else
		_test_fail=$((_test_fail + 1))
		_test_total=$((_test_total + 1))
		printf '  FAIL: %s (pattern "%s" not found)\n' "$label" "$pattern"
		show_screen "$(capture_screen)" "captured"
	fi
}

# Assert that a pattern does NOT appear on screen.
#   $1 = pattern (fixed string for grep -F)
#   $2 = test label
assert_screen_no_match () {
	local pattern="$1"
	local label="$2"

	if capture_pane | grep -qF "$pattern"
	then
		_test_fail=$((_test_fail + 1))
		_test_total=$((_test_total + 1))
		printf '  FAIL: %s (pattern "%s" should not appear)\n' "$label" "$pattern"
		show_screen "$(capture_screen)" "captured"
	else
		_test_pass=$((_test_pass + 1))
		_test_total=$((_test_total + 1))
		printf '  PASS: %s\n' "$label"
	fi
}

# ─── Visual display ──────────────────────────────────────────────

# Display a captured screen framed with box-drawing characters.
# Useful for visual inspection during test failures and development.
#   $1 = screen content (multiline string)
#   $2 = title label (default "screen")
show_screen () {
	local screen="$1"
	local title="${2:-screen}"

	# Header
	printf '    \033[2m+-- %s ' "$title"
	local _tl=${#title}
	local _pd=$((68 - _tl))
	local _p=0
	while test $_p -lt $_pd; do printf '-'; _p=$((_p + 1)); done
	printf '+\033[0m\n'

	# Body
	printf '%s\n' "$screen" | while IFS= read -r line
	do
		printf '    \033[2m|\033[0m %-72s \033[2m|\033[0m\n' "$line"
	done

	# Footer
	printf '    \033[2m+'
	_p=0
	while test $_p -lt 74; do printf '-'; _p=$((_p + 1)); done
	printf '+\033[0m\n'
}
