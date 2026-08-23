<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# Shell Compatibility

## Supported Shells

| Shell      | Version  | Read Method    |
|------------|----------|----------------|
| bash       | 4+       | `read -n 1`    |
| zsh        | 5+       | `read -k1 -u0` |
| ksh93      | AJM 93u+ | `read -n 1`    |
| mksh       | R59+     | `read -n 1`    |
| busybox sh | 1.30+    | `read -n 1`    |

tui.sh auto-detects the read method at startup.

## Locale

compat.sh sets `LC_ALL=C` and `LC_CTYPE=C` at source time for consistent byte handling across all shells. Before overwriting these variables, it saves the original values in `_tuish_orig_lang`, `_tuish_orig_lc_all`, and `_tuish_orig_lc_ctype`. This allows modules like draw.sh to check the saved locale and detect UTF-8 support even after the C locale is active.

## Module Sourcing Order

`compat.sh` must be sourced first (shell normalization), then `ord.sh` (ASCII tables), then `tui.sh`. Other modules can be sourced in any order after that, with the following exceptions:

- `hid.sh` requires `event.sh`
- `viewport.sh` requires `term.sh` and `event.sh`
- `draw.sh` requires `term.sh` and `str.sh`

`hl.sh` and `md.sh` are the exceptions to the rule above: both are **standalone**
and require nothing at all, not even `compat.sh`. `md.sh` uses `hl.sh` when it is
present and degrades to unhighlighted code lines when it is not.

That is deliberate. Sourcing `compat.sh` applies `set -euf` and pins `LC_ALL=C` at
source time, which a general-purpose script — a site generator, say — usually
cannot accept: `set -f` alone breaks any use of filename globbing. Keeping the two
document modules dependency-free lets such a script source them directly, and lets
the same parse feed both it and a full tuish app.

## Timeout Resolution

| Resolution               | Shells                            | Idle Timeout                                  |
|--------------------------|-----------------------------------|-----------------------------------------------|
| `sub` (subsecond)        | bash, zsh, ksh93, mksh, busybox sh | 0.26s (configurable via `TUISH_IDLE_TIMEOUT`) |
| `second` (whole seconds) | a shell whose `read -t` rejects a fraction | 1s minimum                           |

This is **probed, not assumed** (`_tuish_init_timing`): tui.sh runs `read -t0.01` and believes
the answer. A launcher can declare `TUISH_TIMING=sub|second` to skip the probe's two forks.

> **busybox is `sub`, not `second`.** This table used to say otherwise, and it sent a real
> investigation looking for a 1s idle timeout that was never there. busybox `ash` reads
> fractional timeouts whenever it is built with `FEATURE_SH_READ_FRAC`, which is usual — the
> wasm build the website runs sets it, and probes `sub`. Trust `TUISH_TIMING`, not a table.

Check `TUISH_TIMING` after `tuish_init` to know which is active.

An idle tick is that `read` **timing out**, which is worth knowing before choosing an
interval: an app whose interval is longer than the terminal's key-autorepeat interval gets no
idle at all while a key is held. See [tui.md](tui.md#an-idle-tick-is-a-timeout-not-a-timer).

## Shell-Specific Notes

### bash
Full support. No known limitations.

### zsh
Full support with minor caveats:
- `setopt` options (`FLOW_CONTROL`, `GLOB`, etc.) are automatically
  disabled by tui.sh
- Bare ESC detection is unreliable under zsh+tmux due to terminal
  driver buffering. Works in direct terminal usage.
- Alt+Ctrl+letter delivery is unreliable under zsh+tmux.

### ksh93
Full support, but it costs one trick, and the trick is worth understanding.

`local` is aliased to `typeset` — and **`typeset` does not create a local variable in a
POSIX `f () { ... }` function.** It only does so in a ksh-style `function f { ... }` one.
Every function in tuish is POSIX-style, so on ksh93 that alias is a lie: every `local`
declares a *global*, and a framework helper's scratch variable will happily overwrite a
caller variable of the same name. (draw.sh holds a box's top border in `local _top`; a host
that keeps its layout row in `_top` got the string `╭────────╮` back where its row used to
be.)

So after everything is sourced, `tuish_init` calls `tuish_fnfix` (compat.sh): it dumps each
framework function with `typeset -f` and re-declares it with the `function` keyword, which
makes `local` mean local. Detection is by **feature** — declare a local in a throwaway
function and see whether it escapes — not by shell name, so every other shell skips it.

Three things are deliberately left as POSIX functions, and each is load-bearing:

| left POSIX | why |
|---|---|
| the trap path (`_tuish_init_term`, `tuish_fini`, …) | a ksh-style function owns its traps: an EXIT trap set inside one fires when the **function** returns, not when the process exits |
| `tuish_run` | entering a ksh-style function **resets traps to default** for that scope, so a signal arriving while one is on the stack is *discarded*, not deferred. `tuish_run` is where the process blocks on `read` — exactly where SIGWINCH lands. Convert it and resizes vanish. |
| the `tuish_str_*` readers | ksh-style functions are **statically scoped**, so a callee cannot see a caller's local. tuish's no-fork idiom passes a variable *name* (`tuish_str_width _t`) for the callee to dereference. Left POSIX, they run in the caller's scope and can still read what they were handed. |

App functions are never converted, for the same trap reason (your `_main` is on the stack
for the whole run) — and because they don't need to be: the bug is a *framework* local
overwriting an *app* global, and fixing the framework's side ends it.

`tests/unit/test_scope.sh` pins all of this.

### mksh (MIRBSD KSH)
Full support. `local` is aliased to `typeset`. Uses `echo -ne` instead
of `printf` for output (mksh has no builtin `printf`). Unicode
box-drawing characters use `\xHH` hex escapes which work with both
`printf` and `echo -ne`.

### busybox sh
Works with limitations:
- Only whole-second timeouts (`TUISH_TIMING='second'`)
- String utilities (`tuish_str_*`) may not be available (requires
  `${var:off:len}` support, which varies by busybox build)

## String Utilities

The `tuish_str_*` functions use `${var:off:len}` parameter expansion,
which is supported by bash, zsh, ksh93, and mksh but is not part of the
POSIX standard. Availability on busybox sh depends on the build
configuration.

`hl.sh` and `md.sh` avoid it entirely, so they also run on shells outside the
supported set (dash, for one) — useful when a build script is invoked as `sh`.

Two pattern rules those two modules follow, both learned the hard way:

- **Never store a pattern in a variable.** `${s%%$PAT*}` matches on bash, mksh,
  dash and busybox, and on zsh silently does *not* — it needs `${~PAT}` and
  otherwise returns the whole string, so the failure is a wrong result rather than
  an error.
- **Enumerate character classes; do not use ranges.** POSIX leaves range behaviour
  outside the C locale unspecified, and ksh93 honours that: in a UTF-8 locale it
  collates `ç` inside `A-Za-z`. Any code that must produce identical output under
  both `LC_ALL=C` and the user's own locale has to spell the class out.

Bracket and backtick literals inside `${…}` are written as quoted expansions, never
backslash-escaped: `${v%%\](*}` is a zsh parse error, and an escaped backtick makes
mksh read an unterminated command substitution and abandon the whole file.

## Known Terminal Limitations

- **CR (Enter) via tmux PTY**: The terminal driver may translate CR
  before it reaches the raw-mode read. Works in direct terminal usage.
- **Shift+Ctrl+letter (VT protocol)**: Indistinguishable from
  Ctrl+letter. Use the kitty keyboard protocol for disambiguation.
- **DECAWM (auto-wrap)**: Disabled by default (`tuish_wrap_off`).
  Universally supported by xterm, VTE, kitty, alacritty, Windows
  Terminal, iTerm2, mintty, tmux, and screen.

## Keyboard Protocol

The keyboard protocol defaults to VT.  Call `tuish_kitty_on` after
`tuish_init` to probe the terminal and enable the kitty keyboard
protocol if supported.  `tuish_kitty_off` (and `tuish_fini`) restore
VT mode.
