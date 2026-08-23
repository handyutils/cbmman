# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# src/compat.sh - Shell compatibility layer
# Source first, before any other module.  Do not execute directly.
#
# Provides:
#   Shell options    - set -euf, zsh POSIX compat unsetopt
#   _tuish_printf   - 1 if printf is usable for output, 0 for mksh (use echo -ne)
#   _tuish_out()    - raw terminal output (printf or echo -ne depending on shell)
#   alias local      - ksh93 compatibility (local → typeset)

# ─── Shell options ───────────────────────────────────────────────

set -euf
unsetopt NO_POSIX_TRAPS FLOW_CONTROL GLOB NO_MATCH NO_SH_WORD_SPLIT NO_PROMPT_SUBST 2>/dev/null || :

# ─── Locale ──────────────────────────────────────────────────────
# Force byte-oriented locale for consistent string operations across
# all shells.

_tuish_orig_lang="${LANG:-}"
_tuish_orig_lc_all="${LC_ALL:-}"
_tuish_orig_lc_ctype="${LC_CTYPE:-}"
LC_ALL=C; export LC_ALL
LC_CTYPE=C; export LC_CTYPE

# ─── Shell detection ──────────────────────────────────────────────

_tuish_printf=1

_tuish_out ()
{
	printf "${1:-}"
}

if test -n "${KSH_VERSION:-}"
then
	if test -z "${KSH_VERSION##*Version AJM*}"
	then
		alias local=typeset
	fi
	if test -z "${KSH_VERSION##*MIRBSD*}"
	then
		_tuish_printf=0
		_tuish_out ()
		{
			echo -ne "${1:-}"
		}
	fi
fi

# ─── Making `local` mean local ───────────────────────────────────
# On ksh93 the alias above is a lie, and it is the expensive kind.
#
# `typeset` creates a local variable in a KSH-STYLE function — `function f { ... }` — and
# NOT in a POSIX one — `f () { ... }`. Every function in this toolkit is POSIX-style. So on
# ksh93 every `local` in tuish declares a GLOBAL, and a framework helper's scratch variable
# silently overwrites any caller variable that happens to share its name.
#
# That is not a hypothetical. draw.sh builds a box's top border into `local _top`; a host
# that keeps its layout row in `_top` (examples/cooperative.sh does) gets its row replaced
# by the string "╭────────╮" and hands it to tuish_text as a coordinate. The repo has been
# carrying this as "a pre-existing ksh rendering bug" that test_hosting.sh skips over.
#
# The cure is to make the functions ksh-style after the fact: dump each one with
# `typeset -f`, and re-define it with the `function` keyword. Same body, real locals.
#
# WHAT MUST NOT BE CONVERTED, and this is the whole subtlety: a ksh-style function gets its
# own scope for more than variables. **Traps and shell options are local to it too.** An
# EXIT trap set inside one fires when the FUNCTION returns, not when the process exits — so
# converting tuish's trap-installing path would tear the terminal down the instant init
# finished. The exclusion list below is that path, and it is load-bearing.
#
# Detection is by FEATURE, not by shell name: define a POSIX function whose only act is to
# declare a local, and see whether it escapes. Shells where `local` works answer '' and skip
# the whole thing; only a shell that actually leaks pays for the fix.
#
# Ported from the same trick in Coral (core/footer.sh).

# What must stay POSIX. Space-delimited, and every entry earns its place.
#
# 1. THE TRAP PATH. A ksh-style function owns its traps and its shell options: an EXIT trap
#    set inside one fires when the FUNCTION returns, not when the process exits. Convert
#    these and tuish tears the terminal down the instant init finishes.
#
# 2. THE REFLECTIVE FUNCTIONS. This is the subtle one, and it is the reason the conversion
#    cannot simply be applied to everything.
#
#    ksh-style functions are STATICALLY scoped: a caller's local is INVISIBLE to a function
#    it calls. But tuish's whole no-fork idiom is to pass a variable NAME and have the
#    callee dereference it (docs/str.md) — `tuish_str_width _t` — precisely so nobody has
#    to fork a subshell to get an answer back. Convert the callee and it can no longer see
#    the `_t` it was handed.
#
#    Left POSIX, they run in the CALLER's scope and can still read the name they are given —
#    even when the caller is a converted ksh function. That asymmetry is what makes the
#    whole scheme work, and it is why the skip list is a design decision, not a wart.
#
#    The rule is "dereferences a variable NAME", not "is public": it reaches THROUGH the
#    public entry points to the private helpers they hand the name on to. _tuish_byte_val
#    and _tuish_char_byte_off are here for that reason — a converted _tuish_char_byte_off
#    takes tuish_str_left/right/char's whole non-ASCII path down with it, on the one shell
#    this file exists to serve. Adding a name-taking helper means adding it here.
#
# 3. THE BLOCKING LOOP. Worse than local traps: entering a ksh-style function RESETS traps
#    to their default for that scope, so a signal arriving while ANY ksh function is on the
#    stack is not deferred — it is DISCARDED. WINCH's default is "ignore". tuish_run is
#    where the process sits blocked in `read` waiting for input, which is exactly when a
#    terminal resize arrives, so converting it means the resize is silently dropped and the
#    app never relays out. (_tuish_get_byte / _tuish_idle_wait need no entry: _tuish_init_io
#    redefines them at device init, after the fixup has already run.)
#
# ONE LINE, deliberately: the lookup is `case $skip in *" $name "*)`, so every entry has to
# be space-delimited on BOTH sides. Wrap this onto a second line and the last name on each
# line is followed by a newline instead of a space, and silently stops being skipped.
_tuish_fnfix_skip=' _tuish_fnfix tuish_init _tuish_device_init _tuish_init_term tuish_fini tuish_run _tuish_byte_val _tuish_char_byte_off tuish_str_char tuish_str_left tuish_str_len tuish_str_pad tuish_str_right tuish_str_width tuish_str_window '

# Does `local` leak out of a POSIX function in this shell?
_tuish_fnfix_leaks ()
{
	_tuish_fnfix_probe=''
	eval '_tuish_fnfix_p () { local _tuish_fnfix_probe=leaked; }' 2>/dev/null || return 1
	_tuish_fnfix_p 2>/dev/null || :
	unset -f _tuish_fnfix_p 2>/dev/null || :
	# The probe answers by SURVIVING the function that set it, so it cannot be a local —
	# but it must not outlive the question either.
	case "$_tuish_fnfix_probe" in
		leaked) unset _tuish_fnfix_probe 2>/dev/null || :; return 0 ;;
	esac
	unset _tuish_fnfix_probe 2>/dev/null || :
	return 1
}

# Re-declare every framework function as ksh-style, so `local` scopes. Call it once, AFTER
# all modules are sourced — tuish_fnfix (below) is the entry point that does.
#
# ONE FORK, not one per function. The obvious shape is a loop over `typeset +f` calling
# `$(typeset -f "$name")` for each, and that is a command substitution — a subshell, a FORK,
# ~215 of them at every ksh startup. This toolkit spent a commit (07bdc67) removing two forks
# from init; paying back two hundred for a scoping fix is not a trade worth making, and on a
# fork-constrained runtime (the browser) it is not a trade that is available.
#
# `typeset -f` with NO argument dumps every body at once. One substitution, then split it
# in-shell.
_tuish_fnfix ()
{
	_tuish_fnfix_all="$(typeset -f 2>/dev/null)" || return 0
	test -n "$_tuish_fnfix_all" || return 0

	_tuish_fnfix_n=''
	_tuish_fnfix_b=''
	_tuish_fnfix_line=''

	# Split by DEFINITION START only, and accumulate everything up to the next one.
	#
	# Do NOT try to find where a definition ENDS: ksh prints a multi-line function as
	# `name()` / `{` / body / `}` but collapses a one-liner (tuish_pass, tuish_hosted) onto
	# a single `name() { ...; }` line. A parser that looks for a closing `}` at column 0
	# silently drops every one-liner — which is exactly the bug this replaced. A definition
	# runs until the next definition starts; that is true of both forms.
	#
	# A start line is an identifier at column 0 followed by `()`. Body lines in the dump are
	# indented, and `{` / `}` do not match the pattern, so they cannot be mistaken for one.
	_tuish_fnfix_ifs="$IFS"
	IFS='
'
	for _tuish_fnfix_line in $_tuish_fnfix_all
	do
		case "$_tuish_fnfix_line" in
			[A-Za-z_]*"()"*)
				test -n "$_tuish_fnfix_n" && _tuish_fnfix_emit
				# The parens MUST be quoted. Unquoted, `${n%%(*}` reads to ksh as a
				# pattern group opening with `(`, which swallows the `}` and takes the
				# whole FILE down with a syntax error — on the one shell this code
				# exists to serve.
				_tuish_fnfix_n="${_tuish_fnfix_line%%"()"*}"
				_tuish_fnfix_b="$_tuish_fnfix_line"
				continue ;;
		esac
		test -n "$_tuish_fnfix_n" || continue
		_tuish_fnfix_b="${_tuish_fnfix_b}
${_tuish_fnfix_line}"
	done
	test -n "$_tuish_fnfix_n" && _tuish_fnfix_emit
	IFS="$_tuish_fnfix_ifs"

	unset _tuish_fnfix_all _tuish_fnfix_n _tuish_fnfix_b _tuish_fnfix_line \
	      _tuish_fnfix_ifs 2>/dev/null || :
	return 0
}

# Re-declare the collected function _tuish_fnfix_n / _tuish_fnfix_b as ksh-style.
_tuish_fnfix_emit ()
{
	# Framework functions ONLY. We do not rewrite an app's functions behind its back, and
	# the reason is the trap rule: an app's own `_main` is on the stack the whole time the
	# process sits in tuish_run waiting for a key, so converting it would make that entire
	# wait a signal deadzone. It is also plainly rude.
	#
	# It costs nothing to leave them alone. The bug being fixed is a FRAMEWORK local
	# overwriting an APP global — fix the framework's side and the collision is gone,
	# whichever way the names fall.
	case "$_tuish_fnfix_n" in
		tuish_*|_tuish_*|_th_*) ;;
		*) return 0 ;;
	esac
	case "$_tuish_fnfix_skip" in
		*" $_tuish_fnfix_n "*) return 0 ;;
	esac

	# _tuish_fnfix_b holds the WHOLE definition as ksh printed it, header included. Strip
	# through the first `{` to get the body (plus its own closing `}`), and re-attach a
	# `function` header. Works for both of ksh's layouts, because both put the body after
	# the first brace.
	#
	# The trailing `;{ :; }` is not decoration: this file still has to PARSE on every shell,
	# and the parser counts braces inside the double-quoted eval string. Without a balancing
	# pair the `{` opened here is never closed as far as the parser is concerned, and
	# compat.sh dies with "`}' unexpected" — taking the alias above down with it, on every
	# shell. (Coral's footer.sh does the same for the same reason.)
	eval "function $_tuish_fnfix_n { ${_tuish_fnfix_b#*\{};{ :; }" 2>/dev/null || :
	return 0
}

# Public: call once, after every module (and your own functions) are defined. A no-op on
# every shell whose `local` already works, and safe to call more than once.
_tuish_fnfix_done=0
tuish_fnfix ()
{
	test "$_tuish_fnfix_done" -eq 1 && return 0
	_tuish_fnfix_done=1
	_tuish_fnfix_leaks || return 0
	_tuish_fnfix
	return 0
}

