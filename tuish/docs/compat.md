<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# Shell Compatibility Layer (compat.sh)

Shell normalization and portable output. Source first, before any other module.

```sh
. ./src/compat.sh
```

## What It Does

- Sets `set -euf` for strict error handling
- Disables zsh-specific options (`FLOW_CONTROL`, `GLOB`, etc.) for POSIX
  compatibility
- Sets `LC_ALL=C` and `LC_CTYPE=C` for consistent byte handling across
  all shells (saves original locale values for UTF-8 detection by other modules)
- Detects whether `printf` is usable for output (`_tuish_printf` flag)
- Provides `_tuish_out()` for raw terminal output (uses `printf` or `echo -ne`
  depending on shell)
- Aliases `local` to `typeset` for ksh93 compatibility

## Locale Handling

compat.sh saves the original locale values before overwriting them:

| Variable               | Description               |
|------------------------|---------------------------|
| `_tuish_orig_lang`     | Original `LANG` value     |
| `_tuish_orig_lc_all`   | Original `LC_ALL` value   |
| `_tuish_orig_lc_ctype` | Original `LC_CTYPE` value |

These are used by draw.sh to detect UTF-8 support for Unicode box-drawing
characters.

**Note:** Because `LC_ALL=C` is set globally, any user code that runs during
the event loop (e.g., external commands that depend on locale for output
formatting) will see the C locale, not the user's original locale.  If your
callback needs the original locale, temporarily restore it:

```sh
my_callback () {
    LC_ALL="${_tuish_orig_lc_all:-}" my_external_command
}
```

## Internal API

| Symbol          | Description                                                 |
|-----------------|-------------------------------------------------------------|
| `_tuish_printf` | `1` if `printf` is usable for output, `0` for mksh          |
| `_tuish_out()`  | Raw terminal output (printf or echo -ne depending on shell) |
