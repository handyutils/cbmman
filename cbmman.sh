#!/usr/bin/env bash
#
# cbmman.sh — interactive TUI manager for codebase-memory-mcp
# ------------------------------------------------------------------
# Human-friendly terminal UI wrapping the full CLI of:
#   https://github.com/DeusData/codebase-memory-mcp
#
# Uses the tuish TUI toolkit (https://github.com/alganet/tuish).
# tuish is auto-bootstrapped into ./tuish on first run when missing.
#
# Usage:
#   cbmman.sh                 interactive TUI
#   cbmman.sh cli <tool> [args]   pass-through to `codebase-memory-mcp cli`
#   cbmman.sh --help | -h     this help
#   cbmman.sh --version       binary version
#
# Env:
#   CBM_BIN      path to the codebase-memory-mcp binary
#   TUISH_DIR    directory holding the tuish library (default ./tuish)
#   CBM_CACHE_DIR  cache dir override (default ~/.cache/codebase-memory-mcp)
# ------------------------------------------------------------------

set -o pipefail

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Config (env-overridable) ─────────────────────────────────────
if test -z "${CBM_BIN:-}"; then
	CBM_BIN="$(command -v codebase-memory-mcp 2>/dev/null || true)"
	if test -z "$CBM_BIN"; then CBM_BIN=/Users/musichen/.local/bin/codebase-memory-mcp; fi
fi
TUISH_DIR="${TUISH_DIR:-$_dir/tuish}"
CBM_CACHE="${CBM_CACHE_DIR:-$HOME/.cache/codebase-memory-mcp}"

# ─── Non-interactive passthrough modes (no tuish needed) ──────────
case "${1:-}" in
	cli)
		shift
		exec "$CBM_BIN" cli "$@"
		;;
	--help|-h|help)
		sed -n '2,22p' "${BASH_SOURCE[0]}" 2>/dev/null || grep -m20 '#' "${BASH_SOURCE[0]}"
		exit 0
		;;
	--version|-v)
		v=$(grep -m1 '^version =' "$(dirname "${BASH_SOURCE[0]}")/Cargo.toml" 2>/dev/null | sed 's/.*"\(.*\)".*/\1/' || echo "dev")
		echo "cbmman $v"
		exit 0
		;;
	update)
		exec cargo install cbmman --force
		;;
esac

if ! test -t 0; then
	echo "cbmman: interactive TUI needs a terminal." >&2
	echo "        use 'cbmman.sh cli <tool> [args]' for non-interactive." >&2
	exit 1
fi
test -x "$CBM_BIN" || { echo "cbmman: codebase-memory-mcp not found at $CBM_BIN" >&2; exit 1; }

# ─── Bootstrap tuish if missing ────────────────────────────────────
if test ! -f "$TUISH_DIR/src/compat.sh"; then
	echo "cbmman: bootstrapping tuish toolkit into $TUISH_DIR ..." >&2
	git clone --depth 1 https://github.com/alganet/tuish.git "$TUISH_DIR" >&2 || { echo "cbmman: failed to fetch tuish" >&2; exit 1; }
fi

# ─── Source tuish ──────────────────────────────────────────────────
. "$TUISH_DIR/src/compat.sh"        # set -euf
. "$TUISH_DIR/src/ord.sh"
. "$TUISH_DIR/src/tui.sh"
. "$TUISH_DIR/src/term.sh"
. "$TUISH_DIR/src/event.sh"
. "$TUISH_DIR/src/hid.sh"
. "$TUISH_DIR/src/viewport.sh"
. "$TUISH_DIR/src/str.sh"
set -o pipefail

# ─── State ─────────────────────────────────────────────────────────
_screen='main'
_nav=()
_msg=''
_tick_c=0

# generic menu
_menu_title=''
_menu_sub=''
_menu_hint=''
_menu_action=''
_menu_n=0
_menu_cursor=0
_menu_items=()

# generic form
_form_title=''
_form_action=''
_form_meta=''
_form_n=0
_form_cursor=0
_form_label=()
_form_value=()
_form_kind=()
_form_opts=()

# output viewer
_out_title=''
_out_n=0
_out_scroll=0
_out_lines=()

# projects cache
_projects_loaded=0
_projects_n=0
_projects_name=()
_projects_root=()
_projects_branch=()
_projects_nodes=()
_projects_edges=()
_projects_size=()
_sel_project=''
_sel_project_root=''

# busy async runner
_busy_running=0
_busy_pid=0
_busy_out=''
_busy_title=''
_busy_frame=0
_busy_abort=0
_busy_done_cb=''

# confirm
_confirm_msg=''
_confirm_cb=''

# single input
_input_label=''
_input_value=''
_input_cb=''

# config cache
_config_loaded=0
_config_n=0
_config_key=()
_config_val=()

# process monitor
_proc_lines=()
_proc_n=0
_proc_scroll=0
_proc_last=0

_cbm_version="$("$CBM_BIN" --version 2>/dev/null | head -1)"

# ─── Helpers ───────────────────────────────────────────────────────

_hsize () { # bytes -> human
	local b=$1
	if test "$b" -ge 1073741824; then echo "$((b / 1073741824)).$((b % 1073741824 / 107374182))G"
	elif test "$b" -ge 1048576; then echo "$((b / 1048576)).$((b % 1048576 / 104857))M"
	elif test "$b" -ge 1024; then echo "$((b / 1024))K"
	else echo "${b}B"; fi
}

# Format a `cli --json` MCP response on stdin into readable text.
_fmt_py () {
	python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("! failed to parse output: %s" % (e,))
    sys.exit(0)
if d.get("isError"):
    for c in d.get("content", []):
        print("! " + c.get("text", ""))
    sys.exit(0)
for c in d.get("content", []):
    t = c.get("text", "")
    if not t: continue
    try:
        j = json.loads(t)
        print(json.dumps(j, indent=2, ensure_ascii=False))
    except Exception:
        print(t)
'
}

# Build a JSON args object: key kind value [key kind value ...]
# kinds: str | int | bool | list(csv) | json | traces(caller,callee,count;...)
_args_build () {
	python3 -c '
import json, sys
a = sys.argv[1:]
d = {}
for i in range(0, len(a), 3):
    k, kind, v = a[i], a[i + 1], a[i + 2]
    if v == "": continue
    if kind == "int":
        try: d[k] = int(v)
        except Exception: d[k] = v
    elif kind == "bool":
        d[k] = (v == "true")
    elif kind == "list":
        d[k] = [x for x in v.split(",") if x]
    elif kind == "json":
        d[k] = json.loads(v)
    elif kind == "traces":
        out = []
        for part in v.split(";"):
            c = part.split(",")
            if len(c) == 3:
                try: cnt = int(c[2])
                except Exception: cnt = 0
                out.append({"caller": c[0], "callee": c[1], "count": cnt})
        d[k] = out
    else:
        d[k] = v
print(json.dumps(d))
' "$@"
}

# Run a tool and print formatted output. Used in background jobs.
_cbm_quiet () { # tool jsonargs
	local tool="$1" args="${2:-}"
	if test -n "$args"; then
		"$CBM_BIN" cli --json "$tool" "$args" 2>/dev/null | _fmt_py
	else
		"$CBM_BIN" cli --json "$tool" 2>/dev/null | _fmt_py
	fi
	return 0
}
_cbm_bin () { "$CBM_BIN" "$@"; }

# Run a command with a hard timeout; result in $_rt_out. Never blocks forever —
# the CLI one-shot processes contend with the CBM daemon/watchers for locks.
_run_timeout () { # $1=seconds ; rest=cmd... ; -> $_rt_out
	local secs="$1"; shift
	local f
	f="$(mktemp /tmp/cbmman.XXXXXX 2>/dev/null || echo /tmp/cbmman.$$)"
	( set +e; "$@" >"$f" 2>&1 ) &
	local pid=$!
	local waited=0
	while kill -0 "$pid" 2>/dev/null; do
		sleep 0.1
		waited=$((waited + 1))
		if test "$waited" -ge $((secs * 10)); then
			kill "$pid" 2>/dev/null || :
			wait "$pid" 2>/dev/null || :
			break
		fi
	done
	wait "$pid" 2>/dev/null || :
	_rt_out="$(cat "$f" 2>/dev/null)"
	rm -f "$f" 2>/dev/null || :
	return 0
}

# ─── Background job loader (non-blocking CLI) ─────────────────────
_bg_pid=0
_bg_out=''
_bg_done=''

_bg_start () { # done_fn cmd args...
	_bg_done="$1"; shift
	_bg_out="$(mktemp /tmp/cbmman.XXXXXX 2>/dev/null || echo /tmp/cbmman.$$)"
	( set +e; "$@" >"$_bg_out" 2>&1 ) &
	_bg_pid=$!
}

_bg_poll () {
	test "$_bg_pid" -eq 0 && return 0
	if ! kill -0 "$_bg_pid" 2>/dev/null; then
		local cb="$_bg_done" pid="$_bg_pid" out="$_bg_out"
		_bg_pid=0; _bg_done=''
		wait "$pid" 2>/dev/null || :
		"$cb" "$out" || :
		tuish_request_redraw
	fi
	return 0
}

# ─── Navigation stack ─────────────────────────────────────────────
# Each nav entry pairs a screen with the function that rebuilds it on
# return (menus lose their widget state when another menu overwrites the
# shared _menu_* globals, so returning into a menu must re-open it).
_nav=()
_nav_fn=()
_menu_build=''

_goto () { # screen [build_fn]
	if test "$_screen" = menu || test "$_screen" = main; then
		_nav+=("$_screen"); _nav_fn+=("${_menu_build:-}")
	else
		_nav+=("$_screen"); _nav_fn+=("")
	fi
	_screen="$1"
	if test -n "${2:-}"; then _menu_build="$2"; fi
	return 0
}

_back () {
	local n=${#_nav[@]}
	if test "$n" -gt 0; then
		local prev="${_nav[$((n - 1))]}" fn="${_nav_fn[$((n - 1))]}"
		unset '_nav[$((n - 1))]' || :
		unset '_nav_fn[$((n - 1))]' || :
		_screen="$prev"
		if test -n "$fn"; then "$fn" || :; fi
		tuish_request_redraw
	fi
	return 0
}

_restart_at () { # screen [back_to] [back_fn]
	_nav=(); _nav_fn=()
	_nav+=("${2:-menu}")
	_nav_fn+=("${3:-_build_main}")
	_screen="$1"
	return 0
}

# ─── Data loaders ──────────────────────────────────────────────────

_load_projects () {
	local _raw _line _n _r _b _nd _e _sz
	_projects_n=0
	_projects_loaded=0
	_run_timeout 8 "$CBM_BIN" cli --json list_projects
	_raw="$_rt_out"
	test -n "$_raw" || return 0
	while IFS='|' read -r _n _r _b _nd _e _sz; do
		test -n "$_n" || continue
		_projects_name[$_projects_n]="$_n"
		_projects_root[$_projects_n]="$_r"
		_projects_branch[$_projects_n]="$_b"
		_projects_nodes[$_projects_n]="$_nd"
		_projects_edges[$_projects_n]="$_e"
		_projects_size[$_projects_n]="$_sz"
		_projects_n=$((_projects_n + 1))
	done < <(printf '%s\n' "$_raw" | python3 -c '
import json, sys
s = sys.stdin.read()
i = s.find("{")
if i < 0:
    sys.exit(0)
try:
    d = json.loads(s[i:])
    t = json.loads(d["content"][0]["text"])
except Exception:
    sys.exit(0)
for p in t.get("projects", []):
    print("|".join([p.get("name",""), p.get("root_path",""), p.get("branch",""),
                    str(p.get("nodes",0)), str(p.get("edges",0)), str(p.get("size_bytes",0))]))
')
	_projects_loaded=1
	return 0
}

# Async variants used at startup so the menu paints immediately.
_load_projects_async () { _bg_start _load_projects_done "$CBM_BIN" cli --json list_projects; }
_load_projects_done () { _load_projects_from "$1"; rm -f "$1" 2>/dev/null || :; }
_load_projects_from () { # file -> parse into cache
	local _raw _line _n _r _b _nd _e _sz
	_raw="$(cat "$1" 2>/dev/null)"
	_projects_n=0
	_projects_loaded=0
	test -n "$_raw" || return 0
	while IFS='|' read -r _n _r _b _nd _e _sz; do
		test -n "$_n" || continue
		_projects_name[$_projects_n]="$_n"
		_projects_root[$_projects_n]="$_r"
		_projects_branch[$_projects_n]="$_b"
		_projects_nodes[$_projects_n]="$_nd"
		_projects_edges[$_projects_n]="$_e"
		_projects_size[$_projects_n]="$_sz"
		_projects_n=$((_projects_n + 1))
	done < <(printf '%s\n' "$_raw" | python3 -c '
import json, sys
s = sys.stdin.read()
i = s.find("{")
if i < 0:
    sys.exit(0)
try:
    d = json.loads(s[i:])
    t = json.loads(d["content"][0]["text"])
except Exception:
    sys.exit(0)
for p in t.get("projects", []):
    print("|".join([p.get("name",""), p.get("root_path",""), p.get("branch",""),
                    str(p.get("nodes",0)), str(p.get("edges",0)), str(p.get("size_bytes",0))]))
')
	_projects_loaded=1
	return 0
}

_load_config () {
	local _l _v
	_config_n=0
	_run_timeout 5 "$CBM_BIN" config list
	while IFS= read -r _l || test -n "$_l"; do
		[[ $_l =~ ^[[:space:]]*([^[:space:]=]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
		_config_key[$_config_n]="${BASH_REMATCH[1]}"
		_v="${BASH_REMATCH[2]}"
		_v="${_v%"${_v##*[![:space:]]}"}"
		_config_val[$_config_n]="$_v"
		_config_n=$((_config_n + 1))
	done < <(printf '%s\n' "$_rt_out")
	_config_loaded=1
	return 0
}

_load_config_async () { _bg_start _load_config_done "$CBM_BIN" config list; }
_load_config_done () { _load_config_from "$1"; rm -f "$1" 2>/dev/null || :; }
_load_config_from () { # file -> parse into cache
	local _l _v
	_config_n=0
	while IFS= read -r _l || test -n "$_l"; do
		[[ $_l =~ ^[[:space:]]*([^[:space:]=]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
		_config_key[$_config_n]="${BASH_REMATCH[1]}"
		_v="${BASH_REMATCH[2]}"
		_v="${_v%"${_v##*[![:space:]]}"}"
		_config_val[$_config_n]="$_v"
		_config_n=$((_config_n + 1))
	done < <(printf '%s\n' "$(cat "$1" 2>/dev/null)")
	_config_loaded=1
	return 0
}

_config_get () { # key -> value
	local k="$1" i
	for ((i = 0; i < _config_n; i++)); do
		test "${_config_key[$i]}" = "$k" && { echo "${_config_val[$i]}"; return 0; }
	done
	echo ""
	return 0
}

# ─── Busy async runner ─────────────────────────────────────────────

_busy_start () { # title cmd args...
	_busy_title="$1"; shift
	_busy_out="$(mktemp /tmp/cbmman.XXXXXX 2>/dev/null || echo /tmp/cbmman.$$)"
	_busy_running=1
	_busy_abort=0
	_busy_frame=0
	_busy_done_cb=''
	( set +e; "$@" >"$_busy_out" 2>&1; echo "__EXIT__:$?" >>"$_busy_out" ) &
	_busy_pid=$!
	_goto busy
	tuish_request_redraw
}

_busy_poll () {
	test "$_busy_running" -eq 1 || return 0
	if kill -0 "$_busy_pid" 2>/dev/null; then return 0; fi
	_busy_running=0
	_out_lines=()
	_out_n=0
	local _l _ec=0
	while IFS= read -r _l || test -n "$_l"; do
		case "$_l" in
			__EXIT__:*) _ec=${_l#__EXIT__:} ;;
			*) _out_lines[$_out_n]="$_l"; _out_n=$((_out_n + 1)) ;;
		esac
	done < "$_busy_out"
	rm -f "$_busy_out" 2>/dev/null || :
	_out_scroll=0
	_out_title="$_busy_title (exit $_ec)"
	if test -n "$_busy_done_cb"; then
		local _cb=$_busy_done_cb; _busy_done_cb=''
		"$_cb" || :
	fi
	if test "$_screen" = busy; then
		_screen=out
	else
		_msg="background job done: $_busy_title"
	fi
	tuish_request_redraw
	return 0
}

_tick () {
	_tick_c=$((_tick_c + 1))
	_busy_poll
	_bg_poll
	if test "$_screen" = busy; then
		_busy_frame=$((_busy_frame + 1))
		tuish_request_redraw
		return 0
	fi
	if test "$_screen" = proc; then
		if test $((_tick_c - _proc_last)) -ge 40; then
			_proc_last=$_tick_c
			_proc_refresh
			tuish_request_redraw
		fi
	fi
	return 0
}

# ─── Process / resource monitor ────────────────────────────────────

_proc_add () { _proc_lines[$_proc_n]="$1"; _proc_n=$((_proc_n + 1)); }

_proc_refresh () {
	_proc_lines=(); _proc_n=0; _proc_scroll=0
	local _rss_total=0 _nproc=0
	_proc_add "== codebase-memory-mcp processes =="
	while IFS=' ' read -r _pid _cpu _mem _rss _et _rest; do
		test -z "$_pid" && continue
		_rss_total=$((_rss_total + _rss))
		_nproc=$((_nproc + 1))
		_proc_add "$(printf '  pid %-7s cpu %5s%%  mem %4s%%  rss %-9s  time %-9s  %s' "$_pid" "$_cpu" "$_mem" "$(_hsize $((_rss * 1024)))" "$_et" "$_rest")"
	done < <(ps -axo pid=,pcpu=,pmem=,rss=,etime=,command= 2>/dev/null | grep codebase-memory-mcp | grep -v grep)
	_proc_add "  $([ "$_nproc" -eq 0 ] && echo 'no processes' || echo "processes: $_nproc")   total rss: $(_hsize $((_rss_total * 1024)))"
	_proc_add ""
	_proc_add "== artifacts in $CBM_CACHE =="
	local _cachel="$(du -sh "$CBM_CACHE" 2>/dev/null | awk '{print $1}')"
	_proc_add "  cache total: ${_cachel:-n/a}"
	local _f _sz
	while IFS= read -r -d '' _f; do
		_sz="$(du -sh "$_f" 2>/dev/null | awk '{print $1}')"
		_proc_add "  ${_sz:-?}   ${_f#$CBM_CACHE/}"
	done < <(find "$CBM_CACHE" -maxdepth 1 -name '*.db' -print0 2>/dev/null | sort -z)
	local _logsz="$(du -sh "$CBM_CACHE/logs" 2>/dev/null | awk '{print $1}')"
	_proc_add "  ${_logsz:-?}   logs/"
	return 0
}

_proc_open () {
	_goto proc
	_proc_last=0
	_proc_refresh
	tuish_request_redraw
}

# ─── Generic menu ──────────────────────────────────────────────────

_menu_open () { # title sub hint action items...  (pure state builder)
	_menu_title="$1"; _menu_sub="$2"; _menu_hint="$3"; _menu_action="$4"
	shift 4
	_menu_n=0; _menu_cursor=0; _menu_items=()
	local _it
	for _it in "$@"; do _menu_items[$_menu_n]="$_it"; _menu_n=$((_menu_n + 1)); done
}

# ─── Generic form ──────────────────────────────────────────────────

_form_begin () { _form_title="$1"; _form_action="$2"; _form_meta=''; _form_n=0; _form_cursor=0; _form_label=(); _form_value=(); _form_kind=(); _form_opts=(); }
_form_field () { _form_label[$_form_n]="$1"; _form_value[$_form_n]="$2"; _form_kind[$_form_n]="$3"; _form_opts[$_form_n]="$4"; _form_n=$((_form_n + 1)); }
_form_show () { _goto form; tuish_request_redraw; }

_form_val () { # label -> value
	local k="$1" i
	for ((i = 0; i < _form_n; i++)); do
		test "${_form_label[$i]}" = "$k" && { echo "${_form_value[$i]}"; return 0; }
	done
	echo ""
	return 0
}

# ─── Confirm / single input ────────────────────────────────────────

_confirm_open () { _confirm_msg="$1"; _confirm_cb="$2"; _goto confirm; tuish_request_redraw; }
_input_open () { _input_label="$1"; _input_value="$2"; _input_cb="$3"; _goto input; tuish_request_redraw; }

# ─── Screen openers ────────────────────────────────────────────────

_main_open () {
	_goto menu
	_build_main
}
_build_main () {
	_menu_build=_build_main
	_menu_open "cbmman — codebase-memory-mcp manager" "" \
		"↑/↓ navigate · Enter select · digit jump · q/ctrl-c quit" _main_enter \
		"1. Projects" \
		"2. Scan / Index project" \
		"3. Graph server (UI)" \
		"4. Processes & resources" \
		"5. Configuration" \
		"6. Graph queries" \
		"7. ADR management" \
		"8. Maintenance" \
		"0. Quit"
}

_pactions_open () {
	_goto menu
	_build_pactions
}
_build_pactions () {
	_menu_build=_build_pactions
	_menu_open "Project actions" "project: $_sel_project" \
		"↑/↓ navigate · Enter select · esc back" _paction_enter \
		"Index status" \
		"Architecture overview" \
		"Index coverage" \
		"Detect changes" \
		"Re-scan" \
		"Delete project" \
		"Back"
}

_server_sub () { _menu_sub="port $(_config_get ui_port) · ui_enabled $(_config_get ui_enabled)"; }

_server_open () {
	_goto menu
	_build_server
}
_build_server () {
	_menu_build=_build_server
	_load_config
	_server_sub
	_menu_open "Graph server (UI)" "$_menu_sub" \
		"↑/↓ · Enter select · esc back" _server_enter \
		"Start UI server" \
		"Stop UI server" \
		"Set port" \
		"Open in browser" \
		"Refresh status" \
		"Back"
}

_qmenu_open () {
	_goto menu
	_build_qmenu
}
_build_qmenu () {
	_menu_build=_build_qmenu
	test $_projects_loaded -eq 0 && _load_projects
	_menu_open "Graph queries" "projects indexed: $_projects_n" \
		"↑/↓ · Enter select · esc back" _qmenu_enter \
		"Search graph" \
		"Search code" \
		"Get code snippet" \
		"Trace path" \
		"Cypher query" \
		"Architecture overview" \
		"Graph schema" \
		"Ingest traces" \
		"Back"
}

_adr_open () {
	_form_begin "ADR — architecture decision records" _adr_run
	_qf_proj_field
	_form_field "action" "get" choice "get sections update"
	_form_field "content file (for update)" "" text ""
	_form_field "RUN" "run" action ""
	_form_field "CANCEL" "cancel" action ""
	_menu_hint="choose action · Enter next · ←/→ cycle · Enter on [RUN] executes · esc cancel"
	_form_show
}

_maint_open () {
	_goto menu
	_build_maint
}
_build_maint () {
	_menu_build=_build_maint
	_menu_open "Maintenance" "" \
		"↑/↓ · Enter select · esc back" _maint_enter \
		"Version" \
		"CLI help" \
		"Update (show command)" \
		"Uninstall (dry-run)" \
		"Cache & diagnostics" \
		"Back"
}

_scan_open () { # [path] [name]
	local path="${1:-$PWD}" name="${2:-}"
	_form_begin "Scan / index a repository" _scan_run
	_form_field "repo path" "$path" text ""
	_form_field "mode" "moderate" choice "moderate full fast cross-repo"
	_form_field "name override (optional)" "$name" text ""
	_form_field "persist artifact" "no" choice "no yes"
	_form_field "target projects (cross-repo, csv)" "" text ""
	_form_field "SCAN" "run" action ""
	_form_field "CANCEL" "cancel" action ""
	_menu_hint="type path · Enter next · ←/→ cycle · Enter on [SCAN] indexes · esc cancel"
	_form_show
}

# ─── Query form helpers ────────────────────────────────────────────

_qf_proj_opts () {
	local out='' i
	for ((i = 0; i < _projects_n; i++)); do out="$out ${_projects_name[$i]}"; done
	echo "${out# }"
	return 0
}

_qf_project () {
	if test -n "$_sel_project"; then echo "$_sel_project"; return 0; fi
	if test "$_projects_n" -eq 1; then echo "${_projects_name[0]}"; return 0; fi
	echo ""
	return 0
}

_qf_proj_field () {
	local opts
	opts="$(_qf_proj_opts)"
	if test -n "$opts"; then _form_field "project" "$(_qf_project)" choice "$opts"
	else _form_field "project" "" text ""; fi
}

_qf_open () { # tool title
	_form_begin "$2" _qf_run
	_form_meta="$1"
	case "$_form_meta" in
		search_graph)
			_qf_proj_field
			_form_field "query" "" text ""
			_form_field "name pattern" "" text ""
			_form_field "semantic (csv)" "" text ""
			_form_field "limit" "50" text "" ;;
		search_code)
			_qf_proj_field
			_form_field "pattern" "" text ""
			_form_field "regex" "no" choice "no yes"
			_form_field "limit" "10" text "" ;;
		get_code_snippet)
			_qf_proj_field
			_form_field "qualified name" "" text "" ;;
		trace_path)
			_qf_proj_field
			_form_field "function name" "" text ""
			_form_field "direction" "inbound" choice "inbound outbound both"
			_form_field "depth" "3" text "" ;;
		query_graph)
			_qf_proj_field
			_form_field "cypher query" "" text "" ;;
		get_architecture)
			_qf_proj_field
			_form_field "aspects (csv)" "clusters,dependencies,structure" text "" ;;
		get_graph_schema)
			_qf_proj_field ;;
		ingest_traces)
			_qf_proj_field
			_form_field "traces (caller,callee,count;...)" "" text "" ;;
	esac
	_form_field "RUN" "run" action ""
	_form_field "CANCEL" "cancel" action ""
	_menu_hint="fill fields · Enter next · ←/→ cycle · Enter on [RUN] executes · esc cancel"
	_form_show
}

# ─── Main menu actions ─────────────────────────────────────────────

_main_enter () {
	local idx=$1
	case "$idx" in
		0) test $_projects_loaded -eq 0 && _load_projects; _goto projects; _menu_cursor=0; tuish_request_redraw ;;
		1) _scan_open ;;
		2) _server_open ;;
		3) _proc_open ;;
		4) _config_open ;;
		5) _qmenu_open ;;
		6) _adr_open ;;
		7) _maint_open ;;
		8) tuish_quit_clear ;;
	esac
}

_paction_enter () {
	case "$1" in
		0) _busy_start "Index status" _cbm_quiet index_status "$(_args_build project str "$_sel_project")" ;;
		1) _busy_start "Architecture" _cbm_quiet get_architecture "$(_args_build project str "$_sel_project" aspects list "clusters,dependencies,structure,hotspots")" ;;
		2) _busy_start "Index coverage" _cbm_quiet check_index_coverage "$(_args_build project str "$_sel_project" scopes list ".")" ;;
		3) _busy_start "Detect changes" _cbm_quiet detect_changes "$(_args_build project str "$_sel_project")" ;;
		4) _scan_open "${_sel_project_root:-$PWD}" "$_sel_project" ;;
		5) _confirm_open "Delete project '$_sel_project'? Its index and graph are removed (irreversible)." _do_delete_project ;;
		6) _back ;;
	esac
}

_server_enter () {
	case "$1" in
		0) _server_toggle true ;;
		1) _server_toggle false ;;
		2) _input_open "New UI port" "$(_config_get ui_port)" _server_port_cb ;;
		3) open "http://localhost:$(_config_get ui_port)" 2>/dev/null || : ;;
		4) _load_config; _server_sub; _msg="status refreshed"; tuish_request_redraw ;;
		5) _back ;;
	esac
}

_qmenu_enter () {
	case "$1" in
		0) _qf_open search_graph "Search graph" ;;
		1) _qf_open search_code "Search code" ;;
		2) _qf_open get_code_snippet "Get code snippet" ;;
		3) _qf_open trace_path "Trace path" ;;
		4) _qf_open query_graph "Cypher query" ;;
		5) _qf_open get_architecture "Architecture overview" ;;
		6) _qf_open get_graph_schema "Graph schema" ;;
		7) _qf_open ingest_traces "Ingest traces" ;;
		8) _back ;;
	esac
}

_maint_enter () {
	case "$1" in
		0) _busy_start "Version" _cbm_bin --version ;;
		1) _busy_start "CLI help" _cbm_bin --help ;;
		2) _busy_start "Update" _cbm_bin update -y ;;
		3) _busy_start "Uninstall dry-run" _cbm_bin uninstall --dry-run ;;
		4) _busy_start "Cache & diagnostics" _cache_info ;;
		5) _back ;;
	esac
}

_cache_info () {
	echo "cache dir : $CBM_CACHE"
	echo "binary    : $CBM_BIN"
	du -sh "$CBM_CACHE" 2>/dev/null || echo "cache missing"
	echo "-- artifacts --"
	find "$CBM_CACHE" -maxdepth 1 -name '*.db' -exec du -sh {} \; 2>/dev/null
	echo "-- logs --"
	find "$CBM_CACHE/logs" -maxdepth 1 -type f -exec du -sh {} \; 2>/dev/null | sort -k1 -h 2>/dev/null | head -15
	return 0
}

# ─── Scan / qform / config / ADR run handlers ──────────────────────

_scan_run () {
	case "$1" in
		cancel) _back ;;
		run)
			local path mode name persist targets args
			path="$(_form_val "repo path")"
			test -n "$path" || { _msg="repo path is required"; return 0; }
			mode="$(_form_val "mode")"
			name="$(_form_val "name override (optional)")"
			persist="$(_form_val "persist artifact")"
			targets="$(_form_val "target projects (cross-repo, csv)")"
			if test "$mode" = cross-repo; then
				test -n "$targets" || { _msg="cross-repo mode needs target projects (csv)"; return 0; }
				args="$(_args_build repo_path str "$path" mode str "cross-repo-intelligence" name str "$name" target_projects list "$targets")"
			else
				local pers=false
				test "$persist" = yes && pers=true
				args="$(_args_build repo_path str "$path" mode str "$mode" name str "$name" persistence bool "$pers")"
			fi
			_busy_start "Indexing $path" _cbm_quiet index_repository "$args"
			_busy_done_cb=_load_projects
			;;
	esac
}

_qf_run () {
	case "$1" in
		cancel) _back ;;
		run)
			local p args
			p="$(_form_val "project")"
			test -n "$p" || { _msg="choose a project first (Projects → Scan to index)"; return 0; }
			args=''
			case "$_form_meta" in
				search_graph) args="$(_args_build project str "$p" query str "$(_form_val "query")" name_pattern str "$(_form_val "name pattern")" semantic list "$(_form_val "semantic (csv)")" limit int "$(_form_val "limit")")" ;;
				search_code)
					local re=false
					test "$(_form_val "regex")" = yes && re=true
					args="$(_args_build project str "$p" pattern str "$(_form_val "pattern")" regex bool "$re" limit int "$(_form_val "limit")")" ;;
				get_code_snippet) args="$(_args_build project str "$p" qualified_name str "$(_form_val "qualified name")")" ;;
				trace_path) args="$(_args_build project str "$p" function_name str "$(_form_val "function name")" direction str "$(_form_val "direction")" depth int "$(_form_val "depth")")" ;;
				query_graph) args="$(_args_build project str "$p" query str "$(_form_val "cypher query")")" ;;
				get_architecture) args="$(_args_build project str "$p" aspects list "$(_form_val "aspects (csv)")")" ;;
				get_graph_schema) args="$(_args_build project str "$p")" ;;
				ingest_traces) args="$(_args_build project str "$p" traces traces "$(_form_val "traces (caller,callee,count;...)")")" ;;
			esac
			_busy_start "$_form_meta" _cbm_quiet "$_form_meta" "$args"
			;;
	esac
}

_config_open () {
	_load_config
	_form_begin "Configuration" _config_run
	local i key val
	for ((i = 0; i < _config_n; i++)); do
		key="${_config_key[$i]}"; val="${_config_val[$i]}"
		if test "$val" = true || test "$val" = false; then
			_form_field "$key" "$val" choice "false true"
		else
			_form_field "$key" "$val" text ""
		fi
	done
	_form_field "SAVE ALL" "save" action ""
	_form_field "REFRESH" "refresh" action ""
	_form_field "BACK" "back" action ""
	_menu_hint="Enter next · ←/→ toggle choice · [SAVE ALL] applies all · esc cancel"
	_form_show
}

_config_run () {
	case "$1" in
		back) _back ;;
		refresh) _config_open ;;
		save)
			_out_lines=(); _out_n=0
			local i key val res
			for ((i = 0; i < _form_n; i++)); do
				test "${_form_kind[$i]}" = action && continue
				key="${_form_label[$i]}"; val="${_form_value[$i]}"
				_out_lines[$_out_n]="set $key = $val"; _out_n=$((_out_n + 1))
				_run_timeout 2 "$CBM_BIN" config set "$key" "$val"
				res="$_rt_out"
				test -n "$res" && { _out_lines[$_out_n]="  $res"; _out_n=$((_out_n + 1)); }
			done
			_out_title="Config save"; _out_scroll=0
			_load_config
			_goto out
			;;
	esac
}

_adr_run () {
	case "$1" in
		cancel) _back ;;
		run)
			local p a f
			p="$(_form_val "project")"; a="$(_form_val "action")"; f="$(_form_val "content file (for update)")"
			test -n "$p" || { _msg="choose a project first"; return 0; }
			if test "$a" = update; then
				if test -z "$f" || test ! -f "$f"; then _msg="content file does not exist: $f"; return 0; fi
				local content
				content="$(cat "$f" 2>/dev/null)" || content=''
				_busy_start "Update ADR" _cbm_quiet manage_adr "$(_args_build project str "$p" mode str update content str "$content")"
			else
				_busy_start "ADR $a" _cbm_quiet manage_adr "$(_args_build project str "$p" mode str "$a")"
			fi
			;;
	esac
}

_server_toggle () { # true|false
	local v="$1" out
	_run_timeout 2 "$CBM_BIN" config set ui_enabled "$v"
	out="$_rt_out"
	_load_config
	_server_sub
	_msg="ui_enabled = $v"
	test -n "$out" && _msg="$_msg ($out)"
	tuish_request_redraw
}

_server_port_cb () {
	_run_timeout 2 "$CBM_BIN" config set ui_port "$1"
	_load_config
	_server_sub
	_back
	tuish_request_redraw
}

_do_delete_project () {
	_busy_start "Deleting $_sel_project" _cbm_quiet delete_project "$(_args_build project str "$_sel_project")"
	_busy_done_cb=_delete_done
}
_delete_done () {
	_load_projects
	_sel_project=''; _sel_project_root=''
	_restart_at projects
	tuish_request_redraw
}

# ─── Projects screen events ────────────────────────────────────────

_ev_projects () {
	local ev="$1"
	case "$ev" in
		up) test $_menu_cursor -gt 0 && _menu_cursor=$((_menu_cursor - 1)) ;;
		down) test $_menu_cursor -lt $((_projects_n - 1)) && _menu_cursor=$((_menu_cursor + 1)) ;;
		enter)
			if test $_projects_n -gt 0; then
				_sel_project="${_projects_name[$_menu_cursor]:-}"
				_sel_project_root="${_projects_root[$_menu_cursor]:-}"
				_pactions_open
			fi ;;
		r) _load_projects ;;
		n) _scan_open ;;
		d)
			if test $_projects_n -gt 0; then
				_sel_project="${_projects_name[$_menu_cursor]:-}"
				_sel_project_root="${_projects_root[$_menu_cursor]:-}"
				_confirm_open "Delete project '$_sel_project'? Its index and graph are removed (irreversible)." _do_delete_project
			fi ;;
		esc) _back ;;
	esac
}

# ─── Form events ───────────────────────────────────────────────────

_form_cycle () {
	local o="${_form_opts[$_form_cursor]:-}"
	test -n "$o" || return 0
	local cur="${_form_value[$_form_cursor]}"
	local -a opts=()
	local x
	for x in $o; do opts+=("$x"); done
	local n=${#opts[@]} i idx=0 found=0
	for ((i = 0; i < n; i++)); do
		if test "${opts[$i]}" = "$cur"; then idx=$(( (i + 1) % n )); found=1; break; fi
	done
	test $found -eq 0 && idx=0
	_form_value[$_form_cursor]="${opts[$idx]}"
}

_form_type () { # char or 'bksp'
	test "${_form_kind[$_form_cursor]}" = text || return 0
	local ch="$1"
	if test "$ch" = bksp; then
		_form_value[$_form_cursor]="${_form_value[$_form_cursor]%?}"
	else
		_form_value[$_form_cursor]="${_form_value[$_form_cursor]}${ch}"
	fi
}

_ev_form () {
	local ev="$1" kind
	case "$ev" in
		up) test $_form_cursor -gt 0 && _form_cursor=$((_form_cursor - 1)) ;;
		down) test $_form_cursor -lt $((_form_n - 1)) && _form_cursor=$((_form_cursor + 1)) ;;
		tab) test $_form_cursor -lt $((_form_n - 1)) && _form_cursor=$((_form_cursor + 1)) ;;
		left|right)
			test "${_form_kind[$_form_cursor]}" = choice && _form_cycle ;;
		enter)
			kind="${_form_kind[$_form_cursor]}"
			if test "$kind" = action; then
				"$_form_action" "${_form_value[$_form_cursor]}"
			elif test "$kind" = choice; then
				_form_cycle
			elif test $_form_cursor -lt $((_form_n - 1)); then
				_form_cursor=$((_form_cursor + 1))
			fi ;;
		'char '*) _form_type "${ev#char }" ;;
		space) _form_type ' ' ;;
		bksp) _form_type bksp ;;
		esc) _back ;;
	esac
}

# ─── Other screens events ──────────────────────────────────────────

_ev_input () {
	local ch
	case "$1" in
		enter) "$_input_cb" "$_input_value" ;;
		esc) _back ;;
		bksp) _input_value="${_input_value%?}" ;;
		'char '*) ch="${1#char }"; test "$ch" = bslash && ch='\'; _input_value="${_input_value}${ch}" ;;
		space) _input_value="${_input_value} " ;;
	esac
}

_ev_confirm () {
	case "$1" in
		y|Y) local cb=$_confirm_cb; "$cb" || : ;;
		n|N|esc) _back ;;
	esac
}

_out_max () {
	local max=$((_out_n - (TUISH_VIEW_ROWS - 4)))
	test $max -lt 0 && max=0
	_out_scroll=$max
}

_ev_out () {
	case "$1" in
		up) test $_out_scroll -gt 0 && _out_scroll=$((_out_scroll - 1)) ;;
		down) test $_out_scroll -lt $((_out_n - 1)) && _out_scroll=$((_out_scroll + 1)) ;;
		pgup) _out_scroll=$((_out_scroll - 10)); test $_out_scroll -lt 0 && _out_scroll=0 ;;
		pgdn) _out_scroll=$((_out_scroll + 10)); _out_max ;;
		home) _out_scroll=0 ;;
		end) _out_max ;;
		enter|esc|q) _back ;;
	esac
}

_ev_busy () {
	case "$1" in
		esc) _busy_abort=1; _back; tuish_request_redraw ;;
	esac
}

# ─── Event dispatcher ──────────────────────────────────────────────

_on_event () {
	local ev="$TUISH_EVENT"
	case "$ev" in
		idle) _tick; return 0 ;;
		ctrl-c) tuish_quit_clear; return 0 ;;
		resize) tuish_request_redraw ;;
	esac
	_msg=''
	case "$_screen" in
		main|menu) _ev_menu "$ev" ;;
		projects) _ev_projects "$ev" ;;
		form) _ev_form "$ev" ;;
		input) _ev_input "$ev" ;;
		confirm) _ev_confirm "$ev" ;;
		out) _ev_out "$ev" ;;
		busy) _ev_busy "$ev" ;;
		proc)
			case "$ev" in
				up) test $_proc_scroll -gt 0 && _proc_scroll=$((_proc_scroll - 1)) ;;
				down) test $_proc_scroll -lt $((_proc_n - 1)) && _proc_scroll=$((_proc_scroll + 1)) ;;
				r) _proc_last=0; _proc_refresh ;;
				esc|q) _back ;;
			esac ;;
	esac
	tuish_request_redraw
	return 0
}

_ev_menu () {
	local ev="$1" d
	case "$ev" in
		up) test $_menu_cursor -gt 0 && _menu_cursor=$((_menu_cursor - 1)) ;;
		down) test $_menu_cursor -lt $((_menu_n - 1)) && _menu_cursor=$((_menu_cursor + 1)) ;;
		enter) "$_menu_action" "$_menu_cursor" ;;
		esc) test "$_menu_action" = _main_enter || _back ;;
		'char '*)
			if test "$_menu_action" = _main_enter; then
				d="${ev#char }"
				case "$d" in
					1|2|3|4|5|6|7|8) _main_enter $((d - 1)) ;;
					0) _main_enter 8 ;;
				esac
			fi ;;
		q)
			if test "$_menu_action" = _main_enter; then tuish_quit_clear; fi ;;
	esac
}

# ─── Rendering primitives ──────────────────────────────────────────

_put () { # row col text
	if tuish_vmove "$1" "$2"; then tuish_print "$3"; fi
	return 0
}

_clear_put () { # row text
	tuish_clear_to_edge "$1"
	if tuish_vmove "$1" 1; then tuish_print "$2"; fi
	return 0
}

_title_bar () { # text
	tuish_reverse
	tuish_clear_to_edge 1
	_put 1 1 " $1 "
	tuish_sgr_reset
	return 0
}

# ─── Screen renderers ──────────────────────────────────────────────

_render_menu () {
	_title_bar "$_menu_title"
	if test -n "$_menu_sub"; then _clear_put 2 "$_menu_sub"; fi
	local i r=3
	i=0
	while test $i -lt $_menu_n; do
		tuish_clear_to_edge $r
		if test $i -eq $_menu_cursor; then tuish_reverse; fi
		_put $r 1 "  ${_menu_items[$i]}"
		tuish_sgr_reset
		r=$((r + 1))
		i=$((i + 1))
	done
	return 0
}

_render_form () {
	_title_bar "$_form_title"
	_clear_put 2 "use ←/→ to cycle choices · Enter moves to next · Enter on [ACTION] runs"
	local i r=3 label val kind
	i=0
	while test $i -lt $_form_n; do
		label="${_form_label[$i]:-}"; val="${_form_value[$i]:-}"; kind="${_form_kind[$i]:-}"
		tuish_clear_to_edge $r
		if test $i -eq $_form_cursor; then tuish_reverse; fi
		if test "$kind" = action; then
			_put $r 1 "  [ ${label} ]"
		else
			_put $r 1 "  ${label}: ${val}"
		fi
		tuish_sgr_reset
		r=$((r + 1))
		i=$((i + 1))
	done
	return 0
}

_render_projects () {
	_title_bar "Indexed projects"
	_clear_put 2 "Enter: project actions · n: scan · r: refresh · d: delete · esc: back"
	# header row
	tuish_clear_to_edge 3
	_put 3 1 "$(printf '  %-44s %-9s %9s %9s %9s' 'name' 'branch' 'nodes' 'edges' 'size')"
	local i r=4 name
	i=0
	while test $i -lt $_projects_n && test $r -lt $((TUISH_VIEW_ROWS - 2)); do
		name="${_projects_name[$i]:-}"
		test ${#name} -gt 44 && name="${name:0:42}.."
		tuish_clear_to_edge $r
		if test $i -eq $_menu_cursor; then tuish_reverse; fi
		_put $r 1 "$(printf '  %-44s %-9s %9s %9s %9s' "$name" "${_projects_branch[$i]:-}" "${_projects_nodes[$i]:-}" "${_projects_edges[$i]:-}" "$(_hsize "${_projects_size[$i]:-0}")")"
		tuish_sgr_reset
		r=$((r + 1))
		i=$((i + 1))
	done
	if test $_projects_n -eq 0; then
		if test "$_projects_loaded" -eq 0; then
			_clear_put 4 "loading projects…"
		else
			_clear_put 4 "no indexed projects yet — press n to scan one"
		fi
	fi
	if test $_projects_n -gt 0; then
		tuish_clear_to_edge $r
		_put $r 1 "  root: ${_projects_root[$_menu_cursor]:-}"
	fi
	return 0
}

_render_out () {
	_title_bar "$_out_title"
	local r=2 i=$_out_scroll
	while test $r -le $((TUISH_VIEW_ROWS - 1)); do
		tuish_clear_to_edge $r
		if test $i -lt $_out_n; then _put $r 1 "${_out_lines[$i]:-}"; fi
		i=$((i + 1))
		r=$((r + 1))
	done
	return 0
}

_render_proc () {
	_title_bar "Processes & resources"
	_clear_put 2 "auto-refreshes · r: refresh now · ↑/↓ scroll · esc: back"
	local r=3 i=$_proc_scroll
	while test $r -le $((TUISH_VIEW_ROWS - 1)); do
		tuish_clear_to_edge $r
		if test $i -lt $_proc_n; then _put $r 1 "${_proc_lines[$i]:-}"; fi
		i=$((i + 1))
		r=$((r + 1))
	done
	return 0
}

_render_busy () {
	_title_bar "$_busy_title"
	local s='-\|/'
	local f=$((_busy_frame % 4))
	_clear_put 4 "  ${s:$f:1}  running... (esc: skip waiting, job continues)"
	_clear_put 6 "  a background job is executing a codebase-memory-mcp command."
	_clear_put 7 "  long operations (indexing large repos) can take a while."
	return 0
}

_render_input () {
	_title_bar "Input"
	_clear_put 3 "$_input_label"
	tuish_reverse
	tuish_clear_to_edge 5
	_put 5 1 "  $_input_value"
	tuish_sgr_reset
	_clear_put 6 "  Enter: confirm · Esc: cancel"
	return 0
}

_render_confirm () {
	_title_bar "Confirm"
	tuish_clear_to_edge 4
	_put 4 1 "  $_confirm_msg"
	_clear_put 6 "  y: yes   n / esc: no"
	return 0
}

_render () {
	local level=${1:--1}
	local _r=2
	while test $_r -le $((TUISH_VIEW_ROWS - 1)); do
		tuish_clear_to_edge $_r
		_r=$((_r + 1))
	done
	case "$_screen" in
		main) _render_menu ;;
		menu) _render_menu ;;
		projects) _render_projects ;;
		form) _render_form ;;
		input) _render_input ;;
		confirm) _render_confirm ;;
		out) _render_out ;;
		busy) _render_busy ;;
		proc) _render_proc ;;
	esac
	# footer
	local fr=$TUISH_VIEW_ROWS
	tuish_reverse
	tuish_clear_to_edge $fr
	_put $fr 1 " $_menu_hint"
	if test -n "$_msg"; then _put $fr 1 " $_menu_hint   |  $_msg"; fi
	tuish_sgr_reset
	return 0
}

# ─── Setup / run ───────────────────────────────────────────────────

_setup () {
	test -x "$CBM_BIN" || { echo "cbmman: codebase-memory-mcp not found at $CBM_BIN" >&2; exit 1; }
	tuish_init || { echo "cbmman: terminal init failed (need a real tty)" >&2; exit 1; }
	tuish_viewport fullscreen
	tuish_on_event _on_event
	tuish_on_redraw _render
	_main_open
	_menu_hint="↑/↓ navigate · Enter select · digit jump · q/ctrl-c quit"
	_load_projects_async
}

main () {
	_setup
	tuish_run || :
	tuish_fini
}

main "$@"
