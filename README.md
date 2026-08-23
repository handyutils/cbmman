# cbmman

Interactive TUI manager for **[codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp)** — a human-friendly front end for indexing and querying codebase knowledge graphs.

Two implementations of the same manager:

| Version | File | TUI toolkit | Requirements |
|---|---|---|---|
| Bash | `cbmman.sh` | [tuish](https://github.com/alganet/tuish) | `bash` 4+, `python3`, `git`, `curl` (optional) |
| Rust | `cbmman.rs` | [ratatui](https://github.com/ratatui/ratatui) | `cargo` / Rust toolchain |

Both wrap the full `codebase-memory-mcp` CLI so humans can drive it interactively instead of hand-writing JSON tool calls.

## Features

- **Projects** — list indexed projects (branch, nodes, edges, size), select one, and run per-project actions:
  - index status, architecture overview, index coverage, git-diff impact (`detect_changes`)
  - re-scan, delete
- **Scan / Index** — add a repository with mode (`moderate` / `full` / `fast` / `cross-repo`), optional project-name override, and optional team-shared artifact persistence (`.codebase-memory/graph.db.zst`)
- **Graph server (UI)** — start / stop the graph-visualization server, set the port, open the UI in a browser, live status
- **Processes & resources** — live monitor of every `codebase-memory-mcp` process (CPU, memory, RSS, uptime) plus artifact sizes in the cache directory; auto-refreshing
- **Configuration** — view and edit persisted settings (`auto_index`, `auto_index_limit`, `auto_watch`, `ui_enabled`, `ui_port`, …) with one `SAVE ALL` applying everything
- **Graph queries** — search graph (BM25 / name / semantic), search code, get code snippet, trace call paths, raw Cypher, architecture overview, graph schema, ingest runtime traces
- **ADR management** — get / list sections / update architecture decision records
- **Maintenance** — binary version, CLI help, update, uninstall (dry-run first), cache & diagnostics
- All long-running operations run in the **background** with a spinner; the UI never freezes
- `cli` pass-through mode for scripting

## Quick start

```bash
# make sure the codebase-memory-mcp binary is on your PATH
# (or set CBM_BIN to its location)
codebase-memory-mcp --version

# Bash version (auto-bootstraps tuish into ./tuish on first run)
./cbmman.sh

# Rust version
cargo run --release            # or: cargo build --release
```

### Non-interactive / scripting

```bash
./cbmman.sh cli search_graph '{"project":"my-project","query":"order handler"}'
./cbmman.sh --version
```

## Environment

| Variable | Default | Used by |
|---|---|---|
| `CBM_BIN` | `codebase-memory-mcp` (PATH) | binary location |
| `TUISH_DIR` | `./tuish` | bash version's tuish checkout |
| `CBM_CACHE_DIR` | `~/.cache/codebase-memory-mcp` | process/artifact monitor |

## Keyboard

- `↑` / `↓` navigate, `Enter` select
- `1`–`8`, `0` jump straight to a main-menu item
- `Esc` back one level (no-op on the main menu)
- `q` quit on the main menu, `Ctrl-C` quit anywhere

## Layout

```
├── cbmman.sh      bash + tuish version
├── Cargo.toml     rust build
├── cbmman.rs      rust + ratatui version
├── README.md
└── LICENSE        MIT (c) HandyUtils
```

## License

MIT — see [LICENSE](LICENSE).
