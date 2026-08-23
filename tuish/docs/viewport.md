<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# Viewport Modes (viewport.sh)

Viewport modes that control how your application occupies the terminal
screen. Set a mode after `tuish_init` with `tuish_viewport MODE [MAX]`.
Source after `term.sh` and `event.sh`.

```sh
. ./src/term.sh
. ./src/event.sh
. ./src/viewport.sh
```

## Modes

### Fullscreen

```sh
tuish_viewport fullscreen
```

Enters the alternate screen buffer and uses the entire terminal.

- `TUISH_VIEW_ROWS` = `TUISH_LINES`
- `TUISH_VIEW_TOP` = 1
- `TUISH_VIEW_COLS` = `TUISH_COLUMNS`
- `TUISH_VIEW_LEFT` = 0

Use for full-screen applications (editors, file managers). The alternate
screen is automatically cleaned up on exit.

> **When hosted, every mode fills the region instead.** The mode distinctions
> below are about how an app relates to the terminal's scrollback, which is
> meaningless for a sub-region -- so for a child context all of them map to
> "fill my region": no alternate screen, no scroll region, and the viewport
> variables describe the region, not the terminal. That is what lets a
> full-screen app run unchanged inside a host's content pane. See
> [hosting.md](hosting.md).

### Fixed

```sh
tuish_viewport fixed 10
```

Reserves a fixed-size region in the normal screen. The viewport starts
at the cursor's position when `tuish_init` was called.

- `TUISH_VIEW_ROWS` = min(MAX, `TUISH_LINES`)
- `TUISH_VIEW_TOP` = `TUISH_INIT_ROW` (adjusted if near bottom)
- A scroll region is set to protect content above and below

Use for inline UI elements (menus, dialogs, search results) that
coexist with terminal output above and below.

### Grow

```sh
tuish_viewport grow 15
```

Starts at the cursor position and grows downward as content is emitted
via `tuish_grow`, up to MAX rows.

Two phases:
1. **Growing** (phase 0): Each `tuish_grow` call emits a newline, pushing
   content up. `TUISH_VIEW_ROWS` increases.
2. **Scrolling** (phase 1): Once MAX rows are reached, a scroll region is
   set. New `tuish_grow` calls scroll within the region.

Use for streaming output (logs, event displays) that starts small and
expands.

| Function     | Description                                                                 |
|--------------|-----------------------------------------------------------------------------|
| `tuish_grow` | Emit a new row: grows the viewport (phase 0) or scrolls within it (phase 1) |

## Drawing with Viewports

Use `tuish_vmove` instead of `tuish_move` when a viewport is active.
It translates viewport-relative coordinates to absolute terminal cells,
applying both the row origin (`TUISH_VIEW_TOP`) and the column origin
(`TUISH_VIEW_LEFT`):

```sh
tuish_vmove 1 1    # top-left of viewport (not terminal)
tuish_vmove 3 5    # row 3, column 5 within viewport
```

`TUISH_VIEW_LEFT` is 0 for the root context, so standalone the column is
unchanged; a hosted child's logical column 1 lands at its region's left edge
(see [hosting.md](hosting.md)).

`tuish_move` always uses absolute terminal coordinates regardless of
viewport mode.

Mouse coordinates in `TUISH_MOUSE_X` and `TUISH_MOUSE_Y` are both
viewport-relative (region-relative when hosted) while a viewport is active.
Use `TUISH_MOUSE_ABS_Y` for the absolute row.

The raw erase primitives `tuish_clear_screen`, `tuish_clear_line` and
`tuish_clear_to_eol` are **not** viewport-aware -- they act on the physical
terminal. Use `tuish_clear_to_edge` / `tuish_clear_region` (see
[term.md](term.md)) inside a viewport.

## Runtime Mode Switching

You can switch modes at any time:

```sh
# Toggle between fullscreen and fixed
case "$TUISH_EVENT" in
    alt-f)
        if test "$TUISH_VIEW_MODE" = 'fullscreen'
        then
            tuish_viewport fixed 10
        else
            tuish_viewport fullscreen
        fi
        redraw
        ;;
esac
```

## Resize Handling

When the terminal is resized, tui.sh:

1. Fires a `resize` event
2. Updates `TUISH_LINES` and `TUISH_COLUMNS`
3. Recalculates `TUISH_VIEW_ROWS` and adjusts scroll regions

Your `resize` handler should redraw the UI:

```sh
resize)
    _view_height=$((TUISH_VIEW_ROWS - 2))
    redraw
    ;;
```

## Overflow Control

By default, tui.sh disables terminal auto-wrap (DECAWM off) so content
past the right edge is clipped by the terminal. Call `tuish_wrap_on`
after `tuish_init` if your app needs wrapping behavior.

| Function         | Description                                            |
|------------------|--------------------------------------------------------|
| `tuish_wrap_on`  | Enable line wrapping (DECAWM on)                       |
| `tuish_wrap_off` | Disable line wrapping (DECAWM off, clip at right edge) |

This complements the vertical clipping in draw.sh -- vertical clipping
is software-based, horizontal clipping is handled by the terminal.

## Variables Summary

| Variable          | Description                                          |
|-------------------|------------------------------------------------------|
| `TUISH_VIEW_MODE` | Current mode: `fullscreen`, `fixed`, `grow`, or `""` |
| `TUISH_VIEW_ROWS` | Usable content rows                                  |
| `TUISH_VIEW_COLS` | Usable content columns (`TUISH_COLUMNS` at top level; the region's width when hosted) |
| `TUISH_VIEW_TOP`  | Absolute terminal row where viewport starts          |
| `TUISH_VIEW_LEFT` | Column origin (0-based); 0 for the root, the region's absolute column when hosted -- see [hosting.md](hosting.md) |
