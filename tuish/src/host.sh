#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Load guard: skip re-definition if already sourced (see tui.sh). Without it a second
# source would reset the child table out from under the children it is holding.
if test -n "${_tuish_host_loaded:-}"; then return 0; fi
_tuish_host_loaded=1

# src/host.sh - Hosting several live children in one event loop.
# Source after tui.sh and event.sh (and keybind.sh, if the host binds keys).
#
# tui.sh gives you the primitives: mount a child in a region, move it, clip it, drive it,
# tick it. This module is what you end up writing ON TOP of them the second time — a table
# of children, and the handful of rules that make them behave. It exists because two hosts
# wrote it independently (the website and examples/cooperative.sh) and only one of them got
# it right.
#
#   tuish_host_pane [R C W H]       the window children are seen through (none: no clipping)
#   tuish_host_begin                start (re)declaring the child list
#   tuish_host_slot ID FN [ARG] R C W H [modal]
#   tuish_host_commit               reconcile: mount / reseat / unmount, adopt the tick
#
#   tuish_host_paint                render live children into the host's OPEN frame
#   tuish_host_paint_focus          ... or just the focused one (the caret; see below)
#   tuish_host_render ID            ... or just that one
#   tuish_host_route                the standard router; returns 1 if nothing took it
#   tuish_host_focus [ID]           give the keyboard to a child (no arg: take it back)
#   tuish_host_at X Y               which child is under (x,y)? -> TUISH_HOST_HIT
#   tuish_host_owns_row ROW         does a live child own that screen row?
#   tuish_host_row_free ROW C W     which of it is still YOURS -> TUISH_HOST_SEGS
#   tuish_host_ctx ID               that child's context id -> TUISH_HOST_CTX
#   tuish_host_drop ID              unmount one child
#   tuish_host_clear                unmount all of them (host teardown)
#
# Out-variables, read after the call that fills them:
#   TUISH_HOST_FOCUS  the child holding the keyboard ('' = the host itself)
#   TUISH_HOST_HIT    tuish_host_at         TUISH_HOST_CTX   tuish_host_ctx
#   TUISH_HOST_SEGS   tuish_host_row_free   TUISH_HOST_DROVE the id route drove
#   TUISH_HOST_QUIT   the id of a child that ended ITSELF
#
# The host still owns LAYOUT: it says where each child goes, every time. This module never
# learns what a "scroll offset" or a "line of text" is — you hand it rectangles.

# ─── State ───────────────────────────────────────────────────────
# One table, eval-indexed (the idiom the rest of the toolkit uses). A slot is:
#   id    caller's stable key. NOT the rectangle — see tuish_host_slot.
#   fn    setup function, arg  its argument (or '')
#   r c w h   where it goes, in the host's logical coords. May be OUTSIDE the pane.
#   modal 1 if it owns its region outright (see tuish_host_route)
#   ctx   its context, once mounted ('' = not mounted)
_th_n=0                 # live slots
_th_interval=''         # the host's own tick, to restore when the last child goes

# The pane, in FIELDS. It is read on every hit test and every row query — parsing it out of
# a string each time is work, and the two places that did the parsing drifted apart.
_th_haspane=0
_th_pr=0 _th_pc=0 _th_pw=0 _th_ph=0

_th_decl_n=0            # slots declared since tuish_host_begin

TUISH_HOST_HIT=''       # out: tuish_host_at
TUISH_HOST_CTX=''       # out: tuish_host_ctx
TUISH_HOST_SEGS=''      # out: tuish_host_row_free
TUISH_HOST_DROVE=''     # out: the id tuish_host_route handed the event to
TUISH_HOST_QUIT=''      # out: the id of a child that ended ITSELF

# Who has the keyboard ('' = the host). A VARIABLE, because that is what it is — the same
# kind of thing as TUISH_EVENT or TUISH_MOUSE_X, and read as often. It used to be a getter
# that PRINTED its answer, which is the one thing a shell function cannot do without a
# subshell: every host that wanted to know who was focused forked to ask, once per frame in
# examples/cooperative.sh and once per idle tick in the website. In a toolkit whose whole
# argument is that it does not fork, that was the fork.
TUISH_HOST_FOCUS=''

# ─── The pane ────────────────────────────────────────────────────
# The window children are seen through. Children may be seated partly (or wholly) outside
# it — that is a child scrolled under an edge, and it is CLIPPED, not resized. Without a
# pane, children are simply not clipped.
#
# No arguments means NO PANE, the way tuish_ctx_clip means it. (It used to store the empty
# rectangle as a string of spaces, which is not empty — so every later query happily parsed
# blanks out of it and compared them as numbers.)
tuish_host_pane ()   # [$1=R $2=C $3=W $4=H]
{
	if test $# -ge 4
	then
		_th_haspane=1
		_th_pr=$1; _th_pc=$2; _th_pw=$3; _th_ph=$4
		tuish_ctx_clip "$1" "$2" "$3" "$4"
	else
		_th_haspane=0
		tuish_ctx_clip
	fi
	return 0
}

# ─── Declaring children ──────────────────────────────────────────
# Declarative, and meant to be re-run whenever the layout changes:
#
#   tuish_host_begin
#   tuish_host_slot clock _clk_setup '' 4 2 30 10
#   tuish_host_slot edit  _ed_setup  '' 4 34 30 10
#   tuish_host_commit
#
# ID is yours and must be STABLE — it is the identity tuish_host_commit reconciles on. It
# is deliberately not the rectangle: a scrolling host re-declares every child at a new row
# on every wheel tick, and if the row were part of the identity, every child would be torn
# down and remounted (and repainted) sixty times a second.
tuish_host_begin () { _th_decl_n=0; return 0; }

# The MODAL flag is normalized here, to 0 or 1, and both spellings are taken: `modal`
# because that is what a host writes and reads, `1` because that is what this file's own
# comments told people to write — while the router compared it against the word, so the
# documented spelling produced a child that was not modal at all.
tuish_host_slot ()   # $1=ID $2=FN $3=ARG $4=R $5=C $6=W $7=H [$8=modal]
{
	local _m=0
	case "${8:-}" in modal|1) _m=1;; esac
	_th_decl_n=$(( _th_decl_n + 1 ))
	eval "_th_d_id_$_th_decl_n=\$1  _th_d_fn_$_th_decl_n=\$2  _th_d_arg_$_th_decl_n=\$3
	      _th_d_r_$_th_decl_n=\$4   _th_d_c_$_th_decl_n=\$5
	      _th_d_w_$_th_decl_n=\$6   _th_d_h_$_th_decl_n=\$7
	      _th_d_modal_$_th_decl_n=\$_m"
	return 0
}

# Reconcile the declared list against the live one.
#
#   same id, still visible  -> KEEP the context, just reseat it
#   new id, visible         -> mount it (clipped from its first paint)
#   gone, or wholly off-pane-> unmount it
#
# Keeping the context is the whole point. A host rebuilds its child list for all sorts of
# reasons that have nothing to do with most of the children — the website rebuilds the
# entire page to toggle ONE code block — and remounting them all would repaint them all,
# one write each, before the real repaint even started. That is a visible flash.
tuish_host_commit ()
{
	local _i=1 _j _id _fn _arg _r _c _w _h _modal _ctx _keep
	local _old_n=$_th_n

	# Snapshot the live table; we rebuild over it.
	_j=1
	while test $_j -le $_old_n
	do
		eval "_th_o_id_$_j=\$_th_id_$_j _th_o_ctx_$_j=\$_th_ctx_$_j"
		_j=$(( _j + 1 ))
	done

	_th_n=0
	while test $_i -le $_th_decl_n
	do
		eval "_id=\$_th_d_id_$_i    _fn=\$_th_d_fn_$_i _arg=\$_th_d_arg_$_i
		      _r=\$_th_d_r_$_i      _c=\$_th_d_c_$_i
		      _w=\$_th_d_w_$_i      _h=\$_th_d_h_$_i
		      _modal=\$_th_d_modal_$_i"

		# Claim the context this id had, if any.
		_ctx=''
		_j=1
		while test $_j -le $_old_n
		do
			eval "_keep=\$_th_o_id_$_j"
			if test "$_keep" = "$_id"
			then eval "_ctx=\$_th_o_ctx_$_j _th_o_ctx_$_j=''"; break; fi
			_j=$(( _j + 1 ))
		done

		_th_n=$(( _th_n + 1 ))
		eval "_th_id_$_th_n=\$_id       _th_fn_$_th_n=\$_fn   _th_arg_$_th_n=\$_arg
		      _th_r_$_th_n=\$_r         _th_c_$_th_n=\$_c
		      _th_w_$_th_n=\$_w         _th_h_$_th_n=\$_h
		      _th_modal_$_th_n=\$_modal _th_ctx_$_th_n=\$_ctx"

		if _th_offpane "$_r" "$_c" "$_w" "$_h"
		then
			# Entirely out of sight: drop it. Pure resource management — it comes back
			# when it scrolls into view.
			test -n "$_ctx" && _th_unmount $_th_n
		elif test -z "$_ctx"
		then
			if test -n "$_arg"
			then tuish_ctx_mount "$_r" "$_c" "$_w" "$_h" "$_fn" "$_arg"
			else tuish_ctx_mount "$_r" "$_c" "$_w" "$_h" "$_fn"
			fi
			eval "_th_ctx_$_th_n=\$TUISH_CTX"
		else
			tuish_ctx_reseat "$_ctx" "$_r" "$_c" "$_w" "$_h"
		fi
		_i=$(( _i + 1 ))
	done

	# Whatever nothing claimed is gone from the host: unmount it.
	_j=1
	while test $_j -le $_old_n
	do
		eval "_ctx=\$_th_o_ctx_$_j _id=\$_th_o_id_$_j"
		if test -n "$_ctx"
		then
			tuish_ctx_unmount "$_ctx"
			test "$TUISH_HOST_FOCUS" = "$_id" && TUISH_HOST_FOCUS=''
		fi
		_j=$(( _j + 1 ))
	done

	_th_adopt_interval
	return 0
}

# Wholly outside the pane? (No pane = never.)
_th_offpane ()   # $1=R $2=C $3=W $4=H
{
	test "$_th_haspane" -eq 1 || return 1
	test $(( $1 + $4 - 1 )) -lt "$_th_pr" && return 0
	test "$1" -gt $(( _th_pr + _th_ph - 1 ))  && return 0
	test $(( $2 + $3 - 1 )) -lt "$_th_pc" && return 0
	test "$2" -gt $(( _th_pc + _th_pw - 1 ))  && return 0
	return 1
}

_th_unmount ()   # $1 = slot index
{
	local _c _id
	eval "_c=\$_th_ctx_$1 _id=\$_th_id_$1"
	test -n "$_c" || return 0
	tuish_ctx_unmount "$_c"
	eval "_th_ctx_$1=''"
	test "$TUISH_HOST_FOCUS" = "$_id" && TUISH_HOST_FOCUS=''
	return 0
}

# Poll at the FASTEST live child's rate, so a 50Hz game is not throttled by a 1Hz clock
# beside it; tuish_ctx_tick then divides that back down per child, so the clock is not sped
# up either. With no children left, go back to the host's own tick.
_th_adopt_interval ()
{
	local _i=1 _c _ids=''
	while test $_i -le $_th_n
	do
		eval "_c=\$_th_ctx_$_i"
		test -n "$_c" && _ids="$_ids $_c"
		_i=$(( _i + 1 ))
	done
	test -n "$_th_interval" || _th_interval=$_tuish_interval_s
	tuish_idle_interval "$_th_interval"
	test -n "$_ids" && tuish_ctx_sync_interval $_ids
	return 0
}

# ─── Lookups ─────────────────────────────────────────────────────
# Everything in here is one of two questions — WHICH SLOT is this id, and WHERE can that
# slot be seen — so there is one answer to each, and every public query is a loop around it.
# There used to be three copies of the second one, differing only in what they did with the
# rectangle at the end; the mouse router asked the first one three times per click.

# The slot index of id $1 -> _th_i (0 = unknown). A PREDICATE: call it in a condition.
_th_i=0
_th_find ()   # $1 = id
{
	local _i=1 _id
	_th_i=0
	while test $_i -le $_th_n
	do
		eval "_id=\$_th_id_$_i"
		if test "$_id" = "$1"; then _th_i=$_i; return 0; fi
		_i=$(( _i + 1 ))
	done
	return 1
}

# The VISIBLE rectangle of slot $1 — what it declared, clamped to the pane — in
# _th_t/_th_b/_th_l/_th_r, absolute cells. A PREDICATE: 1 if the slot is not mounted, or if
# nothing of it survives the clip. So "is any of this child on screen" and "where" are the
# same question, asked once.
_th_t=0 _th_b=0 _th_l=0 _th_r=0
_th_rect ()   # $1 = slot index
{
	local _c _r _cc _w _h
	eval "_c=\$_th_ctx_$1 _r=\$_th_r_$1 _cc=\$_th_c_$1 _w=\$_th_w_$1 _h=\$_th_h_$1"
	test -n "$_c" || return 1
	_th_t=$_r;  _th_b=$(( _r + _h - 1 ))
	_th_l=$_cc; _th_r=$(( _cc + _w - 1 ))
	if test "$_th_haspane" -eq 1
	then
		test "$_th_t" -lt "$_th_pr" && _th_t=$_th_pr
		test "$_th_b" -gt $(( _th_pr + _th_ph - 1 )) && _th_b=$(( _th_pr + _th_ph - 1 ))
		test "$_th_l" -lt "$_th_pc" && _th_l=$_th_pc
		test "$_th_r" -gt $(( _th_pc + _th_pw - 1 )) && _th_r=$(( _th_pc + _th_pw - 1 ))
	fi
	test "$_th_t" -le "$_th_b" || return 1
	test "$_th_l" -le "$_th_r" || return 1
	return 0
}

tuish_host_ctx ()   # $1 = id -> TUISH_HOST_CTX ('' = not mounted / unknown)
{
	TUISH_HOST_CTX=''
	_th_find "$1" || return 0
	eval "TUISH_HOST_CTX=\$_th_ctx_$_th_i"
	return 0
}

# Which child is under host-absolute (x,y)? -> TUISH_HOST_HIT
#
# CLIP-AWARE: the part of a child that has scrolled out of the pane is not clickable, even
# though its rectangle nominally still covers those rows. You cannot click what you cannot
# see, and a host that gets this wrong routes clicks to a widget hidden behind its own
# chrome.
# The hit's slot index is left in _th_i, so a router that wants the child's context and its
# modal flag next does not scan the table again for each.
tuish_host_at ()   # $1=x $2=y
{
	local _i=1
	TUISH_HOST_HIT=''
	while test $_i -le $_th_n
	do
		if _th_rect $_i \
		   && test "$1" -ge "$_th_l" && test "$1" -le "$_th_r" \
		   && test "$2" -ge "$_th_t" && test "$2" -le "$_th_b"
		then eval "TUISH_HOST_HIT=\$_th_id_$_i"; _th_i=$_i; return 0; fi
		_i=$(( _i + 1 ))
	done
	return 0
}

# ─── Painting around the children ────────────────────────────────
# A host that draws its own content AROUND live children has to know which cells are not
# its to touch: filling them would wipe a running app on every repaint. Two questions, and
# they are not the same one.
#
# tuish_host_owns_row answers by ROW: enough to decide whether to draw a line of text, which
# a host either draws or does not.
#
# tuish_host_row_free answers by CELL, and it is what you need before you FILL. A child
# narrower than the pane leaves columns beside it that are the host's; two children leave a
# gap between them that is also the host's — and a host that skips the whole row paints
# neither, so whatever was there last frame just stays, and the children end up standing in
# a puddle of stale text as the content scrolls underneath them. Asking for the children's
# outer bounds cannot express that gap. Asking what is FREE can: the complement of a set of
# rectangles is a set of rectangles.

# Does a live child own screen row $1? PREDICATE.
tuish_host_owns_row ()   # $1 = absolute screen row
{
	local _i=1
	while test $_i -le $_th_n
	do
		if _th_rect $_i && test "$1" -ge "$_th_t" && test "$1" -le "$_th_b"
		then return 0; fi
		_i=$(( _i + 1 ))
	done
	return 1
}

# Which parts of screen row $1, within the span [C .. C+W-1], are still the HOST'S to paint?
# -> TUISH_HOST_SEGS, as "C W C W ..." — the caller's span minus every live child on the row.
# PREDICATE: 0 if anything is left, 1 if the children cover the span outright (SEGS empty).
#
# C W pairs, not L R, because that is the shape of every rectangle in this toolkit: the
# caller spends them straight on tuish_draw_fill without doing arithmetic on the way.
tuish_host_row_free ()   # $1=ROW $2=C $3=W
{
	local _row=$1 _c0=$2 _c1=$(( $2 + $3 - 1 ))
	local _i=1 _n=0 _cur=$2 _hit _next _l _r
	TUISH_HOST_SEGS=''
	test "$_c1" -ge "$_c0" || return 1

	# The children ON this row, clipped to the pane and to the caller's span. Collected
	# once: the sweep below walks them repeatedly.
	while test $_i -le $_th_n
	do
		if _th_rect $_i && test "$_row" -ge "$_th_t" && test "$_row" -le "$_th_b"
		then
			_l=$_th_l; _r=$_th_r
			test "$_l" -lt "$_c0" && _l=$_c0
			test "$_r" -gt "$_c1" && _r=$_c1
			if test "$_l" -le "$_r"
			then _n=$(( _n + 1 )); eval "_th_iv_l_$_n=\$_l _th_iv_r_$_n=\$_r"; fi
		fi
		_i=$(( _i + 1 ))
	done
	if test $_n -eq 0
	then TUISH_HOST_SEGS="$_c0 $3"; return 0; fi

	# Sweep left to right: step over whatever covers the cursor, emit whatever is free up to
	# the next child's left edge. Gaps, overlaps, and children wider than the span all fall
	# out of it without a special case.
	while test "$_cur" -le "$_c1"
	do
		_hit=0; _i=1
		while test $_i -le $_n
		do
			eval "_l=\$_th_iv_l_$_i _r=\$_th_iv_r_$_i"
			if test "$_cur" -ge "$_l" && test "$_cur" -le "$_r"
			then _cur=$(( _r + 1 )); _hit=1; break; fi
			_i=$(( _i + 1 ))
		done
		test "$_hit" -eq 1 && continue

		_next=$(( _c1 + 1 )); _i=1
		while test $_i -le $_n
		do
			eval "_l=\$_th_iv_l_$_i"
			test "$_l" -gt "$_cur" && test "$_l" -lt "$_next" && _next=$_l
			_i=$(( _i + 1 ))
		done
		TUISH_HOST_SEGS="${TUISH_HOST_SEGS}${TUISH_HOST_SEGS:+ }$_cur $(( _next - _cur ))"
		_cur=$_next
	done
	test -n "$TUISH_HOST_SEGS"
}

# ─── Focus ───────────────────────────────────────────────────────
# Give the keyboard to a child; no argument takes it back for the host. To ASK who has it,
# read TUISH_HOST_FOCUS — it is a variable, not a call.
tuish_host_focus ()   # [$1 = id]
{
	TUISH_HOST_FOCUS="${1:-}"
	return 0
}

# ─── Painting ────────────────────────────────────────────────────
# Render every live child. Call this INSIDE your own tuish_begin/tuish_end and AFTER your
# chrome — tuish_ctx_render splices into the open frame, so the whole repaint (background,
# chrome, and every child) goes out as ONE write. Paint the children first and your
# background fill lands on top of them; paint them in a frame of their own and the terminal
# draws each one separately, and you see the chrome move a frame before the children do.
#
# The FOCUSED child is painted LAST, and that is about the caret. A child that wants one
# shows it where it wants it (editor.sh does, via tuish_cursor) — but the next child to
# paint drags the terminal's cursor off to wherever ITS last cell was, leaving a caret
# blinking in the middle of somebody else's box. Painting the focused child last means the
# caret ends the frame where the thing you are typing into put it.
#
# The caret is hidden first, because a host without a focused child should not have one at
# all: a document does not blink at you.
tuish_host_paint ()
{
	local _i=1 _c _id _fc=''
	tuish_hide_cursor
	while test $_i -le $_th_n
	do
		eval "_c=\$_th_ctx_$_i _id=\$_th_id_$_i"
		if test -n "$_c"
		then
			if test "$_id" = "$TUISH_HOST_FOCUS"
			then _fc=$_c
			else tuish_ctx_render "$_c"
			fi
		fi
		_i=$(( _i + 1 ))
	done
	test -n "$_fc" && tuish_ctx_render "$_fc"
	return 0
}

# Repaint ONLY the focused child. For the cheap partial repaints a host does that do not
# touch the children at all — a hover highlight in a sidebar, say. The framework hides the
# caret before every deferred render, so a frame that repaints nothing containing a caret
# would blink it out from under someone who is typing. This puts it back, for the price of
# one small widget.
tuish_host_paint_focus ()
{
	test -n "$TUISH_HOST_FOCUS" || return 0
	tuish_host_render "$TUISH_HOST_FOCUS" || :
	return 0
}

# Repaint ONE child, now, into the host's open frame. PREDICATE: 1 if nobody has that id.
#
# A host that has just changed what a single child SHOWS — the website recompiles the code
# you typed and the picture beneath it has to catch up — wants that child repainted and
# nothing else. Without this it has to fetch the child's context and call tuish_ctx_render
# on it, which means knowing that a child IS a context. Out here it is not: it is an id.
tuish_host_render ()   # $1 = id
{
	tuish_host_ctx "$1"
	test -n "$TUISH_HOST_CTX" || return 1
	tuish_ctx_render "$TUISH_HOST_CTX"
	return 0
}

# ─── Routing ─────────────────────────────────────────────────────
# The standard policy. Returns 0 if a child took the event, 1 if it is the host's.
#
#   mouse   the child under the pointer; a click also FOCUSES it. If the child does not
#           act on the event, it CHAINS back to the host (see below).
#   key     the focused child.
#   paste   the focused child.
#   idle    every live child, each at ITS OWN rate (tuish_ctx_tick, not dispatch).
#   signal  nothing — a resize means your layout changed, so YOU re-declare the children
#           (tuish_host_begin/slot/commit) and repaint. This module cannot guess the new
#           rectangles.
#
# SCROLL CHAINING. An event offered to a child that does nothing with it comes back. Route
# it purely by position and the wheel over a widget that scrolls nothing kills the host's
# scrolling entirely — and it can never recover, because nothing then moves the widget out
# from under the pointer. TUISH_CTX_HANDLED (tui.sh) and tuish_pass (event.sh) are what
# make "the child declined it" a thing a host can see.
#
# A MODAL child is the exception: it owns its region, there is nothing behind it to scroll,
# and it consumes what it is given.
#
# QUITTING. A child ends by ITS OWN means and we detect it (TUISH_CTX_QUIT) rather than
# intercepting its quit key — a host cannot know which key an app exits on, and the
# terminal or browser may reserve it anyway. The id lands in TUISH_HOST_QUIT; what a child
# quitting MEANS is the host's business, so route does not unmount it for you.
tuish_host_route ()
{
	local _c _id _modal _i=1
	TUISH_HOST_DROVE=''
	TUISH_HOST_QUIT=''

	case "$TUISH_EVENT_KIND" in
		mouse)
			test "$_th_n" -gt 0 || return 1
			# tuish_host_at leaves the slot it hit in _th_i, so its context and its modal
			# flag are one eval away rather than two more scans of the table.
			tuish_host_at "$TUISH_MOUSE_X" "$TUISH_MOUSE_Y"
			test -n "$TUISH_HOST_HIT" || return 1
			_id=$TUISH_HOST_HIT
			eval "_c=\$_th_ctx_$_th_i _modal=\$_th_modal_$_th_i"
			test -n "$_c" || return 1

			case "$TUISH_EVENT" in
				*clik) TUISH_HOST_FOCUS="$_id";;
			esac
			tuish_ctx_dispatch "$_c"
			TUISH_HOST_DROVE=$_id
			test "$TUISH_CTX_QUIT" = 1 && TUISH_HOST_QUIT=$_id
			test "$_modal" -eq 1 && return 0
			test "$TUISH_CTX_HANDLED" -eq 1 && return 0
			return 1                       # declined: it chains back to the host
			;;
		key|paste)
			test -n "$TUISH_HOST_FOCUS" || return 1
			_th_find "$TUISH_HOST_FOCUS" || return 1
			eval "_c=\$_th_ctx_$_th_i _modal=\$_th_modal_$_th_i"
			test -n "$_c" || return 1
			tuish_ctx_dispatch "$_c"
			TUISH_HOST_DROVE=$TUISH_HOST_FOCUS
			test "$TUISH_CTX_QUIT" = 1 && TUISH_HOST_QUIT=$TUISH_HOST_FOCUS
			test "$_modal" -eq 1 && return 0
			test "$TUISH_CTX_HANDLED" -eq 1 && return 0
			return 1
			;;
		idle)
			test "$_th_n" -gt 0 || return 1
			while test $_i -le $_th_n
			do
				eval "_c=\$_th_ctx_$_i"
				if test -n "$_c"
				then
					tuish_ctx_tick "$_c"
					test "$TUISH_CTX_QUIT" = 1 && eval "TUISH_HOST_QUIT=\$_th_id_$_i"
				fi
				_i=$(( _i + 1 ))
			done
			return 1                       # an idle tick is everybody's
			;;
	esac
	return 1
}

# Unmount a child by id (the host's answer to TUISH_HOST_QUIT, usually).
tuish_host_drop ()   # $1 = id
{
	_th_find "$1" || return 0
	_th_unmount $_th_i
	_th_adopt_interval
	return 0
}

# Unmount everything (host teardown).
tuish_host_clear ()
{
	local _i=1
	while test $_i -le $_th_n
	do _th_unmount $_i; _i=$(( _i + 1 )); done
	_th_n=0
	TUISH_HOST_FOCUS=''
	test -n "$_th_interval" && tuish_idle_interval "$_th_interval"
	return 0
}
