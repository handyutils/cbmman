#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Integration tests: mouse events via tmux PTY (SGR 1006 protocol)

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"
. "$TESTS_DIR/lib/tmux_helpers.sh"

trap 'cleanup_session' EXIT

printf 'Integration tests: mouse (%s)\n' "$TUISH_SHELL"

start_tuish_session

# SGR 1006 mouse format: ESC [ < Cb ; Cx ; Cy M (press) or m (release)
# Cb = button code, Cx = column, Cy = row

# --- Left click at (10, 5): ESC [ < 0 ; 10 ; 5 M ---
# 1b 5b 3c 30 3b 31 30 3b 35 4d
assert_event "1b 5b 3c 30 3b 31 30 3b 35 4d" "lclik" "left click"

# --- Right click at (20, 10): ESC [ < 2 ; 20 ; 10 M ---
# 1b 5b 3c 32 3b 32 30 3b 31 30 4d
assert_event "1b 5b 3c 32 3b 32 30 3b 31 30 4d" "rclik" "right click"

# --- Middle click at (15, 8): ESC [ < 1 ; 15 ; 8 M ---
# 1b 5b 3c 31 3b 31 35 3b 38 4d
assert_event "1b 5b 3c 31 3b 31 35 3b 38 4d" "mclik" "middle click"

# --- Scroll up at (1,1): ESC [ < 64 ; 1 ; 1 M ---
# 1b 5b 3c 36 34 3b 31 3b 31 4d
assert_event "1b 5b 3c 36 34 3b 31 3b 31 4d" "whup" "scroll up"

# --- Scroll down at (1,1): ESC [ < 65 ; 1 ; 1 M ---
# 1b 5b 3c 36 35 3b 31 3b 31 4d
assert_event "1b 5b 3c 36 35 3b 31 3b 31 4d" "wdown" "scroll down"

# --- Ctrl+scroll up: ESC [ < 80 ; 1 ; 1 M ---
# 1b 5b 3c 38 30 3b 31 3b 31 4d
assert_event "1b 5b 3c 38 30 3b 31 3b 31 4d" "ctrl-whup" "ctrl scroll up"

# --- Ctrl+scroll down: ESC [ < 81 ; 1 ; 1 M ---
# 1b 5b 3c 38 31 3b 31 3b 31 4d
assert_event "1b 5b 3c 38 31 3b 31 3b 31 4d" "ctrl-wdown" "ctrl scroll down"

# --- Left hold (drag start): ESC [ < 32 ; 10 ; 5 M ---
# 1b 5b 3c 33 32 3b 31 30 3b 35 4d
assert_event "1b 5b 3c 33 32 3b 31 30 3b 35 4d" "lhold" "left hold (drag start)"

# --- Mouse move: ESC [ < 35 ; 12 ; 6 M ---
# 1b 5b 3c 33 35 3b 31 32 3b 36 4d
assert_event "1b 5b 3c 33 35 3b 31 32 3b 36 4d" "move" "mouse move"

# --- Ctrl+left click: ESC [ < 16 ; 5 ; 5 M ---
# 1b 5b 3c 31 36 3b 35 3b 35 4d
assert_event "1b 5b 3c 31 36 3b 35 3b 35 4d" "ctrl-lclik" "ctrl left click"

# --- Alt+left click: ESC [ < 8 ; 5 ; 5 M ---
# 1b 5b 3c 38 3b 35 3b 35 4d
assert_event "1b 5b 3c 38 3b 35 3b 35 4d" "alt-lclik" "alt left click"

# --- Alt scroll up: ESC [ < 72 ; 1 ; 1 M ---
# 1b 5b 3c 37 32 3b 31 3b 31 4d
assert_event "1b 5b 3c 37 32 3b 31 3b 31 4d" "alt-whup" "alt scroll up"

# --- Alt scroll down: ESC [ < 73 ; 1 ; 1 M ---
# 1b 5b 3c 37 33 3b 31 3b 31 4d
assert_event "1b 5b 3c 37 33 3b 31 3b 31 4d" "alt-wdown" "alt scroll down"

# --- Shift+left click: ESC [ < 4 ; 5 ; 5 M ---
# 1b 5b 3c 34 3b 35 3b 35 4d
assert_event "1b 5b 3c 34 3b 35 3b 35 4d" "shift-lclik" "shift left click"

# --- Shift+scroll up: ESC [ < 68 ; 1 ; 1 M ---
# 1b 5b 3c 36 38 3b 31 3b 31 4d
assert_event "1b 5b 3c 36 38 3b 31 3b 31 4d" "shift-whup" "shift scroll up"

# --- Shift+scroll down: ESC [ < 69 ; 1 ; 1 M ---
# 1b 5b 3c 36 39 3b 31 3b 31 4d
assert_event "1b 5b 3c 36 39 3b 31 3b 31 4d" "shift-wdown" "shift scroll down"

# --- Alt+right click: ESC [ < 10 ; 5 ; 5 M ---
# 1b 5b 3c 31 30 3b 35 3b 35 4d
assert_event "1b 5b 3c 31 30 3b 35 3b 35 4d" "alt-rclik" "alt right click"

# --- Ctrl+Alt+left click: ESC [ < 24 ; 5 ; 5 M ---
# 1b 5b 3c 32 34 3b 35 3b 35 4d
assert_event "1b 5b 3c 32 34 3b 35 3b 35 4d" "ctrl-alt-lclik" "ctrl-alt left click"

# --- Ctrl+Alt+scroll up: ESC [ < 88 ; 1 ; 1 M ---
# 1b 5b 3c 38 38 3b 31 3b 31 4d
assert_event "1b 5b 3c 38 38 3b 31 3b 31 4d" "ctrl-alt-whup" "ctrl-alt scroll up"

quit_tuish
test_summary
