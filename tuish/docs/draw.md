<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# Box Drawing (draw.sh)

Box-drawing primitives with style support, mixed-style junctions, and
viewport clipping. Source after `term.sh` and `str.sh`.

```sh
. ./src/term.sh
. ./src/str.sh
. ./src/draw.sh
```

## Backends

Auto-detected from locale at source time, stored in `TUISH_DRAW_BACKEND`:

| Backend   | When                  | Characters                              |
|-----------|-----------------------|-----------------------------------------|
| `unicode` | UTF-8 locale detected | `┌─┐│└┘  ┏━┓┃┗┛  ╔═╗║╚╝  ╭╮╰╯`          |
| `ascii`   | fallback              | `+-.|=` with VT100 bold for heavy style |

Detection checks the saved locale variables (`_tuish_orig_lc_all`, `_tuish_orig_lc_ctype`, `_tuish_orig_lang`) captured by compat.sh before it sets `LC_ALL=C`.

`TUISH_DRAW_BACKEND` is per-context **state**, seeded from that source-time
detection: every context starts at the detected value, but an app that switches
itself to `ascii` no longer leaks that choice to its host or siblings. See
[hosting.md](hosting.md).

## Styles

| Style             | Unicode        | ASCII        |
|-------------------|----------------|--------------|
| `light` (default) | `┌─┐│└┘ ├┤┬┴┼` | `+-\|+`      |
| `heavy`           | `┏━┓┃┗┛ ┣┫┳┻╋` | `+-\|+` bold |
| `double`          | `╔═╗║╚╝ ╠╣╦╩╬` | `+=\|+`      |
| `rounded`         | `╭─╮│╰╯ ├┤┬┴┼` | `.-'\|+`     |

Rounded uses light-weight horizontals/verticals with rounded corners.

## Drawing Functions

### tuish_draw_box ROW COL W H [opts]

Draw a bordered rectangle with optional background fill.

```sh
tuish_draw_box 1 1 20 8
tuish_draw_box 1 1 20 8 style=double fg=4 bg=0
tuish_draw_box 1 1 20 8 border=lr bg=0    # sides only, no top/bottom
```

Options:
- `style=STYLE` -- line style (default: `light`)
- `fg=N` -- foreground color: 0-7 basic, 8-15 bright, 16-255 palette, or `R:G:B` truecolor (-1 = unchanged)
- `bg=N` -- background color: same format as fg (-1 = unchanged)
- `border=MASK` -- which borders to draw (default: `tlbr`)

The border mask is any combination of `t` (top), `l` (left), `b` (bottom),
`r` (right), or the special value `none`.  Missing borders are filled with
background color instead.

### tuish_draw_fill ROW COL W H [bg=N]

Fill a rectangle with a background color (unlike `tuish_clear_region` in
[term.md](term.md), which writes plain spaces with no color). Accepts
`bg=N` named option or a positional fifth argument for backward
compatibility.

```sh
tuish_draw_fill 1 1 20 5 bg=4      # named option
tuish_draw_fill 1 1 20 5 4         # positional (same result)
```

### tuish_draw_text ROW COL TEXT [maxwidth=N] [fg=N] [bg=N]

Render text at a position with optional foreground/background color and
width clipping. Respects the draw-layer transform (origin offset + clip
region), then delegates placement, color, and edge clipping to
[`tuish_text`](term.md). Text that extends past the right edge of the
viewport is automatically truncated. With the canvas off and no draw origin
set, prefer `tuish_text` directly.

```sh
tuish_draw_text 1 1 "Hello, world!"
tuish_draw_text 3 5 "$long_string" maxwidth=20 fg=2 bg=0
```

### tuish_draw_hdiv ROW COL W [opts]

Horizontal divider spanning W columns: `├───┤`

Endpoints use T-junction characters that connect to a vertical border.

```sh
tuish_draw_hdiv 4 1 20 style=light
```

Options: `style=`, `fg=`, `join=`

### tuish_draw_vdiv ROW COL H [opts]

Vertical divider spanning H rows: `┬│┴`

Endpoints use T-junction characters that connect to a horizontal border.

```sh
tuish_draw_vdiv 1 10 8 style=light
```

Options: `style=`, `fg=`, `join=`

### tuish_draw_hline ROW COL W [opts]

Bare horizontal line (no endpoint junctions).

```sh
tuish_draw_hline 5 3 10 style=heavy fg=1
```

Options: `style=`, `fg=`

### tuish_draw_vline ROW COL H [opts]

Bare vertical line (no endpoint junctions).

Options: `style=`, `fg=`

### tuish_draw_cross ROW COL [opts]

Single cross/junction character: `┼`

The `style=` controls the horizontal arm weight, `join=` controls the
vertical arm weight.

Options: `style=`, `fg=`, `join=`

### tuish_draw_tee ROW COL DIR [opts]

Single T-junction character.

DIR values:
- `r` -- `├` (stem points right)
- `l` -- `┤` (stem points left)
- `d` -- `┬` (stem points down)
- `u` -- `┴` (stem points up)

Options: `style=`, `fg=`, `join=`

## Composability

Build complex layouts by overlaying primitives.  Dividers and crosses
produce correct junction characters where lines meet.

### Grid

```sh
tuish_draw_box   1 1 20 8 style=rounded
tuish_draw_hdiv  4 1 20   style=rounded
tuish_draw_vdiv  1 10 8   style=rounded
tuish_draw_cross 4 10     style=rounded
```

```
╭────────┬─────────╮
│  A     │  B      │
│        │         │
├────────┼─────────┤
│  C     │  D      │
│        │         │
╰────────┴─────────╯
```

### Header + sidebar with tees

```sh
tuish_draw_box   1 1 20 8 style=double
tuish_draw_hdiv  3 1 20   style=light join=double
tuish_draw_vline 4 8 4    style=light
tuish_draw_tee   3 8  d   style=light
tuish_draw_tee   8 8  u   style=light join=double
```

```
╔══════════════════╗
║  Header          ║
╟──────┬───────────╢
║ Nav  │  Content  ║
║      │           ║
║      │           ║
║      │           ║
╚══════╧═══════════╝
```

## Mixed-Style Junctions (`join=`)

When a divider of one style meets a border of a different style, use
`join=` to specify the border's style.  This selects the correct mixed
Unicode junction character (e.g. `╟` instead of `├`).

```sh
tuish_draw_box   1 1 20 8 style=double
tuish_draw_hdiv  4 1 20   style=light join=double    # ╟───╢
tuish_draw_vdiv  1 10 8   style=light join=double    # ╤│╧
tuish_draw_cross 4 10     style=light                # ┼
```

```
╔════════╤═════════╗
║        │         ║
║        │         ║
╟────────┼─────────╢
║        │         ║
║        │         ║
╚════════╧═════════╝
```

The cross at (4,10) uses `style=light` without `join=` because both
the hdiv and vdiv passing through it are light.  Use `join=` only where
a divider's **endpoint** meets a border of a different style.

For `tuish_draw_cross` and `tuish_draw_tee`, `style=` controls the
horizontal arm and `join=` controls the vertical arm.

### Supported Combinations (Unicode)

| style  | join   | hdiv | vdiv | cross | tee    |
|--------|--------|------|------|-------|--------|
| light  | double | `╟╢` | `╤╧` | `╫`   | `╟╢╤╧` |
| double | light  | `╞╡` | `╥╨` | `╪`   | `╞╡╥╨` |
| light  | heavy  | `┠┨` | `┯┷` | `╂`   | `┠┨┯┷` |
| heavy  | light  | `┝┥` | `┰┸` | `┿`   | `┝┥┰┸` |

Unsupported combinations (e.g. heavy+double) fall back to the divider's
own style junctions.  On the ASCII backend, `join=` is ignored (all
junctions are `+`).

## Viewport

The viewport system provides coordinate transformation and vertical
clipping for all draw functions.  This lets you implement scrolling views
without manual coordinate math in every draw call.

### Coordinate Model

```
Logical coordinates (what your code uses)
          │
          ▼
   tuish_draw_set_origin(scroll, 0)
          │
          ▼
Screen coordinates (row - origin)
          │
          ▼
   tuish_draw_set_clip(top, bot)
          │
          ▼
Visible output (only rows within clip region)
```

1. **Origin offset** is subtracted from logical coordinates before drawing.
   Setting origin to `(scroll, 0)` means logical row `scroll` maps to
   screen row 0.

2. **Clip region** culls or clamps drawing to a vertical band of screen
   rows.  Elements fully outside the band produce no output.  Elements
   partially inside are clamped: boxes lose their clipped border edges
   and fill the remaining rows; vertical dividers lose their endpoint
   tees and draw plain verticals at the clipped boundary.

### Functions

| Function                        | Description                            |
|---------------------------------|----------------------------------------|
| `tuish_draw_set_origin ROW COL` | Set origin offset (default: 0 0)       |
| `tuish_draw_set_clip TOP BOT`   | Enable vertical clipping (screen rows) |
| `tuish_draw_reset_clip`         | Disable clipping                       |

The draw origin/clip layer (`_tuish_draw_origin_*`, `_tuish_draw_clip*`) is
per-context too, so an origin or clip set by one app does not bleed into
another. See [hosting.md](hosting.md).

### Example: Scrollable Content Area

```sh
_scroll=0

_redraw () {
    tuish_draw_set_origin $_scroll 0
    tuish_draw_set_clip 2 $TUISH_VIEW_ROWS    # clip below header

    # These use logical coordinates -- viewport handles the rest
    tuish_draw_box  1 1 40 50 style=rounded
    tuish_draw_hdiv 5 1 40   style=rounded
    tuish_draw_vdiv 1 20 50  style=rounded

    tuish_draw_reset_clip
}
```

As `_scroll` increases, content scrolls up.  Elements that move above
the clip region are automatically culled.  Elements that span the clip
boundary are clamped -- a box whose top border scrolls out loses the top
border line and fills from the clip top instead.

### Clipping Behavior by Element Type

| Element            | Behavior                                                 |
|--------------------|----------------------------------------------------------|
| Box                | Height clamped; top/bottom borders stripped when clipped |
| Vertical divider   | Height clamped; endpoint tees replaced by verticals      |
| Vertical line      | Height clamped                                           |
| Horizontal divider | Culled entirely if row is outside clip                   |
| Horizontal line    | Culled entirely if row is outside clip                   |
| Cross              | Culled entirely if row is outside clip                   |
| Tee                | Culled entirely if row is outside clip                   |

### How It Works

Internally, draw functions call one of two transform helpers:

- **Point transform** (`_tuish_draw_xform`): for single-row elements.
  Returns 1 (no draw) if the transformed row falls outside the clip region.

- **Rect transform** (`_tuish_draw_xform_rect`): for multi-row elements.
  Clamps the height to the clip region and sets flags indicating whether
  the top or bottom was clipped.  The box renderer uses these flags to
  strip border edges and expand the fill area.

### Horizontal Overflow

By default, tui.sh disables terminal auto-wrap (DECAWM off). Content
drawn past the right edge is silently discarded by the terminal.
Box dimensions remain unchanged -- the terminal handles the clipping,
so boxes partially off-screen show only their visible portion.
