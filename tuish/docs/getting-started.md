<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# Getting Started

tui.sh is a terminal UI toolkit for POSIX-ish shells. Source it from your
script, bind events to actions, and it gives you parsed keyboard, mouse,
and signal events plus drawing primitives for building interactive TUIs.

Runs on **bash**, **zsh**, **ksh93**, **mksh**, and **busybox sh**.

## Minimal Example

```sh
#!/bin/sh
. ./src/compat.sh
. ./src/ord.sh
. ./src/tui.sh
. ./src/term.sh
. ./src/event.sh
. ./src/hid.sh
. ./src/keybind.sh

_on_idle ()
{
    tuish_move 1 1
    tuish_print "Press Ctrl+W to quit"
}

tuish_bind 'ctrl-w' 'tuish_quit'
tuish_bind 'idle'   '_on_idle'

tuish_start
```

`tuish_start` is a convenience that calls `tuish_init`, `tuish_run`, and
`tuish_fini` in sequence. The first `idle` event fires before any input
arrives, making it the natural place for initial rendering.

Events are dispatched through `tuish_bind` bindings automatically -- no
event handler boilerplate is needed.

## A Richer Example

```sh
#!/bin/sh
. ./src/compat.sh
. ./src/ord.sh
. ./src/tui.sh
. ./src/term.sh
. ./src/event.sh
. ./src/hid.sh
. ./src/viewport.sh
. ./src/keybind.sh

_count=0

_render ()
{
    tuish_hide_cursor

    # Reverse-fill row 1 across the drawable width, then print the title over it.
    # tuish_clear_to_edge is bounded by the viewport (or the region, when hosted);
    # tuish_clear_to_eol would erase to the end of the physical line. See term.md.
    tuish_reverse
    tuish_clear_to_edge 1
    tuish_vmove 1 1
    tuish_print " Click counter "
    tuish_sgr_reset

    tuish_clear_to_edge 3
    tuish_vmove 3 3
    tuish_fg 2
    tuish_print "Clicks: $_count"
    tuish_sgr_reset
    tuish_show_cursor
}

_on_click ()
{
    _count=$((_count + 1))
    _render
}

tuish_bind 'ctrl-w'      'tuish_quit'
tuish_bind 'lclik'       '_on_click'
tuish_bind 'resize'      '_render'
tuish_bind 'idle'        '_render'

tuish_init
tuish_mouse_on
tuish_viewport fixed 8
tuish_run || :
tuish_fini
```

This creates an 8-row fixed viewport that shows a click counter with
colored text and a reverse-video title bar. `tuish_mouse_on` is needed
to receive mouse events like `lclik`.

## Architecture

```
your-app.sh
    |
    v
tuish_init          set up terminal (raw mode, keyboard protocol)
    |
    v
tuish_run           main loop: read input -> parse -> dispatch bindings
    |                                                       |
    |               <---------------------------------------+
    |               draw with tuish_move, tuish_print, tuish_fg, etc.
    |
    v
tuish_fini          restore terminal
```

1. **Source** `src/compat.sh`, then `src/ord.sh`, then `src/tui.sh`, then any additional modules you need
2. **Bind** events to actions with `tuish_bind`
3. **Call** `tuish_init` (or `tuish_start` for the simple case)
4. **Optionally** set a viewport mode with `tuish_viewport`
5. **Draw** inside bound actions using the drawing API
6. **Quit** by calling `tuish_quit` from a bound action

Output buffering is automatic -- all writes inside an event handler are
coalesced and flushed after it returns.

For advanced use cases that need logic wrapping every event (e.g., saving
state before dispatch and checking side effects after), register your own
handler with `tuish_on_event _my_handler`. See
[event.md](event.md#callbacks) for details.

> **If your app might ever be embedded in another** (see
> [hosting.md](hosting.md)), always *register* handlers by name --
> `tuish_on_redraw _render`, `tuish_on_event _handler` -- rather than
> redefining `tuish_on_redraw ()` / `tuish_on_event ()` as functions.
> Redefinition is process-global, so two apps written that way would fight
> over the same function; registration stores the handler per context.

## Module System

`compat.sh`, `ord.sh`, and `tui.sh` are the required modules. `compat.sh`
provides shell normalization (`set -euf`, locale, output primitives),
`ord.sh` provides ASCII lookup tables, and `tui.sh` provides terminal
setup/teardown, traps, and IO stubs. Everything else is optional -- source
only what your app needs.

| Module        | Provides                                            | Depends on            |
|---------------|-----------------------------------------------------|-----------------------|
| `compat.sh`   | shell options, portable output, ksh93 `local` alias | --                    |
| `ord.sh`      | ASCII ord/chr lookup tables                         | `compat.sh`           |
| `tui.sh`      | terminal setup, teardown, traps, IO stubs, state, contexts | `compat.sh`    |
| `term.sh`     | buffered write, cursor, colors, SGR, scroll regions | `tui.sh`              |
| `event.sh`    | event loop, dispatch, redraw scheduling             | `tui.sh`, `ord.sh`    |
| `hid.sh`      | keyboard/mouse name resolution                      | `event.sh`            |
| `viewport.sh` | viewport modes (fullscreen, fixed, grow)            | `term.sh`, `event.sh` |
| `canvas.sh`   | clipped sub-region with local coordinates           | `term.sh`             |
| `str.sh`      | string/Unicode width utilities                      | `ord.sh`              |
| `buf.sh`      | line buffer                                         | --                    |
| `keybind.sh`  | key binding dispatch                                | `ord.sh`              |
| `clip.sh`     | system clipboard (OSC 52), base64                   | `tui.sh`, `ord.sh`    |
| `draw.sh`     | box drawing                                         | `term.sh`, `str.sh`   |

Modules that own per-app state (`draw.sh`, `hid.sh`, `viewport.sh`, `event.sh`,
`keybind.sh`) register it with `tui.sh` so it can be saved and restored per
context -- one more reason `tui.sh` must be sourced before them. See
[hosting.md](hosting.md).

Always source `compat.sh` first, then `ord.sh`, then `tui.sh`. After that,
order does not matter as long as dependencies are satisfied.

A minimal interactive app needs `compat.sh` + `ord.sh` + `tui.sh` + `term.sh` + `event.sh` + `hid.sh`.
For a full-featured app, source all modules:

```sh
. ./src/compat.sh
. ./src/ord.sh
. ./src/tui.sh
. ./src/term.sh
. ./src/event.sh
. ./src/hid.sh
. ./src/viewport.sh
. ./src/str.sh
. ./src/buf.sh
. ./src/keybind.sh
```

## Gotchas

**Locale override:** compat.sh sets `LC_ALL=C` globally for byte-oriented
string operations. Any external commands called from your event handlers
will see the C locale. To restore the user's locale for a specific command:
`LC_ALL="${_tuish_orig_lc_all:-}" my_command`. See [compat.md](compat.md#locale-handling).

## Redraw Scheduling

When the user holds down a key, many keypresses queue up. Drawing on every
keypress causes visible lag after the key is released. Use
`tuish_request_redraw` to coalesce redraws -- state updates happen for every
event, but rendering fires only once when the input queue is drained:

```sh
. ./src/compat.sh
. ./src/ord.sh
. ./src/tui.sh
. ./src/term.sh
. ./src/event.sh
. ./src/hid.sh
. ./src/keybind.sh

_page=0

_next_page ()
{
    _page=$((_page + 1))
    tuish_request_redraw      # schedule, don't draw
}

_render ()
{
    tuish_clear_to_edge 1        # erase row 1 across our width, then draw
    tuish_vmove 1 1
    tuish_print "Page: $_page"
}

tuish_on_redraw _render
tuish_bind 'char n' '_next_page'
```

`tuish_request_redraw` accepts an optional level: `-1` (full, the default),
or a positive number for partial redraws. The framework passes the level to
`tuish_on_redraw`, letting your callback skip expensive work when only a
cheap update is needed. See [Redraw Scheduling](event.md#redraw-scheduling)
for details.

## Next Steps

- [Hosting and Contexts](hosting.md) -- run one app inside another; cooperative multi-app loops
- [Core (tui.sh)](tui.md) -- lifecycle, buffering, terminal variables
- [Terminal Output (term.sh)](term.md) -- cursor, colors, text attributes
- [Event Loop (event.sh)](event.md) -- redraw scheduling
- [HID (hid.sh)](hid.md) -- every event tui.sh can produce
- [Viewport Modes (viewport.sh)](viewport.md) -- fullscreen, fixed, grow
- [Box Drawing (draw.sh)](draw.md) -- styles, junctions, clipping
- [String Utilities (str.sh)](str.md) -- Unicode width, substrings
- [Line Buffer (buf.sh)](buf.md) -- indexed line storage
- [Key Bindings (keybind.sh)](keybind.md) -- declarative event dispatch
- [Shell Compatibility](compatibility.md) -- supported shells and limits
