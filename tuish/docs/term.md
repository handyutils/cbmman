<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# Terminal Output (term.sh)

Drawing primitives for cursor movement, text output, colors, text attributes,
screen clearing, and scroll regions. Source after `tui.sh`.

```sh
. ./src/tui.sh
. ./src/term.sh
```

## Cursor Positioning

| Function               | Description                                                                                 |
|------------------------|---------------------------------------------------------------------------------------------|
| `tuish_move ROW COL`   | Move cursor to absolute position (1-based)                                                  |
| `tuish_vmove ROW COL`  | Move cursor relative to the viewport's top *and left* (1-based)                             |
| `tuish_move_up [N]`    | Move cursor up N rows (default: 1)                                                          |
| `tuish_move_down [N]`  | Move cursor down N rows (default: 1)                                                        |
| `tuish_move_right [N]` | Move cursor right N columns (default: 1)                                                    |
| `tuish_move_left [N]`  | Move cursor left N columns (default: 1)                                                     |
| `tuish_cursor ROW COL` | Move to viewport-relative position, show cursor, and record position for rAF cursor-restore |

`tuish_vmove` applies both a row origin (`TUISH_VIEW_TOP`) and a column origin
(`TUISH_VIEW_LEFT`), so it -- and everything built on it (`tuish_print_at`,
`tuish_text`, `tuish_cursor`, `tuish_clear_region`, and the draw primitives in
[draw.md](draw.md)) -- is relative to the viewport's top *and* left. For the
root context `TUISH_VIEW_LEFT` is 0, so nothing changes standalone; a hosted
child gets its region's left edge as logical column 1
(see [hosting.md](hosting.md)).

## Cursor Shape

| Function               | Description                                                     |
|------------------------|-----------------------------------------------------------------|
| `tuish_cursor_shape N` | **Declare** this context's caret shape (DECSCUSR). Writes nothing |

| N            | Shape              |
|--------------|--------------------|
| `0` (or none)| No opinion         |
| 1            | Blinking block     |
| 2            | Steady block       |
| 3            | Blinking underline |
| 4            | Steady underline   |
| 5            | Blinking bar       |
| 6            | Steady bar         |

Three things to know, because the shape does not behave like an escape you send:

- **It declares; it does not write.** The shape is part of the caret, like its position and
  its visibility, and like them it is re-declared every frame. `tuish_cursor` emits it.
- **No caret, no shape.** A context that never shows a caret never sends a DECSCUSR, so it
  cannot change the shape under an app that did.
- **`0` means *no opinion*, not "send DECSCUSR 0".** You inherit whatever the device has.
  The only DECSCUSR 0 this toolkit sends is at device teardown, restoring the terminal for
  the reader — and only if an app actually changed the shape.

Declare a shape in your setup and forget about it. It survives being hosted, being scrolled
off screen and back, and sharing a terminal with other widgets: see
[hosting.md](hosting.md#the-caret).

## Output

| Function                                       | Description                                                                         |
|------------------------------------------------|-------------------------------------------------------------------------------------|
| `tuish_print TEXT`                             | Print text at cursor position (backslashes and `%` signs are escaped automatically) |
| `tuish_text ROW COL TEXT [fg= bg= maxwidth= width=]` | Viewport/canvas-relative move + colored, width-clipped print (see below)       |
| `tuish_print_at ROW COL TEXT`                  | Convenience alias for `tuish_text ROW COL TEXT` (no color/width options)             |
| `tuish_put_at ROW COL TEXT`                    | Fast place-and-print: no display-width clipping (see below)                          |
| `tuish_newline`                                | Output newline + carriage return                                                    |

### tuish_text ROW COL TEXT [fg=N] [bg=N] [maxwidth=N] [width=N]

The single text-placement entry point. Moves to viewport- (or canvas-) relative
`(ROW, COL)` and prints `TEXT`, optionally colored (`fg=`/`bg=`, same color forms
as `tuish_fg`) and width-limited. It honors the active canvas transform and trims
text to the display width that fits the visible window (including trimming leading
cells when `COL` falls left of column 1). SGR is reset only when a color was
applied, so the plain `tuish_text R C "x"` form is a pure place-and-print.

Width-aware clipping requires `str.sh`; in the minimal profile without it,
`tuish_text` still places and colors the text and lets the terminal clip at the
screen edge.

**Every width here is display columns, never characters.** `maxwidth=6` on CJK
means three ideographs, not six. A wide glyph that would straddle the right cut is
dropped rather than split, so a clip against an odd budget can come back one column
short — short is correct, because half a wide glyph corrupts the cell beside it.

```sh
tuish_text 3 5 "Hello"                       # plain placement
tuish_text 1 1 "$status" fg=2 maxwidth=20    # green, capped at 20 display columns
```

#### width=N — fields, and why not to erase first

`maxwidth=N` caps the text. `width=N` makes it a **field**: exactly N columns,
space-padded when the text is shorter, in a single run.

The idiom it replaces is erase-then-print — `tuish_clear_to_edge` (or a
`tuish_draw_fill`) over the area, then the text on top of it:

```sh
tuish_clear_to_edge $row 1                   # two passes over the same cells,
tuish_text $row 1 "$status"                  # with a blank state in between

tuish_text $row 1 "$status" width=$TUISH_VIEW_COLS   # one pass, no blank state
```

Two passes is where a lot of "my TUI blinks" comes from: between the erase and the
print, the field is genuinely empty, and any terminal that renders mid-frame shows
you that. `width=N` never produces the empty state, and the padding carries `bg=`
just like the text does — so a colored field no longer needs a fill underneath it
either. It is also cheaper: measured at ~152 µs against ~223 µs for the erase-then-
print pair.

The pad is clipped like everything else, so a field wider than the region stops at
the region's edge instead of padding through a host's border.

### tuish_put_at ROW COL TEXT

The fast path for callers that already know `TEXT` fits its cell: position via
`tuish_vmove` (which still clips off-screen cells) and print, skipping the
display-width computation `tuish_text`/`tuish_print_at` run per call. Use it
for fixed-size sprites/glyphs or pre-clipped slices in render loops; there is
no right-edge trimming, so text wider than the remaining columns is the
caller's responsibility.

## Erase

| Function                         | Description                                                                                                         |
|----------------------------------|---------------------------------------------------------------------------------------------------------------------|
| `tuish_clear_screen`             | Erase entire screen (**not region-safe**)                                                                           |
| `tuish_clear_line`               | Erase entire current line (**not region-safe**)                                                                     |
| `tuish_clear_to_eol`             | Erase from cursor to end of line (**not region-safe**)                                                              |
| `tuish_clear_to_bol`             | Erase from cursor to beginning of line (**not region-safe**)                                                        |
| `tuish_clear_to_edge ROW [COL]`  | Erase logical ROW from COL (default 1) rightward to the edge of the drawable area                                   |
| `tuish_clear_region ROW COL W H` | Clear a rectangular area by writing spaces (no color; for colored fill see `tuish_draw_fill` in [draw.md](draw.md)) |

> **`tuish_clear_screen`, `tuish_clear_line`, `tuish_clear_to_eol` and
> `tuish_clear_to_bol` are not region-safe.** They emit the raw `ESC[2J` /
> `ESC[2K` / `ESC[K` / `ESC[1K` sequences, which act on the **physical**
> terminal screen or line: they ignore the
> viewport and a hosted region, so from inside an embedded app they erase
> straight through into the host's chrome (an embedded editor's `ESC[K` will
> eat the host's box border). Code that may ever run hosted must use
> `tuish_clear_to_edge` or `tuish_clear_region` instead. The raw forms remain
> the cheapest possible erase for root-owned, full-width apps.

### tuish_clear_to_edge ROW [COL]

Erases logical `ROW` from `COL` (default 1) rightward to the edge of the
**drawable area** -- the viewport standalone, the region when hosted. It is
bounded by `TUISH_VIEW_COLS` (falling back to `TUISH_COLUMNS` when no viewport
is set), so it degrades to exactly the old full-width behavior standalone.

Because it *erases* rather than trims, the idiom is **clear first, then print**
-- the reverse of the old print-then-`ESC[K`. An SGR set before the call (e.g.
`tuish_reverse`) colors the padding, which is how a full-width reverse
status/header bar is drawn.

```sh
tuish_reverse
tuish_clear_to_edge $TUISH_VIEW_ROWS      # reverse-video padding to the edge
tuish_print_at $TUISH_VIEW_ROWS 1 " status "
tuish_sgr_reset
```

## Scrolling

| Function                      | Description                              |
|-------------------------------|------------------------------------------|
| `tuish_scroll_region TOP BOT` | Set scroll region (rows TOP through BOT) |
| `tuish_scroll_up`             | Scroll content up one line               |
| `tuish_scroll_down`           | Scroll content down one line             |
| `tuish_scroll_up_n N`         | Scroll content up N lines                |
| `tuish_scroll_down_n N`       | Scroll content down N lines              |

Reset the scroll region with `tuish_reset_scroll` (defined in tui.sh).

## Alternate Screen

| Function              | Description                              |
|-----------------------|------------------------------------------|
| `tuish_altscreen_on`  | Switch to alternate screen buffer        |
| `tuish_altscreen_off` | Switch back from alternate screen buffer |

## Text Attributes

| Function              | SGR Code | Description                     |
|-----------------------|----------|---------------------------------|
| `tuish_bold`          | 1        | Bold / increased intensity      |
| `tuish_dim`           | 2        | Dim / decreased intensity       |
| `tuish_italic`        | 3        | Italic                          |
| `tuish_underline`     | 4        | Underline                       |
| `tuish_blink`         | 5        | Blink                           |
| `tuish_reverse`       | 7        | Reverse video (swap fg/bg)      |
| `tuish_strikethrough` | 9        | Strikethrough                   |
| `tuish_sgr CODE`      | any      | Set arbitrary SGR attribute     |
| `tuish_sgr_reset`     | 0        | Reset all attributes and colors |

Attributes are cumulative until `tuish_sgr_reset` is called.

### Combined Style

| Function                            | Description                                     |
|-------------------------------------|-------------------------------------------------|
| `tuish_style [attrs] [fg=N] [bg=N]` | Reset + apply attributes and colors in one call |

Accepts any combination of attribute names (`bold`, `dim`, `italic`, `underline`,
`blink`, `reverse`, `strikethrough`) and `fg=`/`bg=` color values. Colors accept
0-7 (basic), 8-15 (bright), 16-255 (256-palette), or `R:G:B` (truecolor).

```sh
tuish_style bold fg=1              # bold red
tuish_style italic underline fg=45 bg=0  # italic underlined magenta on black
tuish_style fg=255:128:0           # truecolor orange foreground
```

### Sequence Builders (batched rendering)

Each writer above has a `*_seq` twin that builds the SGR escape into the
variable `TUISH_SEQ` instead of writing it:

| Function                                | Builds                                    |
|-----------------------------------------|-------------------------------------------|
| `tuish_fg_seq VALUE`                    | Foreground color (same forms as `tuish_fg`) |
| `tuish_bg_seq VALUE`                    | Background color (same forms as `tuish_bg`) |
| `tuish_sgr_seq CODE`                    | Arbitrary SGR attribute                   |
| `tuish_sgr_reset_seq`                   | Reset all attributes and colors           |
| `tuish_style_seq [attrs] [fg=N] [bg=N]` | Combined style (same forms as `tuish_style`) |

A render loop can assemble a whole row as one string — appending `TUISH_SEQ`
only when the color/style *changes* — and emit it with a single `tuish_print`,
instead of paying one write call per colored cell. On slow interpreters the
per-frame call count dominates render cost, so dense output gets several times
faster.

The built sequence uses a literal ESC byte (not `\033`), so it passes through
`tuish_print`'s backslash/`%` escaping untouched and can be safely embedded in
a row string that also carries arbitrary text.

```sh
tuish_fg_seq 4; row="${TUISH_SEQ}████"       # blue wall...
tuish_sgr_reset_seq; row="${row}${TUISH_SEQ}"
tuish_print "$row"                           # one write for the whole run
```

## Colors

`tuish_fg VALUE` and `tuish_bg VALUE` set the foreground/background through one
smart entry point each. VALUE accepts every color form:

| VALUE      | Meaning                                                      |
|------------|--------------------------------------------------------------|
| `0`-`7`    | Basic color (black red green yellow blue magenta cyan white) |
| `8`-`15`   | Bright color (bright black … bright white)                   |
| `16`-`255` | 256-color palette (16-231 = 6×6×6 cube, 232-255 = grayscale) |
| `R:G:B`    | Truecolor, each component 0-255 (e.g. `255:128:0`)           |
| `default`  | Reset just this role to the terminal default                 |

| N | Basic color |
|---|-------------|
| 0 | Black       |
| 1 | Red         |
| 2 | Green       |
| 3 | Yellow      |
| 4 | Blue        |
| 5 | Magenta     |
| 6 | Cyan        |
| 7 | White       |

`tuish_style` (below) takes the same forms via `fg=`/`bg=` and folds colors and
attributes into a single SGR sequence.

### Composing Styles

Attributes and colors are cumulative. Combine them freely:

```sh
tuish_bold
tuish_fg 1
tuish_print "bold red text"
tuish_sgr_reset

tuish_dim
tuish_fg 242
tuish_print "dim gray"
tuish_sgr_reset

tuish_reverse
tuish_fg 4
tuish_bg 7
tuish_print " status bar "
tuish_sgr_reset
```

Always call `tuish_sgr_reset` after styled output to avoid leaking styles
into subsequent text.

### Raw SGR Access

For any SGR code not covered by a convenience function:

```sh
tuish_sgr '4;58;2;255;100;0'    # colored underline (if supported)
```
