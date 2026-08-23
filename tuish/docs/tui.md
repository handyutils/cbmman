<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# Core (tui.sh)

Terminal setup, teardown, traps, and IO stubs. This is the required core
module that manages the terminal lifecycle. Source `compat.sh` and `ord.sh`
before this file.

```sh
. ./src/compat.sh
. ./src/ord.sh
. ./src/tui.sh
```

## Lifecycle

| Function            | Description                                                                                                                                 |
|---------------------|---------------------------------------------------------------------------------------------------------------------------------------------|
| `tuish_init`        | Set up terminal for TUI (raw mode, keyboard protocol detection)                                                                             |
| `tuish_fini`        | Tear down: restore the terminal, or -- for a hosted child -- fold just that child (see below)                                               |
| `tuish_on_fini`     | Register a per-app teardown function, run on **every** exit path (see [event.md](event.md#callbacks))                                       |
| `tuish_quit`        | Signal the event loop to stop (call from inside `tuish_on_event`)                                                                           |
| `tuish_quit_main`   | Quit and leave viewport content visible (cursor below output) -- use for tools like `fzf` where the selected result should remain on screen |
| `tuish_quit_clear`  | Quit, clear viewport output, and restore cursor position -- use for transient UI that should leave no trace                                 |
| `tuish_update_size` | Refresh `TUISH_LINES` and `TUISH_COLUMNS` from the terminal                                                                                 |

`tuish_init` brings up the terminal **device** (raw mode, traps, timing) exactly
once per process. A nested app's `tuish_init` finds the device already up and
simply adopts the context its host created for it, so an app needs no special
code to be embeddable.

`tuish_fini` mirrors that. At top level it restores the terminal. Called on a
**hosted child** it folds only that child -- runs the child's `tuish_on_fini`
hook, clears its region, drops its context, and resumes the parent -- leaving the
shared device up, because a child must never restore the terminal out from under
its host. (On a real process exit the full device teardown still runs even with a
child active, so a signal mid-embed cannot leave the terminal wedged.)

See [hosting.md](hosting.md) for contexts, regions, and running one app inside
another.

## Buffering

| Function      | Description                         |
|---------------|-------------------------------------|
| `tuish_begin` | Start output buffering              |
| `tuish_end`   | Flush buffer and stop buffering     |
| `tuish_flush` | Flush buffer, keep buffering active |

Buffering is automatic inside `tuish_on_event` -- all output is coalesced
and flushed after the handler returns.

`tuish_flush` can also be called **inside** `tuish_on_event` to send output
to the terminal immediately, before the deferred redraw check runs. This
is useful for latency-sensitive updates (see [event.md](event.md#immediate-rendering)).

### Frames nest

`tuish_begin`/`tuish_end` are a **depth counter**, not a flag. Only the outermost pair
does anything: the inner `tuish_begin` does not reset the buffer, and the inner
`tuish_end` does not write.

That is what lets you buffer inside your own render handler without cutting somebody
else's frame in half. The framework opens a frame *before* it calls you, and puts things
in it -- the caret hide that precedes every deferred render, for one. Without nesting, an
app that called `tuish_begin` in its render handler silently threw that away, and the
caret stayed on, blinking wherever the last cell was drawn.

`tuish_flush` is the exception: it writes what has accumulated **now**, at any depth, and
leaves the frame open. That is the whole point of it (an editor echoing a keystroke ahead
of its deferred redraw) -- but note it flushes the *whole* frame, chrome and all, not just
your part of it.

`tuish_end` below depth zero is a no-op, not an underflow, so one unbalanced app cannot
wedge the loop into never flushing again.

### One write is not one repaint

Batching a frame into a single `write(2)` is not the same as the terminal *drawing* it
at once, and the gap is where a lot of apparent blink lives. The browser lane hands
stdout to xterm.js in ~4 KiB `postMessage` chunks, so a full-screen frame can reach the
eye as the erase first and the text a frame later. tmux and a loaded emulator can split
one the same way.

So every write to the device is wrapped in DECSET 2026 (BSU/ESU) — "hold the screen
until I say go". It costs 12 bytes per write and makes the frame atomic at the far end.
The wrap is per **write**, not per `tuish_begin`/`tuish_end` pair, because `tuish_flush`
deliberately emits a partial frame mid-handler and that partial wants to land whole too.

This is the difference between "repainting everything blinks" and "repainting everything
is invisible", which is most of what an app's dirty-tracking was buying.

| Variable     | Default | Description                                            |
|--------------|---------|--------------------------------------------------------|
| `TUISH_SYNC` | `1`     | Wrap device writes in synchronized output (launcher config) |

Terminals that do not implement it ignore the private mode, so there is nothing to
detect. Two places it will not help: the bare Linux VT has no synchronized output at
all, and it cannot make a frame arrive sooner — only whole. Set
`TUISH_SYNC=0` when debugging a renderer, since making a half-drawn frame invisible is
also a way to hide a bug that draws one.

## Cursor Basics

| Function               | Description                        |
|------------------------|------------------------------------|
| `tuish_show_cursor`    | Show cursor                        |
| `tuish_hide_cursor`    | Hide cursor                        |
| `tuish_save_cursor`    | Save cursor position (DECSC)       |
| `tuish_restore_cursor` | Restore cursor position (DECRC)    |
| `tuish_reset_scroll`   | Reset scroll region to full screen |

The caret is **re-declared every frame** -- its position, its visibility, and its *shape*.
The framework hides it before each deferred render; a render handler that wants one calls
`tuish_cursor R C`, which places it, gives it the shape this context declared with
`tuish_cursor_shape`, and shows it. Draw nothing that shows it and there is no caret --
which is what you want for a document, and what you do not want to discover by accident.

For full cursor movement, shapes, and drawing primitives, see [term.md](term.md).

## Terminal Variables

Available after `tuish_init`:

| Variable          | Description                                              |
|-------------------|----------------------------------------------------------|
| `TUISH_LINES`     | Terminal height in rows                                  |
| `TUISH_COLUMNS`   | Terminal width in columns                                |
| `TUISH_INIT_ROW`  | Cursor row when `tuish_init` was called                  |
| `TUISH_PROTOCOL`  | Keyboard protocol: `vt` or `kitty`                       |
| `TUISH_TIMING`    | Timeout resolution: `sub` (subsecond) or `second`        |
| `TUISH_TICK_US`   | Idle interval in microseconds -- the wall-time one idle tick spans, and so the `dt` a time-based animation should integrate against |
| `TUISH_CTX`       | Id of the context just created or mounted (see [hosting.md](hosting.md)) |
| `TUISH_CTX_ROOT`  | Id of the root (top-level app) context                   |

`TUISH_LINES` / `TUISH_COLUMNS` are the **terminal's** size. An app's own drawable
size is `TUISH_VIEW_ROWS` / `TUISH_VIEW_COLS` -- the same thing at top level, but
the region's size when the app is hosted. Code that may run embedded should use the
viewport variables. See [viewport.md](viewport.md).

## Configuration

Set these before calling `tuish_init`:

| Variable             | Default | Description                                                       |
|----------------------|---------|-------------------------------------------------------------------|
| `TUISH_TABSIZE`      | `4`     | Tab stop interval                                                 |
| `TUISH_FINI_OFFSET`  | `0`     | Lines below init position to place cursor after fini              |
| `TUISH_IDLE_TIMEOUT` | `0.26`  | Idle event interval in seconds (clamped to `1` for second timing) |

`TUISH_IDLE_TIMEOUT` is *launcher* configuration: it is read once at `tuish_init`
and never written back by the framework. To change the idle interval at runtime --
which a hosted real-time app must do, since it cannot set an environment variable
before its host's `tuish_init` -- call:

| Function                  | Description                                                        |
|---------------------------|--------------------------------------------------------------------|
| `tuish_idle_interval SECS`| Set the idle interval for the **active context** (e.g. `0.02` for 50Hz) |

Being per-context, a child's chosen rate is restored to the host's when the child
is unmounted. A cooperative host reconciles differing rates with
`tuish_ctx_sync_interval` and `tuish_ctx_tick`; see
[hosting.md](hosting.md#idle-tick-negotiation).

### An idle tick is a timeout, not a timer

This is the one thing to understand about the clock, because everything real-time rests
on it and it is not what the name suggests.

An `idle` event is the reader's `read -t<interval>` **timing out**. Nothing schedules it.
So while a key is held, an idle fires only if your interval is **shorter than the
terminal's autorepeat interval** -- above it, a byte is always waiting before the timeout
can land, the read never times out, and the tick stops for as long as the key is down.

The margin is thinner than it looks. A 20ms interval against a typical ~33ms autorepeat
survives on 13ms of slack, and `xset r rate 250 50` erases it outright.

The framework will not let the clock **stop**: when events keep arriving with no timeout
between them, `tuish_run` injects the tick the reader is not delivering. Healthy
interleaving (`idle, byte, idle, byte`) never triggers it, so a well-fed loop is exactly
what it always was.

| Variable           | Default | Description                                                     |
|--------------------|---------|-----------------------------------------------------------------|
| `TUISH_BURST_MAX`  | `2`     | Events with no read timeout before a tick is injected (launcher config) |

What that buys is **liveness, not fidelity**. Under starvation the tick fires per-N-events
rather than per-wall-ms, so time dilates -- fast where the interval is coarse, slow where
the autorepeat is. It never stops, which is what it did before. True fidelity needs a wall
clock, and reading one costs a fork per tick on the shells tui.sh targets; the accumulator
stays the clock, and this bounds how wrong it gets.

**So a real-time app should still pick an interval below the autorepeat interval** (the
platformer's `0.02` is the working example). The guarantee is a floor, not a substitute.

A corollary worth stating, because a demo claimed otherwise: "the app plays the same at any
`TUISH_IDLE_TIMEOUT`" holds for anything the tick integrates (gravity, animation), and does
**not** hold for anything driven by a held key.

## Terminal Setup

tui.sh configures the terminal at startup and restores it on exit:

| Feature            | Enable sequence      | Purpose                                           |
|--------------------|----------------------|---------------------------------------------------|
| Raw mode           | `stty raw -isig ...` | Byte-by-byte input, no signal generation          |
| Bracketed paste    | `ESC[?2004h`         | Paste start/end markers                           |
| Application cursor | `ESC[?1h`            | SS3 arrow keys                                    |
| Focus events       | `ESC[?1004h`         | Focus in/out reporting                            |

All modes are disabled on exit, and `stty` is restored to its previous state.

The kitty keyboard protocol (`ESC[>9u`, CSI u key events) is **not** enabled
at startup — `TUISH_PROTOCOL` defaults to `vt`. Opt in by calling
`tuish_kitty_on` (it probes for support and falls back to VT if absent);
`tuish_kitty_off` and `tuish_fini` restore it.
