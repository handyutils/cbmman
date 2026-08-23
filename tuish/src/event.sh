# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# src/event.sh - Event loop, dispatch, and redraw scheduling
# Optional module. Source after tui.sh.
#
# Provides:
#   tuish_run              - main event loop
#   tuish_start            - convenience: init + run + fini
#   tuish_request_redraw   - schedule deferred redraw (rAF pattern)
#   tuish_cancel_redraw    - cancel pending redraw
#   tuish_has_pending_input - check if input is queued
#   tuish_on_redraw        - callback stub (override in your app)
#   tuish_on_event         - default: calls tuish_dispatch (override for custom logic)
#
# Internal:
#   _tuish_parse_event     - dispatch wrapper (delegates to _tuish_resolve_event)
#   _tuish_dump_code       - route raw byte to parse_event
#   _tuish_kitty_decode    - decode kitty CSI-u ords into the parameter string

if test -n "${_tuish_event_loaded:-}"; then return 0; fi
_tuish_event_loaded=1

# ─── Redraw scheduling ────────────────────────────────────────────

_tuish_redraw_requested=0
_tuish_redraw_level=0
# How many times running this context's pending frame has been held back. Bounds the
# deferral so a sustained burst cannot withhold the screen indefinitely; see the rAF
# check in _tuish_parse_event for why it has to be bounded at all, and why the bound
# has a floor as well as a ceiling.
_tuish_raf_defers=0

# The redraw scheduler is per-context (a nested child renders on its own clock). The defer
# count goes with it: it measures how long THIS context's frame has been owed, and a host
# driving four children must not spend one budget across all four.
tuish_ctx_register _tuish_redraw_requested _tuish_redraw_level _tuish_raf_defers

# ─── The starved clock ───────────────────────────────────────────
# Complete events dispatched since the last idle actually fired.
#
# An idle event is not a timer — it is the reader's `read -t<interval>` TIMING OUT. So the
# tick fires while a key is held if and only if the idle interval is SHORTER than the
# terminal's autorepeat interval. Above it, a byte is always waiting before the timeout
# lands, the read never times out, and a real-time app's clock stops dead for as long as the
# key is down. Nothing announced that constraint, and the margin is thin: the platformer
# polls at 20ms against a typical ~33ms autorepeat, and `xset r rate 250 50` erases it.
#
# So count. Healthy interleaving is `idle, byte, idle, byte` and the count never passes 1 —
# a burst tick never fires and the clock is exactly what it always was. Reaching 2 means two
# complete events with NO read timeout between them, which IS the definition of a starved
# tick, so we owe one. 1 would fire after every byte in the healthy case and double the rate.
#
# This buys LIVENESS, not fidelity. Under starvation the tick fires per-N-events rather than
# per-wall-ms, so game-time dilates — fast where the interval is coarse, slow where the
# autorepeat is. It never STOPS, which is what it did before. Real fidelity needs a wall
# clock, and reading one costs a fork per tick on the shells this targets; the accumulator
# stays the clock, and this bounds how wrong it can get.
#
# DEVICE-global: it describes the input stream, like _tuish_pending_byte. It also has to
# outlive a loop iteration, so it could not be one of tuish_run's locals in any case — and
# tuish_run is permanently on tuish_fnfix's skip list, where `local` is a global on ksh93
# forever.
_tuish_burst=0

# ─── The rAF peek inhibit ────────────────────────────────────────
# "Do not peek at the input right now: the next sequence's ESC byte has already been
# read, so a peek would eat its body."
#
# DEVICE-global, and that is a correctness requirement, not a preference — there is one
# input stream, one _tuish_pending_byte (tui.sh), and one reader. It says nothing about
# any context.
#
# It was a context register, and the bug that hides there is worth naming, because it
# looks so much like the thing that is right everywhere else in this file. tuish_run sets
# the flag in ITS context, then dispatches; a cooperative host routes that event onward
# with tuish_ctx_dispatch, which activates the child — and the child's saved frame carries
# its OWN copy of the flag, which is 0. The child then requests a redraw, reaches the rAF
# check, sees no inhibit, and peeks. That peek stashes a byte in _tuish_pending_byte while
# tuish_run's escape loop is reading the tty DIRECTLY, so the sequence body it was in the
# middle of assembling loses a byte to a replay queue the loop will not drain until later.
# Bytes come out reordered: exactly the failure the flag exists to prevent, entered through
# the front door, and only when a host is driving a child — the one case the escape-burst
# tests do not cover.
#
# Same reasoning as TUISH_HANDLED below: state that describes the DEVICE, or the single
# event in flight, must not be marshalled per context.
_tuish_raf_inhibit=0

tuish_request_redraw ()
{
	local _level=${1:--1}
	test "$_level" -eq 0 && return
	if test "$_level" -eq -1 || test "$_tuish_redraw_level" -eq -1
	then
		_tuish_redraw_level=-1
	elif test "$_level" -gt "$_tuish_redraw_level"
	then
		_tuish_redraw_level=$_level
	fi
	_tuish_redraw_requested=1
}
tuish_cancel_redraw ()
{
	_tuish_redraw_requested=0
	_tuish_redraw_level=0
	# Cancelling ends this frame's wait, so the next request starts its budget fresh.
	# Deliberately NOT reset in tuish_request_redraw: re-requesting a frame that is still
	# pending is exactly the thing being counted.
	_tuish_raf_defers=0
}

# ─── Render / event handlers, referenced by name per context ─────
# A context stores the NAME of its render/event handler (not a redefined global
# function), so multiple apps can coexist and be saved/restored without any
# function-body introspection (busybox has none). The framework calls the active
# context's handler indirectly, falling back to the redefinable tuish_on_redraw /
# tuish_on_event stubs when no name was registered — so the classic "redefine the
# hook" style keeps working unchanged for a single-context app.
_tuish_render_fn=''
_tuish_event_fn=''
command -v tuish_ctx_register >/dev/null 2>&1 && tuish_ctx_register _tuish_render_fn _tuish_event_fn

# ─── Did anything act on this event? ─────────────────────────────
# Set to 0 before each dispatch and to 1 by tuish_dispatch when a binding matches.
# A host reads it (as TUISH_CTX_HANDLED, after tuish_ctx_dispatch) to decide whether
# a child consumed the event or is handing it back — which is what makes scroll
# CHAINING possible: give the wheel to the widget under the pointer, and if the
# widget declines it, scroll the page instead.
#
# DEVICE-global, deliberately not a context register: it describes the one event in
# flight, and a per-context copy would be swapped out by tuish_ctx_activate in the
# middle of the very dispatch it is reporting on.
TUISH_HANDLED=0

# ─── Was this key event a REPEAT? ────────────────────────────────
# 1 if the key event in flight is the terminal autorepeating a key that was already down,
# 0 if it is a fresh press. Set by _tuish_key_stamp (keybind.sh) for tracked keys only, and
# meaningful on a `key` event.
#
# This is the press/repeat split that the kitty protocol reports natively and a plain VT
# does not — synthesized from the window keybind.sh is already keeping: the slot was empty,
# so this is a press; the slot was open, so the key never came up.
#
# It is what makes an app EDGE-TRIGGERABLE, and without it the tracking API cannot serve its
# own motivating case. A binding cannot ask tuish_key_down to tell a press from a repeat,
# because by the time the binding runs the window has been refilled either way — that is
# deliberate (a handler must be able to ask about the key that just arrived), and it means
# the distinction has to be handed to it rather than derived by it. A game reads this to
# step exactly one tile on the press and let the tick own the run; without it, movement has
# to come off the tick alone, and a tap moves however far one window happens to be worth.
#
# DEVICE-global, for TUISH_HANDLED's reason above: it describes the single event in flight,
# and a per-context copy would be swapped out by tuish_ctx_activate in the middle of the
# dispatch it is reporting on. A host driving two children re-derives it per child anyway,
# because _tuish_ctx_drive re-enters the parse against that child's own tracked set.
TUISH_KEY_REPEAT=0

# "I saw this event and I am not acting on it." An action calls this to hand the
# event back to whoever hosts it, so a bound-but-inert key still chains: an editor
# already scrolled to the bottom passes the wheel up rather than swallowing it.
# Call it from inside the action -- tuish_dispatch marks the event handled BEFORE
# running the action, precisely so the action can take it back.
tuish_pass () { TUISH_HANDLED=0; }

# tuish_on_redraw is polymorphic:
#   tuish_on_redraw FUNC   (arg contains a non-digit) -> register FUNC as the
#                          active context's render handler (the hostable form).
#   tuish_on_redraw LEVEL  (empty or numeric, i.e. the framework's fallback call
#                          when nothing was registered) -> no-op default.
# An app may instead redefine this function outright; then it is never called as
# a setter (the fallback simply invokes the redefined body).
tuish_on_redraw ()
{
	case "${1:-}" in
		*[!0-9-]*) _tuish_render_fn="$1";;
		*) : ;;
	esac
}

tuish_has_pending_input ()
{
	test -n "${_tuish_pending_byte}" && return 0
	if _tuish_peek_byte
	then
		_tuish_pending_byte="$_tuish_byte"
		return 0
	fi
	return 1
}

# _tuish_resolve_event, _tuish_viewport_on_resize and tuish_dispatch are stubbed
# in tui.sh (the base) and overridden by hid.sh / viewport.sh / keybind.sh.

# ─── Default event handler (override in your app if needed) ──────
# Polymorphic like tuish_on_redraw:
#   tuish_on_event FUNC  (one arg) -> register FUNC as the active context's event
#                        handler (the hostable form).
#   tuish_on_event       (no arg, the framework's fallback call) -> the default
#                        behavior: dispatch the event through the bindings.
tuish_on_event ()
{
	if test $# -gt 0
	then _tuish_event_fn="$1"
	else tuish_dispatch || :
	fi
}

# ─── Internal: event dispatch ─────────────────────────────────────

_tuish_parse_event ()
{
	set -- ${1}

	local _class=$1
	TUISH_EVENT=''
	TUISH_EVENT_KIND=''
	TUISH_RAW="${*:-}"

	case "$_class" in
		S) TUISH_EVENT_KIND='signal'; TUISH_EVENT="${2}";;
		F) TUISH_EVENT_KIND='idle'; TUISH_EVENT='idle'
		   # Age this context's held-key windows by one tick (see keybind.sh). A driven
		   # child arrives here through tuish_ctx_tick, which only fires once the child's
		   # OWN interval has banked — so TUISH_TICK_US is the right unit for host and
		   # child alike, with no wall-clock read and no fork.
		   #
		   # One glob, and it answers BOTH questions at once: "nothing tracked" (the set is
		   # empty) and "nothing down" (every window reads :0) alike contain no colon
		   # followed by a non-zero digit — a sanitized key name cannot contain a colon, and
		   # $(( )) never emits a leading zero. So an app that tracks nothing pays one
		   # comparison per tick, and keybind.sh being unsourced is not a special case: the
		   # set stays empty and the call is unreachable.
		   case "$_tuish_key_set" in *:[1-9]*) _tuish_key_decay;; esac;;
		# The pasted TEXT is NOT in the descriptor — it would not survive `set --`
		# word splitting, and a paste can contain anything. It lives in TUISH_PASTE,
		# which _tuish_capture_paste filled before emitting this.
		P) TUISH_EVENT_KIND='paste'; TUISH_EVENT='paste';;
		*) _tuish_resolve_event "$@";;
	esac

	# No event resolved — skip
	test -z "$TUISH_EVENT" && return

	# Drop mouse events when mouse tracking is off
	if test "$TUISH_EVENT_KIND" = 'mouse' && test $_tuish_mouse -eq 0
	then
		return
	fi

	# MODAL hosting only: a click outside our region is meant for the host, not us,
	# but a modal child owns the keyboard inside its own nested tuish_run — so the
	# only way to hand control back is to end that loop. We quit; the host's
	# tuish_run resumes and its UI is live again. The click itself is CONSUMED, not
	# replayed: closing the child IS the response to it. Motion outside is ignored.
	#
	# A cooperatively-driven child (_tuish_driven) never takes this path: its host
	# keeps the one loop and routes by region, forwarding only what falls inside —
	# so an outside click simply never reaches the child, and self-quitting here
	# would be a spurious quit the host would read as "the app ended".
	if test "${_tuish_owns_dev:-1}" -eq 0 && test "${_tuish_driven:-0}" -ne 1 \
	   && test "$TUISH_EVENT_KIND" = 'mouse'
	then
		case "$TUISH_EVENT" in
			*clik)
				if test "$TUISH_MOUSE_X" -lt 1 || test "$TUISH_MOUSE_X" -gt "$_tuish_rgn_cols" \
				   || test "$TUISH_MOUSE_Y" -lt 1 || test "$TUISH_MOUSE_Y" -gt "$_tuish_rgn_rows"
				then
					tuish_quit
					return
				fi
				;;
		esac
	fi

	# Drop repeat/release events when detailed mode is off
	if test $_tuish_detailed -eq 0
	then
		case "$TUISH_EVENT" in
			*-rel|*-rep) return;;
		esac
	fi

	# Drop physical modifier key events when modkeys mode is off
	if test $_tuish_modkeys -eq 0
	then
		case "$TUISH_EVENT" in
			*.[lr]) return;;
		esac
	fi

	# Intercept resize for viewport management
	if test -n "$_tuish_view_mode" && test "$TUISH_EVENT" = 'resize'
	then
		_tuish_viewport_on_resize
	fi

	# Refill the window on a tracked key, and decide whether this is a repeat.
	#
	# HERE, and the position is the whole design. After the drop filters: a key the app is
	# never shown must not count as held on its behalf. Before the handler: a binding for
	# the very key that just arrived has to be able to ask tuish_key_down and TUISH_KEY_REPEAT
	# and get answers about ITSELF — which is exactly what an edge-triggered action needs,
	# and the reason the press/repeat split has to come from here rather than from the app.
	#
	# Set first, kind second: the set is empty for almost every app that will ever run, so
	# the first pattern is the one that has to be cheap. `case` rather than `test -n` for
	# that reason and no other — it is a shell keyword where test is a builtin call, and the
	# bench puts the difference at ~0.5us of every dispatch.
	case "$_tuish_key_set" in ?*) test "$TUISH_EVENT_KIND" = 'key' && _tuish_key_stamp;; esac

	# ONE frame for the whole dispatch: the handler's output, then (if it asked for a
	# deferred redraw) the render's, closed once at the end. Frames nest, so a handler
	# that opens its own no longer resets ours.
	#
	# _tuish_pe_base heals an UNBALANCED handler. A depth counter is unforgiving where the
	# old boolean self-healed: one stray tuish_begin would wedge the loop into never
	# flushing again — a permanently frozen screen. Restoring the depth we entered at
	# turns that into a lost frame instead of a dead app.
	#
	# The ugly name is load-bearing, and it is NOT free to shorten to `_base`.
	#
	# On ksh93, `local` is an alias for `typeset` (compat.sh), and typeset does NOT create
	# a local in a POSIX `f () { ... }` function — only in a ksh-style `function f { ... }`
	# one. Every function in this toolkit is POSIX-style, so on ksh93 EVERY `local` here is
	# really a global. That is survivable exactly as long as the names cannot collide with
	# a caller's, which is what the prefix buys.
	#
	# It is not hypothetical: this variable was called `_base`, and it silently overwrote
	# the `_base` loop variable of the caller that drives us — turning `E 91 49 59 50 65`
	# into `E 91 1 59 50 65` on the second iteration and taking 176 modifier tests down
	# with it. A framework local is a framework global on one of our five shells. Name it
	# like one.
	tuish_begin
	local _tuish_pe_base=$_tuish_buffering
	TUISH_HANDLED=0
	"${_tuish_event_fn:-tuish_on_event}"
	_tuish_buffering=$_tuish_pe_base

	if test $_tuish_redraw_requested -eq 1
	then
		# rAF mode: a deferred redraw supersedes whatever the handler drew. Discard the
		# CONTENT, not the frame — the frame is still ours and still open.
		_tuish_buf=''
		# Those bytes never reached the terminal, so nothing may go on believing they did.
		# The caret-shape cache is the one record of "what the device has" that a discarded
		# frame can falsify: a widget MOUNTED inside this handler — which is how every host
		# mounts anything — wrote its DECSCUSR into the buffer we just threw away. Forget
		# it; the render below re-asserts the shape from the context's declaration, which is
		# a variable and was never in here to lose.
		#
		# The same hole swallows any other one-shot device escape a child emits while being
		# mounted (tuish_mouse_on in its setup, say) — those are not re-declared per frame,
		# so they are simply gone, and only the host's own device setup covers for them. A
		# child should not be setting device modes; see docs/hosting.md.
		_tuish_cursor_shape_dev=''

		# Hold this frame back? Three clauses, and the last two are the interesting ones.
		#
		# An IDLE never holds. Idle MEANS the input was exhausted — _tuish_idle_wait let a
		# whole interval elapse with nothing arriving to produce this event, so a byte that
		# lands while the handler runs does not undo the wait we already paid. It is also the
		# safest place to render: not testing means not PEEKING, and the peek is the only
		# thing here that can reorder a byte. It cannot race the inhibit either — that flag is
		# raised only around a half-read sequence, a signal, and a paste marker, none of which
		# dispatch an idle.
		#
		# Ask _class, not TUISH_EVENT_KIND, and the cheap reason is not the good one. Cheap:
		# _class is already in hand, so an app that never defers a redraw pays nothing —
		# latching the kind before the handler instead cost ~8% of EVERY dispatch, on the one
		# path this toolkit cannot afford to tax. Good: _class is the descriptor we were woken
		# by, and no handler can reach it. TUISH_EVENT_KIND is a context field, i.e. whatever
		# the handler last left lying there.
		#
		# And the hold is BOUNDED. "Input is pending" is a -t0 peek: it does not say a burst
		# is coming, it says we are BEHIND — a byte is already buffered. Unbounded, that is a
		# livelock. A frame costing more than the terminal's autorepeat interval lets bytes
		# queue faster than they drain, so the peek never comes back empty and the screen
		# stays withheld until the key is RELEASED. Every app has this; a real-time one just
		# meets it first.
		#
		# The budget is a TRADE, and the direction that bites is the unobvious one: each
		# forced render costs a frame the backlog must then chew through, so too SMALL a
		# budget drains slower than input arrives — the queue grows without bound and letting
		# go of the key leaves the app still acting on it a second later. Keep it above
		# autorepeat_rate x frame_cost: at VT's ~30/s, 8 carries a 266ms frame, as slow as our
		# slowest target renders. Around 4 it inverts. Spending it past _tuish_raf_inhibit is
		# safe and looks like it is not — inhibit stops the PEEK from eating a sequence body,
		# and rendering never peeks. It writes.
		if test "$_class" != 'F' &&
		   { test "${_tuish_raf_inhibit:-0}" -eq 1 || tuish_has_pending_input ;} &&
		   test "$_tuish_raf_defers" -lt "${TUISH_DEFER_MAX:-8}"
		then
			# More input in flight — leave the redraw pending. When inhibit is set, the
			# next sequence's ESC byte was already read, so peeking would eat its body;
			# a later dispatch with the peek allowed (burst-final timeout path, or an
			# idle event) fires the redraw.
			_tuish_raf_defers=$(( _tuish_raf_defers + 1 ))
		else
			_tuish_raf_defers=0
			# Render now: the input is exhausted, or we were woken by an idle, or the
			# budget above ran out and the frame is owed regardless.
			#
			# The caret is re-declared every frame: we hide it here, and a handler that
			# wants one calls tuish_cursor, which shows it again. Because frames nest,
			# that hide now survives a render handler opening a frame of its own — which
			# is what every host does, and which used to throw it away.
			_tuish_redraw_requested=0
			local _level=$_tuish_redraw_level
			_tuish_redraw_level=0
			tuish_hide_cursor
			_tuish_cursor_vrow=0
			"${_tuish_render_fn:-tuish_on_redraw}" "$_level"
			_tuish_buffering=$_tuish_pe_base
		fi
	fi
	tuish_end
}

# ─── Internal: byte-to-event loop ──────────────────────────────────

# Decode kitty CSI-u byte codes (space-separated ords) into the parameter
# string. Result in _tuish_ku_str.
#
# INVARIANT: tuish_run must contain no `for`/iteration construct that leaves a
# control variable set in its own frame. Under zsh, a loop-control variable
# still live in the main loop's frame when the next read-then-render fires (the
# burst race) gets echoed to the terminal — the `_ku_c=51` screen leak. Plain
# live locals (_esc, _sig) do NOT leak: they are equally in scope at the
# legacy-escape and kitty dispatches yet never echoed, so the defect is the
# loop variable specifically. This decode is therefore kept in its own
# function: _kc dies on return, before any dispatch. tuish_run's remaining
# loops are `while _tuish_get_byte` (no control variable — the byte is the
# global _tuish_byte), which are safe. Keep it that way.
_tuish_kitty_decode ()
{
	local _kc
	_tuish_ku_str=''
	for _kc in $1
	do
		case "$_kc" in
			59) _tuish_ku_str="${_tuish_ku_str};";;
			58) _tuish_ku_str="${_tuish_ku_str}:";;
			*)  eval "_tuish_ku_str=\"\${_tuish_ku_str}\$_tuish_chr_$_kc\"";;
		esac
	done
}

_tuish_dump_code ()
{
	if test $_tuish_code -gt 31 && test $_tuish_code -lt 127
	then
		_tuish_parse_event "C $_tuish_byte"
		return
	elif test $_tuish_code -eq 226
	then
		local _prev="${_tuish_byte}"
		_tuish_get_byte
		_prev="${_prev}${_tuish_byte}"
		_tuish_get_byte
		_tuish_parse_event "C ${_prev}${_tuish_byte}"
		return
	elif test $_tuish_code -eq 194 || test $_tuish_code -eq 195
	then
		local _prev="${_tuish_byte}"
		_tuish_get_byte
		_tuish_parse_event "C ${_prev}${_tuish_byte}"
		return
	else
		_tuish_parse_event "E ${_tuish_code}"
	fi
}

# Dispatch an accumulated escape body $1 (e.g. "91 67" or " 79 65"): a CSI
# ('91…'), SS3 (' 79…'), or bare ESC ('') body emits class E unchanged; any other
# body is an Alt-<key> (ESC + byte), emitted with the 27 (ESC) prefix. Factored
# out of tuish_run's escape-dispatch sites so the CSI/SS3-vs-Alt rule lives in one
# place. A plain function (no loop variable) is safe here — see the
# _tuish_kitty_decode INVARIANT note above.
_tuish_esc_emit ()
{
	case "${1}" in
		''|91*|' 79'*) _tuish_parse_event "E ${1}";;
		*) _tuish_parse_event "E 27${1}";;
	esac
}

# ─── Bracketed paste capture ─────────────────────────────────────
# The body of a paste (everything between ESC[200~ and ESC[201~) is TEXT, not input.
# Without this it fell through to the ordinary key decoder, so a paste arrived as a
# burst of individual key events: a pasted newline fired the app's `enter` BINDING, a
# tab its `tab` binding, and every character forced a separate render+flush. Capture
# the body here instead and hand the app one atomic `paste` event with the text in
# TUISH_PASTE.
#
# TUISH_PASTE is DEVICE-global, deliberately NOT a context field: it belongs to the
# event in flight, and registering it would make tuish_ctx_activate swap it out from
# under a cooperative host dispatching the paste into a child.
TUISH_PASTE=''
TUISH_PASTE_MAX=${TUISH_PASTE_MAX:-262144}

# Read bytes until the ESC[201~ terminator, accumulating the body into TUISH_PASTE.
# Byte-oriented and ord-free on the hot path: we compare raw bytes, so multi-byte
# UTF-8 passes through untouched (the key decoder only understands a few lead bytes).
# A partial terminator that turns out not to be one (an ESC inside the pasted text) is
# flushed back into the body via _hold, so nothing is lost. Reads are esc-timeout
# bounded, so a truncated paste cannot hang the loop.
_tuish_capture_paste ()
{
	TUISH_PASTE=''
	local _st=0 _hold='' _n=0 _cr=0
	while _tuish_get_byte "$_tuish_esc_timeout"
	do
		# Terminator FSM: ESC [ 2 0 1 ~
		case "$_st" in
			0) if test "$_tuish_byte" = "$_tuish_chr_27"
			   then _st=1; _hold="$_tuish_byte"; continue; fi ;;
			1) if test "$_tuish_byte" = '['
			   then _st=2; _hold="${_hold}["; continue
			   fi; _st=0 ;;
			2) if test "$_tuish_byte" = '2'
			   then _st=3; _hold="${_hold}2"; continue
			   fi; _st=0 ;;
			3) if test "$_tuish_byte" = '0'
			   then _st=4; _hold="${_hold}0"; continue
			   fi; _st=0 ;;
			4) if test "$_tuish_byte" = '1'
			   then _st=5; _hold="${_hold}1"; continue
			   fi; _st=0 ;;
			5) test "$_tuish_byte" = '~' && return 0      # terminator: done
			   _st=0 ;;
		esac

		# Not (or no longer) a terminator: flush any held partial, then this byte.
		if test -n "$_hold"
		then TUISH_PASTE="${TUISH_PASTE}${_hold}"; _hold=''
		fi

		# Newlines: terminals send CR (or CRLF) for a line break inside a paste.
		# Normalize to LF so the body is an ordinary multi-line string.
		if test "$_tuish_byte" = "$_tuish_chr_13"
		then TUISH_PASTE="${TUISH_PASTE}${_tuish_chr_10}"; _cr=1
		elif test "$_tuish_byte" = "$_tuish_chr_10"
		then test "$_cr" -eq 1 || TUISH_PASTE="${TUISH_PASTE}${_tuish_chr_10}"; _cr=0
		else TUISH_PASTE="${TUISH_PASTE}${_tuish_byte}"; _cr=0
		fi

		# Bound the body: a runaway paste must truncate, not eat memory. Shell string
		# append is O(n), so a very large paste is slow regardless — the cap keeps a
		# pathological one survivable.
		_n=$(( _n + 1 ))
		if test "$_n" -ge "$TUISH_PASTE_MAX"
		then
			while _tuish_get_byte "$_tuish_esc_timeout"       # drain to the terminator
			do
				test "$_tuish_byte" = '~' && test "$_st" -eq 5 && break
				case "$_tuish_byte" in
					"$_tuish_chr_27") _st=1;;
					'[') test "$_st" -eq 1 && _st=2 || _st=0;;
					'2') test "$_st" -eq 2 && _st=3 || _st=0;;
					'0') test "$_st" -eq 3 && _st=4 || _st=0;;
					'1') test "$_st" -eq 4 && _st=5 || _st=0;;
					*) _st=0;;
				esac
			done
			return 0
		fi
	done
	# Timed out with no terminator: keep whatever body we got.
	test -n "$_hold" && TUISH_PASTE="${TUISH_PASTE}${_hold}"
	return 0
}

tuish_run ()
{
	_tuish_quit=''
	_tuish_quit_mode=''
	_tuish_burst=0

	# Fire initial idle event so the app can render before waiting for input
	_tuish_parse_event "F"

	while
		test "${_tuish_quit:-}" != yes && {
		test -n "${_tuish_pending_byte}" ||
		_tuish_idle_wait ||
		_tuish_noinput=yes ;}
	do
		if test -n "${_tuish_pending_byte}"
		then
			_tuish_byte="$_tuish_pending_byte"
			_tuish_pending_byte=''
			_tuish_noinput=no
		fi

		if test -n "${_tuish_signal:-}"
		then
			local _tuish_r_sig="$_tuish_signal"
			_tuish_signal=''
			# If read timed out / failed, no byte to process:
			# nothing is in flight, so the rAF peek is safe and
			# signal redraws render immediately
			if test "${_tuish_noinput:-no}" = "yes"
			then
				_tuish_parse_event "S $_tuish_r_sig"
				_tuish_noinput=no
				continue
			fi
			# A companion byte was read alongside the signal (zsh):
			# its sequence body is still unread — inhibit the rAF
			# peek so it can't eat those bytes. The pending redraw
			# fires when the companion byte's own events dispatch.
			local _tuish_r_sigbyte="$_tuish_byte"
			_tuish_raf_inhibit=1
			_tuish_parse_event "S $_tuish_r_sig"
			_tuish_raf_inhibit=0
			_tuish_byte="$_tuish_r_sigbyte"
			# Fall through to process the companion byte
		elif test "${_tuish_noinput:-no}" = "yes"
		then
			# The read timed out: the clock is healthy, so the burst owes nothing.
			_tuish_burst=0
			_tuish_parse_event "F"
			_tuish_noinput=no
			continue
		fi

		# A real byte, and we are between complete events — the escape FSM below reads its
		# own body, so this is the only point in the loop guaranteed not to be mid-sequence.
		# An idle injected here lands cleanly between two events; injected inside the FSM it
		# would split an ESC from its body.
		#
		# Count EVENTS, not bytes: an arrow key is three bytes and one iteration, so a held
		# arrow banks the same credit as a held letter.
		_tuish_burst=$(( _tuish_burst + 1 ))
		if test "$_tuish_burst" -ge "${TUISH_BURST_MAX:-2}"
		then
			_tuish_burst=0
			_tuish_parse_event "F"
		fi

		_tuish_ord "${_tuish_byte}"

		if test "$_tuish_code" -eq 27
		then
			local _tuish_r_esc=''
			while _tuish_get_byte "$_tuish_esc_timeout"
			do
				if test "$_tuish_r_esc" = '91' &&
					test "${_tuish_byte}" = '<'
				then
					_tuish_r_esc='M '
					while _tuish_get_byte
					do
						if test "${_tuish_byte}" = ';'
						then
							_tuish_r_esc="${_tuish_r_esc} "
							continue
						elif test "${_tuish_byte}" = 'm'
						then
							# SGR release: use class 'm'
							_tuish_r_esc="m${_tuish_r_esc#M}"
							break
						elif test "${_tuish_byte}" = 'M'
						then
							break
						else
							_tuish_r_esc="${_tuish_r_esc}${_tuish_byte}"
							continue
						fi
					done
					_tuish_parse_event "${_tuish_r_esc}"
					continue 2
				elif test "$_tuish_r_esc" = '91' && test "${_tuish_byte}" = 'M'
				then
					# X10 mouse (ESC [ M cb cx cy): the fallback for a terminal
					# without SGR-mouse (1006). The three bytes are button/x/y, each
					# offset by 32. Consume them HERE — otherwise the final-byte
					# dispatch below fires on 'M' (0x4D, a CSI final) and the three
					# coordinate bytes leak out as spurious keystrokes. cb-32 is the
					# same button encoding SGR sends, so it resolves via the same
					# M-class path. Reads are esc-timeout-bounded so a truncated
					# report can't hang the loop.
					local _tuish_r_x10n=0 _tuish_r_x10b='' _tuish_r_x10x='' _tuish_r_x10y=''
					while test $_tuish_r_x10n -lt 3
					do
						_tuish_get_byte "$_tuish_esc_timeout" || break
						_tuish_ord "${_tuish_byte}"
						case $_tuish_r_x10n in
							0) _tuish_r_x10b=$((_tuish_code - 32));;
							1) _tuish_r_x10x=$((_tuish_code - 32));;
							2) _tuish_r_x10y=$((_tuish_code - 32));;
						esac
						_tuish_r_x10n=$((_tuish_r_x10n + 1))
					done
					test $_tuish_r_x10n -eq 3 && \
						_tuish_parse_event "M ${_tuish_r_x10b} ${_tuish_r_x10x} ${_tuish_r_x10y}"
					continue 2
				elif
					test "$_tuish_r_esc" = '' &&
					test "$_tuish_byte" = "["
				then
					_tuish_r_esc="91"
					continue
				elif
					test "$_tuish_r_esc" = '' &&
					test "$_tuish_byte" = "O"
				then
					# SS3 introducer (ESC O): the next byte is the final. Mark the
					# state so the final-byte check below doesn't fire on the 'O'.
					_tuish_r_esc=" 79"
					continue
				elif
					test "$_tuish_r_esc" = '91' &&
					test "$_tuish_byte" = "["
				then
					# Linux console F1-F5 arrive as ESC [ [ A..E — the SECOND '[' is
					# an INTRODUCER, not a CSI final byte. Mark the state so the
					# final-byte dispatch below does not fire on '[' (0x5B is inside
					# 0x40-0x7E) and leak the trailing letter as a keystroke; the next
					# byte (A..E) is the real final. Resolves to f1..f5 in hid.sh.
					_tuish_r_esc="91 91"
					continue
				elif test "${_tuish_byte}" = 'u' && test "${_tuish_r_esc}" != "${_tuish_r_esc#91}"
				then
					# CSI u (kitty keyboard protocol)
					_tuish_kitty_decode "${_tuish_r_esc#91 }"
					_tuish_parse_event "K ${_tuish_ku_str}"
					continue 2
				fi

				_tuish_ord "${_tuish_byte}"

				if test "$_tuish_code" -eq 27
				then
					if test -n "$_tuish_r_esc"
					then
						# Inhibit rAF input-peek: the inner loop still needs to read
						# the bytes that follow this ESC (next sequence's O, C, etc.).
						# The rAF check defers the redraw instead of peeking; the
						# burst-final sequence (timeout path below) fires it.
						_tuish_raf_inhibit=1
						_tuish_esc_emit "$_tuish_r_esc"
						_tuish_raf_inhibit=0
					fi
					_tuish_r_esc=''
					continue
				elif test "$_tuish_code" -lt 32
				then
					if test -z "$_tuish_r_esc"
					then
						_tuish_parse_event "E 27 ${_tuish_code}"
						continue 2
					fi
					_tuish_esc_emit "$_tuish_r_esc"
					_tuish_r_esc=''
					_tuish_dump_code
					continue 2
				fi

				_tuish_r_esc="${_tuish_r_esc} ${_tuish_code}"

				# A CSI/SS3 final byte (0x40-0x7E) ends the sequence: dispatch now
				# instead of waiting out _tuish_esc_timeout for a continuation that
				# is not coming. Parameter/intermediate bytes are all < 0x40, so the
				# first byte >= 0x40 after the introducer is the final one. (Mouse
				# '<…M/m' and kitty '…u' already break above; the 91*/' 79'* guard
				# keeps Alt-<key> — ESC with no introducer — on the timeout path.)
				# This makes cursor/function keys instant and stops a held arrow's
				# autorepeat from starving idle events.
				if test "$_tuish_code" -ge 64 && test "$_tuish_code" -le 126
				then
					case "${_tuish_r_esc}" in
						# ESC[200~ — a bracketed paste opens. Capture the BODY here,
						# before emitting anything: the pasted bytes are text, not
						# keystrokes, and _tuish_parse_event's rAF input-peek would
						# otherwise eat them mid-render. paste-start / paste-end still
						# bracket it for apps that track the boundaries; the atomic
						# `paste` event in between carries the text in TUISH_PASTE.
						'91 50 48 48 126')
							_tuish_capture_paste
							_tuish_raf_inhibit=1
							_tuish_parse_event "E 91 50 48 48 126"
							_tuish_raf_inhibit=0
							_tuish_parse_event "P"
							_tuish_parse_event "E 91 50 48 49 126"
							continue 2;;
						91*|' 79'*) _tuish_parse_event "E ${_tuish_r_esc}"; continue 2;;
					esac
				fi
			done
			_tuish_esc_emit "$_tuish_r_esc"
			continue
		fi

		_tuish_dump_code
	done
}

tuish_start ()
{
	tuish_init
	tuish_run || :
	tuish_fini
}
