# cbmman

**📖 Docs website: <https://handyutils.github.io/cbmman/>** · [crates.io](https://crates.io/crates/cbmman) · [docs.rs](https://docs.rs/cbmman)

Interactive TUI manager for **[codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp)** — a human-friendly front end for indexing and querying codebase knowledge graphs.

This crate is the **Rust** implementation, built on [ratatui](https://github.com/ratatui/ratatui) + crossterm. A companion **bash** implementation (built on [tuish](https://github.com/alganet/tuish)) lives in the same repository: <https://github.com/handyutils/cbmman>.

## Install

```bash
cargo install cbmman
```

## Run

```bash
# make sure the codebase-memory-mcp binary is on your PATH
# (or set CBM_BIN to its location)
codebase-memory-mcp --version

cbmman
```

## Features

- **Projects** — list indexed projects (branch, nodes, edges, size, full root path), select one, and run per-project actions: index status, architecture overview, index coverage, git-diff impact (`detect_changes`), re-scan, delete
- **Scan / Index** — add a repository with mode (`moderate` / `full` / `fast` / `cross-repo`), optional project-name override, and optional team-shared artifact persistence
- **Graph server (UI)** — start / stop the graph-visualization server, set the port, open the UI in a browser, live status
- **Processes & resources** — live monitor of every `codebase-memory-mcp` process (CPU, memory, RSS, uptime) plus artifact sizes in the cache directory; auto-refreshing
- **Configuration** — view and edit persisted settings (`auto_index`, `auto_index_limit`, `auto_watch`, `ui_enabled`, `ui_port`, …) with one `SAVE ALL`
- **Graph queries** — search graph (BM25 / name / semantic), search code, get code snippet, trace call paths, raw Cypher, architecture overview, graph schema, ingest runtime traces
- **ADR management** — get / list sections / update architecture decision records
- **Maintenance** — binary version, CLI help, update, uninstall (dry-run first), cache & diagnostics
- All long-running operations run in the **background** with a spinner; the UI never freezes
- `cli` pass-through mode for scripting: `cbmman cli search_graph '{"project":"p","query":"q"}'`

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `CBM_BIN` | `codebase-memory-mcp` (PATH) | binary location |
| `CBM_CACHE_DIR` | `~/.cache/codebase-memory-mcp` | process/artifact monitor |

## Keyboard

- `↑` / `↓` navigate, `Enter` select
- `1`–`8`, `0` jump straight to a main-menu item
- `Esc` back one level (no-op on the main menu)
- `q` quit on the main menu, `Ctrl-C` quit anywhere

## License

MIT — see [LICENSE](LICENSE).
