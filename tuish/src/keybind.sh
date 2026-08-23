# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Load guard: skip re-definition if already sourced (see tui.sh).
if test -n "${_tuish_keybind_loaded:-}"; then return 0; fi
_tuish_keybind_loaded=1
# src/keybind.sh - Declarative key binding dispatch
# Optional module. Source after ord.sh.
#
# Provides:
#   tuish_bind EVENT ACTION   - bind event to shell function/command
#   tuish_unbind EVENT        - remove binding
#   tuish_dispatch            - dispatch TUISH_EVENT through bindings
#
# Bindings are stored as variables: _tuish_kb_<sanitized_event>=action.
# The event name is sanitized injectively: alphanumerics and the escape
# underscores survive; every other byte (including a literal '_') becomes
# _<decimal-ord>_, so two distinct events can never collide on one key.
#
# Dependencies: _tuish_ord() (from src/ord.sh)

_tuish_kb_sanitize ()
{
	# Event name -> injective variable suffix in _tuish_kb_key. Escaping the
	# literal '_' first lets the common specials map to their own _<ord>_ form
	# via fast ${//} (no per-char loop on the dispatch hot path); only rarely
	# typed bytes fall through to the char-by-char encoder.
	_tuish_kb_key="$1"
	_tuish_kb_key="${_tuish_kb_key//_/_95_}"
	_tuish_kb_key="${_tuish_kb_key//-/_45_}"
	_tuish_kb_key="${_tuish_kb_key//./_46_}"
	_tuish_kb_key="${_tuish_kb_key// /_32_}"
	_tuish_kb_key="${_tuish_kb_key//\*/_42_}"
	case "$_tuish_kb_key" in *[!A-Za-z0-9_]*)
		local _kb_tmp="$_tuish_kb_key" _kb_out='' _kb_i=0 _kb_c
		while test $_kb_i -lt ${#_kb_tmp}
		do
			_kb_c="${_kb_tmp:$_kb_i:1}"
			case "$_kb_c" in
				[A-Za-z0-9_]) _kb_out="${_kb_out}${_kb_c}";;
				*) _tuish_ord "$_kb_c"; _kb_out="${_kb_out}_${_tuish_code}_";;
			esac
			_kb_i=$((_kb_i + 1))
		done
		_tuish_kb_key="$_kb_out";;
	esac
}

# Catch-all key, resolved once (sanitize is pure for a fixed input).
_tuish_kb_sanitize '*'
_tuish_kb_star="$_tuish_kb_key"

# The bind table is per-context: an active-context prefix isolates each app's
# bindings so two apps coexisting in one process cannot collide. The root context
# keeps the empty prefix, so its keys are byte-identical to the flat table.
# _tuish_kb_keys tracks the sanitized keys bound in the active context, so
# tuish_ctx_destroy can unset them deterministically (shell cannot unset by glob).
_tuish_kb_ns=''
_tuish_kb_keys=''
command -v tuish_ctx_register >/dev/null 2>&1 && tuish_ctx_register _tuish_kb_ns _tuish_kb_keys

tuish_bind ()
{
	_tuish_kb_sanitize "$1"
	eval "_tuish_kb_${_tuish_kb_ns}${_tuish_kb_key}=\"\$2\""
	_tuish_kb_keys="${_tuish_kb_keys} ${_tuish_kb_key}"
}

tuish_unbind ()
{
	_tuish_kb_sanitize "$1"
	eval "unset _tuish_kb_${_tuish_kb_ns}${_tuish_kb_key}"
}

# A match sets TUISH_HANDLED=1 *before* the action runs, so the action itself can
# call tuish_pass to give the event back (see event.sh). Returns 0 when a binding
# matched -- which is not the same question: a binding that passed still returns 0.
tuish_dispatch ()
{
	# Exact match
	_tuish_kb_sanitize "$TUISH_EVENT"
	eval "local _d_action=\"\${_tuish_kb_${_tuish_kb_ns}${_tuish_kb_key}:-}\""
	if test -n "$_d_action"; then TUISH_HANDLED=1; eval "$_d_action"; return 0; fi

	# Glob prefix: a "char *" binding matches any "char X"
	local _d_prefix="${TUISH_EVENT%% *}"
	if test "$_d_prefix" != "$TUISH_EVENT"
	then
		_tuish_kb_sanitize "${_d_prefix} *"
		eval "_d_action=\"\${_tuish_kb_${_tuish_kb_ns}${_tuish_kb_key}:-}\""
		if test -n "$_d_action"; then TUISH_HANDLED=1; eval "$_d_action"; return 0; fi
	fi

	# Wildcard catch-all "*"
	eval "_d_action=\"\${_tuish_kb_${_tuish_kb_ns}${_tuish_kb_star}:-}\""
	if test -n "$_d_action"; then TUISH_HANDLED=1; eval "$_d_action"; return 0; fi

	return 1
}

# ─── Held keys, on a keyboard that cannot say so ─────────────────
#
# A plain VT reports no key release. Hold a key and the tty simply repeats the same event at
# the OS autorepeat rate — so "is A down?" has no direct answer, and an app that wants one
# has to infer it from RECENCY: a repeat arrived a moment ago, therefore the key is still
# down; nothing for a while, therefore it was let go.
#
# That inference has exactly one number in it, and the number has to sit between two
# timescales the app does not control:
#
#     autorepeat interval  ~33ms  --> the window must EXCEED this, or a held key
#                                     looks released in the gaps between repeats
#     the window           150ms
#     initial repeat delay ~500ms --> the window must FALL SHORT of this, or a single
#                                     tap is still "down" when the first repeat lands,
#                                     and a tap becomes a hold
#
# Miss on either side and it is not subtly wrong, it is the wrong feature. examples/game.sh
# carried this window by hand (as MOVE_TTL_US) with the same value and the same reasoning,
# and every other real-time app would have had to rediscover it. The decay also has to ride
# the CONTEXT's tick — a hosted child is ticked at its own negotiated rate, which it cannot
# compute for itself without asking whether it is hosted, and asking that is a smell
# (docs/hosting.md). So it belongs here.
#
# Kitty sharpens this and is never required: with tuish_detailed_on the terminal sends real
# `-rep`/`-rel` events, and the stamp below uses them when they arrive — a release zeroes
# the window outright instead of waiting it out. Same API, same app code, better source.

# Declare the keys this context tracks. Replaces the set, like a fresh declaration and not
# an append — call it once in your setup, next to your binds.
tuish_key_track ()   # $@ = event names, e.g. 'char a' 'left'
{
	local _tuish_kt_a
	_tuish_key_set=''
	for _tuish_kt_a in "$@"
	do
		_tuish_kb_sanitize "$_tuish_kt_a"
		_tuish_key_set="${_tuish_key_set} ${_tuish_kb_key}:0"
	done
	return 0
}

# The window, in seconds. See the timescales above before changing it.
tuish_key_ttl ()   # $1 = seconds, e.g. 0.15
{
	_tuish_timeout_us "$1"
	_tuish_key_ttl_us=$_tuish_tick_us
	return 0
}

# Is any of these keys down? Several, because aliasing is the normal case: a game binds
# `left` and `char a` to one action and wants one question, not two.
#
# The answer is an exit status, which does not break the "answers come back in variables"
# rule — that rule bans stdout, because asking a question must not cost a fork. A status
# forks nothing. tuish_hosted and tuish_host_owns_row answer the same way.
tuish_key_down ()   # $@ = event names
{
	local _tuish_kq_a
	for _tuish_kq_a in "$@"
	do
		_tuish_kb_sanitize "$_tuish_kq_a"
		case " $_tuish_key_set " in
			*" ${_tuish_kb_key}:0 "*) ;;          # tracked, window empty
			*" ${_tuish_kb_key}:"*) return 0;;    # tracked, window open
		esac
	done
	return 1
}

# Refill a tracked key's window, and say whether this event was a REPEAT.
#
# Called from the event hot path, so it does no work an app has not asked for: the caller
# tests _tuish_key_set first.
_tuish_key_stamp ()
{
	local _tuish_ks_n="$TUISH_EVENT" _tuish_ks_t=$_tuish_key_ttl_us

	# Kitty detailed mode reports the truth, so believe it over the inference: a held key
	# repeats as `<key>-rep` and ends with `<key>-rel`. Fold both onto the pressed key's
	# slot — a release empties the window at once rather than waiting it out.
	case "$_tuish_ks_n" in
		*-rel) _tuish_ks_n="${_tuish_ks_n%-rel}"; _tuish_ks_t=0;;
		*-rep) _tuish_ks_n="${_tuish_ks_n%-rep}";;
	esac
	# ...and then put back what hid.sh dropped. It spells an unmodified printable PRESS
	# `char a`, but its REPEAT `a-rep` — the suffix path does not re-add the `char ` prefix.
	# Left alone, the repeats miss the slot the press created and a physically-held key
	# reads as up the moment any app calls tuish_detailed_on. A one-BYTE name can only be
	# that case: every other event name is two or more (`up`, `f1`, `tab`), and a modified
	# one keeps its prefix (`ctrl-a-rep` -> `ctrl-a`, a real name that must NOT be rewritten).
	# LC_ALL=C is pinned, so `?` is one byte — a kitty repeat of a non-ASCII key will not
	# re-acquire its `char `. Games track ASCII.
	case "$_tuish_ks_n" in ?) _tuish_ks_n="char ${_tuish_ks_n}";; esac

	_tuish_kb_sanitize "$_tuish_ks_n"
	TUISH_KEY_REPEAT=0
	case " $_tuish_key_set " in
		*" ${_tuish_kb_key}:0 "*) ;;             # tracked, was up -> a fresh press
		*" ${_tuish_kb_key}:"*) TUISH_KEY_REPEAT=1;;   # tracked, still down -> a repeat
		*) return 0;;                            # not tracked at all
	esac

	local _tuish_ks_out='' _tuish_ks_p
	for _tuish_ks_p in $_tuish_key_set
	do
		case "$_tuish_ks_p" in
			"${_tuish_kb_key}:"*) _tuish_ks_p="${_tuish_kb_key}:${_tuish_ks_t}";;
		esac
		_tuish_ks_out="${_tuish_ks_out} ${_tuish_ks_p}"
	done
	_tuish_key_set="$_tuish_ks_out"
	return 0
}

# Age every open window by one tick. The caller has already established that at least one
# is open, so this never runs on an idle nobody is tracking keys through.
#
# Its own function, and that is load-bearing rather than tidy: it needs a `for`, and a loop
# variable still live in tuish_run's frame when a read-then-render fires gets ECHOED to the
# terminal under zsh (see the invariant above _tuish_kitty_decode in event.sh). Dying on
# return is the whole point.
_tuish_key_decay ()
{
	local _tuish_kd_out='' _tuish_kd_p _tuish_kd_t
	for _tuish_kd_p in $_tuish_key_set
	do
		_tuish_kd_t="${_tuish_kd_p##*:}"
		if test "$_tuish_kd_t" -gt 0
		then
			_tuish_kd_t=$(( _tuish_kd_t - TUISH_TICK_US ))
			test "$_tuish_kd_t" -lt 0 && _tuish_kd_t=0
			_tuish_kd_p="${_tuish_kd_p%:*}:${_tuish_kd_t}"
		fi
		_tuish_kd_out="${_tuish_kd_out} ${_tuish_kd_p}"
	done
	_tuish_key_set="$_tuish_kd_out"
	return 0
}
