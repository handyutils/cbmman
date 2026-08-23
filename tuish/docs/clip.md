<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# System Clipboard (clip.sh)

Copy to the **system** clipboard from a tuish app. Optional module; source after
`tui.sh` and `ord.sh`.

```sh
. ./src/clip.sh

tuish_clip_set "$my_text"      # -> the system clipboard
```

| Function             | Description                                                     |
|----------------------|------------------------------------------------------------------|
| `tuish_clip_set TEXT`| Copy TEXT to the system clipboard (OSC 52)                        |
| `tuish_b64 TEXT`     | Base64-encode TEXT into `TUISH_B64` (fork-free; used by the above) |

## How it works, and why it works over ssh

The clipboard belongs to the **terminal**, not to the shell. `tuish_clip_set` emits
OSC 52 -- the escape sequence that means *"here is a payload, put it on the system
clipboard"*:

```
ESC ] 52 ; c ; <base64> ESC \
```

Because it is just bytes on stdout, it works wherever your output reaches a terminal:
locally, inside tmux, over ssh, and in the browser build (xterm.js exposes it through
`parser.registerOscHandler(52, …)`). tuish needs no cooperation from the host process
for any of it.

A terminal that does not implement OSC 52 ignores it. There is no reply to wait for
and nothing to time out, so calling `tuish_clip_set` is always safe.

`tuish_b64` is fork-free: it is built on `ord.sh`'s byte tables and `compat.sh`'s
`LC_ALL=C`, so it encodes **bytes**, and UTF-8 payloads (emoji, CJK) round-trip
correctly rather than being mangled per character.

## Copy out, paste in

The two directions are **not** symmetric, and deliberately so.

| Direction | Mechanism |
|---|---|
| App → clipboard (**copy**) | `tuish_clip_set` (OSC 52) |
| Clipboard → app (**paste**) | **bracketed paste** — the terminal pushes the text; tuish captures it as a `paste` event with the body in `TUISH_PASTE`. See [event.md](event.md#paste). |

There is no `tuish_clip_get`. Reading the clipboard back (the OSC 52 `?` query) is
absent on purpose: most terminals refuse it and every browser blocks it, because it
would let any program running in your terminal exfiltrate whatever you last copied.
Pasting *into* an app is the terminal's job to initiate, and bracketed paste is how it
does it.

A consequence worth knowing when you write an app: if you want copy **and** paste
*within* your own app, keep your own register. You cannot read back what you put on
the system clipboard. `examples/editor.sh` does exactly this — `_ed_clip` holds the
text, and copy *also* mirrors it out with `tuish_clip_set`.

## In the browser

`web/index.html` registers an OSC 52 handler that forwards the payload to
`navigator.clipboard.writeText()`. Note that `writeText` requires transient user
activation: in practice a copy is always a keypress away (Ctrl+C), and the round-trip
through the worker takes milliseconds, so it lands inside the activation window. If a
browser refuses it, the page logs it rather than failing silently.
