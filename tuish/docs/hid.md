<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# Human Interface Device (hid.sh)

Keyboard and mouse event resolution. Overrides event.sh's stub with full
name resolution for keyboard, mouse, focus, paste, and signal events.
Source after `event.sh`.

```sh
. ./src/event.sh
. ./src/hid.sh
```

## Event Reporting Controls

Mouse tracking and detailed key events (press/release/repeat) are **off by
default**. Enable them at runtime after `tuish_init`:

| Function             | Description                                                     |
|----------------------|-----------------------------------------------------------------|
| `tuish_kitty_on`     | Probe terminal and enable kitty keyboard protocol if supported  |
| `tuish_kitty_off`    | Disable kitty keyboard protocol, restore VT mode                |
| `tuish_mouse_on`     | Enable mouse tracking (clicks, drags, scroll, motion)           |
| `tuish_mouse_off`    | Disable mouse tracking                                          |
| `tuish_detailed_on`  | Enable press/release/repeat reporting                           |
| `tuish_detailed_off` | Disable press/release/repeat reporting                          |
| `tuish_modkeys_on`   | Enable physical modifier key events (`shift.l`, `ctrl.r`, etc.) |
| `tuish_modkeys_off`  | Disable physical modifier key events                            |

These can be toggled at any time. When mouse is off, mouse events are silently
dropped. When detailed is off, `-rep` and `-rel` suffixed events are dropped,
and the kitty protocol omits the event-types flag for less terminal traffic.
When modkeys is off, physical modifier key events (e.g. `shift.l`, `ctrl.r`)
are dropped.

## Held Keys

A plain VT never reports a key **release**. Hold a key down and the terminal simply
repeats the same event at the OS autorepeat rate — so "is A down right now?" has no
direct answer, and a real-time app has to infer it from **recency**: a repeat arrived
a moment ago, so the key is still down; nothing for a while, so it was let go.

The framework keeps that inference for you. **No kitty required** — this is plain VT.

| Function                  | Description                                                        |
|---------------------------|--------------------------------------------------------------------|
| `tuish_key_track KEY...`  | Declare the keys this context tracks. **Replaces** the set          |
| `tuish_key_down KEY...`   | Predicate: is **any** of them down? (returns 0 = yes)              |
| `tuish_key_ttl SECS`      | How long a repeat keeps a key "down" (default `0.15`)              |

| Variable           | Description                                                       |
|--------------------|-------------------------------------------------------------------|
| `TUISH_KEY_REPEAT` | On a `key` event: `1` if it is a repeat of a key already down, `0` if it is a fresh press |

```sh
_app_setup ()
{
    tuish_init
    tuish_key_track 'left' 'char a' 'right' 'char d'   # after init: it is per-context
    tuish_key_ttl 0.15
}

_jump ()
{
    # A running jump, or a standing one?
    if tuish_key_down 'left' 'char a' 'right' 'char d'
    then _carry_momentum; else _straight_up; fi
}
```

`tuish_key_down` takes several keys and ORs them, because aliasing is the normal case:
`left` and `char a` are one action and deserve one question. It answers with an **exit
status**, which costs no fork — the same bargain as `tuish_hosted`.

Call `tuish_key_track` **after `tuish_init`**, next to your binds: the tracked set is a
context field, so a hosted child gets its own, and two mounts of one app never share a
keyboard.

### Press vs. repeat

`TUISH_KEY_REPEAT` is the press/repeat distinction the kitty protocol reports natively
and VT does not — synthesized from the window already being kept. It is what makes an app
**edge-triggerable**:

```sh
_walk ()
{
    _face=$1
    test "$TUISH_KEY_REPEAT" -eq 1 && return 0   # repeats do nothing...
    _step_one_tile "$1"                          # ...only a fresh press steps
}
```

You cannot derive this from `tuish_key_down` yourself. The window is refilled **before**
your binding runs — deliberately, so a handler can ask about the very key whose event is
in flight — which means `tuish_key_down` says "down" either way by the time you look.

### The three timescales

The window has to land between two numbers you do not control:

| | |
|---|---|
| autorepeat interval (~33ms) | the window must **exceed** this, or a held key looks released in the gaps between repeats |
| **the window** (150ms) | |
| initial repeat delay (~500ms) | the window must **fall short** of this, or a single tap is still "down" when the first repeat lands — and a tap becomes a hold |

Miss on either side and it is not subtly wrong, it is the wrong feature. The default sits
in the middle on purpose; `examples/game.sh` reached the same value by hand before this
existed.

That initial delay is inherent to VT: a held key gives you one event, then ~500ms of
nothing, then a stream. An app that wants motion during that gap must decide for itself
what a press means — the framework will not invent repeats that the terminal did not send.

### What kitty adds

Nothing you must have. With `tuish_detailed_on` the terminal sends real `-rep` and `-rel`
events, and the same API uses them when they arrive: a release empties the window **at
once** instead of waiting it out, and `TUISH_KEY_REPEAT` is read from the event rather than
inferred. Same calls, same app code, better source where available.

> Device modes belong to the host — see [hosting.md](hosting.md). Do not call
> `tuish_detailed_on` from a widget to get this; the VT path is the supported one.

### Decay rides your tick

Windows are aged on the **idle tick**, by `TUISH_TICK_US`. This is the other reason the
feature is not an app's to write: a hosted child is ticked at its *own* negotiated rate
(see [hosting.md](hosting.md#idle-tick-negotiation)), and it cannot learn that rate without
asking whether it is hosted — which is a smell. Driving the decay from the event path means
a child gets it right for free.

An app that tracks nothing pays one string comparison per event.

## Overflow Control

Line wrapping (DECAWM) is **off by default** -- content past the right
edge is clipped by the terminal. Toggle at runtime:

| Function         | Description                                            |
|------------------|--------------------------------------------------------|
| `tuish_wrap_on`  | Enable line wrapping (DECAWM on)                       |
| `tuish_wrap_off` | Disable line wrapping (DECAWM off, clip at right edge) |

```sh
tuish_init
tuish_mouse_on         # app uses mouse
# tuish_detailed_on    # uncomment if you need release/repeat events
# tuish_modkeys_on     # uncomment if you need physical modifier key events
tuish_viewport fixed 10
tuish_run || :
tuish_fini
```

---

## Event Kinds

Every event sets `TUISH_EVENT` (the event name) and `TUISH_EVENT_KIND` (the
category). Use `TUISH_EVENT_KIND` to dispatch by category, and `TUISH_EVENT` for
specific event handling.

| Kind     | Description                                          | Example events                            |
|----------|------------------------------------------------------|-------------------------------------------|
| `key`    | Keyboard input (characters, special keys, modifiers) | `char a`, `ctrl-w`, `up`, `f5`, `shift.l` |
| `mouse`  | Mouse interactions (clicks, drags, scroll, motion)   | `lclik`, `lhold`, `whup`, `move`          |
| `focus`  | Terminal window focus changes                        | `focus-in`, `focus-out`                   |
| `paste`  | Bracketed paste boundaries                           | `paste-start`, `paste-end`                |
| `signal` | OS signal notifications                              | `resize`, `cont`                          |
| `idle`   | No input received within timeout                     | `idle`                                    |

### Usage Example

```sh
tuish_bind 'ctrl-w' 'tuish_quit'
tuish_bind 'resize' '_on_resize'
tuish_bind 'lclik'  '_on_click'
```

Or dispatch by kind with a `tuish_on_event` override:

```sh
tuish_on_event ()
{
    case "$TUISH_EVENT_KIND" in
        key)    handle_key;;
        mouse)  handle_mouse;;
        signal) handle_signal;;
    esac
}
```

---

## Modifier Prefix Ordering

All modifier combinations use a consistent prefix order:

```
ctrl- alt- shift- super- hyper- meta-
```

This applies to keyboard events (VT and kitty), mouse events, and modifier
helper functions. Examples: `ctrl-alt-a`, `ctrl-shift-z`, `ctrl-alt-shift-up`.

---

## Keyboard Events (Kind: `key`)

### Named Special Keys

| Event name    | Byte(s)    | Notes                                                                                  |
|---------------|------------|----------------------------------------------------------------------------------------|
| `ctrl-bksp`   | 0x08 (8)   | BS / Ctrl+H / Ctrl+Backspace (see [Control Byte Collisions](#control-byte-collisions)) |
| `tab`         | 0x09 (9)   |                                                                                        |
| `enter`       | 0x0D (13)  | CR; may be unreliable via tmux PTY                                                     |
| `esc`         | 0x1B (27)  | Bare ESC (no following bytes)                                                          |
| `bksp`        | 0x7F (127) | DEL / Backspace                                                                        |
| `ctrl-bslash` | 0x1C (28)  | Requires `quit undef` in stty                                                          |
| `ctrl-]`      | 0x1D (29)  |                                                                                        |
| `ctrl-^`      | 0x1E (30)  |                                                                                        |
| `ctrl-_`      | 0x1F (31)  |                                                                                        |
| `shift-tab`   | ESC [ Z    | Shift+Tab (backtab)                                                                    |

### Ctrl+Letter (bytes 1-26)

Bytes 1-26 map to `ctrl-a` through `ctrl-z`, except where a functional key
takes precedence (see [Control Byte Collisions](#control-byte-collisions)).
Notable entries:

| Event name  | Byte      | Notes                                               |
|-------------|-----------|-----------------------------------------------------|
| `ctrl-a`    | 0x01 (1)  |                                                     |
| `ctrl-b`    | 0x02 (2)  |                                                     |
| `ctrl-c`    | 0x03 (3)  | Requires `-isig` + `intr undef`                     |
| `ctrl-bksp` | 0x08 (8)  | Functional: Backspace takes precedence over Ctrl+H  |
| `tab`       | 0x09 (9)  | Functional: Tab takes precedence over Ctrl+I        |
| `enter`     | 0x0A (10) | Functional: Enter (LF) takes precedence over Ctrl+J |
| `ctrl-l`    | 0x0C (12) |                                                     |
| `enter`     | 0x0D (13) | Functional: Enter (CR) takes precedence over Ctrl+M |
| `ctrl-q`    | 0x11 (17) | Requires `-ixon`                                    |
| `ctrl-s`    | 0x13 (19) | Requires `-ixon`                                    |
| `ctrl-w`    | 0x17 (23) | Kept as Ctrl+W in VT; some terminals send it for Ctrl+Backspace |
| `ctrl-z`    | 0x1A (26) | Requires `-isig`                                    |

> Ctrl+letter produces the same byte regardless of Shift — `Ctrl+Z` and
> `Shift+Ctrl+Z` both send byte 26 under the VT protocol. Only the kitty
> keyboard protocol (CSI u) can distinguish them.

### Control Byte Collisions

The VT protocol maps Ctrl+letter to bytes 1-26 (byte = letter - 64). Some of
these bytes also represent functional keys like Tab, Enter, and Backspace. When
a byte is ambiguous, tui.sh maps it to the **functional key identity**, since
functional keys are more commonly bound in applications:

| Byte | ASCII name | Ctrl+letter | Functional key                  | Event emitted |
|------|------------|-------------|---------------------------------|---------------|
| 8    | BS         | Ctrl+H      | Backspace                       | `ctrl-bksp`   |
| 9    | HT         | Ctrl+I      | Tab                             | `tab`         |
| 10   | LF         | Ctrl+J      | Enter (line feed)               | `enter`       |
| 13   | CR         | Ctrl+M      | Enter (carriage return)         | `enter`       |
| 23   | ETB        | Ctrl+W      | Ctrl+Backspace (some terminals) | `ctrl-w`      |
| 27   | ESC        | Ctrl+[      | Escape                          | `esc`         |

Byte 23 is notable: most terminals send byte 23 for Ctrl+W, but some
(e.g. Windows Terminal, some xterm configurations) send byte 23 for
Ctrl+Backspace. In the VT protocol tui.sh keeps the Ctrl+letter identity and
emits `ctrl-w`, so on those terminals Ctrl+Backspace also surfaces as `ctrl-w`.
Applications that need to tell the two apart should use the kitty protocol,
where Ctrl+W arrives unambiguously via CSI u (and a terminal that still leaks a
raw byte 23 in kitty mode is mapped to `ctrl-bksp`).

In **kitty mode**, these collisions are largely resolved. Real Ctrl+letter
combinations arrive via CSI u sequences with unambiguous keycodes. Some
terminals may still send raw control bytes for certain keys; tui.sh maps
these to the same event names as their CSI u equivalents, so applications
only need one binding per key.

### Arrow Keys

Plain arrows are recognized in both SS3 (application mode) and CSI format:

| Event name | SS3 Sequence | CSI Sequence |
|------------|--------------|--------------|
| `up`       | ESC O A      | ESC [ A      |
| `down`     | ESC O B      | ESC [ B      |
| `right`    | ESC O C      | ESC [ C      |
| `left`     | ESC O D      | ESC [ D      |

### Function Keys

F1-F4 are recognized in both SS3 and CSI format:

| Event name | SS3 Sequence | CSI Sequence |
|------------|--------------|--------------|
| `f1`       | ESC O P      | ESC [ P      |
| `f2`       | ESC O Q      | ESC [ Q      |
| `f3`       | ESC O R      | ESC [ R      |
| `f4`       | ESC O S      | ESC [ S      |

F5-F12 use CSI sequences:

| Event name | Sequence    |
|------------|-------------|
| `f5`       | ESC [ 1 5 ~ |
| `f6`       | ESC [ 1 7 ~ |
| `f7`       | ESC [ 1 8 ~ |
| `f8`       | ESC [ 1 9 ~ |
| `f9`       | ESC [ 2 0 ~ |
| `f10`      | ESC [ 2 1 ~ |
| `f11`      | ESC [ 2 3 ~ |
| `f12`      | ESC [ 2 4 ~ |

### Navigation Keys

| Event name | Sequence(s)                         |
|------------|-------------------------------------|
| `home`     | ESC O H _or_ ESC [ H _or_ ESC [ 1 ~ |
| `end`      | ESC O F _or_ ESC [ F _or_ ESC [ 4 ~ |
| `ins`      | ESC [ 2 ~                           |
| `del`      | ESC [ 3 ~                           |
| `pgup`     | ESC [ 5 ~                           |
| `pgdn`     | ESC [ 6 ~                           |

### Modifier Combinations (VT Protocol)

Arrows, F-keys, and navigation keys support the standard modifier combinations
plus an unmodified entry (modifier value 1). The CSI parameter is `1 + bitmask`
where the bits are Shift=1, Alt=2, Ctrl=4, and the xterm "meta" bit=8. The event
name is prefixed with the modifier:

| Prefix                  | Modifier             | CSI parameter |
|-------------------------|----------------------|---------------|
| _(none)_                | No modifier          | ;1            |
| `shift-`                | Shift                | ;2            |
| `alt-`                  | Alt                  | ;3            |
| `alt-shift-`            | Alt+Shift            | ;4            |
| `ctrl-`                 | Ctrl                 | ;5            |
| `ctrl-shift-`           | Ctrl+Shift           | ;6            |
| `ctrl-alt-`             | Ctrl+Alt             | ;7            |
| `ctrl-alt-shift-`       | Ctrl+Shift+Alt       | ;8            |
| `super-`                | Super (Cmd ⌘)        | ;9            |
| `shift-super-`          | Shift+Super          | ;10           |
| `alt-super-`            | Alt+Super            | ;11           |
| `ctrl-super-`           | Ctrl+Super           | ;13           |
| `ctrl-alt-shift-super-` | Ctrl+Alt+Shift+Super | ;16           |

The meta bit (parameters 9–16) is how terminals report the macOS **Cmd** (⌘) key
in the legacy VT protocol; tui.sh surfaces it as the `super-` prefix so the event
names match the kitty protocol's Cmd mapping (see below). The prefix order is
always `ctrl- alt- shift- super-`.

Examples: `ctrl-right`, `shift-f5`, `alt-shift-up`, `ctrl-home`, `shift-ins`,
`ctrl-del`, `ctrl-alt-f12`, `ctrl-alt-shift-up`, `super-left`, `super-right`,
`shift-super-left`.

Modifier sequences use the 5-code form `ESC [ 1 ; <mod> <final>` for arrows,
F1-F4, Home, End, and the 6-code form `ESC [ <base> <extra> ; <mod> ~` for
F5-F12, Ins, Del, PgUp, PgDn.

> **Capturing Cmd (⌘).** Whether Cmd reaches the application is terminal-dependent
> and tui.sh performs no terminal detection. Some terminals send the meta bit
> above; others only distinguish Cmd from Ctrl under the kitty keyboard protocol
> (where Cmd is the separate Super bit) — enable it with `tuish_kitty_on`. A
> terminal that maps Cmd onto the Ctrl modifier in legacy mode emits bytes
> identical to a real Ctrl press, so the two are inherently indistinguishable
> there. Terminals that reserve Cmd for their own menus (e.g. Terminal.app,
> iTerm2 in their default configuration) never deliver it at all.

### Event Type Suffixes (VT Protocol)

When a terminal sends event type sub-parameters (colon-separated after the
modifier value), tui.sh appends a suffix:

| Type | Suffix   | Description                   |
|------|----------|-------------------------------|
| 1    | _(none)_ | Key press (default, stripped) |
| 2    | `-rep`   | Key repeat (held down)        |
| 3    | `-rel`   | Key release                   |

Examples: `up-rep`, `ctrl-up-rel`, `f5-rep`.

### Alt+Character

ESC followed by a printable byte (32-126) produces `alt-<char>`:

| Example | Sequence | Event name |
|---------|----------|------------|
| Alt+a   | ESC a    | `alt-a`    |
| Alt+A   | ESC A    | `alt-A`    |
| Alt+1   | ESC 1    | `alt-1`    |
| Alt+/   | ESC /    | `alt-/`    |

In kitty mode, the same event names are emitted regardless of whether the
key arrived via CSI u or as a raw VT byte.

### Alt+Special Key

ESC followed by a control byte that maps to a functional key produces an
`alt-` prefixed functional name:

| Key combination | Sequence             | Event name  |
|-----------------|----------------------|-------------|
| Alt+Backspace   | ESC 0x08             | `alt-bksp`  |
| Alt+Tab         | ESC 0x09             | `alt-tab`   |
| Alt+Enter       | ESC 0x0A or ESC 0x0D | `alt-enter` |
| Alt+Backspace   | ESC 0x7F             | `alt-bksp`  |

These are universal — the same event name is emitted regardless of protocol
mode (VT or kitty). The functional key identity takes precedence over the
Ctrl+letter interpretation, consistent with [Control Byte
Collisions](#control-byte-collisions).

### Alt+Ctrl+Letter

ESC followed by a control byte (1-26) produces `ctrl-alt-<letter>`, unless
the byte maps to a functional key (see Alt+Special Key above):

| Example    | Sequence | Event name   |
|------------|----------|--------------|
| Alt+Ctrl+A | ESC 0x01 | `ctrl-alt-a` |
| Alt+Ctrl+Z | ESC 0x1A | `ctrl-alt-z` |

In kitty mode, the same event names are emitted regardless of whether the
key arrived via CSI u or as a raw VT byte.

### Unrecognized Sequences

Any escape sequence that doesn't match a known pattern produces
`MISS <decimal bytes>`, e.g. `MISS 91 99 99`.

---

## Character Events (Kind: `key`)

Printable bytes (32-126) and UTF-8 multibyte sequences produce character events:

| Event name    | Input                         | Notes                             |
|---------------|-------------------------------|-----------------------------------|
| `char <c>`    | Any printable ASCII           | e.g. `char a`, `char Z`, `char 5` |
| `char bslash` | Backslash (0x5C)              | Named to avoid escape issues      |
| `space`       | Space (0x20)                  |                                   |
| `char <utf8>` | 2-byte UTF-8 (0xC2-0xC3 lead) | e.g. `char ñ`                     |
| `char <utf8>` | 3-byte UTF-8 (0xE2 lead)      | e.g. `char €`                     |

---

## Focus Events (Kind: `focus`)

| Event name  | Sequence | Description                  |
|-------------|----------|------------------------------|
| `focus-in`  | ESC [ I  | Terminal window gained focus |
| `focus-out` | ESC [ O  | Terminal window lost focus   |

These arrive as escape sequences but are categorized as `focus` kind, not `key`.

---

## Paste Events (Kind: `paste`)

| Event name    | Sequence    | Description           |
|---------------|-------------|-----------------------|
| `paste`       | (the body)  | **The pasted text, in `TUISH_PASTE`** |
| `paste-start` | ESC [ 200 ~ | Bracketed paste begin |
| `paste-end`   | ESC [ 201 ~ | Bracketed paste end   |

These are categorized as `paste` kind, not `key`.

A paste fires **three** events: `paste-start`, then a single `paste` carrying the whole
body, then `paste-end`. Bind `paste` and read `TUISH_PASTE`:

```sh
_on_paste () { _insert_text "$TUISH_PASTE"; }
tuish_bind 'paste' '_on_paste'
```

The body is **not** delivered as keystrokes. This matters: the bytes between the two
markers are *text*, not input. Were they fed to the key decoder, a pasted newline would
fire your `enter` binding, a pasted tab your `tab` binding (indenting, or expanding to
spaces), and every character would force its own render — which is quadratic. tuish
consumes the body itself and hands it over in one piece, so a paste is one atomic edit.

`TUISH_PASTE` holds the text with line breaks normalized to `\n` (terminals send CR, or
CRLF, inside a paste). It is capped at `TUISH_PASTE_MAX` bytes (default 256 KiB); a
larger paste is truncated rather than allowed to run away.

The `paste-start` / `paste-end` markers still fire, for apps that only want to know a
paste is in progress. Note there is no reliable way to *initiate* a paste from the app —
see [clip.md](clip.md#copy-out-paste-in).

---

## Mouse Events (Kind: `mouse`)

Mouse events set `TUISH_EVENT` to the action name and `TUISH_MOUSE_X` /
`TUISH_MOUSE_Y` to the 1-based coordinates (see [Mouse
Coordinates](#mouse-coordinates)).

### Click Events

| Event name | Button code | Description  |
|------------|-------------|--------------|
| `lclik`    | 0           | Left click   |
| `mclik`    | 1           | Middle click |
| `rclik`    | 2           | Right click  |

### Hold / Drag Events

| Event name | Button code | Description                   |
|------------|-------------|-------------------------------|
| `lhold`    | 32          | Left button hold (drag start) |
| `mhold`    | 33          | Middle button hold            |
| `rhold`    | 34          | Right button hold             |
| `move`     | 35          | Mouse motion (no button)      |

A hold followed by button release produces a `drop` event (the corresponding
`ldrop`, `mdrop`, or `rdrop` name is tracked internally via `_tuish_held`).

### Scroll Events

| Event name | Button code | Description       |
|------------|-------------|-------------------|
| `whup`     | 64          | Scroll wheel up   |
| `wdown`    | 65          | Scroll wheel down |

### Mouse Modifier Combinations

All click, hold, move, and scroll events support modifier prefixes.
The SGR button code adds +4 for Shift, +8 for Alt, +16 for Ctrl.

#### Modifier + Click

| Prefix      | Left                  | Middle                | Right                 | Button offset |
|-------------|-----------------------|-----------------------|-----------------------|---------------|
| `shift-`    | `shift-lclik` (4)     | `shift-mclik` (5)     | `shift-rclik` (6)     | +4            |
| `alt-`      | `alt-lclik` (8)       | `alt-mclik` (9)       | `alt-rclik` (10)      | +8            |
| `ctrl-`     | `ctrl-lclik` (16)     | `ctrl-mclik` (17)     | `ctrl-rclik` (18)     | +16           |
| `ctrl-alt-` | `ctrl-alt-lclik` (24) | `ctrl-alt-mclik` (25) | `ctrl-alt-rclik` (26) | +24           |

#### Modifier + Hold/Move

| Prefix      | Left                  | Middle                | Right                 | Move                 | Base offset |
|-------------|-----------------------|-----------------------|-----------------------|----------------------|-------------|
| `shift-`    | `shift-lhold` (36)    | `shift-mhold` (37)    | `shift-rhold` (38)    | `shift-move` (39)    | +4          |
| `alt-`      | `alt-lhold` (40)      | `alt-mhold` (41)      | `alt-rhold` (42)      | `alt-move` (43)      | +8          |
| `ctrl-`     | `ctrl-lhold` (48)     | `ctrl-mhold` (49)     | `ctrl-rhold` (50)     | `ctrl-move` (51)     | +16         |
| `ctrl-alt-` | `ctrl-alt-lhold` (56) | `ctrl-alt-mhold` (57) | `ctrl-alt-rhold` (58) | `ctrl-alt-move` (59) | +24         |

#### Modifier + Scroll

| Prefix      | Up                   | Down                  | Button offset |
|-------------|----------------------|-----------------------|---------------|
| `shift-`    | `shift-whup` (68)    | `shift-wdown` (69)    | +4            |
| `alt-`      | `alt-whup` (72)      | `alt-wdown` (73)      | +8            |
| `ctrl-`     | `ctrl-whup` (80)     | `ctrl-wdown` (81)     | +16           |
| `ctrl-alt-` | `ctrl-alt-whup` (88) | `ctrl-alt-wdown` (89) | +24           |

#### Modifier + Drop

When a modifier+hold is released, the corresponding modifier+drop event fires:
`shift-drop`, `alt-drop`, `ctrl-drop`, `ctrl-alt-drop`.

### Mouse Coordinates

Mouse events set `TUISH_MOUSE_X` (column) and `TUISH_MOUSE_Y` (row).
Coordinates are 1-based.

When a viewport is active, both are translated into the **active context's**
coordinate frame -- the inverse of the `tuish_vmove` transform:

```
TUISH_MOUSE_Y = row    - TUISH_VIEW_TOP  + 1
TUISH_MOUSE_X = column - TUISH_VIEW_LEFT
```

So for a hosted child they are region-local, and an embedded app's click
handling works unchanged (see [hosting.md](hosting.md)). For the root context
`TUISH_VIEW_LEFT` is 0, so standalone coordinates are unchanged.
`TUISH_MOUSE_ABS_Y` still holds the absolute terminal row; there is
deliberately no `TUISH_MOUSE_ABS_X`.

### X10 Fallback

For terminals without SGR 1006, tui.sh also decodes the legacy X10 mouse report
(`ESC [ M cb cx cy` -- three bytes, each offset by +32). It is consumed in the
CSI parser and resolves through the same button path as SGR, so the event names
and modifier prefixes above are identical. Two known limits of the legacy
encoding: X10 reports a **release** as button 3 rather than as a distinct
release class, and it cannot express coordinates beyond column/row 223.

---

## Kitty Keyboard Protocol (Kind: `key`)

When the terminal supports the kitty keyboard protocol, key events arrive as
CSI u sequences: `ESC [ <keycode> ; <modifiers> [: <event_type>] u`.

`TUISH_PROTOCOL` is set to `'kitty'` when this protocol is active,
or `'vt'` for standard VT sequences.

The protocol is VT by default. Call `tuish_kitty_on` after `tuish_init`
to probe the terminal and enable kitty mode if supported.  The base
flags are 9 (disambiguate + all keys as CSI u).  `tuish_detailed_on`
raises the flags to 11 (adding event types for press/repeat/release).

### CSI u Key Names

Special keycodes map to the same names as VT events:

| Keycode | Event name                                |
|---------|-------------------------------------------|
| 9       | `tab`                                     |
| 13      | `enter`                                   |
| 27      | `esc`                                     |
| 32      | `space`                                   |
| 92      | `bslash`                                  |
| 127     | `bksp`                                    |
| 33-126  | The character itself (e.g. `a`, `Z`, `/`) |
| Other   | `key-<keycode>`                           |

An unmodified printable key press (keycodes 33-126, no modifier, no
repeat/release) produces `char <key>` to match the character event format.

### CSI u Modifiers

Modifier values (1 + bitmask) produce prefixes in the standard order
(`ctrl-`, `alt-`, `shift-`, `super-`, `hyper-`, `meta-`):

| Modifier value | Prefix            | Bits           |
|----------------|-------------------|----------------|
| 1              | _(none)_          | No modifier    |
| 2              | `shift-`          | Shift          |
| 3              | `alt-`            | Alt            |
| 4              | `alt-shift-`      | Alt+Shift      |
| 5              | `ctrl-`           | Ctrl           |
| 6              | `ctrl-shift-`     | Ctrl+Shift     |
| 7              | `ctrl-alt-`       | Ctrl+Alt       |
| 8              | `ctrl-alt-shift-` | Ctrl+Shift+Alt |
| 9              | `super-`          | Super          |
| 13             | `ctrl-super-`     | Ctrl+Super     |
| 17             | `hyper-`          | Hyper          |
| 33             | `meta-`           | Meta           |

### CSI u Event Types

The kitty protocol supports key press, repeat, and release:

| Type | Suffix   | Description            |
|------|----------|------------------------|
| 1    | _(none)_ | Key press (default)    |
| 2    | `-rep`   | Key repeat (held down) |
| 3    | `-rel`   | Key release            |

### Physical Modifier Keys

With kitty flags=11, pressing individual modifier keys generates events.
Left and right physical keys are distinguished using dot notation:

| Keycode | Event name | Key         |
|---------|------------|-------------|
| 57441   | `shift.l`  | Left Shift  |
| 57447   | `shift.r`  | Right Shift |
| 57442   | `ctrl.l`   | Left Ctrl   |
| 57448   | `ctrl.r`   | Right Ctrl  |
| 57443   | `alt.l`    | Left Alt    |
| 57449   | `alt.r`    | Right Alt   |
| 57444   | `super.l`  | Left Super  |
| 57450   | `super.r`  | Right Super |
| 57445   | `hyper.l`  | Left Hyper  |
| 57451   | `hyper.r`  | Right Hyper |
| 57446   | `meta.l`   | Left Meta   |
| 57452   | `meta.r`   | Right Meta  |

The dot notation enables shell glob pattern matching:

```sh
case "$TUISH_EVENT" in
    shift.[lr]) echo "any shift pressed";;
    ctrl.[lr]) echo "any ctrl pressed";;
    shift.l)    echo "left shift only";;
esac
```

#### Self-Referential Modifier Stripping

When a modifier key is pressed, the terminal sends both the keycode and the
modifier bit for that key. tui.sh strips the self-referential bit so that
pressing Left Ctrl alone produces `ctrl.l` (not `ctrl-ctrl.l`). When another
modifier is also held, only the additional modifier appears as a prefix:
pressing Alt while holding Left Ctrl produces `alt-ctrl.l`.

### Lock and System Keys

| Keycode | Event name    |
|---------|---------------|
| 57358   | `caps-lock`   |
| 57359   | `scroll-lock` |
| 57360   | `num-lock`    |
| 57361   | `prtsc`       |
| 57362   | `pause`       |
| 57363   | `menu`        |

### Function Keys F13-F35

Keycodes 57376-57398 map to `f13` through `f35`.

### Keypad Keys

| Keycode     | Event name            |
|-------------|-----------------------|
| 57399-57408 | `kp-0` through `kp-9` |
| 57409       | `kp-.`                |
| 57410       | `kp-/`                |
| 57411       | `kp-*`                |
| 57412       | `kp--`                |
| 57413       | `kp-+`                |
| 57414       | `kp-enter`            |
| 57415       | `kp-=`                |
| 57416       | `kp-sep`              |
| 57417       | `kp-left`             |
| 57418       | `kp-right`            |
| 57419       | `kp-up`               |
| 57420       | `kp-down`             |
| 57421       | `kp-pgup`             |
| 57422       | `kp-pgdn`             |
| 57423       | `kp-home`             |
| 57424       | `kp-end`              |
| 57425       | `kp-ins`              |
| 57426       | `kp-del`              |
| 57427       | `kp-begin`            |

### Navigation Keys (CSI u keycodes)

| Keycode | Event name |
|---------|------------|
| 57348   | `ins`      |
| 57349   | `del`      |
| 57350   | `left`     |
| 57351   | `right`    |
| 57352   | `up`       |
| 57353   | `down`     |
| 57354   | `pgup`     |
| 57355   | `pgdn`     |
| 57356   | `home`     |
| 57357   | `end`      |

### Media Keys

| Keycode | Event name         |
|---------|--------------------|
| 57428   | `media-play`       |
| 57429   | `media-pause`      |
| 57430   | `media-play-pause` |
| 57431   | `media-reverse`    |
| 57432   | `media-stop`       |
| 57433   | `media-ff`         |
| 57434   | `media-rw`         |
| 57435   | `media-next`       |
| 57436   | `media-prev`       |
| 57437   | `media-rec`        |
| 57438   | `vol-down`         |
| 57439   | `vol-up`           |
| 57440   | `vol-mute`         |

### ISO Level Keys

| Keycode | Event name   |
|---------|--------------|
| 57453   | `iso-level3` |
| 57454   | `iso-level5` |

### CSI u Examples

| Sequence             | Event name     |
|----------------------|----------------|
| `ESC [ 97 u`         | `char a`       |
| `ESC [ 97 ; 5 u`     | `ctrl-a`       |
| `ESC [ 122 ; 6 u`    | `ctrl-shift-z` |
| `ESC [ 97 ; 3 u`     | `alt-a`        |
| `ESC [ 97 ; 7 u`     | `ctrl-alt-a`   |
| `ESC [ 9 ; 5 u`      | `ctrl-tab`     |
| `ESC [ 13 ; 2 u`     | `shift-enter`  |
| `ESC [ 97 ; 5 : 3 u` | `ctrl-a-rel`   |
| `ESC [ 97 ; 5 : 2 u` | `ctrl-a-rep`   |
| `ESC [ 57441 ; 2 u`  | `shift.l`      |
| `ESC [ 57442 ; 5 u`  | `ctrl.l`       |
| `ESC [ 57442 ; 7 u`  | `alt-ctrl.l`   |

### Advantages Over VT

The kitty protocol resolves ambiguities that the VT protocol cannot:

- **Shift+Ctrl+letter**: `ctrl-shift-z` (VT sends the same byte as `ctrl-z`)
- **Key release/repeat**: `-rel` and `-rep` suffixes
- **Modifier+Tab/Enter/Backspace**: `ctrl-tab`, `shift-enter`, etc.
- **Individual modifier keys**: `ctrl.l`, `shift.r`, etc.
- **Left/right modifier distinction**: dot notation with `.l`/`.r`
- **Unambiguous Escape**: ESC key vs. ESC as sequence introducer

### VT Prefix (Kitty Mode)

When the kitty protocol is active (`TUISH_PROTOCOL=kitty`), real Ctrl+letter
and Alt+character combinations arrive via unambiguous CSI u sequences. However,
some terminals (e.g. WezTerm) may still send raw VT bytes for certain keys.

tui.sh maps these raw bytes to the **same event names** as their CSI u
equivalents, so applications only need a single binding per key:

| VT bytes             | Event name          | Notes                                              |
|----------------------|---------------------|----------------------------------------------------|
| byte 1-7             | `ctrl-a`..`ctrl-g`  | Same in both VT and kitty mode                     |
| byte 8               | `ctrl-bksp`         | Functional key (Ctrl+H / Ctrl+Backspace collision) |
| byte 9               | `tab`               | Functional key                                     |
| byte 10, 13          | `enter`             | Functional key                                     |
| byte 11-26           | `ctrl-k`..`ctrl-z`  | Same in both VT and kitty mode                     |
| byte 127             | `bksp`              | Functional key                                     |
| ESC + printable      | `alt-<char>`        | Same in both VT and kitty mode                     |
| ESC + control (1-26) | `ctrl-alt-<letter>` | Same in both VT and kitty mode                     |
| ESC + 0x64           | `ctrl-del`          | Functional key (ESC+d collision)                   |

**Key principles:**

1. **One binding per key.** Whether a key arrives via CSI u or as a raw VT
   byte, the same event name is emitted. `ctrl-w` is always `ctrl-w`.

2. **Functional keys are universal.** Named special keys (`ctrl-bksp`, `tab`,
   `enter`, `bksp`, `alt-bksp`, `alt-tab`, `alt-enter`) emit the same event
   name in both VT and kitty mode.

3. **Escape sequences (CSI/SS3) are protocol-independent.** Arrow keys, function
   keys, navigation keys, and their modifier combinations produce the same event
   names regardless of protocol.

**Binding strategy:**

```sh
tuish_bind 'ctrl-bksp' 'delete_word_left'
tuish_bind 'ctrl-w'    'close_window'      # works in both VT and kitty mode
tuish_bind 'ctrl-del'  'delete_word_right'
tuish_bind 'alt-bksp'  'delete_word_left'
```

---

## Signal Events (Kind: `signal`)

| Event name | Trigger  | Description                                   |
|------------|----------|-----------------------------------------------|
| `resize`   | SIGWINCH | Terminal window resized                       |
| `cont`     | SIGCONT  | Process resumed (e.g. after Ctrl+Z in parent) |

Signal events are checked at the top of every read loop iteration. The CONT
handler also restores stty settings that may have been reset by the suspending
shell.

---

## Idle Events (Kind: `idle`)

| Event name | Description                                 |
|------------|---------------------------------------------|
| `idle`     | No input received within the timeout period |

An initial idle event is fired before the event loop starts, allowing
applications to perform their first render. Subsequent idle events fire
whenever no input is received within the idle timeout (default: 260ms with
sub-second resolution, 1s otherwise). Configure with `TUISH_IDLE_TIMEOUT`
(in seconds) before calling `tuish_init`.
