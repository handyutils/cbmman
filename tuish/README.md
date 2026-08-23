<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# tui.sh

TUI toolkit written in pure portable shell script. No compilation, no subprocesses, requires only `stty` (almost universal).

![Demo](https://i.imgur.com/t8NZbSe.gif)

## Quick Start

```sh
#!/bin/sh
. ./src/compat.sh
. ./src/ord.sh
. ./src/tui.sh
. ./src/term.sh
. ./src/event.sh
. ./src/hid.sh
. ./src/keybind.sh

tuish_bind 'ctrl-w' 'tuish_quit'
tuish_bind 'idle'   '_render'

_render () {
    tuish_vmove 1 1
    tuish_print "Hello from tui.sh -- press Ctrl+W to quit"
}

tuish_start
```

## Features

- **Keyboard and mouse events** with named dispatch (`ctrl-w`, `char a`,
  `lclik`, `resize`, `idle`). VT and kitty keyboard protocols.
- **Declarative key bindings** -- `tuish_bind EVENT ACTION`, no
  boilerplate event handler needed.
- **Drawing primitives** -- cursor movement, 256/truecolor, text
  attributes, box drawing with four line styles and mixed-style junctions.
- **Viewport modes** -- fullscreen (alternate screen), fixed (inline
  region), and grow (streaming output).
- **Redraw scheduling** -- `requestAnimationFrame`-style coalescing so
  held keys don't cause lag.
- **Unicode-aware** -- display width calculation for CJK, emoji, combining
  marks. Box drawing auto-detects UTF-8 for Unicode line characters.
- **App-in-app hosting** -- run a whole tuish app inside a region of
  another, in one process with no forks. Either modally (the child takes
  the keyboard until it quits) or **cooperatively**: one event loop driving
  several live children at once, each ticking at its own negotiated rate,
  clipped to a scrolling pane, with focus and browser-style scroll chaining.
  `host.sh` does the bookkeeping. See [hosting.md](docs/hosting.md).

## Supported Shells

| Shell      | Version  |
|------------|----------|
| bash       | 4+       |
| zsh        | 5+       |
| ksh93      | AJM 93u+ |
| mksh       | R59+     |
| busybox sh | 1.30+    |

## Modules

Source `compat.sh` first, then `ord.sh`, then `tui.sh`. Everything else
is optional -- pick what you need:

| Module        | Purpose                                         |
|---------------|-------------------------------------------------|
| `compat.sh`   | Shell normalization, portable output            |
| `ord.sh`      | ASCII lookup tables                             |
| `tui.sh`      | Terminal lifecycle, traps, buffering, contexts  |
| `term.sh`     | Cursor, colors, text attributes, scroll regions |
| `event.sh`    | Event loop, redraw scheduling                   |
| `hid.sh`      | Keyboard/mouse event name resolution            |
| `viewport.sh` | Fullscreen, fixed, and grow viewport modes      |
| `canvas.sh`   | Clipped sub-region with local coordinates       |
| `str.sh`      | String operations, Unicode display width        |
| `buf.sh`      | Indexed line buffer                             |
| `keybind.sh`  | Declarative event-to-action dispatch            |
| `clip.sh`     | System clipboard (OSC 52)                       |
| `draw.sh`     | Box drawing with styles and junctions           |
| `hl.sh`       | Generic code highlighting (standalone)          |
| `md.sh`       | Markdown to a record stream (standalone)        |
| `host.sh`     | Hosting several live apps in one loop           |

## Examples

```sh
bash examples/cooperative.sh  # One loop, two live apps: a clock + the editor
bash examples/editor.sh       # CUA-like text editor
bash examples/game.sh         # Emoji platformer (dirty-sprite renderer)
bash examples/boxes.sh        # Box drawing styles and composable layouts
bash examples/canvas_demo.sh  # Two independently scrollable clipped panels
bash examples/debug.sh        # Live event inspector
bash examples/width.sh        # Unicode width ACID test
bash examples/slow_menu.sh    # Streaming output in a grow viewport
```

Each is **dual-mode**: run it standalone, or source it from another tuish app
and run it inside a region -- that is what `cooperative.sh` does with the
editor, and what the website does with all of them.

## Documentation

- [Getting Started](docs/getting-started.md) -- examples, architecture, module system
- [Core (tui.sh)](docs/tui.md) -- lifecycle, buffering, terminal variables
- [Terminal Output (term.sh)](docs/term.md) -- cursor, colors, text attributes
- [Event Loop (event.sh)](docs/event.md) -- event lifecycle, redraw scheduling
- [HID (hid.sh)](docs/hid.md) -- complete event name reference
- [Viewport Modes (viewport.sh)](docs/viewport.md) -- fullscreen, fixed, grow
- [Hosting and Contexts](docs/hosting.md) -- one app inside another, cooperative multi-app loops
- [Box Drawing (draw.sh)](docs/draw.md) -- styles, junctions, clipping
- [String Utilities (str.sh)](docs/str.md) -- Unicode width, substrings
- [Line Buffer (buf.sh)](docs/buf.md) -- indexed line storage
- [Key Bindings (keybind.sh)](docs/keybind.md) -- declarative event dispatch
- [System Clipboard (clip.sh)](docs/clip.md) -- OSC 52 copy, and how paste works
- [Code Highlighting (hl.sh)](docs/hl.md) -- one generic lexer, token styles, fence modes
- [Markdown (md.sh)](docs/md.md) -- the record stream, the sink, the supported subset
- [Shell Compatibility](docs/compatibility.md) -- supported shells, limits, workarounds

## License

ISC
