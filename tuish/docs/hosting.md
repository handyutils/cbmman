<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# Hosting and Contexts (tui.sh)

One tuish app can run **another tuish app inside a region of itself** -- in the
same process, with no forks, over the same keyboard. A page can open an example
in its content box; a dashboard can drive a clock and a text editor side by side.

Two shapes:

| Shape           | Who owns the event loop         | Use it when                                            |
|-----------------|---------------------------------|--------------------------------------------------------|
| **Modal**       | the child (a nested `tuish_run`) | the child takes over until it quits, then the host resumes |
| **Cooperative** | the host (one loop, always)      | several children must stay live at once                |

Cooperative is the more general of the two: because the host keeps its loop, its
own chrome stays interactive and any number of children stay live simultaneously.

## Contexts

A **context** is one app's logical state: its viewport, transform, bindings,
render/event handlers, redraw scheduler, canvas, and idle tick.

The active context's fields live in plain shell globals -- the "registers" that
the hot paths read. Inactive contexts are spilled to namespaced saved frames. A
switch marshals a fixed, registered field list and only ever happens at app
boundaries, never per byte or per frame, so the render path pays nothing for it.

The terminal **device** -- raw mode, traps, the byte reader, the screen size, the
keyboard protocol -- is singular and is *not* part of any context. `tuish_init`
brings the device up exactly once per process; a nested app's `tuish_init` simply
adopts the context its host created for it.

| Function                          | Purpose                                                             |
|-----------------------------------|---------------------------------------------------------------------|
| `tuish_ctx_create`                | Allocate a context seeded with default field values; id in `TUISH_CTX` |
| `tuish_ctx_create_region R C W H` | Create **and activate** a child bound to a region of the active context |
| `tuish_ctx_activate CTX`          | Spill the current context, fill the working set from `CTX`            |
| `tuish_ctx_reseat CTX R C W H`    | Move a child's rectangle (call from the host's resize handler)        |
| `tuish_ctx_destroy CTX`           | Free a context's bindings and drop its saved frame                    |
| `tuish_ctx_register NAME...`      | Register working vars as marshalled context fields (for **modules**)  |
| `tuish_ctx_declare SET NAME...`   | Declare an **app's** field set, once, at source time                  |
| `tuish_ctx_fields SET`            | Attach a declared set to the active context (in your `_setup`)        |

### State that belongs to an INSTANCE

An app's state lives in plain shell globals -- `_cur_row`, `_view_top` -- and a shell has
exactly one of each. So mounting the same app **twice** used to mean two widgets sharing one
cursor: type in the left editor and the right one's caret moved.

Declare the state instead, and each instance gets its own copy:

```sh
_cur_row=1                       # the defaults, written where they belong
_view_top=1
_status_msg=''

tuish_ctx_declare _ed  _cur_row _view_top _status_msg     # once, at SOURCE time

_ed_setup ()
{
	tuish_init
	tuish_ctx_fields _ed         # this instance's copy, at those defaults
	...
}
```

`tuish_ctx_fields` resets the set to its declared defaults on attach, so it also replaces the
hand-written "fresh state each launch" block an app would otherwise need.

**Declare at source time, not inside `_setup`.** It looks like it should not matter, and it is
the one thing that must be right: the defaults are captured when you declare. Declare inside
`_setup` and the *second* instance captures whatever the *first* one currently holds -- it
would open on the other editor's cursor row.

Two tiers, and the difference is who they belong to:

| | `tuish_ctx_register` | `tuish_ctx_declare` / `tuish_ctx_fields` |
|---|---|---|
| for | framework modules | apps |
| marshalled for | **every** context | only contexts that attached the set |
| defaults captured | at registration | at declaration (source time) |
| two instances | share nothing (framework state is per-context anyway) | **each gets its own copy** |

See `examples/twins.sh` -- two copies of the editor, side by side, in one loop. The editor is
unchanged, and does not know there is another one of it.


| Variable         | Meaning                                                    |
|------------------|------------------------------------------------------------|
| `TUISH_CTX`      | Id of the context just created or mounted                  |
| `TUISH_CTX_ROOT` | Id of the root (top-level app) context                     |
| `TUISH_CTX_QUIT` | Set by `tuish_ctx_dispatch`/`tuish_ctx_tick` when the child it drove quit itself |
| `TUISH_CTX_HANDLED` | Set by `tuish_ctx_dispatch`: 1 if the child acted on the event, 0 if it declined it (see [Scroll chaining](#scroll-chaining)) |

`R C` are the region's top-left in the **host's** logical coordinates and `W H`
its size. The host's live transform resolves that to absolute cells, so regions
compose to any depth.

Inside a child, its region *is* its screen: logical `(1,1)` is the region's
top-left, drawing clips to the region, and `tuish_viewport fullscreen` fills the
region rather than the terminal (it never touches the alternate screen). That is
what lets a full-screen example run unchanged inside a host's content pane.

## Writing a hostable app

An app is hostable when it does two things.

**1. Register handlers by name; never redefine the global hooks.**

```sh
tuish_on_redraw _my_render      # NOT: tuish_on_redraw () { ... }
tuish_on_event  _my_on_event    # NOT: tuish_on_event  () { ... }
tuish_on_fini   _my_fini        # restore anything device-ish you changed
```

Redefining `tuish_on_redraw` as a function still works, but it is process-global:
two apps written that way would fight over the same function. Registration stores
the handler *per context*, so apps compose. See [event.md](event.md).

**A render handler is not optional, even if you never ask for a redraw yourself.** A
real-time app paints every frame directly (`examples/game.sh` does — `tuish_request_redraw`
coalesces, which freezes a game while a key is held). It still has to answer
`tuish_on_redraw`, because that is how a **host** repaints it: when the host assembles a
frame (its background fill would otherwise land on top of you) and when it moves you.
Register one that forces a full repaint. An app that registers none paints *nothing* where
the host put it, and the reader is left looking at whatever was on screen underneath.

`tuish_on_fini` matters more than it looks. A cooperatively-driven app never
returns from a `tuish_run` of its own, so cleanup placed after `tuish_run` never
runs. `tuish_fini` invokes the registered hook on **every** exit path -- standalone
teardown, modal return, and cooperative unmount.

Use it for state that is *yours* -- a scratch buffer to free, a file to flush.

### An app REQUESTS device state. It never restores it.

This is the one rule that makes hosting seamless, and it is worth stating as a rule because
the alternative looks so reasonable.

The terminal is **singular**. Your context is not. So when you switch on the alt-screen, the
mouse, a caret shape, autowrap, or kitty's detailed mode, you are not changing *your*
state -- you are changing the one terminal that you, your host, and every sibling widget are
all looking at. Turning it back off on your way out reaches outside the rectangle you own.

And a fini hook is exactly where that goes wrong, because a host unmounts a child for its own
reasons: the reader left edit mode, or the widget scrolled off the pane. One editor closing
would reset the caret under another one still being typed into.

So: **declare what you want, and stop there.**

```sh
_app_setup ()
{
	tuish_init
	tuish_cursor_shape 6      # "I want a bar caret." That is the whole contract.
	tuish_mouse_on            # "I want mouse events."
	...
}
                              # No fini hook. Nothing to put back.
```

The framework tracks every such request against the *device* (not against your context, which
may be long destroyed by the time anyone asks) and puts the terminal back exactly once, when
the process actually exits. Where the answer depends on who is active -- autowrap, which the
drawing code reads to know whether the terminal clips at the right edge -- it is reconciled
for you on every context switch.

The device layer owns, and will restore: **alt-screen, scroll region, mouse tracking, caret
shape, autowrap, kitty detailed mode, bracketed paste, focus events, `stty`, and the signal
traps.**

> `tuish_hosted` still exists, and a host may legitimately ask. But **in an app it is a
> smell**: if you are reaching for it, you are almost certainly about to touch the device.
> No example in this repo needs it any more.

| Function        | Description                                                     |
|-----------------|-----------------------------------------------------------------|
| `tuish_hosted`  | Predicate: am I a hosted child, or do I own this terminal?       |

**2. Split setup from the event loop.**

Register bindings and handlers *after* `tuish_init`, so they land in whichever
context is active -- the root standalone, the region when hosted -- and put
everything except the loop in a `_setup` function:

```sh
_app_setup ()      # everything but the loop: a cooperative host calls THIS
{
	tuish_init                     # adopts the host's context when nested
	tuish_on_redraw _app_render
	tuish_bind 'char q' '_app_quit'
	tuish_viewport fullscreen      # hosted -> fills our region
	_app_render
}

_app_main ()       # the blocking form: standalone, or a modal host
{
	_app_setup
	tuish_run || :
	tuish_fini
}

# Only bootstrap when we are the top-level program.
if test -z "${_tuish_tui_loaded:-}"
then . ../src/tui.sh; ...; _app_main; fi
```

A host that sources the file gets the definitions without running the app. Every
example in `examples/` is built this way.

Two things to avoid, because they punch out of a region:

- **`tuish_clear_to_eol` / `tuish_clear_line` / `tuish_clear_screen`** act on the
  *physical* terminal line or screen. Use `tuish_clear_to_edge ROW [COL]`, which
  is bounded by the drawable area. See [term.md](term.md).
- **`TUISH_COLUMNS` / `TUISH_LINES`** are the terminal's size. An app's own width
  and height are `TUISH_VIEW_COLS` / `TUISH_VIEW_ROWS`.

## Modal hosting

The host creates a region, calls the child's `_main`, and gets control back when
the child quits:

```sh
_open_example ()
{
	tuish_ctx_create_region 4 3 "$_box_w" "$_box_h"
	_cd_main                      # the child owns the keyboard until it quits
	tuish_request_redraw -1       # repaint our chrome over it
}
```

A click **outside** the child's region ends the child (its loop is the only one
running, so quitting is the only way to hand control back). The click itself is
consumed -- closing the child *is* the response to it.

## Cooperative hosting

The host keeps its single loop and feeds each decoded event to the right child.
No child runs a loop of its own, so every child stays live at once.

**Start with `host.sh`.** The rest of this section is the machinery underneath it, and
you should read it -- but you should not have to *write* it. [`src/host.sh`](../src/host.sh)
is what you end up building the second time you host anything, and it already gets the
parts wrong that are easy to get wrong.

```sh
. ./src/host.sh                 # after tui.sh + event.sh

tuish_host_pane 4 2 60 20       # the window children are seen through

tuish_host_begin                # declare the children; re-run this whenever the layout moves
tuish_host_slot clock  _clk_setup '' 4 2  28 20
tuish_host_slot editor _ed_setup  '' 4 32 30 20
tuish_host_commit               # mounts, reseats, unmounts, adopts the fastest tick

_render ()
{
	tuish_begin
	_draw_chrome
	tuish_host_paint            # every child, into THIS frame, focused one last
	tuish_end
}

_on_event ()
{
	tuish_host_route && return 0    # mouse -> the child under the pointer (a click focuses
	                                # it); keys -> the focused one; idle -> tick each at its
	                                # own rate. Returns 1 if nothing took it.
	tuish_dispatch || :             # ... and then it is the host's
}
```

| Function                                   | Purpose                                                     |
|--------------------------------------------|-------------------------------------------------------------|
| `tuish_host_pane [R C W H]`                | The window children are seen through; they clip to it (no args: no pane) |
| `tuish_host_begin`                         | Start (re)declaring the child list                          |
| `tuish_host_slot ID FN [ARG] R C W H [modal]` | One child, and where it goes                             |
| `tuish_host_commit`                        | Reconcile: mount, reseat, unmount, adopt the fastest tick    |
| `tuish_host_paint`                         | Render live children into the host's open frame              |
| `tuish_host_paint_focus`                   | Render only the focused child (cheap partial repaints)       |
| `tuish_host_render ID`                     | Render only that child (you changed what it shows)           |
| `tuish_host_route`                         | The standard router; returns 1 if nothing took the event     |
| `tuish_host_focus [ID]`                    | Give the keyboard to a child (no arg: take it back)          |
| `tuish_host_at X Y`                        | Which child is under (x,y)? -> `TUISH_HOST_HIT`              |
| `tuish_host_owns_row ROW`                  | Does a live child own that screen row?                       |
| `tuish_host_row_free ROW C W`              | Which cells of it are still yours -> `TUISH_HOST_SEGS`       |
| `tuish_host_ctx ID`                        | That child's context -> `TUISH_HOST_CTX`                     |
| `tuish_host_drop ID` / `tuish_host_clear`  | Unmount one / all                                            |

Answers come back in variables, never on stdout — asking a question must not cost a fork:

| Variable            | Set by                | Holds                                             |
|---------------------|-----------------------|---------------------------------------------------|
| `TUISH_HOST_FOCUS`  | `tuish_host_focus`, and a click | The child holding the keyboard (`''` = the host) |
| `TUISH_HOST_HIT`    | `tuish_host_at`       | The child under the pointer (`''` = none)          |
| `TUISH_HOST_SEGS`   | `tuish_host_row_free` | The free runs of a row, as `C W C W ...`           |
| `TUISH_HOST_CTX`    | `tuish_host_ctx`      | That child's context (`''` = not mounted)          |
| `TUISH_HOST_DROVE`  | `tuish_host_route`    | The id it handed the event to                      |
| `TUISH_HOST_QUIT`   | `tuish_host_route`    | The id of a child that ended itself                |

Three things it gets right that a hand-rolled host usually does not:

- **`ID` is not the rectangle.** A scrolling host re-declares every child at a new row on
  every wheel tick. Reconciling on identity means those children are *reseated*, not torn
  down and remounted — and a mount **paints**, so remounting them all would redraw the
  page widget by widget, one write each, before the real repaint even started.
- **The focused child paints last**, which is the only reason the caret ends up where you
  are typing rather than wherever the next widget's last cell landed.
- **An event a child declines comes back** (see [Scroll chaining](#scroll-chaining)).

After routing, `TUISH_HOST_DROVE` holds the id it handed the event to and
`TUISH_HOST_QUIT` the id of a child that ended itself — so you can wrap the standard
policy instead of forking it. What a child quitting *means* is yours to decide; route does
not unmount it for you.

`examples/cooperative.sh` is the whole thing in ~30 lines.

### The caret

There is one caret and there may be many widgets, so the caret belongs to whoever shows it
last -- and a host paints its **focused** child last, on purpose. That is the whole
negotiation, and it covers the shape too: `tuish_cursor_shape` *declares* what this
context's caret looks like, and `tuish_cursor` re-asserts it every frame along with the
caret's position and visibility. The focused child's declaration is therefore the last one
in the frame, and the one the terminal is left holding.

A widget that shows a caret and cares what it looks like declares a shape. One that does
not, inherits — the same bargain the caret's *position* has always offered.

This is why a shape must never be a one-shot escape sent at setup. A child is mounted from
inside the host's event handler, and a deferred redraw **discards that handler's frame**
(the redraw supersedes whatever the handler drew) — so an escape written there is thrown
away, and nothing re-declares it. That is exactly how `examples/editor.sh` drew a thin bar
in a terminal and a fat block on the website, from the same line of code.

> **The same hole swallows device MODES.** `tuish_mouse_on`, `tuish_kitty_on` and friends
> emitted from a child's setup are one-shot escapes too: written into a frame that may be
> discarded, and never re-declared. The mode *variable* survives and then lies about what
> the terminal was told. Until that is fixed generally, **device modes belong to the host** —
> enable them once, in the host, not in a widget.

### Painting around live children

A host that draws its own content *around* its children — prose with widgets embedded in
it, a scrolling document — must not paint the cells the children own, or it wipes a running
app on every repaint. There are two questions, and they are not the same one.

`tuish_host_owns_row ROW` is the cheap predicate: a line of text is either drawn or it is
not, so a row is all the answer you need.

`tuish_host_row_free ROW C W` is what you need before you **fill**, because filling happens
cell by cell. A child narrower than the pane leaves columns beside it that are *yours*. Two
children side by side leave a gap between them that is also yours. A host that skips the
whole row paints neither — so whatever was there last frame simply stays, and the children
end up standing in a puddle of stale text as the content scrolls underneath them. Ask what
is free and fill exactly that:

```sh
if tuish_host_row_free "$_row" "$_c" "$_w"
then
	set -- $TUISH_HOST_SEGS          # "C W C W ..." — the runs no child covers
	while test $# -ge 2
	do tuish_draw_fill "$_row" "$1" "$2" 1 bg=$C_PANEL; shift 2; done
fi
```

It returns 1 when the children cover the span outright, so a full-pane child costs you
nothing. Both queries are clip-aware: a child scrolled under the pane's edge owns only what
can actually be seen of it.

### The primitives underneath

| Function                        | Purpose                                                        |
|---------------------------------|----------------------------------------------------------------|
| `tuish_ctx_mount R C W H FN...` | Create a region, run the child's (non-blocking) `FN` setup in it, leave the host active |
| `tuish_ctx_dispatch CTX`        | Drive a child with the currently decoded event (keys, mouse, resize) |
| `tuish_ctx_tick CTX`            | Drive a child with an **idle** tick, at *its own* rate (see below) |
| `tuish_ctx_render CTX`          | Repaint a child now — into the host's frame if one is open (see [One frame, one write](#one-frame-one-write)) |
| `tuish_ctx_sync_interval CTX...`| Adopt the fastest tick among the host and the listed children   |
| `tuish_ctx_unmount CTX`         | Fold a child's viewport and drop its context                    |

```sh
tuish_ctx_mount "$_lr" "$_lc" "$_lw" "$_lh" _clk_setup ; _clk=$TUISH_CTX
tuish_ctx_mount "$_rr" "$_rc" "$_rw" "$_rh" _ed_setup  ; _ed=$TUISH_CTX
tuish_ctx_sync_interval "$_clk" "$_ed"

_on_event ()
{
	case "$TUISH_EVENT_KIND" in
		mouse)  _in_left  && tuish_ctx_dispatch "$_clk"
		        _in_right && tuish_ctx_dispatch "$_ed" ;;
		key)    tuish_ctx_dispatch "$_ed"
		        test "$TUISH_CTX_QUIT" = 1 && tuish_quit_clear ;;
		idle)   tuish_ctx_tick "$_clk"; tuish_ctx_tick "$_ed" ;;
		signal) _relayout
		        tuish_ctx_reseat "$_clk" "$_lr" "$_lc" "$_lw" "$_lh"
		        tuish_ctx_reseat "$_ed"  "$_rr" "$_rc" "$_rw" "$_rh"
		        tuish_ctx_dispatch "$_clk"; tuish_ctx_dispatch "$_ed" ;;
	esac
}
tuish_on_event _on_event
```

When a child context is active the whole pipeline already targets it -- mouse is
decoded into the child's region-local frame, dispatch uses the child's bind table,
and the render path calls the child's handler -- so driving a child is just
"activate it, feed it the event, restore the host".

The host routes; a driven child never sees an event that landed outside its
region, so it has no reason to self-quit.

### Quitting

Let a child quit **by its own means** and detect it, rather than intercepting its
quit key. After each `tuish_ctx_dispatch` / `tuish_ctx_tick`, `TUISH_CTX_QUIT` is 1
if the child ended itself; the host then calls `tuish_ctx_unmount`. This matters
because a terminal or browser may reserve the key an app quits on (Ctrl+W closes a
browser tab), so a host cannot reliably know or intercept it.

It is worth giving the host its own escape hatch too -- `web/site/site.sh` binds
Esc to close whatever example is mounted.

### Scrolling a live child

A child does not have to fit in the pane it is shown through. A region is **three
independent things**, and keeping them apart is what lets a running app scroll under
an edge like any other content:

| | |
|---|---|
| **layout size** (`TUISH_VIEW_ROWS`/`COLS`) | how big the child *thinks* it is. It lays out to fill this, so it must not shrink just because part of it is off-screen — or the child reflows instead of sliding. |
| **origin** (`TUISH_VIEW_TOP`/`LEFT`) | where its logical `(1,1)` lands. May be **outside** the visible pane — even above row 1. That *is* a child scrolled partly out of view. |
| **visible clip** | what may actually reach the terminal. `tuish_vmove` drops any cell outside it. |

So pass `tuish_ctx_reseat` a rectangle whose top is above the pane, plus the pane
itself as the clip window:

```sh
tuish_ctx_reseat "$_ctx"  $(( _pane_r + _line - _scroll ))  "$_pane_c" "$_w" "$_h" \
                          "$_pane_r" "$_pane_c" "$_pane_w" "$_pane_h"
tuish_ctx_render "$_ctx"     # repaint it where it now is
```

The child is **occluded, not resized**. It never learns it is clipped.

`tuish_ctx_render` matters here: a child repaints on its own idle tick, and at a lazy
interval that leaves a visibly torn widget on screen for a whole tick while the user
scrolls. Repaint it yourself, right after you move it.

### One frame, one write

Call `tuish_ctx_render` **inside your own `tuish_begin`/`tuish_end`** and the child's
output is spliced into your frame rather than written on its own:

```sh
tuish_begin
_paint_background
_draw_prose
_render_children      # tuish_ctx_render for each — no writes yet
tuish_end             # ONE write: background, prose, and every child
```

This is not just a byte count. `_tuish_buf` is a *per-context* frame, so a host cannot
buffer "everything that happens" — the moment it activates a child, it is looking at the
child's buffer, and the child's own `tuish_end` goes straight to the terminal. A page
with three widgets therefore emitted four writes, and the terminal drew each: you saw the
prose land at the new scroll offset while the widgets were still at the old one, a frame
at a time. It reads as a shimmer, or a ghost trailing the text.

The child's output enters the buffer at the point you called from, so render children
**last** — after your background fill, or it lands on top of them.

`tuish_ctx_mount` does the same with the child's first paint, so mounting a widget in
response to a click does not flash it onto the screen a frame before the page around it.

**Declare the pane once.** `tuish_ctx_clip R C W H` says "the children of this context
are seen through this window". `tuish_ctx_mount` and `tuish_ctx_reseat` both honour it,
so you say it in your layout and never again:

```sh
tuish_ctx_clip "$_pane_r" "$_pane_c" "$_pane_w" "$_pane_h"
tuish_ctx_mount "$_r" "$_c" "$_w" "$_h" _app_setup     # clipped from its first paint
```

That "first paint" matters. `tuish_ctx_mount` does not merely create a context — it runs
the child's setup *and paints it*. A child mounted while already partly outside the pane
would draw over the host's chrome once, before any reseat could bound it.

**Clipping only holds for drawing that goes through the transform**, which is
everything except the raw escapes. Two rules for an app that may be clipped:

- **Honour `tuish_vmove`'s return value.** It *refuses* a clipped cell. Printing
  anyway drops the text at whatever cell the cursor last sat on — standalone that
  almost never bites (a cell is refused only off-screen), but in a clipped region it
  fires constantly and smears stray text across the host's chrome. Use
  `if tuish_vmove R C; then …; fi`, or the primitives that already do
  (`tuish_text`, `tuish_put_at`, `_tuish_write_at`, the `draw.sh` calls).
  A bounds test is *not* a substitute — `TUISH_VIEW_ROWS` is the layout height, which
  stays full-size while the visible clip shrinks. Only `tuish_vmove` knows.
- Keep off `tuish_clear_screen` / `clear_line` / `clear_to_eol` / `clear_to_bol` and
  `tuish_move`, which address the physical terminal. See [term.md](term.md).

### Scroll chaining

Once a child scrolls *with* the page, the wheel over it is ambiguous. It may be the
child's (an editor with more lines than it can show) or the page's (a widget that
scrolls nothing at all). Routing it purely by position gets this wrong in the way that
matters most: park the pointer over a widget that ignores the wheel and the page stops
scrolling **entirely** -- and it can never recover, because nothing moves the widget
out from under the pointer.

So ask the child first, and take the event back if it did nothing with it:

```sh
tuish_ctx_dispatch "$_ctx"
if test "$TUISH_CTX_HANDLED" -eq 0
then
    case "$TUISH_EVENT" in
        whup|wdown) _scroll_the_page ;;   # the child declined it — it is ours
    esac
fi
```

`TUISH_CTX_HANDLED` is 1 when a binding in the child matched **and acted**. Three ways
it comes back 0:

- the child has no binding for the event;
- the event never reached the child's bindings at all (a child that never called
  `tuish_mouse_on` drops mouse events);
- a binding matched, ran, and called **`tuish_pass`** -- "I looked at this and I am
  not acting on it."

That last one is what makes the end of a scroll continue onto the page, the way a
nested scroller does in a browser. `tuish_dispatch` marks the event handled *before*
running the action, precisely so the action can hand it back:

```sh
_scroll_down ()
{
    test $_top -ge $_max && { tuish_pass; return 0; }   # already at the bottom
    _top=$((_top + 3))
    tuish_request_redraw
}
```

An app that is a *picture* rather than an app -- a rendered snippet, a chart -- should
bind `tuish_pass`, not `:`, as its catch-all. `:` silently eats every event a host
offers it.

A **full-pane** child is the exception: it owns its region and there is nothing behind
it to scroll, so a host should let it consume the wheel unconditionally.

### Idle-tick negotiation

Children can want different clocks: a game at 50Hz next to a clock at 1Hz. One
loop has one poll rate, so two rules pull in opposite directions:

- the **fast** child must not be *slowed* -- so the host polls at the **fastest**
  tick among itself and its children (`tuish_ctx_sync_interval`);
- the **slow** child must not be *sped up* -- so each child accumulates the host's
  tick and is only driven once **its own** interval has elapsed (`tuish_ctx_tick`).

The host therefore polls fast enough for the fastest child and divides that down
per child. A 50Hz game and a 1Hz clock hosted together each animate at their own
rate, in one loop, with no forks and no wall-clock reads.

A child asks for its rate with `tuish_idle_interval SECS` (per-context, so the
host's own tick is restored when the child is unmounted). Its tick in microseconds
is `TUISH_TICK_US` -- the wall-time one idle tick spans, which is what a
time-based animation should integrate against.

`TUISH_IDLE_TIMEOUT` is *launcher* configuration, read once at `tuish_init`. It is
never written by the framework; use `tuish_idle_interval` to change a rate at
runtime.

## See also

- `examples/cooperative.sh` -- one loop driving a live clock and the real editor
- `tests/lib/host_demo.sh` -- the minimal modal host
- `tests/integration/test_cooperative.sh`, `tests/integration/test_hosting.sh`
- `tests/unit/test_context.sh` -- region seating, the region-safe erase, negotiation
