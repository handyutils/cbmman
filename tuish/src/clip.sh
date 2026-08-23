# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Load guard: skip re-definition if already sourced (see tui.sh).
if test -n "${_tuish_clip_loaded:-}"; then return 0; fi
_tuish_clip_loaded=1
# src/clip.sh - System clipboard (OSC 52)
# Optional module. Source after tui.sh (for _tuish_write) and ord.sh (for the
# byte tables).
#
# Provides:
#   tuish_clip_set TEXT   - copy TEXT to the system clipboard (OSC 52)
#   tuish_b64 TEXT        - base64-encode TEXT into TUISH_B64 (fork-free)
#
# WHY OSC 52 and not something else: the clipboard is the TERMINAL's, not the
# shell's. OSC 52 is the escape a terminal understands ("here is a payload, put it
# on the system clipboard"), so this works over ssh, inside tmux, and in the
# browser build alike — xterm.js exposes it via parser.registerOscHandler(52).
# tuish needs no help from the host process for any of it.
#
# ONE DIRECTION ONLY. Reading the clipboard back (the OSC 52 `?` query) is
# deliberately absent: most terminals refuse it and every browser blocks it, since
# it lets any program running in your terminal exfiltrate whatever you last copied.
# Pasting INTO an app is bracketed paste's job — the terminal pushes the text and
# tuish captures it as a `paste` event (see event.sh:_tuish_capture_paste).

_TUISH_B64_ALPHA='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

# tuish_b64 TEXT -> TUISH_B64
# Fork-free base64. compat.sh pins LC_ALL=C, so `${_s#?}` strips exactly one BYTE
# and the encoder is byte-oriented — UTF-8 payloads (emoji, CJK) encode correctly
# rather than per-character. _tuish_ord is the fork-free byte->code lookup ord.sh
# builds at init; the alphabet is indexed with ${var:off:len}, which every target
# shell has (this is a portable-shell codebase, not a strict-POSIX one).
tuish_b64 ()
{
	local _s="$1" _b1 _b2 _b3 _n
	TUISH_B64=''
	while test -n "$_s"
	do
		# Byte 1 (always present).
		_tuish_ord "${_s%"${_s#?}"}"; _b1=$_tuish_code; _s="${_s#?}"
		# Bytes 2 and 3 may be missing at the tail — that is what the padding is for.
		if test -n "$_s"
		then _tuish_ord "${_s%"${_s#?}"}"; _b2=$_tuish_code; _s="${_s#?}"; _n=2
		else _b2=0; _n=1
		fi
		if test "$_n" -eq 2 && test -n "$_s"
		then _tuish_ord "${_s%"${_s#?}"}"; _b3=$_tuish_code; _s="${_s#?}"; _n=3
		else _b3=0
		fi

		# 3 bytes (24 bits) -> 4 six-bit groups.
		TUISH_B64="${TUISH_B64}${_TUISH_B64_ALPHA:$(( _b1 >> 2 )):1}"
		TUISH_B64="${TUISH_B64}${_TUISH_B64_ALPHA:$(( ((_b1 & 3) << 4) | (_b2 >> 4) )):1}"
		if test "$_n" -ge 2
		then TUISH_B64="${TUISH_B64}${_TUISH_B64_ALPHA:$(( ((_b2 & 15) << 2) | (_b3 >> 6) )):1}"
		else TUISH_B64="${TUISH_B64}="
		fi
		if test "$_n" -eq 3
		then TUISH_B64="${TUISH_B64}${_TUISH_B64_ALPHA:$(( _b3 & 63 )):1}"
		else TUISH_B64="${TUISH_B64}="
		fi
	done
	return 0
}

# tuish_clip_set TEXT
# Copy TEXT to the system clipboard: OSC 52, selection 'c' (the CLIPBOARD selection,
# i.e. what Ctrl+V pastes), payload base64, terminated with ST.
#
# Emitted OUTSIDE the frame buffer, deliberately. This is a side-channel message to
# the terminal, not part of the picture — and the redraw path DISCARDS the pending
# buffer before a full render (event.sh: `_tuish_buf=''`). A copy action almost always
# requests a redraw too (to show "copied" in a status bar), so a clipboard write
# coalesced into the frame would be silently dropped exactly when it was wanted. Same
# reasoning as viewport.sh's structural sequences, which also bypass buffering.
#
# A terminal that does not implement OSC 52 ignores it silently — there is no reply to
# wait for and nothing to time out, so calling this is always safe.
tuish_clip_set ()
{
	tuish_b64 "$1"
	local _was=$_tuish_buffering
	_tuish_buffering=0
	_tuish_write "\033]52;c;${TUISH_B64}\033\\"
	_tuish_buffering=$_was
	return 0
}
