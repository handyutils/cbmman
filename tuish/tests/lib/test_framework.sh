#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Minimal test assertion framework for tui.sh tests

unsetopt NO_POSIX_TRAPS FLOW_CONTROL GLOB NO_MATCH NO_SH_WORD_SPLIT NO_PROMPT_SUBST 2>/dev/null || :

# ksh compatibility: alias local=typeset
if test -n "${KSH_VERSION:-}"
then
	case "$KSH_VERSION" in
		*'Version AJM'*|*MIRBSD*) alias local=typeset;;
	esac
fi

_test_pass=0
_test_fail=0
_test_total=0
_test_file="${0##*/}"

assert_eq () {
	_test_total=$((_test_total + 1))
	if test "$1" = "$2"
	then
		_test_pass=$((_test_pass + 1))
		printf '  PASS: %s\n' "$3"
	else
		_test_fail=$((_test_fail + 1))
		printf '  FAIL: %s\n    expected: [%s]\n    actual:   [%s]\n' "$3" "$2" "$1"
	fi
}

assert_contains () {
	_test_total=$((_test_total + 1))
	case "$1" in
		*"$2"*)
			_test_pass=$((_test_pass + 1))
			printf '  PASS: %s\n' "$3"
			;;
		*)
			_test_fail=$((_test_fail + 1))
			printf '  FAIL: %s (output did not contain "%s")\n' "$3" "$2"
			;;
	esac
}

test_summary () {
	printf '\n[%s] %d/%d passed, %d failed\n' "$_test_file" "$_test_pass" "$_test_total" "$_test_fail"
	test "$_test_fail" -eq 0
}
