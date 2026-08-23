<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# Code Highlighting (hl.sh)

A single language-agnostic lexer. Turns one line of code into a segmented payload
of `style<US>text` fields that a renderer paints.

Standalone: it depends on nothing, not even `compat.sh`.

```sh
. ./src/hl.sh
```

## Functions

| Function | Effect |
|----------|--------|
| `tuish_hl_begin [INFO]` | Start a code block. `INFO` is the fence info string. |
| `tuish_hl_line LINE` | Lex one line into `TUISH_HL_PAY`. |
| `tuish_hl_end` | Drop the carried state. |

`TUISH_HL_KEYWORDS` is the keyword set (see below). Everything else is internal.

```sh
tuish_hl_begin sh
while IFS= read -r line
do
    tuish_hl_line "$line"
    render "$TUISH_HL_PAY"
done < code.txt
```

## Never call it in a subshell

`/* */` carries across lines in `_tuish_hl_st`. Writing

```sh
pay=$(tuish_hl_line "$line")      # WRONG
```

throws that state away with the subshell, so every block comment silently reopens
on the next line. That is why the result is a register and not stdout — the same
reason `str.sh` answers in `TUISH_SWIDTH`.

## Token styles

| Style | Meaning |
|-------|---------|
| `.` | default — identifiers, and anything unclassified |
| `S` | string |
| `C` | comment |
| `N` | number |
| `O` | operator, punctuation, whitespace |
| `F` | function — an identifier immediately before `(` |
| `K` | keyword |
| `+` `-` | added/removed line, `diff` fences only |

Adjacent segments of the same style are merged, which keeps a typical line at four
to eight segments rather than one per token.

## What the info string does

It does **not** select a grammar. There is one lexer. The info string flips three
rules that genuinely disagree between language families, once per block:

| Info string | `#` comment | `//` `/* */` | `\` in `'…'` | lexed |
|---|---|---|---|---|
| *(empty)*, `sh`, `bash`, `python`, `make`, `yaml`, … | yes | yes | no | yes |
| `c`, `js`, `php`, `css`, `json`, `go`, `rust`, … | **no** | yes | yes | yes |
| `diff`, `patch` | no | no | — | line-level |
| `output`, `text`, `log`, `console`, `plain`, … | no | no | — | **no** |

Three gates exist because real code breaks without them:

- `#` opens a comment only at line start or after whitespace, and never before `[`
  — otherwise PHP's `#[Route(...)]` loses the rest of its line.
- `//` does not open a comment after `:` — otherwise every `https://` in a code
  block turns green from the colon onward.
- `--` is never a comment. `docker run --rm` and `--dry-run` are ordinary code.

An **unlabelled** fence defaults to the shell family, so an unlabelled C or CSS
block will mis-colour its `#` lines. Label the fence.

`output` is not a nicety. Program output is not source, and lexing it is worse than
useless: one apostrophe in `don't actually delete anything` opens a string that runs
to the end of the line.

## Keywords

A generic lexer has no grammar to ask, so `TUISH_HL_KEYWORDS` is one shared list
for every language — space-delimited on both sides, looked up with a single `case`
glob, the same idiom as `compat.sh`'s `_tuish_fnfix_skip`.

```sh
TUISH_HL_KEYWORDS=''      # emit no K at all
```

The trade is deliberate. Without it, `K` — the most visible colour in the palette —
is never emitted and code reads flat. With it, a variable literally named `type` or
`class` gets keyword colour.

## The round-trip invariant

Concatenating a line's segment *texts* reproduces the source line **byte for byte**.
Readers rebuild code from these segments to put it on the clipboard, so anything
this module changed — expanding tabs, trimming indentation — would corrupt every
paste. Whitespace-only text is kept; only `""` is dropped.

The unit suite asserts this over tabs, UTF-8, emoji and unterminated strings.

## Two portability rules worth knowing

**Bracket patterns are written literally, never stored in a variable.**
`${s%%$PAT*}` matches on bash, mksh, dash and busybox, and on zsh silently *does
not* — it needs `${~PAT}` and otherwise returns the whole string. The lexer would
emit one giant token per line and merely look unhighlighted.

**The character classes are enumerated, not ranges.** POSIX leaves range behaviour
outside the C locale unspecified, and ksh93 honours that: in a UTF-8 locale it
collates `ç` inside `A-Za-z`. Since a build script may render HTML in the machine's
own locale while a reader runs under `compat.sh`'s `LC_ALL=C`, a collation-dependent
class would let two renderers disagree about the same line. Enumeration is
locale-proof and costs nothing — it is still one expansion.

## Cost

The hot loop advances by **runs, not characters**: one parameter expansion yields a
maximal identifier run, its complement yields the punctuation run.

Measured on a 1083-line corpus:

| Shell | Time | Per line |
|-------|------|----------|
| dash | 30 ms | ~28 µs |
| busybox ash | 50 ms | ~46 µs |
| bash | 160 ms | ~148 µs |

The equivalent per-character loop measures about 13× worse. If you touch this
module, keep it run-based — that ratio is the difference between a page that opens
instantly and one that visibly hitches.

Under a byte locale a UTF-8 byte is not an identifier character, so an accented
*bare identifier* splits into operator-coloured runs (`acentuação` becomes
`acentua` + `çã` + `o`). This is deliberate: prose inside code blocks lives in
comments, strings or unlexed output fences, all consumed whole before the tokenizer
sees them, and the round-trip invariant holds either way — only the colour is odd,
never the text.
