#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Integration tests: keyboard events via tmux PTY

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"
. "$TESTS_DIR/lib/tmux_helpers.sh"

trap 'cleanup_session' EXIT

printf 'Integration tests: keyboard (%s)\n' "$TUISH_SHELL"

start_tuish_session

# --- Arrow keys (application mode: ESC O A/B/C/D) ---
# Up: ESC O A = 1b 4f 41
assert_event "1b 4f 41" "up" "up arrow"

# Down: ESC O B = 1b 4f 42
assert_event "1b 4f 42" "down" "down arrow"

# Right: ESC O C = 1b 4f 43
assert_event "1b 4f 43" "right" "right arrow"

# Left: ESC O D = 1b 4f 44
assert_event "1b 4f 44" "left" "left arrow"

# --- Function keys F1-F4 (ESC O P/Q/R/S) ---
assert_event "1b 4f 50" "f1" "F1"
assert_event "1b 4f 51" "f2" "F2"
assert_event "1b 4f 52" "f3" "F3"
assert_event "1b 4f 53" "f4" "F4"

# --- Function keys F5-F12 ---
# F5: ESC [ 1 5 ~ = 1b 5b 31 35 7e
assert_event "1b 5b 31 35 7e" "f5" "F5"
# F6: ESC [ 1 7 ~ = 1b 5b 31 37 7e
assert_event "1b 5b 31 37 7e" "f6" "F6"
# F7: ESC [ 1 8 ~ = 1b 5b 31 38 7e
assert_event "1b 5b 31 38 7e" "f7" "F7"
# F8: ESC [ 1 9 ~ = 1b 5b 31 39 7e
assert_event "1b 5b 31 39 7e" "f8" "F8"
# F9: ESC [ 2 0 ~ = 1b 5b 32 30 7e
assert_event "1b 5b 32 30 7e" "f9" "F9"
# F10: ESC [ 2 1 ~ = 1b 5b 32 31 7e
assert_event "1b 5b 32 31 7e" "f10" "F10"
# F11: ESC [ 2 3 ~ = 1b 5b 32 33 7e
assert_event "1b 5b 32 33 7e" "f11" "F11"
# F12: ESC [ 2 4 ~ = 1b 5b 32 34 7e
assert_event "1b 5b 32 34 7e" "f12" "F12"

# --- Navigation keys ---
# Home: ESC O H = 1b 4f 48
assert_event "1b 4f 48" "home" "Home"
# End: ESC O F = 1b 4f 46
assert_event "1b 4f 46" "end" "End"
# Insert: ESC [ 2 ~ = 1b 5b 32 7e
assert_event "1b 5b 32 7e" "ins" "Insert"
# Delete: ESC [ 3 ~ = 1b 5b 33 7e
assert_event "1b 5b 33 7e" "del" "Delete"
# PgUp: ESC [ 5 ~ = 1b 5b 35 7e
assert_event "1b 5b 35 7e" "pgup" "Page Up"
# PgDn: ESC [ 6 ~ = 1b 5b 36 7e
assert_event "1b 5b 36 7e" "pgdn" "Page Down"

# --- Modifier combos on arrows ---
# Ctrl+Right: ESC [ 1 ; 5 C = 1b 5b 31 3b 35 43
assert_event "1b 5b 31 3b 35 43" "ctrl-right" "Ctrl+Right"
# Ctrl+Left: ESC [ 1 ; 5 D = 1b 5b 31 3b 35 44
assert_event "1b 5b 31 3b 35 44" "ctrl-left" "Ctrl+Left"
# Alt+Up: ESC [ 1 ; 3 A = 1b 5b 31 3b 33 41
assert_event "1b 5b 31 3b 33 41" "alt-up" "Alt+Up"
# Shift+Down: ESC [ 1 ; 2 B = 1b 5b 31 3b 32 42
assert_event "1b 5b 31 3b 32 42" "shift-down" "Shift+Down"

# --- Super (macOS Cmd) combos via the xterm meta bit ---
# Cmd+Left: ESC [ 1 ; 9 D = 1b 5b 31 3b 39 44
assert_event "1b 5b 31 3b 39 44" "super-left" "Cmd+Left (super-left)"
# Cmd+Right: ESC [ 1 ; 9 C = 1b 5b 31 3b 39 43
assert_event "1b 5b 31 3b 39 43" "super-right" "Cmd+Right (super-right)"
# Cmd+Shift+Left: ESC [ 1 ; 10 D = 1b 5b 31 3b 31 30 44
assert_event "1b 5b 31 3b 31 30 44" "shift-super-left" "Cmd+Shift+Left (shift-super-left)"

# --- Modifier combos on F-keys ---
# Ctrl+F5: ESC [ 1 5 ; 5 ~ = 1b 5b 31 35 3b 35 7e
assert_event "1b 5b 31 35 3b 35 7e" "ctrl-f5" "Ctrl+F5"
# Alt+F1: ESC [ 1 ; 3 P = 1b 5b 31 3b 33 50
assert_event "1b 5b 31 3b 33 50" "alt-f1" "Alt+F1"

# --- Shift+Tab ---
# ESC [ Z = 1b 5b 5a
assert_event "1b 5b 5a" "shift-tab" "Shift+Tab"

quit_tuish
test_summary
