# cbmman

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
- **Processes & resources** — live monitor of every `codebase-memory-mcp` process (CPU, memory, RSS, uptime) plus artifact sizes in the cache directory; auto-refreshing; **stop / force-kill individual processes** or **kill all CBM processes at once**
- **Configuration** — view and edit persisted settings (`auto_index`, `auto_index_limit`, `auto_watch`, `ui_enabled`, `ui_port`, …) with one `SAVE ALL`
- **Graph queries** — search graph (BM25 / name / semantic), search code, get code snippet, trace call paths, raw Cypher, architecture overview, graph schema, ingest runtime traces
- **ADR management** — get / list sections / update architecture decision records
- **Maintenance** — binary version, CLI help, update, uninstall (dry-run first), cache & diagnostics
- All long-running operations run in the **background** with a spinner; the UI never freezes
- `cli` pass-through mode for scripting: `cbmman cli search_graph '{"project":"p","query":"q"}'`
- **Mouse support** — click menu items, projects, and process rows directly

## Build from source

```bash
git clone https://github.com/handyutils/cbmman.git
cd cbmman
cargo build --release
```

## Build all release targets locally

```bash
./build-all.sh
```

Artifacts are placed in `dist/`.

## Release

CI/CD is configured via GitHub Actions. To publish a new release:

1. Update the version in `Cargo.toml`
2. Commit and push to `main`
3. Create and push a tag:
   ```bash
   git tag v0.1.2
   git push origin v0.1.2
   ```
4. The `Release` workflow builds for all targets and creates a GitHub Release with artifacts:
   - macOS ARM (`aarch64-apple-darwin`)
   - macOS Intel (`x86_64-apple-darwin`)
   - Linux x64 (`x86_64-unknown-linux-gnu`)
   - Linux ARM64 (`aarch64-unknown-linux-gnu`)
   - Windows x64 (`x86_64-pc-windows-msvc`)

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
- Projects screen: `o` open in Terminal, `f` open in Finder, `d` delete, `n` scan, `r` refresh
- Processes screen: `↑/↓` select process, `k` stop selected, `K` force-kill selected, `a` kill all CBM processes, `r` refresh
- **Mouse**: click menu items, projects, and process rows

## License

MIT — see [LICENSE](LICENSE).
