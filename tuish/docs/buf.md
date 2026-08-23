<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# Line Buffer (buf.sh)

Generic line-indexed buffer using variable indirection. Supports multiple
independent named buffers. Source after `compat.sh`.

```sh
. ./src/compat.sh
. ./src/buf.sh
```

## Functions

Lines are 1-based indexed. Every function names its buffer explicitly as the
first argument; buffers are independent. Use `_` when one ad-hoc buffer is enough.

| Function                          | Description                                  |
|-----------------------------------|----------------------------------------------|
| `tuish_buf_init BUF`              | Reinitialize BUF to a single empty line      |
| `tuish_buf_count BUF`             | Load BUF's line count into `TUISH_BUF_COUNT` |
| `tuish_buf_get BUF IDX`           | Get line content at index -> `TUISH_BLINE`   |
| `tuish_buf_set BUF IDX VAL`       | Set line content at index                    |
| `tuish_buf_append BUF VAL`        | Append a new line (auto-creates a fresh BUF) |
| `tuish_buf_insert_at BUF IDX VAL` | Insert line at index, shifting others down   |
| `tuish_buf_delete_at BUF IDX`     | Delete line at index, shifting others up     |

Two guarantees make reads safe under `set -u`:

- `tuish_buf_get BUF IDX` with an out-of-range `IDX` yields an empty
  `TUISH_BLINE` instead of aborting.
- `tuish_buf_count BUF` on a never-touched buffer yields `0`.

These matter in practice: a mouse click below the last line used to abort the
whole application.

## Variables

`TUISH_BUF_COUNT` and `TUISH_BLINE` are output registers — never storage. Lines
live in `_tuish_buf_<BUF>_<IDX>` and counts in `_tuish_bufcount_<BUF>`.

| Variable          | Description                                              |
|-------------------|---------------------------------------------------------|
| `TUISH_BUF_COUNT` | Line count of the last buffer touched (init/append/etc) |
| `TUISH_BLINE`     | Line content returned by `tuish_buf_get`                |

## Example

```sh
# Use '_' for a single ad-hoc buffer
tuish_buf_init _                      # TUISH_BUF_COUNT = 1 (one empty line)
tuish_buf_set _ 1 "first line"
tuish_buf_append _ "second line"      # TUISH_BUF_COUNT = 2
tuish_buf_get _ 1                     # TUISH_BLINE = "first line"
tuish_buf_insert_at _ 2 "inserted"    # shifts "second line" to index 3
tuish_buf_delete_at _ 3               # removes "second line"

# Independent named buffers
tuish_buf_init log
tuish_buf_append log "error: file not found"
tuish_buf_append log "warning: deprecated API"
tuish_buf_count log                   # TUISH_BUF_COUNT = 3
tuish_buf_get log 2                   # TUISH_BLINE = "error: file not found"
```
