# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Load guard: skip re-definition if already sourced (see tui.sh).
if test -n "${_tuish_buf_loaded:-}"; then return 0; fi
_tuish_buf_loaded=1
# src/buf.sh - Line buffer with index-based operations
# Optional module. Source after compat.sh.
#
# Every operation names its buffer explicitly (line indices are 1-based):
#   tuish_buf_init BUF              - (re)initialize BUF to a single empty line
#   tuish_buf_count BUF            - load BUF's line count into TUISH_BUF_COUNT
#   tuish_buf_get BUF IDX         - line at IDX -> TUISH_BLINE
#   tuish_buf_set BUF IDX VAL     - set line at IDX
#   tuish_buf_append BUF VAL      - append a line
#   tuish_buf_insert_at BUF IDX VAL - insert at IDX, shifting the rest down
#   tuish_buf_delete_at BUF IDX     - delete IDX, shifting the rest up
#
# BUF is any identifier; pass '_' when one ad-hoc buffer is enough. Buffers are
# independent. TUISH_BUF_COUNT and TUISH_BLINE are output registers, never
# storage: lines live in _tuish_buf_<BUF>_<IDX>, counts in _tuish_bufcount_<BUF>.
# A mutation also refreshes TUISH_BUF_COUNT with the touched buffer's new count.
#
# Dependencies: none

TUISH_BUF_COUNT=0

tuish_buf_count ()   # BUF
{
	# `:-0` so counting a never-touched buffer is 0, not a set -u abort.
	eval "TUISH_BUF_COUNT=\${_tuish_bufcount_$1:-0}"
}

tuish_buf_get ()   # BUF IDX
{
	# `:-` so an out-of-range index (e.g. a mouse click/selection past the last
	# line) yields an empty line instead of aborting the whole app under set -u.
	eval "TUISH_BLINE=\"\${_tuish_buf_${1}_$2:-}\""
}

tuish_buf_set ()   # BUF IDX VAL
{
	eval "_tuish_buf_${1}_$2=\"\$3\""
}

tuish_buf_append ()   # BUF VAL
{
	local _c
	eval "_c=\${_tuish_bufcount_$1:-0}"   # auto-create: first append starts at 0
	_c=$((_c + 1))
	eval "_tuish_bufcount_$1=$_c"
	eval "_tuish_buf_${1}_$_c=\"\$2\""
	TUISH_BUF_COUNT=$_c
}

tuish_buf_init ()   # BUF
{
	eval "_tuish_bufcount_$1=0"
	tuish_buf_append "$1" ''
}

tuish_buf_insert_at ()   # BUF IDX VAL
{
	local _c _i
	eval "_c=\$_tuish_bufcount_$1"
	_i=$_c
	_c=$((_c + 1))
	eval "_tuish_bufcount_$1=$_c"
	while test $_i -ge $2
	do
		eval "_tuish_buf_${1}_$((_i + 1))=\"\$_tuish_buf_${1}_$_i\""
		_i=$((_i - 1))
	done
	eval "_tuish_buf_${1}_$2=\"\$3\""
	TUISH_BUF_COUNT=$_c
}

tuish_buf_delete_at ()   # BUF IDX
{
	local _c _i
	eval "_c=\$_tuish_bufcount_$1"
	_i=$2
	while test $_i -lt $_c
	do
		eval "_tuish_buf_${1}_$_i=\"\$_tuish_buf_${1}_$((_i + 1))\""
		_i=$((_i + 1))
	done
	_c=$((_c - 1))
	eval "_tuish_bufcount_$1=$_c"
	TUISH_BUF_COUNT=$_c
}
