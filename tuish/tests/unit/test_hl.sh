#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for src/hl.sh — the generic code highlighter

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

# hl.sh is STANDALONE: sourced alone, with no compat.sh, no ord.sh, no tui.sh.
# That is the module's contract and this line is the test of it — if hl.sh ever
# grows a tuish dependency, every case below fails at source time.
. "$TESTS_DIR/../src/hl.sh"

_US=$(printf '\037')
_NL='
'

printf 'Unit tests: hl.sh generic highlighter\n'

# Render TUISH_HL_PAY readably: US -> '|'. Keeps failure output legible.
#
# These helpers answer in a GLOBAL and are called as bare statements — never as
# `$(_pay …)`. tuish_hl_line carries /* */ state between calls, and a subshell
# would discard it, so the block-comment cases below would silently test nothing.
# The suite has to exercise the same no-subshell path production uses.
_pay () {
	tuish_hl_line "$1"
	_PAY='' _rest="$TUISH_HL_PAY"
	while test -n "$_rest"
	do
		_f="${_rest%%${_US}*}"
		case $_rest in *${_US}*) _rest="${_rest#*${_US}}";; *) _rest='';; esac
		if test -n "$_PAY"; then _PAY="$_PAY|$_f"; else _PAY="$_f"; fi
	done
	return 0
}

# Concatenate only the TEXT fields — the clipboard's view of the line.
_roundtrip () {
	tuish_hl_line "$1"
	_RT='' _rest="$TUISH_HL_PAY"
	while test -n "$_rest"
	do
		_rest="${_rest#*${_US}}"                       # drop the style field
		case $_rest in
			*${_US}*) _t="${_rest%%${_US}*}"; _rest="${_rest#*${_US}}";;
			*)        _t="$_rest"; _rest='';;
		esac
		_RT="$_RT$_t"
	done
	return 0
}

# --- strings ---
tuish_hl_begin sh
_pay 'echo "hi"'; assert_eq "$_PAY" '.|echo|O| |S|"hi"' 'string: double-quoted'
_pay "echo 'hi'"; assert_eq "$_PAY" ".|echo|O| |S|'hi'" 'string: single-quoted'
_pay 'a "x\"y" b'; assert_eq "$_PAY" '.|a|O| |S|"x\"y"|O| |.|b' 'string: escaped quote inside'
_pay 'x "unterminated'; assert_eq "$_PAY" '.|x|O| |S|"unterminated' 'string: unterminated stops at EOL'
# Shell single quotes have no escapes: the string ends at the first quote.
_pay "a '\\' b"; assert_eq "$_PAY" ".|a|O| |S|'\\'|O| |.|b" 'string: no escapes in sh single quotes'

# --- comments ---
_pay 'echo x # done'; assert_eq "$_PAY" '.|echo|O| |.|x|O| |C|# done' 'comment: hash after space'
_pay '#!/bin/sh'; assert_eq "$_PAY" 'C|#!/bin/sh' 'comment: hash at line start'
_pay 'echo "a # b"'; assert_eq "$_PAY" '.|echo|O| |S|"a # b"' 'comment: hash inside a string is not one'

# --- the three corpus-driven gates ---
tuish_hl_begin php
_pay '#[Route("/x")]'; assert_eq "$_PAY" 'O|#[|F|Route|O|(|S|"/x"|O|)]' 'gate: #[ is an attribute, not a comment'
_pay 'x; // c'; assert_eq "$_PAY" '.|x|O|; |C|// c' 'gate: // after space is a comment'
tuish_hl_begin c
_pay '#include <stdio.h>'; assert_eq "$_PAY" 'O|#|.|include|O| <|.|stdio|O|.|.|h|O|>' 'gate: # is code in the C family'
tuish_hl_begin css
_pay 'color: #4fd1c2;'; assert_eq "$_PAY" '.|color|O|: #|N|4fd1c2|O|;' 'gate: CSS hex colour is not a comment'
tuish_hl_begin sh
_pay 'docker run --rm x'; assert_eq "$_PAY" '.|docker|O| |.|run|O| --|.|rm|O| |.|x' 'gate: -- is never a comment'
_pay 'curl https://a/b'; assert_eq "$_PAY" '.|curl|O| |.|https|O|://|.|a|O|/|.|b' 'gate: https:// is not a comment'

# --- block comments carry across lines ---
tuish_hl_begin c
_pay '/* one'; assert_eq "$_PAY" 'C|/* one' 'block: opens'
assert_eq "$_tuish_hl_st" '1' 'block: state carries out of the line'
_pay 'two'; assert_eq "$_PAY" 'C|two' 'block: continues'
_pay 'three */ f(1)'; assert_eq "$_PAY" 'C|three */|O| |F|f|O|(|N|1|O|)' 'block: closes mid-line'
assert_eq "$_tuish_hl_st" '0' 'block: state cleared after close'
_pay '/* a */ b'; assert_eq "$_PAY" 'C|/* a */|O| |.|b' 'block: opens and closes on one line'

# --- classification ---
tuish_hl_begin sh
_pay 'f(1)'; assert_eq "$_PAY" 'F|f|O|(|N|1|O|)' 'class: identifier before ( is a function'
_pay 'x=0xFF'; assert_eq "$_PAY" '.|x|O|=|N|0xFF' 'class: number'
_pay 'if x; then y; fi'; assert_eq "$_PAY" 'K|if|O| |.|x|O|; |K|then|O| |.|y|O|; |K|fi' 'class: keywords'

_saved_kw=$TUISH_HL_KEYWORDS
TUISH_HL_KEYWORDS=''
_pay 'if x; fi'; assert_eq "$_PAY" '.|if|O| |.|x|O|; |.|fi' 'class: empty keyword list disables K'
TUISH_HL_KEYWORDS=$_saved_kw

# --- fence modes ---
# An apostrophe in prose must not open a string that swallows the line.
tuish_hl_begin output
_pay "--dry-run  don't delete"; assert_eq "$_PAY" ".|--dry-run  don't delete" 'mode: output is not lexed'
tuish_hl_begin diff
_pay '+added'; assert_eq "$_PAY" '+|+added' 'mode: diff added line'
_pay '-gone'; assert_eq "$_PAY" '-|-gone' 'mode: diff removed line'
_pay ' same'; assert_eq "$_PAY" '.| same' 'mode: diff context line'

# --- the round-trip invariant: segments must reconstruct the source byte-exact,
#     because the reader rebuilds code from them for the clipboard ---
tuish_hl_begin sh
for _line in \
	'echo "hi" # done' \
	'    indentation   preserved' \
	'x=1; y=0xFF; f(2)' \
	'unterminated "string' \
	'acentuação com emoji 🎉' \
	'a="x\"y" b'
do
	_roundtrip "$_line"; assert_eq "$_RT" "$_line" "roundtrip: $_line"
done
# Tabs must survive unexpanded — expanding them here would corrupt every paste.
_tabline="$(printf 'a\tb\tc')"
_roundtrip "$_tabline"; assert_eq "$_RT" "$_tabline" 'roundtrip: tabs are not expanded'
_roundtrip ''; assert_eq "$_RT" '' 'roundtrip: empty line'

# --- whitespace-only text is kept (indentation), only "" is dropped ---
_pay '   '; assert_eq "$_PAY" 'O|   ' 'segments: whitespace-only line is kept'

# --- non-ASCII is punctuation under a byte locale: accented BARE identifiers split
#     into operator runs. Pinned so the behaviour is a decision, not a surprise.
#     Prose in real code blocks lives in comments/strings/output fences, which are
#     consumed whole, so this never shows up there.
_pay 'acentuação'; assert_eq "$_PAY" '.|acentua|O|çã|.|o' 'segments: accented identifier splits'
_pay '# acentuação'; assert_eq "$_PAY" 'C|# acentuação' 'segments: accented text in a comment is intact'
_pay '"acentuação"'; assert_eq "$_PAY" 'S|"acentuação"' 'segments: accented text in a string is intact'

test_summary
