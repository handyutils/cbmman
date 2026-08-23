#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Benchmark runner for tui.sh — runs bench_events.sh across available shells.
# Mirrors tests/run_tests.sh's shell-iteration (incl. the two-word "busybox sh").
#
# Usage:  ./run_bench.sh [shell]
#   With no arg, iterates bash/zsh/ksh/mksh + busybox sh (those installed).
#   BENCH_N / BENCH_WN env vars are passed through to scale iteration counts.
#
# Bounded by construction: a fixed shell list and fixed-N loops inside the
# bench — no recursion, no unbounded input reads.

set -eu

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"

run_one ()
{
	# $1 = shell command (may be two words, e.g. "busybox sh")
	printf '========================================\n'
	printf '  Shell: %s\n' "$1"
	printf '========================================\n'
	# Intentionally unquoted to allow multi-word commands like "busybox sh".
	for _bench in "$BENCH_DIR/bench_events.sh" "$BENCH_DIR/bench_paint.sh"
	do
		$1 "$_bench" || printf '  (%s aborted under %s)\n' "$(basename "$_bench")" "$1"
	done
	printf '\n'
}

if test "$#" -gt 0
then
	run_one "$1"
	exit 0
fi

for shell in bash zsh ksh mksh
do
	if command -v "$shell" >/dev/null 2>&1
	then
		run_one "$shell"
	else
		printf 'SKIP: %s not found\n\n' "$shell"
	fi
done

if command -v busybox >/dev/null 2>&1
then
	run_one "busybox sh"
fi
