#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for src/md.sh — the markdown reader

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

# md.sh is STANDALONE: sourced alone, with no compat.sh, no ord.sh, no tui.sh.
# hl.sh is optional, and the "degrades without hl.sh" case below proves it — so it
# is sourced LAST, after that case has run.
. "$TESTS_DIR/../src/md.sh"

_US=$(printf '\037')
# Records end in "STYLE<TAB>PAYLOAD", so an empty payload leaves a TRAILING TAB.
# Spelled out wherever one occurs: trailing whitespace in a literal is invisible,
# and an editor that trims it would break the assertion for no visible reason.
_T=$(printf '\011')

printf 'Unit tests: md.sh markdown reader\n'

# Collect records into _REC, one "style<TAB>payload" per line with US shown as '|'.
#
# The sink and the drivers answer in GLOBALS and are called as bare statements,
# never as `$(…)`. md.sh carries block state across tuish_md_feed calls, and a
# subshell would discard it — the lazy-continuation and fence cases below would
# then silently test nothing.
_REC=''
tuish_md_emit () {
	_e_p="$2"
	_e_o=''
	while test -n "$_e_p"
	do
		case $_e_p in
			*${_US}*) _e_o="$_e_o${_e_p%%${_US}*}|"; _e_p="${_e_p#*${_US}}" ;;
			*)        _e_o="$_e_o$_e_p"; _e_p='' ;;
		esac
	done
	_REC="$_REC$1	$_e_o
"
}

# _feed MODE LINE... — parse a document given as separate arguments.
_feed () {
	_f_mode=$1; shift
	_REC=''
	tuish_md_begin "$_f_mode"
	for _f_l in "$@"; do tuish_md_feed "$_f_l"; done
	tuish_md_end
	return 0
}

# _one MODE LINE — parse one line and strip the trailing newline.
_one () {
	_feed "$1" "$2"
	_ONE="${_REC%
}"
	return 0
}

# --- degradation without hl.sh (must run BEFORE hl.sh is sourced) ------------
_feed post '```sh' 'echo "hi"' '```'
assert_eq "$_REC" "cb${_T}sh
c${_T}.|echo \"hi\"
" 'code: degrades to flat default segments without hl.sh'

. "$TESTS_DIR/../src/hl.sh"

_feed post '```sh' 'echo "hi"' '```'
assert_eq "$_REC" "cb${_T}sh
c${_T}.|echo|O| |S|\"hi\"
" 'code: lexed once hl.sh is present'

# --- headings: markdown level N becomes HTML level N+1 -----------------------
_one post '# Title';    assert_eq "$_ONE" 't	Title'    'heading: # is the title in post mode'
_one post '## Section'; assert_eq "$_ONE" 'h3	Section' 'heading: ## is h3 in post mode'
_one post '### Sub';    assert_eq "$_ONE" 'h4	Sub'     'heading: ### is h4'
_one post '#### Deep';  assert_eq "$_ONE" 'h5	Deep'    'heading: #### is h5'
_one section '# About'; assert_eq "$_ONE" 'h2	About'   'heading: # is h2 in section mode'

# Only the FIRST # is the title; a second one is an ordinary heading.
_feed post '# One' '' '# Two'
assert_eq "$_REC" 't	One
h2	Two
' 'heading: only the first # becomes the title'

# --- inline ------------------------------------------------------------------
_one post 'a **b** c';  assert_eq "$_ONE" 'p	x|a |s|b|x| c'  'inline: strong'
_one post 'a *b* c';    assert_eq "$_ONE" 'p	x|a |e|b|x| c'  'inline: emphasis'
_one post 'a `b` c';    assert_eq "$_ONE" 'p	x|a |m|b|x| c'  'inline: code'
_one post 'a _b_ c';    assert_eq "$_ONE" 'p	x|a |e|b|x| c'  'inline: underscore emphasis'

# The rule that keeps a shell blog readable.
_one post 'snake_case_names stay'
assert_eq "$_ONE" 'p	x|snake_case_names stay' 'inline: underscores inside a word are literal'

_one post '[t](u)';     assert_eq "$_ONE" 'p	u|u|k|t'        'inline: link, URL first'
_one post 'see [use `printf` here](http://x) ok'
assert_eq "$_ONE" 'p	x|see |u|http://x|k|use |m|printf|k| here|x| ok' 'inline: code inside link text'
# The URL comes FIRST so a link whose text opens with markup still has a
# detectable start. Emitting it last left this one with no 'k' segment at all.
_one post '[*Reflections*](http://x) after'
assert_eq "$_ONE" 'p	u|http://x|e|Reflections|x| after' 'inline: link text starting with emphasis'
_one post '[](http://x)'
assert_eq "$_ONE" 'p	u|http://x|k|http://x' 'inline: empty link text falls back to the URL'

# Unclosed markers degrade to literal text rather than eating the line.
_one post 'a **b';  assert_eq "$_ONE" 'p	x|a **b'  'inline: unclosed strong is literal'
_one post 'a `b';   assert_eq "$_ONE" 'p	x|a `b'   'inline: unclosed code is literal'
_one post 'a [b';   assert_eq "$_ONE" 'p	x|a [b'   'inline: unclosed link is literal'
_one post 'a [b](c'; assert_eq "$_ONE" 'p	x|a [b](c' 'inline: link with no closing paren is literal'

# Backslash escapes.
_one post 'a \*not em\* b'
assert_eq "$_ONE" 'p	x|a *not em* b' 'inline: escaped markers are literal'
_one post 'Respect\Validation'
assert_eq "$_ONE" 'p	x|Respect\Validation' 'inline: a lone backslash survives'

# --- blocks ------------------------------------------------------------------
_one post '- item';    assert_eq "$_ONE" 'b	x|item' 'block: bullet'
_one post '* item';    assert_eq "$_ONE" 'b	x|item' 'block: bullet with *'
_one post '1. item';   assert_eq "$_ONE" 'n	x|item' 'block: ordered item'
_feed post '> quoted'
assert_eq "$_REC" "qb${_T}
q${_T}x|quoted
" 'block: blockquote'
_one post '***';       assert_eq "$_ONE" 'r	'       'block: thematic break with *'
# A bare --- opens front matter while it is still the first content line, so a
# rule needs something above it.
_feed post 'text' '' '---'
assert_eq "$_REC" "p${_T}x|text
r${_T}
" 'block: thematic break with -'
_one post '![alt](/i/x.png)'
assert_eq "$_ONE" 'g	alt|/i/x.png' 'block: standalone image'

# A one-level nested list flattens rather than erroring.
_one post '  - nested'; assert_eq "$_ONE" 'b	x|nested' 'block: nested list flattens'

# Lazy continuation: consecutive lines join into one paragraph.
_feed post 'one' 'two' '' 'three'
assert_eq "$_REC" 'p	x|one two
p	x|three
' 'block: lazy continuation, blank line separates'

# A blockquote spanning two lines is one record.
_feed post '> a' '> b'
assert_eq "$_REC" "qb${_T}
q${_T}x|a b
" 'block: blockquote continuation'

# A blank line inside a fence stays inside it — it must NOT close the block, or a
# code sample with a blank line would split into two cards.
_feed post '```' 'a' '' 'b' '```'
assert_eq "$_REC" "cb${_T}
c${_T}.|a
c${_T}
c${_T}.|b
" 'code: a blank line inside a fence stays in the block'

# Markdown syntax inside a fence is not markdown. Uses an unlexed fence so this
# tests md.sh's block handling rather than the lexer's token choices.
_feed post '```text' '# not a heading' '- not a bullet' '```'
assert_eq "$_REC" "cb${_T}text
c${_T}.|# not a heading
c${_T}.|- not a bullet
" 'code: block markup inside a fence is code'

# --- block boundaries: the reason cb/qb exist -------------------------------
# Two fences with nothing between them are TWO blocks. Their 'c' records are
# contiguous, so without 'cb' a renderer watching for runs would weld them.
_feed post '```text' 'a' '```' '```text' 'b' '```'
assert_eq "$_REC" "cb${_T}text
c${_T}.|a
cb${_T}text
c${_T}.|b
" 'boundary: adjacent fences stay separate'

# Likewise two quotes separated by a blank line.
_feed post '> a' '' '> b'
assert_eq "$_REC" "qb${_T}
q${_T}x|a
qb${_T}
q${_T}x|b
" 'boundary: adjacent blockquotes stay separate'

# ...while a bare '>' separates paragraphs INSIDE one quote: one qb, two q.
_feed post '> a' '>' '> b'
assert_eq "$_REC" "qb${_T}
q${_T}x|a
q${_T}x|b
" 'boundary: one quote with two paragraphs'

# --- caption -----------------------------------------------------------------
_feed post '![alt](/i/x.png)' '' '*The caption.*'
assert_eq "$_REC" 'g	alt|/i/x.png
d	The caption.
' 'caption: an italic paragraph under an image'
# ...but only under an image.
_feed post 'text' '' '*Just italic.*'
assert_eq "$_REC" 'p	x|text
p	e|Just italic.
' 'caption: an italic paragraph elsewhere stays a paragraph'

# --- HTML comments ----------------------------------------------------------
# A licence header is a comment, and it sits ABOVE the front matter — so both the
# comment skipping and the relaxed front-matter window are load-bearing here.
_feed post '<!--' 'SPDX-License-Identifier: CC-BY-NC-SA-4.0' '-->' '---' 'alt: x' '---' '# T'
assert_eq "$_REC" "f${_T}alt|x
t${_T}T
" 'comment: a licence header above the front matter'

_one post '<!-- one line -->'
assert_eq "$_ONE" '' 'comment: single-line is skipped'

_feed post 'before' '' '<!--' 'hidden' '-->' '' 'after'
assert_eq "$_REC" "p${_T}x|before
p${_T}x|after
" 'comment: multi-line in the middle of prose'

# ...but a comment inside a fence is CODE, not a comment.
_feed post '```text' '<!-- kept -->' '```'
assert_eq "$_REC" "cb${_T}text
c${_T}.|<!-- kept -->
" 'comment: inside a fence it stays code'

# --- front matter ------------------------------------------------------------
_feed post '---' 'alt: other-slug.pt' 'date: July 21, 2026' '---' '# T'
assert_eq "$_REC" 'f	alt|other-slug.pt
f	date|July 21, 2026
t	T
' 'front matter: emitted as f records'
tuish_md_meta alt;  assert_eq "$TUISH_MD_META" 'other-slug.pt' 'front matter: meta lookup'
tuish_md_meta date; assert_eq "$TUISH_MD_META" 'July 21, 2026' 'front matter: value keeps its colons and spaces'
tuish_md_meta nope; assert_eq "$TUISH_MD_META" '' 'front matter: absent key is empty'

# Only before any content — a --- further down is a thematic break.
_feed post 'text' '' '---' 'alt: x' '---'
assert_contains "$_REC" 'r	' 'front matter: --- below line 1 is a rule'

# A key that is not an identifier is ignored rather than eval'd.
_feed post '---' 'bad key; rm -rf /: x' 'ok: y' '---'
assert_eq "$_REC" 'f	ok|y
' 'front matter: a non-identifier key is dropped, not evaluated'

# Front matter must NOT leak into the next document parsed. These modules are used
# by build scripts that walk a whole directory in one process.
_feed post '---' 'author: A. Name' 'date: July 21, 2026' '---' '# T'
_feed post '# Second document with no front matter at all'
tuish_md_meta author; assert_eq "$TUISH_MD_META" '' 'front matter: cleared between documents'
tuish_md_meta date;   assert_eq "$TUISH_MD_META" '' 'front matter: date cleared too'
assert_eq "$TUISH_MD_KEYS" '' 'front matter: key list cleared'

# ...and the byline that reads it must not appear on a document that has none.
TUISH_MD_BYLINE=1
_feed post '---' 'author: A. Name' 'date: July 21, 2026' '---' '# T'
_feed post '# Bare'
case $_REC in *"i${_T}"*) assert_eq 'byline leaked' 'no byline' 'byline: not carried into the next document';;
              *) assert_eq 'no byline' 'no byline' 'byline: not carried into the next document';; esac
TUISH_MD_BYLINE=0

# --- byline ------------------------------------------------------------------
TUISH_MD_BYLINE=1
_feed post '---' 'author: A. Name' 'date: July 21, 2026' '---' '# T'
assert_contains "$_REC" 'i	A. Name – July 21, 2026' 'byline: emitted after the title'
TUISH_MD_BYLINE=0
_feed post '---' 'author: A. Name' 'date: July 21, 2026' '---' '# T'
case $_REC in *'i	'*) assert_eq 'emitted' 'absent' 'byline: off by default';; *) assert_eq 'absent' 'absent' 'byline: off by default';; esac

# --- entries -----------------------------------------------------------------
TUISH_MD_ENTRIES=1
_one section '- [The Title](/blog/2026-01-01-00-Slug.md) — *January 1, 2026*'
assert_eq "$_ONE" 'e	2026-01-01-00-Slug|The Title|January 1, 2026' 'entry: local post link'
_one section '- [*More entries...*](/blog.md)'
assert_eq "$_ONE" 'e	@blog|More entries...|' 'entry: the list sentinel'
_one section '- [x](/blog/2026-01-01-00-S.pt.md) — *1 de Janeiro*'
assert_eq "$_ONE" 'e	2026-01-01-00-S.pt|x|1 de Janeiro' 'entry: the .pt basename is kept'
# An external link in the same list shape stays a bullet — the target decides.
_one section '- [github.com/x](https://github.com/x) — Work.'
assert_eq "$_ONE" 'b	u|https://github.com/x|k|github.com/x|x| — Work.' 'entry: an external link stays a bullet'

# With entries OFF, the very same line is an ordinary bullet. This is the scoping
# that keeps a cross-linking post from losing its code-block focus.
TUISH_MD_ENTRIES=0
_one post '- [The Title](/blog/2026-01-01-00-Slug.md) — *January 1, 2026*'
assert_eq "$_ONE" 'b	u|/blog/2026-01-01-00-Slug.md|k|The Title|x| — |e|January 1, 2026' 'entry: inference is off by default'

# --- delimiter safety --------------------------------------------------------
# A TAB is KEPT: records split on the first one, so a payload carries the rest
# through untouched, and that is what makes a copied snippet byte-exact.
_one post "$(printf 'a\tb')"
assert_eq "$_ONE" "p${_T}x|a${_T}b" 'safety: a source TAB is preserved'
# ...and it really does survive a first-tab split.
_one post "$(printf 'a\tb')"
_sty="${_ONE%%${_T}*}"; _pay="${_ONE#*${_T}}"
assert_eq "$_sty" 'p' 'safety: style still splits off correctly with a TAB in the payload'
assert_eq "$_pay" "x|a${_T}b" 'safety: the payload keeps its TAB'
_one post "$(printf 'a\037b')"
assert_eq "$_ONE" 'p	x|ab' 'safety: a source US is dropped'
_one post "$(printf 'a\015')"
assert_eq "$_ONE" 'p	x|a' 'safety: a trailing CR is stripped'

test_summary
