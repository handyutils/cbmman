#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Fixture viewer - display terminal fixture files with visual framing.
# Lets developers inspect exactly what a screen should look like.
#
# Usage:
#   tests/view_fixture.sh tests/fixtures/<name>.screen
#   tests/view_fixture.sh tests/fixtures/*.screen     # view all
#   tests/view_fixture.sh --list                       # list all fixtures

set -eu

FIXTURES_DIR="$(cd "$(dirname "$0")" && pwd)/fixtures"

_usage () {
	printf 'Usage: %s [--list] <fixture-file> ...\n\n' "$0"
	printf 'Display terminal screen fixtures with visual framing.\n\n'
	printf 'Options:\n'
	printf '  --list    List all fixture files\n'
	printf '  --diff    Compare two fixture files side by side\n\n'
	printf 'Examples:\n'
	printf '  %s tests/fixtures/boxes_light.screen\n' "$0"
	printf '  %s tests/fixtures/*.screen\n' "$0"
	printf '  %s --list\n' "$0"
}

_list () {
	if ! test -d "$FIXTURES_DIR"
	then
		printf 'No fixtures directory found at %s\n' "$FIXTURES_DIR"
		exit 1
	fi
	local count=0
	for f in "$FIXTURES_DIR"/*.screen
	do
		test -f "$f" || continue
		local name="${f##*/}"
		name="${name%.screen}"
		local lines
		lines=$(wc -l < "$f")
		# Measure widest line
		local width=0
		while IFS= read -r line
		do
			local len=${#line}
			test "$len" -gt "$width" && width=$len
		done < "$f"
		printf '  %-40s %3d lines, %3d cols\n' "$name" "$lines" "$width"
		count=$((count + 1))
	done
	if test $count -eq 0
	then
		printf '  (no fixtures yet — run tests with TUISH_UPDATE_FIXTURES=1)\n'
	else
		printf '\n  %d fixture(s) in %s\n' "$count" "$FIXTURES_DIR"
	fi
}

_view () {
	local file="$1"
	if ! test -f "$file"
	then
		printf 'Error: %s not found\n' "$file"
		return 1
	fi

	local name="${file##*/}"
	name="${name%.screen}"

	# Measure dimensions
	local width=0
	local height=0
	while IFS= read -r line
	do
		height=$((height + 1))
		local len=${#line}
		test "$len" -gt "$width" && width=$len
	done < "$file"
	test "$width" -lt 72 && width=72

	# Title bar
	printf '\033[7m'
	printf ' %s ' "$name"
	local _tl=$((${#name} + 2))
	local _pd=$((width + 2 - _tl))
	local _p=0
	while test $_p -lt $_pd; do printf ' '; _p=$((_p + 1)); done
	printf '\033[0m\n'

	# Content — display the fixture as-is so the developer sees
	# exactly what the terminal screen should look like
	cat "$file"

	# Footer with dimensions
	printf '\033[2m(%dx%d)  %s\033[0m\n\n' "$width" "$height" "$file"
}

# --- Main ---

if test $# -eq 0
then
	_usage
	exit 1
fi

case "$1" in
	--list)
		_list
		;;
	--help|-h)
		_usage
		;;
	*)
		for arg in "$@"
		do
			_view "$arg"
		done
		;;
esac
