#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Test runner for tui.sh — runs unit and integration tests across available shells

set -eu

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
_total_pass=0
_total_fail=0
_total_suites=0

run_test () {
	local shell="$1"
	local test_file="$2"
	local test_type="$3"

	if test "$test_type" = "unit"
	then
		result=$($shell "$test_file" 2>&1) || :
	else
		result=$(TUISH_SHELL="$shell" bash "$test_file" 2>&1) || :
	fi

	printf '%s\n' "$result"

	# Extract pass/fail counts from summary line
	summary=$(printf '%s' "$result" | grep 'passed,' | tail -1)
	if test -n "$summary"
	then
		passed=$(printf '%s' "$summary" | sed 's/.*] \([0-9]*\)\/.*/\1/')
		total=$(printf '%s' "$summary" | sed 's|.*/\([0-9]*\) passed.*|\1|')
		failed=$(printf '%s' "$summary" | sed 's/.* \([0-9]*\) failed/\1/')
		_total_pass=$((_total_pass + passed))
		_total_fail=$((_total_fail + failed))
	fi
	_total_suites=$((_total_suites + 1))
}

# Check if a shell supports tui.sh interactive mode (read -n or read -k)
# Note: $1 is intentionally unquoted to allow multi-word commands like "busybox sh"
can_run_interactive () {
	$1 -c '{ echo 1 | read -s -k1 2>/dev/null ;} || { echo 1 | read -r -t 0.1 -n 1 2>/dev/null ;}' 2>/dev/null
}

run_shell_tests () {
	local shell="$1"
	local suite="${2:-all}"

	printf '========================================\n'
	printf '  Shell: %s (%s)\n' "$shell" "$suite"
	printf '========================================\n\n'

	# Unit tests — run in the target shell
	if test "$suite" = "all" || test "$suite" = "unit"
	then
		for test_file in "$TESTS_DIR"/unit/test_*.sh
		do
			run_test "$shell" "$test_file" "unit"
			printf '\n'
		done
	fi

	# Integration tests — run via tmux with the target shell
	if test "$suite" = "all" || test "$suite" = "integration"
	then
		if can_run_interactive "$shell"
		then
			for test_file in "$TESTS_DIR"/integration/test_*.sh
			do
				run_test "$shell" "$test_file" "integration"
				printf '\n'
			done
		else
			printf '  SKIP: integration tests (%s lacks read -n/-k support)\n\n' "$shell"
		fi
	fi
}

# Parse arguments: [--unit|--integration] [shell]
_suite='all'
_shell=''
for _arg in "$@"
do
	case "$_arg" in
		--unit)        _suite='unit';;
		--integration) _suite='integration';;
		*)             _shell="$_arg";;
	esac
done

if test -n "$_shell"
then
	run_shell_tests "$_shell" "$_suite"
else
	for shell in bash zsh ksh mksh
	do
		if ! command -v "$shell" >/dev/null 2>&1
		then
			printf 'SKIP: %s not found\n\n' "$shell"
			continue
		fi
		run_shell_tests "$shell" "$_suite"
	done

	# busybox sh — separate because the command is two words
	if command -v busybox >/dev/null 2>&1
	then
		run_shell_tests "busybox sh" "$_suite"
	fi
fi

printf '========================================\n'
printf '  TOTAL: %d passed, %d failed (%d suites)\n' "$_total_pass" "$_total_fail" "$_total_suites"
printf '========================================\n'

test "$_total_fail" -eq 0
