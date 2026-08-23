<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# Event Loop (event.sh)

Event loop, dispatch, and RequestAnimationFrame-style redraw scheduling.
Source after `tui.sh`.

```sh
. ./src/tui.sh
. ./src/term.sh
. ./src/event.sh
```

## Functions

| Function      | Description                                                        |
|---------------|--------------------------------------------------------------------|
| `tuish_start` | Convenience wrapper: calls `tuish_init`, `tuish_run`, `tuish_fini` |
| `tuish_run`   | Start event loop -- reads input, parses events, dispatches them    |

### Callbacks

| Function                | Default                | Description                                                                                   |
|-------------------------|------------------------|-----------------------------------------------------------------------------------------------|
| `tuish_on_event FUNC`   | calls `tuish_dispatch` | Register the per-context event handler, called for every parsed event. Use for pre/post-dispatch logic. |
| `tuish_on_redraw FUNC`  | no-op                  | Register the per-context render handler, called with `LEVEL` when a deferred redraw fires: `-1` (full), or a positive integer (partial). |
| `tuish_on_fini FUNC`    | none                   | Register a teardown function, run by `tuish_fini` on every exit path (setter only).           |

The default `tuish_on_event` calls `tuish_dispatch`, so apps that use
`tuish_bind` (from `keybind.sh`) don't need to define it at all. Override
`tuish_on_event` when you need logic that wraps dispatch -- e.g., saving
state before dispatch and checking side effects after.

### Registering handlers by name

`tuish_on_redraw` and `tuish_on_event` are polymorphic. There are two styles:

```sh
# (a) Register by name -- required if the app may be hosted/embedded
tuish_on_redraw _my_render
tuish_on_event  _my_handler

# (b) Redefine the function -- the classic style, still works
tuish_on_redraw () { ... }
tuish_on_event  () { ... }
```

Style (a) stores the handler **per-context** (`_tuish_render_fn` /
`_tuish_event_fn`). The framework calls
`"${_tuish_render_fn:-tuish_on_redraw}" "$LEVEL"` and
`"${_tuish_event_fn:-tuish_on_event}"`, so it falls back to the redefinable
stub when no name was registered.

Style (b) is process-global: an app written this way **cannot be hosted
alongside another app**, because both would fight over the same function
definition. Register by name if your app may ever run embedded --
see [hosting.md](hosting.md).

> **Gotcha.** `tuish_on_redraw` discriminates by "does the argument contain a
> non-digit", because the framework's own fallback call passes a numeric
> `LEVEL`. A render handler whose *name* is all digits/dashes would be
> swallowed as a level. `tuish_on_event` discriminates on argument **count**
> (`$# -gt 0`).

### Handing an event back

| Function      | Description                                                              |
|---------------|--------------------------------------------------------------------------|
| `tuish_pass`  | From inside a bound action: "I saw this event and I am not acting on it" |
| `TUISH_HANDLED` | 1 once a binding matches, 0 if nothing did (or the action called `tuish_pass`) |

`tuish_dispatch` sets `TUISH_HANDLED=1` **before** running the action, so an action
that turns out to be a no-op can give the event back:

```sh
_scroll_down ()
{
    test $_top -ge $_max && { tuish_pass; return 0; }   # nothing left to scroll
    _top=$((_top + 3))
    tuish_request_redraw
}
```

This only matters when your app may be **hosted**. A host reads the result as
`TUISH_CTX_HANDLED` after `tuish_ctx_dispatch` and chains the event onward -- so the
wheel that runs out of scroll inside your app continues scrolling the page around it,
the way a nested scroller does in a browser. See
[hosting.md](hosting.md#scroll-chaining). Standalone, nothing reads it.

`TUISH_HANDLED` is device-global, not a context field: it describes the single event
in flight.

### Teardown

```sh
tuish_on_fini _my_cleanup
```

`tuish_on_fini` registers a per-context teardown function that `tuish_fini`
runs on **every** exit path: standalone teardown, modal return, and
cooperative unmount. Restore device state your app changed (e.g. cursor
shape) there. Unlike the two callbacks above it is a **setter only** -- the
framework never calls it with a level or with no arguments.

## Event Variables

Set before each event dispatch:

| Variable            | Description                                                        |
|---------------------|--------------------------------------------------------------------|
| `TUISH_EVENT`       | Parsed event name (e.g. `ctrl-w`, `up`, `char x`, `lclik`, `idle`) |
| `TUISH_EVENT_KIND`  | Event category: `key`, `mouse`, `focus`, `paste`, `signal`, `idle` |
| `TUISH_PASTE`       | The pasted text, on a `paste` event (see [hid.md](hid.md#paste-events-kind-paste)) |
| `TUISH_MOUSE_X`     | Mouse column (1-based, viewport/region-relative when viewport active) |
| `TUISH_MOUSE_Y`     | Mouse row (1-based, viewport/region-relative when viewport active)   |
| `TUISH_MOUSE_ABS_Y` | Mouse row (1-based, absolute terminal row)                         |
| `TUISH_RAW`         | Raw event data for debugging (see example below)                   |

`TUISH_MOUSE_X` and `TUISH_MOUSE_Y` are expressed in the **active context's**
coordinate frame: for a hosted child they are region-local, so an embedded
app's click handling works unchanged. `TUISH_MOUSE_ABS_Y` holds the absolute
terminal row; there is deliberately no `TUISH_MOUSE_ABS_X`. For the root
context the column origin is 0, so standalone coordinates are unchanged.
See [hosting.md](hosting.md).

See [hid.md](hid.md) for the complete list of event names.

### Debugging with TUISH_RAW

```sh
tuish_bind '*' 'tuish_print_at 1 1 "RAW: $TUISH_RAW "'
```

## Event Lifecycle

```
byte arrives (terminal)
    │
    ▼
escape sequence assembled (_tuish_read_seq)
    │
    ▼
_tuish_parse_event        → raw parse: CSI u, SS3, CSI ~, mouse, etc.
    │
    ▼
_tuish_resolve_event      → name resolution: raw codes → event names
    │
    ▼
filters (mouse off? detailed off? modkeys off?)
    │
    ▼
tuish_begin               → start output buffering
    │
    ▼
tuish_on_event            → your callback (default: tuish_dispatch)
    │
    ▼
rAF check / tuish_end    → flush buffer, fire deferred redraw if pending
```

Your `tuish_on_event` or `tuish_bind` callbacks run between `tuish_begin`
and `tuish_end`. All terminal output within that window is buffered and
flushed as a single write.

## Redraw Scheduling

When a user holds down a key, the terminal buffers many keypresses. Without
scheduling, each keypress triggers a full redraw -- the UI keeps updating
after the key is released. `tuish_request_redraw` solves this by coalescing
redraws: state updates happen immediately, but rendering is deferred until
the input queue is drained. This applies equally to escape-sequence keys
(arrows, F-keys): a glued autorepeat burst like `ESC [ B ESC [ B ...`
coalesces the same way a burst of plain characters does.

| Function                       | Description                                                    |
|--------------------------------|----------------------------------------------------------------|
| `tuish_request_redraw [LEVEL]` | Schedule a deferred redraw. `LEVEL` defaults to `-1` (full).   |
| `tuish_cancel_redraw`          | Cancel a pending redraw request                                |
| `tuish_has_pending_input`      | Check if more input is queued (returns 0 if pending, 1 if not) |

### The deferral is bounded

"Input is pending" is a zero-timeout peek. It does not say a burst is *coming* -- it says
you are **behind**: a byte is already buffered. Deferring on that with no limit is a
livelock. Once one frame costs more than the terminal's autorepeat interval, bytes queue
faster than they drain, the peek never comes back empty, and the screen is withheld until
the key is **released**.

So the deferral spends a budget, and two rules bound it:

- **An idle event never defers.** `idle` *means* the input was exhausted -- the reader let
  a whole interval elapse to produce it -- so a byte landing while your handler ran does
  not undo the wait already paid.
- **At most `TUISH_DEFER_MAX` events are held back** (default `8`), then the frame paints
  regardless.

| Variable           | Default | Description                                          |
|--------------------|---------|------------------------------------------------------|
| `TUISH_DEFER_MAX`  | `8`     | Events a pending redraw may be held across (launcher config) |

The budget is a **trade**, not a free win, and the direction that bites is the unobvious
one: each forced render costs a frame the backlog must then chew through, so too *small* a
budget drains slower than input arrives -- the queue grows without bound and letting go of
the key leaves the app still acting on it a second later. Keep it above
`autorepeat_rate x frame_cost`; at a typical ~30/s that makes `8` good for a 266ms frame.
Around `4` it inverts.

This is what makes `tuish_request_redraw` safe for a real-time app. It was not, before:
a game that asked for a deferred redraw simply froze while a key was held, which is why
`examples/game.sh` paints directly into the frame instead.

### Redraw levels

The level argument tells `tuish_on_redraw` how much work to do:

| Level | Meaning                                   |
|-------|-------------------------------------------|
| `-1`  | Full redraw (repaint everything)          |
| `0`   | No-op (ignored by `tuish_request_redraw`) |
| `1`   | Minimal (e.g., status bar only)           |
| `2`   | Partial (e.g., current line + status bar) |
| `N`   | App-defined (higher = more work)          |

When multiple events queue up, the framework tracks the **maximum** level
across all `tuish_request_redraw` calls. Level `-1` always wins. Among
positive levels, the highest wins. The final level is passed to
`tuish_on_redraw`.

#### Start at -1 and stay there

Levels used to be the answer to "how do I make this fast", and every app that
grew past a few widgets built a ladder of them. Do not start there. **Ask for a
full redraw and paint everything** — that is the version of the code that is
obviously correct, and it is now cheap:

- Measuring text, which used to dominate a Unicode frame, is memoized
  (see [str.md](str.md#cost-and-the-memo)) — a representative chrome frame went
  from 34 ms to 6.6 ms.
- Frames are atomic, so a repaint is not visible as a repaint
  (see [tui.md](tui.md#one-write-is-not-one-repaint)).
- A field repainted with `width=N` never passes through a blank state
  (see [term.md](term.md#widthn--fields-and-why-not-to-erase-first)).

Reach for a partial level when you have **measured** that a specific path is too
slow, and when what makes it slow is recomputing *state* — re-wrapping a
document, re-querying something, rebuilding a list — rather than re-emitting
output. Skipping output is the framework's problem. Skipping work only you know
is unnecessary is yours.

#### The line to measure against

"Repaint everything" is advice about **output**, and there is a second cost it
does not touch: some renderers are expensive to *compose*, independent of what
they emit. Telling the two apart before deleting any bookkeeping is the whole
skill, and the toolkit ships one of each:

- `examples/session.sh` — its guards protect **bytes**. Dropping the background
  gate takes a frame from 4434 to 7655 bytes; dropping the motion guard takes it
  from 356 to 1163. Nothing is recomputed, the same picture is just re-sent.
- `examples/game.sh` — its delta renderer protects **composition**. Full frame
  4772 µs against 366 µs for the delta, and the width memo moved neither, because
  the cost is walking every cell of the board, not measuring or writing it.

The first kind is what a framework can eventually take over. The second is not:
no amount of downstream cleverness gives back work the app already did to decide
what a cell contains. If your partial path exists for the second reason, keep it,
and say so where the next reader will look.

> **If you do build a ladder, the levels must nest.** Because coalescing takes the
> **maximum**, a cheap request that gets merged with an expensive one is *replaced*
> by it — so level 3 must do everything level 2 does, or the cheap update is
> silently dropped whenever the two land in the same frame. This constraint is easy
> to miss and produces updates that go missing only under load. It is another
> reason to prefer one full repaint.

### Simple example

This works like the browser's `requestAnimationFrame`: event handlers update
state and call `tuish_request_redraw` instead of drawing. The framework calls
`tuish_on_redraw` once when all queued input has been processed.

```sh
_count=0

_on_next ()
{
    _count=$((_count + 1))
    tuish_request_redraw      # schedule full redraw (default -1)
}

_render ()
{
    tuish_clear_to_edge 1        # erase row 1 across our width, then draw
    tuish_vmove 1 1
    tuish_print "Count: $_count"
}

tuish_on_redraw _render
tuish_bind 'char n' '_on_next'
```

No `tuish_on_event` definition is needed -- the default forwards events to
`tuish_dispatch`. If the user holds `n` and 10 keypresses queue up, `_on_next`
runs 10 times (incrementing `_count`), but `tuish_on_redraw` fires only
once -- showing the final value. Single keypresses render immediately with
no added latency.

### Multi-level example

Use levels to skip expensive **state** work when only a cheap update is needed —
after measuring, and remembering that the levels have to nest (see above):

```sh
tuish_on_redraw ()
{
    case "$1" in
        -1) _render_all ;;       # full: repaint everything
         2) _render_line         # partial: current line + status
            _render_status ;;
         *) _render_status ;;    # minimal: status bar only
    esac
}

# Typing a character only needs the current line repainted
_on_char () { _insert_char; tuish_request_redraw 2; }

# Scrolling needs a full repaint
_on_scroll () { _scroll_down; tuish_request_redraw; }

# Cursor movement only needs the status bar
_on_move () { _move_right; tuish_request_redraw 1; }
```

If the user types a character (level 2) then immediately scrolls (level -1),
the framework coalesces them into a single `tuish_on_redraw -1`.

### Immediate rendering

For latency-sensitive updates like text editors, deferred redraw adds a
perceptible delay -- characters don't appear until the input queue drains.
Use `tuish_flush` inside the event handler to render critical output
immediately, then schedule a cheap deferred redraw for the rest:

```sh
_on_char ()
{
    _insert_char               # update state
    _render_current_line       # write line to buffer
    tuish_flush                # send to terminal NOW
    tuish_request_redraw 1     # defer status bar to redraw
}

tuish_on_redraw ()
{
    case "$1" in
        -1) _render_all ;;
         *) _render_status ;;  # level 1: just the status bar
    esac
}
```

How it works: `tuish_flush` sends buffered output to the terminal before the
deferred redraw check runs. The rAF logic then discards the (now empty)
buffer and handles the remaining redraw level. Each keystroke appears on
screen instantly, while cheap updates like the status bar are coalesced.
