<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# Markdown (md.sh)

Reads markdown and emits a stream of records a renderer draws. One parse can feed
several renderers, which is the point: an HTML generator and a terminal reader can
consume the same stream and cannot drift apart, because neither is derived from the
other.

Standalone: it depends on nothing. `hl.sh` is optional — without it, fenced code
degrades to flat default-styled lines.

```sh
. ./src/hl.sh      # optional, for syntax highlighting
. ./src/md.sh
```

## Functions

| Function | Effect |
|----------|--------|
| `tuish_md_emit STYLE PAYLOAD` | The **sink**. Override it. |
| `tuish_md_begin [MODE]` | Reset. `MODE` is `post` (default) or `section`. |
| `tuish_md_feed LINE` | Feed one source line. |
| `tuish_md_end` | Flush the open block. |
| `tuish_md_file FILE [MODE]` | `begin` + read the file + `end`. |
| `tuish_md_meta KEY` | Front-matter value into `TUISH_MD_META`. |

```sh
tuish_md_emit () { tuish_buf_append content "$1	$2"; }
tuish_md_file post.md
tuish_md_meta alt
```

## The sink, and why it is not stdout

A reader has to keep the parse loop in its own shell, so a parser that *printed*
records would push every consumer into a pipeline — and a pipeline is a subshell.
Overriding one function is the trick `tui.sh` already uses for its IO stubs, and it
lets a build script stream HTML while a reader fills a line buffer, from one
parser, with no branching inside it.

The default sink prints `STYLE<TAB>PAYLOAD`, which makes the whole parser
inspectable from a shell prompt:

```sh
sh -c '. src/hl.sh; . src/md.sh; tuish_md_file post.md'
```

`tuish_md_file` reads with a **file redirect, never a pipe**, for the same reason.

## Records

| Style | Payload | Meaning |
|-------|---------|---------|
| `f` | `key<US>value` | front matter, one per key, before the body |
| `t` | plain | page title |
| `h2`…`h5` | plain | heading — the number is the **HTML** level |
| `i` | plain | byline |
| `p` | segments | paragraph |
| `b` | segments | bullet item |
| `n` | segments | ordered item (the renderer supplies the number) |
| `q` | segments | blockquote paragraph |
| `cb` | info string | a fenced block opens |
| `c` | segments | one code line |
| `g` | `alt<US>src` | image |
| `d` | plain | caption |
| `r` | *(empty)* | thematic break |
| `e` | `base<US>title<US>date` | navigable entry |

Markdown level *N* becomes HTML level *N+1*, on the assumption that `<h1>` is a
site wordmark rather than a document heading. In `post` mode the first `#` is the
page title; in `section` mode every `#` is a heading, which is what an index page
with several top-level sections wants.

A fenced block opens with `cb` and runs to the end of the `c` records that follow
it; there is no closing record. The `cb` is what a run of `c` alone cannot express:
two fences with nothing between them yield contiguous `c` records, and a renderer
watching only for runs would weld them into a single card.

## Segments

Paragraph-ish payloads are `style<US>text` fields joined by US (0x1f):

| Style | Meaning |
|-------|---------|
| `x` | plain text |
| `s` | strong |
| `e` | emphasis |
| `m` | inline code |
| `k` | link text |
| `u` | link URL |

**Block and inline styles are separate namespaces** — the block style is the field
before the TAB, inline styles live inside the payload. Block `e` (entry) and inline
`e` (emphasis) never meet. It reads like a collision and is not one.

**A link OPENS at its `u` segment** — which carries the URL — and closes at the
next plain `x` or at the end of the payload. Everything between belongs inside the
anchor, so `[use \`printf\` instead](url)` keeps its inline code:

```
u|https://example.com|k|use |m|printf|k| instead
```

Known limit of that rule: a link followed *immediately* by inline code, with no
character between — `` [text](url)`code` `` — puts the code inside the anchor,
since only a plain segment closes a link. Both renderers agree on it, so the two
forms stay consistent; it simply is not what was written. Put a space there.

The URL comes **first** so that the link's start is always detectable. With it
last, a link whose text opens with markup — `[*like this*](url)` — emitted no `k`
segment at all, leaving a renderer no way to tell where the anchor began: the
emphasis escaped the link and the anchor came out empty.

The URL is carried **raw**. HTML makes it an `href`; a terminal paints a dim
` (url)` after the text. Presentation is the renderer's business — that is exactly
what lets one parse feed both.

## What is supported

**In:** HTML comments (skipped), front matter (`---` … `---`, flat `key: value`), ATX
headings `#`–`####`, paragraphs with lazy continuation, `-`/`*`/`+` bullets, `N.`
ordered items, `>` blockquote, ``` fences with an info string, `---`/`***`/`___`
thematic breaks, `**strong**`, `*em*`, `_em_`, `` `code` ``, `[text](url)`,
`![alt](src)`, and backslash escapes.

**Out**, and how each degrades:

| Construct | Becomes |
|-----------|---------|
| **4-space indented code** | an ordinary paragraph — **fences only** |
| setext headings (`===` under text) | a paragraph; `---` becomes a rule |
| nested lists | flattened to one level |
| tables, footnotes, reference links | literal text |
| raw HTML (other than comments) | literal text |
| hard breaks (two trailing spaces) | an ordinary space |
| an unclosed marker | literal text |

Indented code blocks silently becoming paragraphs is the authoring surprise most
worth knowing about.

## Two rules that earn their keep

**`_` emphasis is boundary-gated.** Both the opener and the closer must sit against
a non-identifier byte. Without that, `snake_case_names` turns half of a technical
post into italics.

**Entry inference is off by default.** With `TUISH_MD_ENTRIES=1`, a list item whose
link points at a local document becomes an `e` record instead of a bullet:

```markdown
- [The Title](/blog/2026-01-01-00-Slug.md) — *January 1, 2026*
```

The discriminator is the link **target**, not the list shape, so a Links section in
the same document pointing at external URLs stays ordinary bullets.

It is off by default because readers typically make entries and code blocks
*mutually exclusive* focus modes — so a single accidental entry inside an article
can silently disable code-block focus for that whole page, and articles cross-link
each other constantly. Turn it on for index and list pages only.

## Comments

`<!-- … -->` is skipped wherever it appears, on one line or many — except inside a
fence, where it is code like anything else.

This is what lets a licence header sit at the top of a document. REUSE wants SPDX
tags inside a comment, and markdown's comment is HTML's:

```markdown
<!--
SPDX-FileCopyrightText: 2026 A. Name <a@example.com>

SPDX-License-Identifier: CC-BY-NC-SA-4.0
-->
---
title: …
---
```

Front matter is therefore recognised until the first **content** line rather than
strictly at line 1 — comments and blank lines do not close the window. Without
both rules a licence header would render as a paragraph reading `<!--` and take
the front matter down with it.

## Front matter

Emitted as `f` records in document order, and queryable afterwards:

```sh
tuish_md_meta alt     # -> TUISH_MD_META
echo "$TUISH_MD_KEYS" # every key seen, in order
```

Only identifier keys become variables, and the value is assigned *from* a variable
rather than interpolated, so nothing in a document can smuggle shell into the
`eval`. A non-identifier key is dropped.

With `TUISH_MD_BYLINE=1`, an `author` plus a `date` produce an `i` record right
after the title — the one blog-shaped convention in the module, which is why it is
opt-in.

## Delimiter safety

US is dropped from the source and one trailing CR is stripped, so CRLF files parse.
The guard is a single glob, so clean lines — nearly all of them — pay nothing.

**Tabs are kept.** A record is split on its *first* tab, so any further tabs inside
a payload are carried through untouched:

```sh
sty="${line%%<TAB>*}"    # shortest prefix — text before the FIRST tab
pay="${line#*<TAB>}"     # everything after it, tabs and all
```

US is the one that genuinely cannot survive: it separates fields *within* a payload
and is consumed iteratively, so one in the source would reframe the segments.

Keeping tabs is what makes a copied code snippet byte-exact. A renderer that cannot
draw one — a terminal canvas, where a raw tab jumps to the next tab stop and breaks
the layout — expands it at **paint** time, which leaves the clipboard holding what
the author actually wrote.

## Portability notes

Bracket and backtick literals inside `${…}` are written as **quoted expansions or
double-quoted literals**, never backslash-escaped. `${v%%\](*}` is a zsh parse
error, and an escaped backtick makes mksh read an unterminated command substitution
and die parsing the whole file. Neither failure is local — both take the file with
them.

This is not the "never put a pattern in a variable" trap, which is about *patterns*.
A quoted expansion is literal text by definition.

## Cost

Measured on a 300-line document with 60 fenced code lines, parsed **and**
highlighted:

| Shell | Per document |
|-------|--------------|
| dash | 8 ms |
| busybox ash | 11 ms |
| bash | 41 ms |

Real articles run about half that. The scanner is prefix-based, like `hl.sh`'s: it
locates the earliest marker by comparing prefix lengths rather than walking
characters. Link text is re-scanned without recursion — the remainder is parked,
the link's text becomes the input, and the URL is emitted when it runs out.
Markdown forbids nested links, so one level of parking is all that can be needed,
and a recursive helper would be a liability on ksh93 where a POSIX-style function's
`local` is a global.
