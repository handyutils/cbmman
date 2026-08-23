#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for bracketed-paste capture (src/event.sh).
#
# Before this, tuish recognized only the ESC[200~ / ESC[201~ MARKERS and let the body
# fall through to the key decoder — so a paste arrived as a burst of individual key
# events: a pasted newline fired the app's `enter` binding, a tab its `tab` binding,
# and each character forced its own render+flush. _tuish_capture_paste consumes the
# body instead and hands the app one atomic `paste` event with the text in TUISH_PASTE.
#
# The byte reader is stubbed so we can feed exact byte sequences without a terminal.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/ord.sh"
. "$TESTS_DIR/../src/tui.sh"
. "$TESTS_DIR/../src/term.sh"
. "$TESTS_DIR/../src/event.sh"
. "$TESTS_DIR/../src/hid.sh"
. "$TESTS_DIR/../src/keybind.sh"

printf 'Unit tests: bracketed paste capture\n'

# Feed _tuish_capture_paste a fixed byte string. _feed holds the remaining bytes;
# the stub pops one per call and fails at the end (a reader timeout).
_feed=''
_tuish_get_byte ()
{
	test -n "$_feed" || return 1
	_tuish_byte="${_feed%"${_feed#?}"}"      # first character
	_feed="${_feed#?}"                        # rest
	return 0
}

_ESC="$_tuish_chr_27"
_CR="$_tuish_chr_13"
_LF="$_tuish_chr_10"
_END="${_ESC}[201~"

# --- The newline character itself (regression) -------------------------------
# ord.sh builds its chr table with $(printf ...) on busybox/ksh93/mksh, and command
# substitution STRIPS TRAILING NEWLINES — so _tuish_chr_10 came back as the empty
# string on exactly those shells (busybox being the browser/wasm target). Nothing read
# chr_10 until paste capture needed it, and every newline assertion below would then
# compare '' against '' and pass vacuously. Assert the character is real FIRST.
assert_eq "${#_LF}" "1" "chr_10 is a real newline byte, not the empty string"
assert_eq "${#_CR}" "1" "chr_13 is a real carriage return"

# --- Plain body --------------------------------------------------------------
_feed="hello${_END}"
_tuish_capture_paste
assert_eq "$TUISH_PASTE" "hello" "body: plain text is captured verbatim"

# --- The terminator is consumed, not left in the body ------------------------
_feed="abc${_END}"
_tuish_capture_paste
assert_eq "$_feed" "" "terminator: ESC[201~ is fully consumed"

# --- Newlines: CR and CRLF both normalize to a single LF ----------------------
_feed="a${_CR}b${_END}"
_tuish_capture_paste
assert_eq "$TUISH_PASTE" "a${_LF}b" "newline: a bare CR becomes LF"

_feed="a${_CR}${_LF}b${_END}"
_tuish_capture_paste
assert_eq "$TUISH_PASTE" "a${_LF}b" "newline: CRLF collapses to ONE LF (not two)"

_feed="a${_LF}b${_END}"
_tuish_capture_paste
assert_eq "$TUISH_PASTE" "a${_LF}b" "newline: a bare LF is preserved"

# A multi-line paste is ONE event with embedded newlines — it must not be a stream
# of `enter` key events, which is exactly what the old path produced.
_feed="one${_CR}two${_CR}three${_END}"
_tuish_capture_paste
assert_eq "$TUISH_PASTE" "one${_LF}two${_LF}three" "multi-line: three lines in one body"

# --- Tabs stay tabs (they used to fire the app's `tab` binding -> 4 spaces) ---
_feed="a	b${_END}"
_tuish_capture_paste
assert_eq "$TUISH_PASTE" "a	b" "tab: a pasted TAB stays a TAB, it is not a key event"

# --- An ESC inside the body is not lost to a false terminator ----------------
# A partial terminator that turns out not to be one must be flushed back.
_feed="a${_ESC}[200Zb${_END}"
_tuish_capture_paste
assert_eq "$TUISH_PASTE" "a${_ESC}[200Zb" "false terminator: the partial match is flushed back, nothing is lost"

_feed="x${_ESC}y${_END}"
_tuish_capture_paste
assert_eq "$TUISH_PASTE" "x${_ESC}y" "false terminator: a lone ESC in the body survives"

# --- UTF-8 passes through byte-for-byte --------------------------------------
# The key decoder only understands a few lead bytes; the capture is byte-oriented,
# so anything (emoji, CJK) round-trips.
_feed="héllo 🌵${_END}"
_tuish_capture_paste
assert_eq "$TUISH_PASTE" "héllo 🌵" "utf-8: multi-byte characters survive the capture"

# --- Empty paste --------------------------------------------------------------
_feed="$_END"
_tuish_capture_paste
assert_eq "$TUISH_PASTE" "" "empty: an empty paste yields an empty body"

# --- Unterminated paste: keep what we got, do not hang -----------------------
_feed="partial"
_tuish_capture_paste
assert_eq "$TUISH_PASTE" "partial" "unterminated: a truncated paste keeps its body (reader timeout)"

# --- The event itself ---------------------------------------------------------
TUISH_PASTE='some text'
_tuish_parse_event "P"
assert_eq "$TUISH_EVENT"      "paste" 'event: class P resolves to the paste event'
assert_eq "$TUISH_EVENT_KIND" "paste" 'event: class P has kind paste'
assert_eq "$TUISH_PASTE"      "some text" "event: the body survives dispatch"

# The boundary markers still resolve, so apps tracking them keep working.
_tuish_parse_event "E 91 50 48 48 126"
assert_eq "$TUISH_EVENT" "paste-start" "compat: paste-start still resolves"
_tuish_parse_event "E 91 50 48 49 126"
assert_eq "$TUISH_EVENT" "paste-end" "compat: paste-end still resolves"

# --- Clipboard out: base64 + OSC 52 (src/clip.sh) ----------------------------
. "$TESTS_DIR/../src/clip.sh"


# Exercise the SHIPPED configuration. tuish_fnfix normally fires from tuish_init, which unit
# tests deliberately never call (they stub the device) — so without this, every suite here
# would validate the framework with its ksh `local` still leaking, i.e. not the library that
# actually runs. It is a no-op on every shell whose `local` already works.
command -v tuish_fnfix >/dev/null 2>&1 && tuish_fnfix

# RFC 4648 test vectors — every padding case.
tuish_b64 "";       assert_eq "$TUISH_B64" ""         "b64: empty"
tuish_b64 "f";      assert_eq "$TUISH_B64" "Zg=="     "b64: 1 byte  (two pad)"
tuish_b64 "fo";     assert_eq "$TUISH_B64" "Zm8="     "b64: 2 bytes (one pad)"
tuish_b64 "foo";    assert_eq "$TUISH_B64" "Zm9v"     "b64: 3 bytes (no pad)"
tuish_b64 "foob";   assert_eq "$TUISH_B64" "Zm9vYg==" "b64: 4 bytes"
tuish_b64 "fooba";  assert_eq "$TUISH_B64" "Zm9vYmE=" "b64: 5 bytes"
tuish_b64 "foobar"; assert_eq "$TUISH_B64" "Zm9vYmFy" "b64: 6 bytes"

# Byte-oriented, not character-oriented: multi-byte UTF-8 must encode as its bytes.
tuish_b64 "héllo 🌵"
assert_eq "$TUISH_B64" "aMOpbGxvIPCfjLU=" "b64: UTF-8 encodes byte-wise (matches coreutils)"

# Newlines and quotes survive — this is what carries a pasted/edited shell snippet.
tuish_b64 "a${_LF}b"
assert_eq "$TUISH_B64" "YQpi" "b64: an embedded newline encodes correctly"

# tuish_clip_set emits OSC 52, selection 'c' (the CLIPBOARD selection), ST-terminated.
# It must BYPASS the frame buffer: the redraw path discards the pending buffer before a
# full render, and a copy action almost always requests a redraw (to show "copied"), so
# a buffered clipboard write would be dropped exactly when it was wanted.
_tuish_buffering=1; _tuish_buf=''
_clip_out="$(tuish_clip_set 'foobar')"
assert_eq "$_clip_out" "$(printf '\033]52;c;Zm9vYmFy\033\\')" \
	"clip: tuish_clip_set emits OSC 52 with the base64 payload"
assert_eq "$_tuish_buf" "" \
	"clip: it bypasses the frame buffer (which a redraw would discard)"
assert_eq "$_tuish_buffering" "1" \
	"clip: it restores the caller's buffering state"
_tuish_buffering=0; _tuish_buf=''

test_summary
