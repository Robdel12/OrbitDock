# Contributing to OrbitDock

Thanks for your interest in contributing. OrbitDock has two main codebases: SwiftUI clients (macOS + iOS) and a Rust server (REST API + WebSocket).

## Prerequisites

- macOS 14+
- Xcode 15+
- Rust toolchain (`rustup` — install from [rustup.rs](https://rustup.rs))
- At least one CLI installed (Claude Code or Codex CLI)

## Getting Started

```bash
git clone https://github.com/Robdel12/OrbitDock.git
cd OrbitDock
```

### SwiftUI Clients

```bash
open OrbitDock/OrbitDock.xcodeproj
```

Select your team in **Signing & Capabilities** (or "Sign to Run Locally" for a personal team), then run either the `OrbitDock` macOS scheme or `OrbitDock iOS`. The clients can connect to one or many `orbitdock-server` endpoints.

### Rust Server

```bash
cd orbitdock-server
cargo build
cargo test
```

By default the server listens on `ws://127.0.0.1:4000/ws`. For development, run it standalone and add it as an endpoint in app settings.

### CLI (standalone)

```bash
cd OrbitDock/OrbitDockCore
swift build
echo '{"session_id":"test","cwd":"/tmp","hook_event_name":"Stop"}' | orbitdock-server hook-forward claude_status_event
```

## Project Layout

```
├── orbitdock-server/            # Rust server (REST API + WebSocket)
│   └── crates/
│       ├── server/              # Actors, registry, transitions, persistence
│       ├── protocol/            # Client ↔ server message types
│       └── connectors/          # Provider connectors (codex-rs)
├── OrbitDock/                   # Xcode project
│   ├── OrbitDock/               # SwiftUI app
│   │   ├── Views/               # All UI
│   │   │   ├── Review/          # Review canvas (magit-style diffs)
│   │   │   ├── Codex/           # Direct Codex session UI
│   │   │   ├── Server/          # Server connection views
│   │   │   ├── ToolCards/       # Tool execution cards
│   │   │   ├── Dashboard/       # Dashboard components
│   │   │   ├── Usage/           # Rate limit gauges
│   │   │   ├── Toast/           # Notification toasts
│   │   │   └── Components/      # Shared components
│   │   ├── Services/            # Business logic
│   │   │   ├── ServerAppState.swift      # Server connection + state
│   │   │   ├── SessionObservable.swift   # Per-session @Observable
│   │   │   └── ServerConnection.swift    # REST + WebSocket client
│   │   └── Models/              # Data models + protocol types
│   └── OrbitDockCore/           # Swift Package (shared code)
│       └── Sources/
│           ├── OrbitDockCore/   # Database, git ops, shared models
│           └── OrbitDockCLI/    # CLI hook handlers
├── orbitdock-debug-mcp/         # MCP server (Node.js)
├── migrations/                  # Database migrations (SQL)
└── plans/                       # Design docs and roadmaps
```

## Key Patterns

### Swift App

**State management** — Keep state endpoint-scoped. Cache values by scoped session identity (endpoint + session ID) to prevent cross-server bleeding. Always guard async callbacks with a current scoped-id check.

**Per-session observation** — `SessionObservable` is a per-session `@Observable` class. Access via `serverState.session(scopedId)`. Views observe only the session they display.

**Theme colors** — Always use the cosmic palette from `Theme.swift`. Never use system colors (`.blue`, `.green`, `.purple`). Never use `.foregroundStyle(.tertiary)` or `.foregroundStyle(.quaternary)` — use `Color.textTertiary` / `Color.textQuaternary` instead. See the full design system in `CLAUDE.md`.

**Animations** — Use `.spring(response: 0.35, dampingFraction: 0.8)`. No timers for animations — SwiftUI's declarative animation system only.

### Rust Server

**Actor model** — Each session gets its own `SessionActor` task. External callers use `SessionActorHandle` which sends commands over mpsc. Lock-free reads via `ArcSwap<SessionSnapshot>`.

**Pure transitions** — All business logic lives in `transition(state, input, now) -> (state, effects)`. No IO in the transition function — it's pure and synchronous. Effects are executed by the actor after transitioning.

**Registry** — `SessionRegistry` backed by `DashMap` for sharded, lock-free lookups. No global mutex.

**Broadcast** — `tokio::broadcast` for event fan-out. One slow client never blocks others.

### Database

**WAL mode required** — All SQLite connections must use `PRAGMA journal_mode = WAL` and `PRAGMA busy_timeout = 5000`. This applies to both the Swift app and the CLI.

**Migrations** — Numbered SQL files in `migrations/`. Both the Swift app (`MigrationManager`) and Rust server (`migration_runner.rs`) run migrations automatically at startup. When adding a migration:

1. Create `migrations/NNN_description.sql`
2. Update `Session.swift` if adding session fields
3. Update `DatabaseManager.swift` column definitions
4. Update `CLIDatabase.swift` if the CLI writes the field

## Build Commands

```bash
# App
make build        # Build SwiftUI app (xcodebuild)
make test-unit    # Unit tests only
make test-ui      # UI tests only
make test-all     # Both

# Server
make rust-build   # Build Rust server
make rust-test    # Run all server tests
make rust-check   # cargo check --workspace

# Quality
make fmt          # Format Swift + Rust
make lint         # Lint Swift + Rust
```

## Testing Changes

1. Build the app (`make build` or ⌘R in Xcode)
2. Run `make test-unit` for Swift tests
3. Run `make rust-test` for server tests
4. For Claude integration: start a Claude Code session to trigger hooks
5. For Codex integration: start a Codex session or modify a rollout file
6. Run `make lint` before submitting

## Debugging

```bash
# CLI logs
tail -f ~/.orbitdock/cli.log

# Codex integration logs (structured JSON)
tail -f ~/.orbitdock/logs/codex.log | jq .
tail -f ~/.orbitdock/logs/codex.log | jq 'select(.level == "error")'

# Server logs (structured JSON)
tail -f ~/.orbitdock/logs/server.log | jq .
tail -f ~/.orbitdock/logs/server.log | jq 'select(.level == "ERROR")'

# Database
sqlite3 ~/.orbitdock/orbitdock.db "SELECT id, work_status FROM sessions LIMIT 5;"
```

## Submitting Changes

1. Fork the repo
2. Create a feature branch
3. Make your changes
4. Run `make lint` and `make test-unit`
5. Open a PR with a clear description of what changed and why
