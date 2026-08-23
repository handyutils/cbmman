//! cbmman — interactive TUI manager for codebase-memory-mcp.
//!
//! Rust counterpart of `cbmman.sh`, built on ratatui + crossterm.
//! Wraps the full CLI of https://github.com/DeusData/codebase-memory-mcp:
//!   * list / index / re-index / delete projects
//!   * start/stop/status of the graph server (UI) and config management
//!   * live process + artifact-size monitor
//!   * graph queries (search, trace, cypher, architecture, schema, traces)
//!   * ADR management and maintenance (version / help / update / uninstall)
//!
//! Run: `cargo run --release`   (or `cargo build --release` for the binary)
//! Env: `CBM_BIN` overrides the codebase-memory-mcp binary path.

use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Cell, List, ListItem, ListState, Paragraph, Table, Wrap};
use ratatui::{Frame, Terminal};
use serde_json::Value;
use std::io;
use std::process::Command;
use std::sync::mpsc::{self, Receiver, Sender};
use std::time::Duration;

// ──────────────────────────────────────────────────────────────────
// Backend: talk to the codebase-memory-mcp binary
// ──────────────────────────────────────────────────────────────────

fn cbm_bin() -> String {
    std::env::var("CBM_BIN").unwrap_or_else(|_| "codebase-memory-mcp".to_string())
}

#[derive(Clone, Default)]
struct Project {
    name: String,
    root: String,
    branch: String,
    nodes: u64,
    edges: u64,
    size: u64,
}

#[derive(Clone)]
struct JobResult {
    code: i32,
    lines: Vec<String>,
}

/// Run `cbm cli --json <tool> '<args>'` and return the RAW stdout (as lines).
/// The binary prints diagnostics on stderr, which is deliberately ignored.
fn run_tool_raw(tool: &str, args: &str) -> JobResult {
    let bin = cbm_bin();
    let output = Command::new(&bin)
        .arg("cli")
        .arg("--json")
        .arg(tool)
        .arg(args)
        .output();
    match output {
        Ok(o) => {
            let code = o.status.code().unwrap_or(1);
            let stdout = String::from_utf8_lossy(&o.stdout).to_string();
            JobResult { code, lines: stdout.lines().map(|s| s.to_string()).collect() }
        }
        Err(e) => JobResult { code: 1, lines: vec![format!("error invoking {}: {}", bin, e)] },
    }
}

/// Run `cbm cli --json <tool> '<args>'` and format the MCP response.
fn run_tool(tool: &str, args: &str) -> JobResult {
    let raw = run_tool_raw(tool, args);
    JobResult { code: raw.code, lines: format_mcp(&raw.lines.join("\n")) }
}

/// Run `cbm <subcommand> <args...>` and return only stdout (raw lines).
fn run_bin_raw(sub: &str, args: &[&str]) -> JobResult {
    let bin = cbm_bin();
    let output = Command::new(&bin).arg(sub).args(args).output();
    match output {
        Ok(o) => {
            let code = o.status.code().unwrap_or(1);
            let stdout = String::from_utf8_lossy(&o.stdout).to_string();
            JobResult { code, lines: stdout.lines().map(|s| s.to_string()).collect() }
        }
        Err(e) => JobResult { code: 1, lines: vec![format!("error invoking {}: {}", bin, e)] },
    }
}

/// Run `cbm <subcommand> <args...>` (config, --version, --help, …).
fn run_bin(sub: &str, args: &[&str]) -> JobResult {
    let bin = cbm_bin();
    let output = Command::new(&bin).arg(sub).args(args).output();
    match output {
        Ok(o) => {
            let code = o.status.code().unwrap_or(1);
            let mut out = String::from_utf8_lossy(&o.stdout).to_string();
            out.push_str(&String::from_utf8_lossy(&o.stderr));
            JobResult {
                code,
                lines: out.lines().map(|s| s.to_string()).collect(),
            }
        }
        Err(e) => JobResult { code: 1, lines: vec![format!("error invoking {}: {}", bin, e)] },
    }
}

/// Format a `cli --json` MCP response into display lines. Robust to any
/// leading noise (the binary prints `level=info` diagnostics on stderr, which
/// we ignore, but also defensively skips non-JSON prefixes on stdout).
fn format_mcp(stdout: &str) -> Vec<String> {
    let i = stdout.find('{').unwrap_or(0);
    let v: Value = match serde_json::from_str(&stdout[i..]) {
        Ok(v) => v,
        Err(_) => return stdout.lines().map(|s| s.to_string()).collect(),
    };
    if v.get("isError").and_then(|b| b.as_bool()).unwrap_or(false) {
        let mut lines = Vec::new();
        if let Some(c) = v.get("content").and_then(|c| c.as_array()) {
            for item in c {
                if let Some(t) = item.get("text").and_then(|t| t.as_str()) {
                    lines.push(format!("! {}", t));
                }
            }
        }
        return lines;
    }
    let mut lines = Vec::new();
    if let Some(c) = v.get("content").and_then(|c| c.as_array()) {
        for item in c {
            if let Some(t) = item.get("text").and_then(|t| t.as_str()) {
                match serde_json::from_str::<Value>(t) {
                    Ok(j) => match serde_json::to_string_pretty(&j) {
                        Ok(p) => lines.extend(p.lines().map(|s| s.to_string())),
                        Err(_) => lines.extend(t.lines().map(|s| s.to_string())),
                    },
                    Err(_) => lines.extend(t.lines().map(|s| s.to_string())),
                }
            }
        }
    }
    lines
}

fn parse_projects(stdout: &str) -> Vec<Project> {
    let mut out = Vec::new();
    let i = stdout.find('{').unwrap_or(0);
    let Ok(v) = serde_json::from_str::<Value>(&stdout[i..]) else { return out };
    let Some(text) = v
        .get("content")
        .and_then(|c| c.as_array())
        .and_then(|c| c.first())
        .and_then(|c| c.get("text"))
        .and_then(|t| t.as_str())
    else {
        return out;
    };
    let Ok(inner) = serde_json::from_str::<Value>(text) else { return out };
    if let Some(arr) = inner.get("projects").and_then(|p| p.as_array()) {
        for p in arr {
            out.push(Project {
                name: p.get("name").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                root: p.get("root_path").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                branch: p.get("branch").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                nodes: p.get("nodes").and_then(|x| x.as_u64()).unwrap_or(0),
                edges: p.get("edges").and_then(|x| x.as_u64()).unwrap_or(0),
                size: p.get("size_bytes").and_then(|x| x.as_u64()).unwrap_or(0),
            });
        }
    }
    out
}

fn parse_config(stdout: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for line in stdout.lines() {
        let line = line.trim_end();
        if let Some(eq) = line.find('=') {
            let key = line[..eq].trim().to_string();
            let val = line[eq + 1..].trim().to_string();
            if !key.is_empty() {
                out.push((key, val));
            }
        }
    }
    out
}

// ──────────────────────────────────────────────────────────────────
// Message channel for background jobs
// ──────────────────────────────────────────────────────────────────

enum Msg {
    Job(JobResult),
    Projects(JobResult),
    Config(JobResult),
}

fn spawn_tool_job(tx: Sender<Msg>, tool: &str, args: String) {
    let tool = tool.to_string();
    std::thread::spawn(move || {
        let _ = tx.send(Msg::Job(run_tool(&tool, &args)));
    });
}

fn spawn_bin_job(tx: Sender<Msg>, sub: String, args: Vec<String>) {
    std::thread::spawn(move || {
        let refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
        let _ = tx.send(Msg::Job(run_bin(&sub, &refs)));
    });
}

fn spawn_load_projects(tx: Sender<Msg>) {
    std::thread::spawn(move || {
        let _ = tx.send(Msg::Projects(run_tool_raw("list_projects", "")));
    });
}

fn spawn_load_config(tx: Sender<Msg>) {
    std::thread::spawn(move || {
        let _ = tx.send(Msg::Config(run_bin_raw("config", &["list"])));
    });
}

// ──────────────────────────────────────────────────────────────────
// UI state
// ──────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq)]
enum Screen {
    Menu,
    Projects,
    Form,
    Output,
    Busy,
    Confirm,
    Input,
    Processes,
}

/// How to rebuild a screen we return to (menus lose their widget state).
#[derive(Clone, Copy, PartialEq)]
enum Rebuild {
    None,
    Main,
    Pactions,
    Server,
    Qmenu,
    Maint,
}

#[derive(Clone, Copy, PartialEq)]
enum MenuAction {
    Main,
    Paction,
    Server,
    Qmenu,
    Maint,
}

#[derive(Clone, Copy, PartialEq)]
enum FieldKind {
    Text,
    Choice,
    Action,
}

struct FormField {
    label: String,
    value: String,
    kind: FieldKind,
    opts: Vec<String>,
}

#[derive(Clone, Copy, PartialEq)]
enum FormAction {
    Scan,
    Query,
    Config,
    Adr,
}

#[derive(Clone, Copy, PartialEq)]
enum ConfirmCb {
    DeleteProject,
}

#[derive(Clone, Copy, PartialEq)]
enum InputCb {
    ServerPort,
}

struct NavEntry {
    screen: Screen,
    rebuild: Rebuild,
}

struct App {
    running: bool,
    screen: Screen,
    nav: Vec<NavEntry>,
    menu_rebuild: Rebuild,
    msg: String,
    tick_c: u64,

    rx: Receiver<Msg>,
    tx: Sender<Msg>,

    // menu
    menu_title: String,
    menu_sub: String,
    menu_hint: String,
    menu_items: Vec<String>,
    menu_cursor: usize,
    menu_action: MenuAction,

    // form
    form_title: String,
    form_meta: String,
    form_action: FormAction,
    form_fields: Vec<FormField>,
    form_cursor: usize,

    // output
    out_title: String,
    out_lines: Vec<String>,
    out_scroll: usize,

    // projects
    projects: Vec<Project>,
    projects_loaded: bool,
    sel_project: Option<usize>,

    // busy job
    job_title: String,
    job_active: bool,

    // processes
    proc_lines: Vec<String>,
    proc_scroll: usize,

    // config
    config: Vec<(String, String)>,
    config_loaded: bool,

    // confirm / input
    confirm_msg: String,
    confirm_cb: ConfirmCb,
    input_label: String,
    input_value: String,
    input_cb: InputCb,
}

impl App {
    fn new(rx: Receiver<Msg>, tx: Sender<Msg>) -> Self {
        let mut a = App {
            running: true,
            screen: Screen::Menu,
            nav: Vec::new(),
            menu_rebuild: Rebuild::None,
            msg: String::new(),
            tick_c: 0,
            rx,
            tx,
            menu_title: String::new(),
            menu_sub: String::new(),
            menu_hint: String::new(),
            menu_items: Vec::new(),
            menu_cursor: 0,
            menu_action: MenuAction::Main,
            form_title: String::new(),
            form_meta: String::new(),
            form_action: FormAction::Query,
            form_fields: Vec::new(),
            form_cursor: 0,
            out_title: String::new(),
            out_lines: Vec::new(),
            out_scroll: 0,
            projects: Vec::new(),
            projects_loaded: false,
            sel_project: None,
            job_title: String::new(),
            job_active: false,
            proc_lines: Vec::new(),
            proc_scroll: 0,
            config: Vec::new(),
            config_loaded: false,
            confirm_msg: String::new(),
            confirm_cb: ConfirmCb::DeleteProject,
            input_label: String::new(),
            input_value: String::new(),
            input_cb: InputCb::ServerPort,
        };
        a.build_main();
        a.menu_rebuild = Rebuild::Main;
        a
    }

    // ── navigation ──
    fn push(&mut self, screen: Screen, rebuild: Rebuild) {
        let leaving = match self.screen {
            Screen::Menu => self.menu_rebuild,
            _ => Rebuild::None,
        };
        self.nav.push(NavEntry { screen: self.screen, rebuild: leaving });
        self.screen = screen;
        self.menu_rebuild = rebuild;
    }

    fn back(&mut self) {
        if let Some(entry) = self.nav.pop() {
            self.screen = entry.screen;
            self.menu_rebuild = Rebuild::None;
            match entry.rebuild {
                Rebuild::Main => self.build_main(),
                Rebuild::Pactions => self.build_pactions(),
                Rebuild::Server => {
                    self.load_config_sync();
                    self.build_server();
                }
                Rebuild::Qmenu => self.build_qmenu(),
                Rebuild::Maint => self.build_maint(),
                Rebuild::None => {}
            }
        }
    }

    fn restart_at(&mut self, screen: Screen) {
        self.nav.clear();
        self.nav.push(NavEntry { screen: Screen::Menu, rebuild: Rebuild::Main });
        self.screen = screen;
    }

    // ── menu builders ──
    fn build_main(&mut self) {
        self.menu_rebuild = Rebuild::Main;
        self.menu_action = MenuAction::Main;
        self.menu_title = "cbmman — codebase-memory-mcp manager".into();
        self.menu_sub = String::new();
        self.menu_hint = "↑/↓ navigate · Enter select · digit jump · q / ctrl-c quit".into();
        self.menu_items = vec![
            "1. Projects".into(),
            "2. Scan / Index project".into(),
            "3. Graph server (UI)".into(),
            "4. Processes & resources".into(),
            "5. Configuration".into(),
            "6. Graph queries".into(),
            "7. ADR management".into(),
            "8. Maintenance".into(),
            "0. Quit".into(),
        ];
        self.menu_cursor = 0;
    }

    fn build_pactions(&mut self) {
        self.menu_rebuild = Rebuild::Pactions;
        self.menu_action = MenuAction::Paction;
        let proj = self
            .sel_project
            .and_then(|i| self.projects.get(i))
            .map(|p| p.name.clone())
            .unwrap_or_default();
        self.menu_title = "Project actions".into();
        self.menu_sub = format!("project: {}", proj);
        self.menu_hint = "↑/↓ navigate · Enter select · esc back".into();
        self.menu_items = vec![
            "Index status".into(),
            "Architecture overview".into(),
            "Index coverage".into(),
            "Detect changes".into(),
            "Re-scan".into(),
            "Delete project".into(),
            "Back".into(),
        ];
        self.menu_cursor = 0;
    }

    fn build_server(&mut self) {
        self.menu_rebuild = Rebuild::Server;
        self.menu_action = MenuAction::Server;
        self.menu_title = "Graph server (UI)".into();
        self.menu_sub = format!(
            "port {} · ui_enabled {}",
            self.config_get("ui_port"),
            self.config_get("ui_enabled")
        );
        self.menu_hint = "↑/↓ · Enter select · esc back".into();
        self.menu_items = vec![
            "Start UI server".into(),
            "Stop UI server".into(),
            "Set port".into(),
            "Open in browser".into(),
            "Refresh status".into(),
            "Back".into(),
        ];
        self.menu_cursor = 0;
    }

    fn build_qmenu(&mut self) {
        self.menu_rebuild = Rebuild::Qmenu;
        self.menu_action = MenuAction::Qmenu;
        self.menu_title = "Graph queries".into();
        self.menu_sub = format!("projects indexed: {}", self.projects.len());
        self.menu_hint = "↑/↓ · Enter select · esc back".into();
        self.menu_items = vec![
            "Search graph".into(),
            "Search code".into(),
            "Get code snippet".into(),
            "Trace path".into(),
            "Cypher query".into(),
            "Architecture overview".into(),
            "Graph schema".into(),
            "Ingest traces".into(),
            "Back".into(),
        ];
        self.menu_cursor = 0;
    }

    fn build_maint(&mut self) {
        self.menu_rebuild = Rebuild::Maint;
        self.menu_action = MenuAction::Maint;
        self.menu_title = "Maintenance".into();
        self.menu_sub = String::new();
        self.menu_hint = "↑/↓ · Enter select · esc back".into();
        self.menu_items = vec![
            "Version".into(),
            "CLI help".into(),
            "Update (show command)".into(),
            "Uninstall (dry-run)".into(),
            "Cache & diagnostics".into(),
            "Back".into(),
        ];
        self.menu_cursor = 0;
    }

    fn config_get(&self, key: &str) -> String {
        self.config
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.clone())
            .unwrap_or_default()
    }

    // ── data loaders ──
    fn load_projects_sync(&mut self) {
        let res = run_tool_raw("list_projects", "");
        self.projects = parse_projects(&res.lines.join("\n"));
        self.projects_loaded = true;
    }

    fn load_config_sync(&mut self) {
        let res = run_bin_raw("config", &["list"]);
        self.config = parse_config(&res.lines.join("\n"));
        self.config_loaded = true;
    }

    // ── busy job helpers ──
    fn start_tool_job(&mut self, title: &str, tool: &str, args: String) {
        self.job_title = title.to_string();
        self.job_active = true;
        let tx = self.tx.clone();
        spawn_tool_job(tx, tool, args);
        self.push(Screen::Busy, Rebuild::None);
    }

    fn start_bin_job(&mut self, title: &str, sub: &str, args: Vec<&str>) {
        self.job_title = title.to_string();
        self.job_active = true;
        let tx = self.tx.clone();
        let argvec: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        spawn_bin_job(tx, sub.to_string(), argvec);
        self.push(Screen::Busy, Rebuild::None);
    }

    fn show_output(&mut self, title: String, lines: Vec<String>, code: i32) {
        self.out_title = format!("{} (exit {})", title, code);
        self.out_lines = lines;
        self.out_scroll = 0;
        if self.screen == Screen::Busy {
            self.screen = Screen::Output;
        } else {
            self.msg = format!("background job done: {}", title);
        }
    }

    // ── form helpers ──
    fn form_begin(&mut self, title: &str, action: FormAction) {
        self.form_title = title.to_string();
        self.form_action = action;
        self.form_meta.clear();
        self.form_fields.clear();
        self.form_cursor = 0;
    }

    fn form_field(&mut self, label: &str, value: &str, kind: FieldKind, opts: Vec<&str>) {
        self.form_fields.push(FormField {
            label: label.to_string(),
            value: value.to_string(),
            kind,
            opts: opts.iter().map(|s| s.to_string()).collect(),
        });
    }

    fn form_val(&self, label: &str) -> String {
        self.form_fields
            .iter()
            .find(|f| f.label == label)
            .map(|f| f.value.clone())
            .unwrap_or_default()
    }

    fn form_cycle(&mut self) {
        let cur = self.form_cursor;
        if cur >= self.form_fields.len() {
            return;
        }
        let opts = self.form_fields[cur].opts.clone();
        if opts.is_empty() {
            return;
        }
        let cur_val = self.form_fields[cur].value.clone();
        let idx = opts.iter().position(|o| *o == cur_val).map(|i| (i + 1) % opts.len()).unwrap_or(0);
        self.form_fields[cur].value = opts[idx].clone();
    }

    fn qf_project_opts(&self) -> Vec<String> {
        self.projects.iter().map(|p| p.name.clone()).collect()
    }

    fn qf_default_project(&self) -> String {
        if let Some(i) = self.sel_project {
            if let Some(p) = self.projects.get(i) {
                return p.name.clone();
            }
        }
        if self.projects.len() == 1 {
            return self.projects[0].name.clone();
        }
        String::new()
    }

    fn qf_proj_field(&mut self) {
        let opts = self.qf_project_opts();
        if opts.is_empty() {
            self.form_field("project", "", FieldKind::Text, vec![]);
        } else {
            let vals: Vec<&str> = opts.iter().map(|s| s.as_str()).collect();
            let d = self.qf_default_project();
            self.form_field("project", &d, FieldKind::Choice, vals);
        }
    }

    fn open_query_form(&mut self, meta: &str, title: &str) {
        if !self.projects_loaded {
            self.load_projects_sync();
        }
        self.form_begin(title, FormAction::Query);
        self.form_meta = meta.to_string();
        match meta {
            "search_graph" => {
                self.qf_proj_field();
                self.form_field("query", "", FieldKind::Text, vec![]);
                self.form_field("name pattern", "", FieldKind::Text, vec![]);
                self.form_field("semantic (csv)", "", FieldKind::Text, vec![]);
                self.form_field("limit", "50", FieldKind::Text, vec![]);
            }
            "search_code" => {
                self.qf_proj_field();
                self.form_field("pattern", "", FieldKind::Text, vec![]);
                self.form_field("regex", "no", FieldKind::Choice, vec!["no", "yes"]);
                self.form_field("limit", "10", FieldKind::Text, vec![]);
            }
            "get_code_snippet" => {
                self.qf_proj_field();
                self.form_field("qualified name", "", FieldKind::Text, vec![]);
            }
            "trace_path" => {
                self.qf_proj_field();
                self.form_field("function name", "", FieldKind::Text, vec![]);
                self.form_field("direction", "inbound", FieldKind::Choice, vec!["inbound", "outbound", "both"]);
                self.form_field("depth", "3", FieldKind::Text, vec![]);
            }
            "query_graph" => {
                self.qf_proj_field();
                self.form_field("cypher query", "", FieldKind::Text, vec![]);
            }
            "get_architecture" => {
                self.qf_proj_field();
                self.form_field("aspects (csv)", "clusters,dependencies,structure", FieldKind::Text, vec![]);
            }
            "get_graph_schema" => {
                self.qf_proj_field();
            }
            "ingest_traces" => {
                self.qf_proj_field();
                self.form_field("traces (caller,callee,count;...)", "", FieldKind::Text, vec![]);
            }
            _ => {}
        }
        self.form_field("RUN", "run", FieldKind::Action, vec![]);
        self.form_field("CANCEL", "cancel", FieldKind::Action, vec![]);
        self.menu_hint = "fill fields · Enter next · ←/→ cycle · Enter on [RUN] executes · esc cancel".into();
        self.push(Screen::Form, Rebuild::None);
    }

    // ── arg builder (mirrors the shell's `_args_build`) ──
    fn build_args(&self, spec: &[(&str, &str, &str)]) -> String {
        let mut map = serde_json::Map::new();
        for (k, kind, v) in spec {
            if v.is_empty() {
                continue;
            }
            match *kind {
                "int" => match v.parse::<u64>() {
                    Ok(n) => {
                        map.insert((*k).to_string(), Value::from(n));
                    }
                    Err(_) => {
                        map.insert((*k).to_string(), Value::from((*v).to_string()));
                    }
                },
                "bool" => {
                    map.insert((*k).to_string(), Value::Bool(*v == "true"));
                }
                "list" => {
                    let items: Vec<Value> =
                        v.split(',').filter(|x| !x.is_empty()).map(|x| Value::from(x.to_string())).collect();
                    map.insert((*k).to_string(), Value::Array(items));
                }
                "traces" => {
                    let mut arr = Vec::new();
                    for part in v.split(';') {
                        let c: Vec<&str> = part.split(',').collect();
                        if c.len() == 3 {
                            let mut obj = serde_json::Map::new();
                            obj.insert("caller".into(), Value::from(c[0].to_string()));
                            obj.insert("callee".into(), Value::from(c[1].to_string()));
                            obj.insert("count".into(), Value::from(c[2].parse::<u64>().unwrap_or(0)));
                            arr.push(Value::Object(obj));
                        }
                    }
                    map.insert((*k).to_string(), Value::Array(arr));
                }
                _ => {
                    map.insert((*k).to_string(), Value::from((*v).to_string()));
                }
            }
        }
        Value::Object(map).to_string()
    }

    // ── per-screen actions ──
    fn main_enter(&mut self, idx: usize) {
        match idx {
            0 => {
                if !self.projects_loaded {
                    self.load_projects_sync();
                }
                self.sel_project = None;
                self.menu_cursor = 0;
                self.push(Screen::Projects, Rebuild::None);
            }
            1 => self.open_scan(),
            2 => {
                self.load_config_sync();
                self.push(Screen::Menu, Rebuild::Server);
                self.build_server();
            }
            3 => self.open_processes(),
            4 => self.open_config(),
            5 => self.push(Screen::Menu, Rebuild::Qmenu),
            6 => self.open_adr(),
            7 => self.push(Screen::Menu, Rebuild::Maint),
            8 => self.running = false,
            _ => {}
        }
        // qmenu/maint rebuild after push
        if self.screen == Screen::Menu && (idx == 5 || idx == 7) {
            match idx {
                5 => self.build_qmenu(),
                7 => self.build_maint(),
                _ => {}
            }
        }
    }

    fn paction_enter(&mut self, idx: usize) {
        let Some(pi) = self.sel_project else { return };
        let proj = self.projects.get(pi).map(|p| p.name.clone()).unwrap_or_default();
        match idx {
            0 => {
                let args = self.build_args(&[("project", "str", &proj)]);
                self.start_tool_job("Index status", "index_status", args);
            }
            1 => {
                let args = self.build_args(&[
                    ("project", "str", &proj),
                    ("aspects", "list", "clusters,dependencies,structure,hotspots"),
                ]);
                self.start_tool_job("Architecture", "get_architecture", args);
            }
            2 => {
                let args = self.build_args(&[("project", "str", &proj), ("scopes", "list", ".")]);
                self.start_tool_job("Index coverage", "check_index_coverage", args);
            }
            3 => {
                let args = self.build_args(&[("project", "str", &proj)]);
                self.start_tool_job("Detect changes", "detect_changes", args);
            }
            4 => {
                let root = self.projects.get(pi).map(|p| p.root.clone()).unwrap_or_default();
                self.open_scan_with(root, proj);
            }
            5 => {
                self.confirm_msg = format!(
                    "Delete project '{}'? Its index and graph are removed (irreversible).",
                    proj
                );
                self.confirm_cb = ConfirmCb::DeleteProject;
                self.push(Screen::Confirm, Rebuild::None);
            }
            6 => self.back(),
            _ => {}
        }
    }

    fn server_enter(&mut self, idx: usize) {
        match idx {
            0 => {
                self.start_bin_job("Start UI server", "config", vec!["set", "ui_enabled", "true"]);
            }
            1 => {
                self.start_bin_job("Stop UI server", "config", vec!["set", "ui_enabled", "false"]);
            }
            2 => {
                self.input_label = "New UI port".into();
                self.input_value = self.config_get("ui_port");
                self.input_cb = InputCb::ServerPort;
                self.push(Screen::Input, Rebuild::None);
            }
            3 => {
                let port = self.config_get("ui_port");
                let url = format!("http://localhost:{}", port);
                let _ = Command::new("open").arg(&url).spawn();
            }
            4 => {
                self.load_config_sync();
                self.build_server();
            }
            5 => self.back(),
            _ => {}
        }
    }

    fn qmenu_enter(&mut self, idx: usize) {
        match idx {
            0 => self.open_query_form("search_graph", "Search graph"),
            1 => self.open_query_form("search_code", "Search code"),
            2 => self.open_query_form("get_code_snippet", "Get code snippet"),
            3 => self.open_query_form("trace_path", "Trace path"),
            4 => self.open_query_form("query_graph", "Cypher query"),
            5 => self.open_query_form("get_architecture", "Architecture overview"),
            6 => self.open_query_form("get_graph_schema", "Graph schema"),
            7 => self.open_query_form("ingest_traces", "Ingest traces"),
            8 => self.back(),
            _ => {}
        }
    }

    fn maint_enter(&mut self, idx: usize) {
        match idx {
            0 => self.start_bin_job("Version", "--version", vec![]),
            1 => self.start_bin_job("CLI help", "--help", vec![]),
            2 => self.start_bin_job("Update", "update", vec!["-y"]),
            3 => self.start_bin_job("Uninstall dry-run", "uninstall", vec!["--dry-run"]),
            4 => self.start_bin_job("Cache & diagnostics", "cache-info", vec![]),
            5 => self.back(),
            _ => {}
        }
    }

    fn open_scan(&mut self) {
        self.open_scan_with(
            std::env::current_dir().map(|p| p.to_string_lossy().to_string()).unwrap_or_default(),
            String::new(),
        );
    }

    fn open_scan_with(&mut self, path: String, name: String) {
        self.form_begin("Scan / index a repository", FormAction::Scan);
        self.form_field("repo path", &path, FieldKind::Text, vec![]);
        self.form_field("mode", "moderate", FieldKind::Choice, vec!["moderate", "full", "fast", "cross-repo"]);
        self.form_field("name override (optional)", &name, FieldKind::Text, vec![]);
        self.form_field("persist artifact", "no", FieldKind::Choice, vec!["no", "yes"]);
        self.form_field("target projects (cross-repo, csv)", "", FieldKind::Text, vec![]);
        self.form_field("SCAN", "run", FieldKind::Action, vec![]);
        self.form_field("CANCEL", "cancel", FieldKind::Action, vec![]);
        self.menu_hint = "type path · Enter next · ←/→ cycle · Enter on [SCAN] indexes · esc cancel".into();
        self.push(Screen::Form, Rebuild::None);
    }

    fn scan_run(&mut self, action: &str) {
        match action {
            "cancel" => self.back(),
            "run" => {
                let path = self.form_val("repo path");
                if path.is_empty() {
                    self.msg = "repo path is required".into();
                    return;
                }
                let mode = self.form_val("mode");
                let name = self.form_val("name override (optional)");
                let persist = self.form_val("persist artifact");
                let targets = self.form_val("target projects (cross-repo, csv)");
                let args = if mode == "cross-repo" {
                    if targets.is_empty() {
                        self.msg = "cross-repo mode needs target projects (csv)".into();
                        return;
                    }
                    self.build_args(&[
                        ("repo_path", "str", &path),
                        ("mode", "str", "cross-repo-intelligence"),
                        ("name", "str", &name),
                        ("target_projects", "list", &targets),
                    ])
                } else {
                    let pers = if persist == "yes" { "true" } else { "false" };
                    self.build_args(&[
                        ("repo_path", "str", &path),
                        ("mode", "str", &mode),
                        ("name", "str", &name),
                        ("persistence", "bool", pers),
                    ])
                };
                self.start_tool_job(&format!("Indexing {}", path), "index_repository", args);
            }
            _ => {}
        }
    }

    fn query_run(&mut self, action: &str) {
        match action {
            "cancel" => self.back(),
            "run" => {
                let proj = self.form_val("project");
                if proj.is_empty() {
                    self.msg = "choose a project first (Projects → Scan to index)".into();
                    return;
                }
                let args: String = match self.form_meta.as_str() {
                    "search_graph" => self.build_args(&[
                        ("project", "str", &proj),
                        ("query", "str", &self.form_val("query")),
                        ("name_pattern", "str", &self.form_val("name pattern")),
                        ("semantic", "list", &self.form_val("semantic (csv)")),
                        ("limit", "int", &self.form_val("limit")),
                    ]),
                    "search_code" => {
                        let re = if self.form_val("regex") == "yes" { "true" } else { "false" };
                        self.build_args(&[
                            ("project", "str", &proj),
                            ("pattern", "str", &self.form_val("pattern")),
                            ("regex", "bool", re),
                            ("limit", "int", &self.form_val("limit")),
                        ])
                    }
                    "get_code_snippet" => self.build_args(&[
                        ("project", "str", &proj),
                        ("qualified_name", "str", &self.form_val("qualified name")),
                    ]),
                    "trace_path" => self.build_args(&[
                        ("project", "str", &proj),
                        ("function_name", "str", &self.form_val("function name")),
                        ("direction", "str", &self.form_val("direction")),
                        ("depth", "int", &self.form_val("depth")),
                    ]),
                    "query_graph" => self.build_args(&[
                        ("project", "str", &proj),
                        ("query", "str", &self.form_val("cypher query")),
                    ]),
                    "get_architecture" => self.build_args(&[
                        ("project", "str", &proj),
                        ("aspects", "list", &self.form_val("aspects (csv)")),
                    ]),
                    "get_graph_schema" => self.build_args(&[("project", "str", &proj)]),
                    "ingest_traces" => self.build_args(&[
                        ("project", "str", &proj),
                        ("traces", "traces", &self.form_val("traces (caller,callee,count;...)")),
                    ]),
                    _ => self.build_args(&[("project", "str", &proj)]),
                };
                let meta = self.form_meta.clone();
                self.start_tool_job(&meta, &meta, args);
            }
            _ => {}
        }
    }

    fn config_run(&mut self, action: &str) {
        match action {
            "back" => self.back(),
            "refresh" => {
                self.load_config_sync();
                self.open_config();
            }
            "save" => {
                let mut lines = Vec::new();
                for f in &self.form_fields {
                    if f.kind == FieldKind::Action {
                        continue;
                    }
                    let res = run_bin("config", &["set", &f.label, &f.value]);
                    lines.push(format!("set {} = {}", f.label, f.value));
                    if !res.lines.is_empty() {
                        lines.push(format!("  {}", res.lines.join(" ")));
                    }
                }
                self.load_config_sync();
                self.show_output("Config save".into(), lines, 0);
            }
            _ => {}
        }
    }

    fn adr_run(&mut self, action: &str) {
        match action {
            "cancel" => self.back(),
            "run" => {
                let proj = self.form_val("project");
                let act = self.form_val("action");
                let file = self.form_val("content file (for update)");
                if proj.is_empty() {
                    self.msg = "choose a project first".into();
                    return;
                }
                if act == "update" {
                    let content = std::fs::read_to_string(&file).unwrap_or_else(|e| {
                        self.msg = format!("content file error: {}", e);
                        String::new()
                    });
                    if self.msg.is_empty() {
                        let args = self.build_args(&[
                            ("project", "str", &proj),
                            ("mode", "str", "update"),
                            ("content", "str", &content),
                        ]);
                        self.start_tool_job("Update ADR", "manage_adr", args);
                    }
                } else {
                    let args = self.build_args(&[("project", "str", &proj), ("mode", "str", &act)]);
                    self.start_tool_job(&format!("ADR {}", act), "manage_adr", args);
                }
            }
            _ => {}
        }
    }

    fn open_config(&mut self) {
        self.load_config_sync();
        self.form_begin("Configuration", FormAction::Config);
        let cfg: Vec<(String, String)> = self.config.clone();
        for (k, v) in &cfg {
            if v == "true" || v == "false" {
                self.form_field(k, v, FieldKind::Choice, vec!["false", "true"]);
            } else {
                self.form_field(k, v, FieldKind::Text, vec![]);
            }
        }
        self.form_field("SAVE ALL", "save", FieldKind::Action, vec![]);
        self.form_field("REFRESH", "refresh", FieldKind::Action, vec![]);
        self.form_field("BACK", "back", FieldKind::Action, vec![]);
        self.menu_hint = "Enter next · ←/→ toggle choice · [SAVE ALL] applies all · esc cancel".into();
        self.push(Screen::Form, Rebuild::None);
    }

    fn open_adr(&mut self) {
        self.form_begin("ADR — architecture decision records", FormAction::Adr);
        self.qf_proj_field();
        self.form_field("action", "get", FieldKind::Choice, vec!["get", "sections", "update"]);
        self.form_field("content file (for update)", "", FieldKind::Text, vec![]);
        self.form_field("RUN", "run", FieldKind::Action, vec![]);
        self.form_field("CANCEL", "cancel", FieldKind::Action, vec![]);
        self.menu_hint = "choose action · Enter next · ←/→ cycle · Enter on [RUN] executes · esc cancel".into();
        self.push(Screen::Form, Rebuild::None);
    }

    fn open_processes(&mut self) {
        self.refresh_processes();
        self.push(Screen::Processes, Rebuild::None);
    }

    fn refresh_processes(&mut self) {
        let mut lines = Vec::new();
        lines.push("== codebase-memory-mcp processes ==".to_string());
        let ps = Command::new("ps")
            .args(["-axo", "pid=,pcpu=,pmem=,rss=,etime=,command="])
            .output();
        if let Ok(o) = ps {
            let text = String::from_utf8_lossy(&o.stdout).to_string();
            let mut total = 0u64;
            let mut n = 0u64;
            for line in text.lines() {
                if !line.contains("codebase-memory-mcp") || line.contains("grep ") {
                    continue;
                }
                let mut it = line.split_whitespace();
                let pid = it.next().unwrap_or("");
                let cpu = it.next().unwrap_or("");
                let mem = it.next().unwrap_or("");
                let rss = it.next().and_then(|r| r.parse::<u64>().ok()).unwrap_or(0);
                let et = it.next().unwrap_or("");
                let cmd = it.collect::<Vec<_>>().join(" ");
                total += rss;
                n += 1;
                lines.push(format!(
                    "  pid {:<7} cpu {:>5}%  mem {:>4}%  rss {:<9}  time {:<9}  {}",
                    pid,
                    cpu,
                    mem,
                    human_size(rss * 1024),
                    et,
                    cmd
                ));
            }
            lines.push(if n == 0 {
                "  no processes".to_string()
            } else {
                format!("  processes: {}   total rss: {}", n, human_size(total * 1024))
            });
        }
        lines.push(String::new());
        lines.push("== artifacts in cache ==".to_string());
        let cache = std::env::var("CBM_CACHE_DIR")
            .unwrap_or_else(|_| format!("{}/.cache/codebase-memory-mcp", std::env::var("HOME").unwrap_or_default()));
        if let Ok(o) = Command::new("du").arg("-sh").arg(&cache).output() {
            let t = String::from_utf8_lossy(&o.stdout).trim().to_string();
            lines.push(format!("  cache total: {}", if t.is_empty() { "n/a".into() } else { t }));
        }
        if let Ok(o) = Command::new("find")
            .arg(&cache)
            .args(["-maxdepth", "1", "-name", "*.db", "-exec", "du", "-sh", "{}", ";"])
            .output()
        {
            for line in String::from_utf8_lossy(&o.stdout).lines() {
                lines.push(format!("  {}", line));
            }
        }
        self.proc_lines = lines;
        self.proc_scroll = 0;
    }

    // ── key handling ──
    fn on_key(&mut self, key: KeyEvent) {
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        match key.code {
            KeyCode::Char('c') if ctrl => {
                self.running = false;
                return;
            }
            _ => {}
        }
        self.msg.clear();
        match self.screen {
            Screen::Menu => self.key_menu(key),
            Screen::Projects => self.key_projects(key),
            Screen::Form => self.key_form(key),
            Screen::Output => self.key_output(key),
            Screen::Busy => {
                if key.code == KeyCode::Esc {
                    self.back();
                }
            }
            Screen::Confirm => self.key_confirm(key),
            Screen::Input => self.key_input(key),
            Screen::Processes => self.key_processes(key),
        }
    }

    fn key_menu(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Up => {
                if self.menu_cursor > 0 {
                    self.menu_cursor -= 1;
                }
            }
            KeyCode::Down => {
                if self.menu_cursor + 1 < self.menu_items.len() {
                    self.menu_cursor += 1;
                }
            }
            KeyCode::Enter => self.menu_select(self.menu_cursor),
            KeyCode::Esc => {
                if self.menu_action != MenuAction::Main {
                    self.back();
                }
            }
            KeyCode::Char(c) => {
                if self.menu_action == MenuAction::Main {
                    if let Some(d) = c.to_digit(10) {
                        if d >= 1 && d <= 8 {
                            self.menu_select((d - 1) as usize);
                        } else if d == 0 {
                            self.menu_select(8);
                        }
                    }
                    if c == 'q' {
                        self.running = false;
                    }
                }
            }
            _ => {}
        }
    }

    fn menu_select(&mut self, idx: usize) {
        match self.menu_action {
            MenuAction::Main => self.main_enter(idx),
            MenuAction::Paction => self.paction_enter(idx),
            MenuAction::Server => self.server_enter(idx),
            MenuAction::Qmenu => self.qmenu_enter(idx),
            MenuAction::Maint => self.maint_enter(idx),
        }
    }

    fn key_projects(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Up => {
                if self.menu_cursor > 0 {
                    self.menu_cursor -= 1;
                }
            }
            KeyCode::Down => {
                if self.menu_cursor + 1 < self.projects.len() {
                    self.menu_cursor += 1;
                }
            }
            KeyCode::Enter => {
                if !self.projects.is_empty() {
                    self.sel_project = Some(self.menu_cursor);
                    self.push(Screen::Menu, Rebuild::Pactions);
                    self.build_pactions();
                }
            }
            KeyCode::Char('r') => self.load_projects_sync(),
            KeyCode::Char('n') => self.open_scan(),
            KeyCode::Char('d') => {
                if let Some(p) = self.projects.get(self.menu_cursor) {
                    self.sel_project = Some(self.menu_cursor);
                    self.confirm_msg = format!(
                        "Delete project '{}'? Its index and graph are removed (irreversible).",
                        p.name
                    );
                    self.confirm_cb = ConfirmCb::DeleteProject;
                    self.push(Screen::Confirm, Rebuild::None);
                }
            }
            KeyCode::Esc => self.back(),
            _ => {}
        }
    }

    fn key_form(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Up => {
                if self.form_cursor > 0 {
                    self.form_cursor -= 1;
                }
            }
            KeyCode::Down | KeyCode::Tab => {
                if self.form_cursor + 1 < self.form_fields.len() {
                    self.form_cursor += 1;
                }
            }
            KeyCode::Left | KeyCode::Right => {
                if self.form_cursor < self.form_fields.len()
                    && self.form_fields[self.form_cursor].kind == FieldKind::Choice
                {
                    self.form_cycle();
                }
            }
            KeyCode::Enter => {
                if self.form_cursor < self.form_fields.len() {
                    let kind = self.form_fields[self.form_cursor].kind;
                    match kind {
                        FieldKind::Action => {
                            let v = self.form_fields[self.form_cursor].value.clone();
                            self.form_dispatch(&v);
                        }
                        FieldKind::Choice => self.form_cycle(),
                        FieldKind::Text => {
                            if self.form_cursor + 1 < self.form_fields.len() {
                                self.form_cursor += 1;
                            }
                        }
                    }
                }
            }
            KeyCode::Char(c) => self.form_type_char(c),
            KeyCode::Backspace => self.form_type_bksp(),
            KeyCode::Esc => self.back(),
            _ => {}
        }
    }

    fn form_dispatch(&mut self, action: &str) {
        match self.form_action {
            FormAction::Scan => self.scan_run(action),
            FormAction::Query => self.query_run(action),
            FormAction::Config => self.config_run(action),
            FormAction::Adr => self.adr_run(action),
        }
    }

    fn form_type_char(&mut self, c: char) {
        let i = self.form_cursor;
        if i >= self.form_fields.len() {
            return;
        }
        if self.form_fields[i].kind == FieldKind::Text {
            self.form_fields[i].value.push(c);
        }
    }

    fn form_type_bksp(&mut self) {
        let i = self.form_cursor;
        if i >= self.form_fields.len() {
            return;
        }
        if self.form_fields[i].kind == FieldKind::Text {
            self.form_fields[i].value.pop();
        }
    }

    fn key_output(&mut self, key: KeyEvent) {
        let max = self.out_lines.len().saturating_sub(self.output_visible());
        match key.code {
            KeyCode::Up => {
                if self.out_scroll > 0 {
                    self.out_scroll -= 1;
                }
            }
            KeyCode::Down => {
                if self.out_scroll < self.out_lines.len().saturating_sub(1) {
                    self.out_scroll += 1;
                }
            }
            KeyCode::PageUp => self.out_scroll = self.out_scroll.saturating_sub(10),
            KeyCode::PageDown => {
                self.out_scroll = (self.out_scroll + 10).min(max);
            }
            KeyCode::Home => self.out_scroll = 0,
            KeyCode::End => self.out_scroll = max,
            KeyCode::Enter | KeyCode::Esc | KeyCode::Char('q') => self.back(),
            _ => {}
        }
    }

    fn output_visible(&self) -> usize {
        30
    }

    fn key_confirm(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Char('y') | KeyCode::Char('Y') => match self.confirm_cb {
                ConfirmCb::DeleteProject => {
                    let Some(pi) = self.sel_project else {
                        self.back();
                        return;
                    };
                    let proj = self.projects.get(pi).map(|p| p.name.clone()).unwrap_or_default();
                    let args = self.build_args(&[("project", "str", &proj)]);
                    self.start_tool_job(&format!("Deleting {}", proj), "delete_project", args);
                    self.job_title = format!("Deleting {}", proj);
                }
            },
            KeyCode::Char('n') | KeyCode::Char('N') | KeyCode::Esc => self.back(),
            _ => {}
        }
    }

    fn key_input(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Enter => {
                let v = self.input_value.clone();
                match self.input_cb {
                    InputCb::ServerPort => {
                        let _ = Command::new(cbm_bin()).args(["config", "set", "ui_port", &v]).output();
                        self.load_config_sync();
                        self.back();
                    }
                }
            }
            KeyCode::Esc => self.back(),
            KeyCode::Backspace => {
                self.input_value.pop();
            }
            KeyCode::Char(c) => self.input_value.push(c),
            _ => {}
        }
    }

    fn key_processes(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Up => {
                if self.proc_scroll > 0 {
                    self.proc_scroll -= 1;
                }
            }
            KeyCode::Down => {
                if self.proc_scroll + 1 < self.proc_lines.len() {
                    self.proc_scroll += 1;
                }
            }
            KeyCode::Char('r') => self.refresh_processes(),
            KeyCode::Esc | KeyCode::Char('q') => self.back(),
            _ => {}
        }
    }

    fn do_delete_done(&mut self) {
        self.load_projects_sync();
        self.sel_project = None;
        self.restart_at(Screen::Projects);
    }

    // ── per-frame tick: poll background jobs ──
    fn tick(&mut self) {
        self.tick_c += 1;
        while let Ok(msg) = self.rx.try_recv() {
            match msg {
                Msg::Job(res) => {
                    let code = res.code;
                    self.job_active = false;
                    let title = self.job_title.clone();
                    // after a delete, go back to the projects list
                    if title.starts_with("Deleting ") {
                        self.do_delete_done();
                        continue;
                    }
                    self.show_output(title, res.lines, code);
                }
                Msg::Projects(res) => {
                    self.projects = parse_projects(&res.lines.join("\n"));
                    self.projects_loaded = true;
                }
                Msg::Config(res) => {
                    self.config = parse_config(&res.lines.join("\n"));
                    self.config_loaded = true;
                }
            }
        }
        if self.screen == Screen::Processes && self.tick_c % 40 == 0 {
            self.refresh_processes();
        }
    }

    // ── rendering ──
    fn render(&mut self, frame: &mut Frame) {
        let area = frame.area();
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Length(1), Constraint::Min(1), Constraint::Length(1)])
            .split(area);
        self.render_title(frame, chunks[0]);
        self.render_body(frame, chunks[1]);
        self.render_footer(frame, chunks[2]);
    }

    fn render_title(&self, frame: &mut Frame, area: Rect) {
        let (title, sub) = match self.screen {
            Screen::Menu => (self.menu_title.clone(), self.menu_sub.clone()),
            Screen::Projects => ("Indexed projects".to_string(), String::new()),
            Screen::Form => (self.form_title.clone(), String::new()),
            Screen::Output => (self.out_title.clone(), String::new()),
            Screen::Busy => (self.job_title.clone(), String::new()),
            Screen::Confirm => ("Confirm".to_string(), String::new()),
            Screen::Input => ("Input".to_string(), String::new()),
            Screen::Processes => ("Processes & resources".to_string(), String::new()),
        };
        let mut title = format!(" {} ", title);
        if !sub.is_empty() {
            title.push_str(&format!("   {}", sub));
        }
        let block = Block::default()
            .borders(Borders::BOTTOM)
            .style(Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD));
        let p = Paragraph::new(Line::from(Span::styled(title, Style::default().fg(Color::Cyan))));
        frame.render_widget(p.block(block), area);
    }

    fn render_body(&mut self, frame: &mut Frame, area: Rect) {
        match self.screen {
            Screen::Menu => self.render_menu(frame, area),
            Screen::Projects => self.render_projects(frame, area),
            Screen::Form => self.render_form(frame, area),
            Screen::Output => self.render_output(frame, area),
            Screen::Busy => self.render_busy(frame, area),
            Screen::Confirm => self.render_confirm(frame, area),
            Screen::Input => self.render_input(frame, area),
            Screen::Processes => self.render_processes(frame, area),
        }
    }

    fn render_menu(&self, frame: &mut Frame, area: Rect) {
        let mut state = ListState::default();
        state.select(Some(self.menu_cursor));
        let items: Vec<ListItem> = self
            .menu_items
            .iter()
            .map(|item| ListItem::new(Line::from(format!("  {}", item))))
            .collect();
        let list = List::new(items)
            .block(Block::default().borders(Borders::NONE))
            .highlight_style(Style::default().add_modifier(Modifier::REVERSED))
            .highlight_symbol("> ");
        frame.render_stateful_widget(list, area, &mut state);
    }

    fn render_projects(&self, frame: &mut Frame, area: Rect) {
        let name_w = if self.projects.iter().any(|p| p.name.chars().count() > 44) { 46 } else { 46 };
        let widths = [
            Constraint::Length(name_w as u16),
            Constraint::Length(9),
            Constraint::Length(9),
            Constraint::Length(9),
            Constraint::Length(9),
        ];
        let mut rows = Vec::new();
        for p in &self.projects {
            let mut n = p.name.clone();
            if n.chars().count() > 44 {
                let truncated: String = n.chars().take(42).collect();
                n = format!("{}..", truncated);
            }
            rows.push(ratatui::widgets::Row::new(vec![
                Cell::from(n),
                Cell::from(p.branch.clone()),
                Cell::from(p.nodes.to_string()),
                Cell::from(p.edges.to_string()),
                Cell::from(human_size(p.size)),
            ]));
        }
        if rows.is_empty() {
            rows.push(ratatui::widgets::Row::new(vec![
                Cell::from(if self.projects_loaded {
                    "no indexed projects yet — press n to scan one"
                } else {
                    "loading projects…"
                }),
                Cell::from(""),
                Cell::from(""),
                Cell::from(""),
                Cell::from(""),
            ]));
        }
        let mut state = ratatui::widgets::TableState::default();
        state.select(if self.projects.is_empty() { None } else { Some(self.menu_cursor) });
        let table = Table::new(rows, widths).header(ratatui::widgets::Row::new(vec![
            Cell::from("name").style(Style::default().add_modifier(Modifier::BOLD)),
            Cell::from("branch").style(Style::default().add_modifier(Modifier::BOLD)),
            Cell::from("nodes").style(Style::default().add_modifier(Modifier::BOLD)),
            Cell::from("edges").style(Style::default().add_modifier(Modifier::BOLD)),
            Cell::from("size").style(Style::default().add_modifier(Modifier::BOLD)),
        ]))
        .row_highlight_style(Style::default().add_modifier(Modifier::REVERSED));
        frame.render_stateful_widget(table, area, &mut state);
    }

    fn render_form(&self, frame: &mut Frame, area: Rect) {
        let mut lines = Vec::new();
        for (i, f) in self.form_fields.iter().enumerate() {
            let (styled, text): (Style, String) = match f.kind {
                FieldKind::Action => (Style::default().fg(Color::Yellow), format!("  [ {} ]", f.label)),
                _ => {
                    let style = if i == self.form_cursor {
                        Style::default().add_modifier(Modifier::REVERSED)
                    } else {
                        Style::default()
                    };
                    (style, format!("  {}: {}", f.label, f.value))
                }
            };
            let span = Span::styled(text, styled);
            lines.push(Line::from(span));
        }
        let p = Paragraph::new(lines).wrap(Wrap { trim: false });
        frame.render_widget(p, area);
    }

    fn render_output(&self, frame: &mut Frame, area: Rect) {
        let lines: Vec<Line> = self
            .out_lines
            .iter()
            .skip(self.out_scroll)
            .map(|l| Line::from(l.clone()))
            .collect();
        let p = Paragraph::new(lines).block(Block::default().borders(Borders::NONE));
        frame.render_widget(p, area);
    }

    fn render_busy(&self, frame: &mut Frame, area: Rect) {
        let spin = ['-', '\\', '|', '/'];
        let f = (self.tick_c / 2) as usize % 4;
        let p = Paragraph::new(vec![
            Line::from(format!("  {}  running… (esc: skip waiting, job continues)", spin[f])),
            Line::from("  a background job is executing a codebase-memory-mcp command."),
            Line::from("  long operations (indexing large repos) can take a while."),
        ])
        .style(Style::default().fg(Color::Yellow));
        frame.render_widget(p, area);
    }

    fn render_confirm(&self, frame: &mut Frame, area: Rect) {
        let p = Paragraph::new(vec![
            Line::from(format!("  {}", self.confirm_msg)),
            Line::from(""),
            Line::from("  y: yes   n / esc: no"),
        ]);
        frame.render_widget(p, area);
    }

    fn render_input(&self, frame: &mut Frame, area: Rect) {
        let p = Paragraph::new(vec![
            Line::from(format!("  {}", self.input_label)),
            Line::from(""),
            Line::from(Span::styled(
                format!("  {}", self.input_value),
                Style::default().add_modifier(Modifier::REVERSED),
            )),
            Line::from(""),
            Line::from("  Enter: confirm · Esc: cancel"),
        ]);
        frame.render_widget(p, area);
    }

    fn render_processes(&self, frame: &mut Frame, area: Rect) {
        let lines: Vec<Line> = self
            .proc_lines
            .iter()
            .skip(self.proc_scroll)
            .map(|l| Line::from(l.clone()))
            .collect();
        let p = Paragraph::new(lines).block(Block::default().borders(Borders::NONE));
        frame.render_widget(p, area);
    }

    fn render_footer(&self, frame: &mut Frame, area: Rect) {
        let hint = match self.screen {
            Screen::Form => &self.menu_hint,
            Screen::Projects => "Enter: project actions · n: scan · r: refresh · d: delete · esc: back",
            Screen::Processes => "auto-refreshes · r: refresh · ↑/↓ scroll · esc: back",
            Screen::Output => "↑/↓ · pgup/pgdn · home/end scroll · esc/enter/q back",
            Screen::Confirm => "y: yes · n: no",
            Screen::Input => "type value · enter confirm · esc cancel",
            Screen::Busy => "esc: skip waiting (job continues)",
            Screen::Menu => &self.menu_hint,
        };
        let mut text = format!(" {}", hint);
        if !self.msg.is_empty() {
            text.push_str(&format!("   |   {}", self.msg));
        }
        let block = Block::default()
            .borders(Borders::TOP)
            .style(Style::default().fg(Color::DarkGray));
        let p = Paragraph::new(Line::from(Span::styled(text, Style::default().fg(Color::DarkGray))));
        frame.render_widget(p.block(block), area);
    }
}

fn human_size(b: u64) -> String {
    if b >= 1073741824 {
        format!("{}.{}G", b / 1073741824, (b % 1073741824) / 107374182)
    } else if b >= 1048576 {
        format!("{}.{}M", b / 1048576, (b % 1048576) / 104857)
    } else if b >= 1024 {
        format!("{}K", b / 1024)
    } else {
        format!("{}B", b)
    }
}

// ──────────────────────────────────────────────────────────────────
// Entry point
// ──────────────────────────────────────────────────────────────────

fn main() -> io::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    // passthrough: cbmman cli <tool> [args]
    if args.get(1).map(|s| s.as_str()) == Some("cli") {
        let mut cmd = Command::new(cbm_bin());
        cmd.arg("cli");
        cmd.args(&args[2..]);
        let status = cmd.status()?;
        std::process::exit(status.code().unwrap_or(1));
    }
    if args.get(1).map(|s| s.as_str()) == Some("--version") {
        let mut cmd = Command::new(cbm_bin());
        cmd.arg("--version");
        let status = cmd.status()?;
        std::process::exit(status.code().unwrap_or(1));
    }

    let (tx, rx) = mpsc::channel::<Msg>();
    spawn_load_projects(tx.clone());
    spawn_load_config(tx.clone());

    let mut terminal = ratatui::init();
    let mut app = App::new(rx, tx);
    let res = run_app(&mut terminal, &mut app);
    ratatui::restore();
    res
}

fn run_app(terminal: &mut Terminal<ratatui::backend::CrosstermBackend<std::io::Stdout>>, app: &mut App) -> io::Result<()> {
    while app.running {
        terminal.draw(|f| app.render(f))?;
        if event::poll(Duration::from_millis(100))? {
            if let Event::Key(key) = event::read()? {
                if key.kind == KeyEventKind::Press {
                    app.on_key(key);
                }
            }
        }
        app.tick();
    }
    Ok(())
}
