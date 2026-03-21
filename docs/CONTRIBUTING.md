# Contributing to OrbitDock

Thanks for your interest in contributing. OrbitDock has two main codebases: SwiftUI clients (macOS + iOS) and a Rust server (REST API + WebSocket).

## Prerequisites

- macOS 15.0+
- Xcode 16+
- Rust toolchain (`rustup` — install from [rustup.rs](https://rustup.rs))
- At least one CLI installed (Claude Code or Codex CLI)

## Getting Started

```bash
git clone https://github.com/Robdel12/OrbitDock.git
cd OrbitDock
```

### SwiftUI Clients

```bash
open OrbitDockNative/OrbitDock.xcodeproj
```

Select your team in **Signing & Capabilities** (or "Sign to Run Locally" for a personal team), then run either the `OrbitDock` macOS scheme or `OrbitDock iOS`. The clients can connect to one or many `orbitdock` server endpoints.

Start with [OrbitDockNative/README.md](../OrbitDockNative/README.md) for the client module map and feature placement guide.

For durable client-side guardrails, read [SWIFT_CLIENT_ARCHITECTURE.md](SWIFT_CLIENT_ARCHITECTURE.md) before adding new shared state, routing, or cross-feature coordination.

For the shorter “how should new client code feel?” version, read [CLIENT_DESIGN_PRINCIPLES.md](CLIENT_DESIGN_PRINCIPLES.md).

For the day-to-day repo workflow, commands, and testing expectations, read [repo-workflow.md](repo-workflow.md).

For the architecture and persistence rules that shape most changes, read [engineering-guardrails.md](engineering-guardrails.md).

For local server setup, file locations, and CLI basics, read [local-development.md](local-development.md).

For logs, hook checks, and database inspection, read [debugging.md](debugging.md).

### Rust Server

```bash
cd orbitdock-server
make rust-build
make rust-test
```

By default the server listens on `ws://127.0.0.1:4000/ws`. For development, run it standalone and add it as an endpoint in app settings.

For persistence rules and migration guidance, read [database-and-persistence.md](database-and-persistence.md).

### Hook transport (testing)

With the server running (`make rust-run`), test hook forwarding directly:

```bash
echo '{"session_id":"test","cwd":"/tmp","model":"claude-opus-4-6","source":"startup"}' \
  | orbitdock hook-forward claude_session_start
```

## Project Layout

```
├── orbitdock-server/            # Rust server (REST API + WebSocket)
│   └── crates/
│       ├── server/              # Actors, registry, transitions, persistence
│       ├── protocol/            # Client ↔ server message types
│       └── connectors/          # Provider connectors (codex-rs)
├── OrbitDockNative/             # Xcode project + SwiftUI app
│   ├── OrbitDock/               # SwiftUI app
│   │   ├── Views/               # All UI
│   │   │   ├── Sessions/        # Shared direct-session UI (composer, capability controls)
│   │   │   ├── SessionDetail/   # Session detail shell and chrome
│   │   │   ├── Conversation/    # Conversation hosts and renderers
│   │   │   ├── Review/          # Review canvas (magit-style diffs)
│   │   │   ├── NewSession/      # Session creation flow
│   │   │   ├── QuickSwitcher/   # Command palette / session switching
│   │   │   ├── Settings/        # Settings feature family
│   │   │   ├── Providers/       # Provider-only controls
│   │   │   ├── ToolCards/       # Tool execution cards
│   │   │   ├── Dashboard/       # Dashboard components
│   │   │   ├── Usage/           # Rate limit gauges
│   │   │   ├── Toast/           # Notification toasts
│   │   │   └── Components/      # Shared presentation components
│   │   ├── Services/            # Endpoint runtimes, transport, session orchestration
│   │   │   └── Server/          # Typed clients, EventStream, SessionStore, runtime registry
│   │   └── Models/              # Data models + protocol types
│   └── OrbitDockCore/           # Swift Package (shared models)
├── migrations/                  # Database migrations (SQL)
└── plans/                       # Living design docs and roadmaps
```

## Key Patterns

### Swift App

**State management** — Keep state endpoint-scoped. Cache values by scoped session identity (endpoint + session ID) to prevent cross-server bleeding. Always guard async callbacks with a current scoped-id check.

**Per-session observation** — `SessionObservable` is a per-session `@Observable` class. Access via `serverState.session(scopedId)`. Views observe only the session they display.

**Theme colors** — Always use the cosmic palette from `Theme.swift`. Never use system colors (`.blue`, `.green`, `.purple`). Never use `.foregroundStyle(.tertiary)` or `.foregroundStyle(.quaternary)` — use `Color.textTertiary` / `Color.textQuaternary` instead. See `AGENTS.md` and `docs/UI_CROSS_PLATFORM_GUIDELINES.md` for UI system rules.

**Animations** — Use `.spring(response: 0.35, dampingFraction: 0.8)`. No timers for animations — SwiftUI's declarative animation system only.

### Rust Server

**Actor model** — Each session gets its own `SessionActor` task. External callers use `SessionActorHandle` which sends commands over mpsc. Lock-free reads via `ArcSwap<SessionSnapshot>`.

**Pure transitions** — All business logic lives in `transition(state, input, now) -> (state, effects)`. No IO in the transition function — it's pure and synchronous. Effects are executed by the actor after transitioning.

**Registry** — `SessionRegistry` backed by `DashMap` for sharded, lock-free lookups. No global mutex.

**Broadcast** — `tokio::broadcast` for event fan-out. One slow client never blocks others.

### Database

**WAL mode required** — All SQLite connections owned by the Rust server must use `PRAGMA journal_mode = WAL` and `PRAGMA busy_timeout = 5000`.

**Migrations** — The Rust server owns schema changes. OrbitDock uses `refinery`, and migration files live in `migrations/` with the `VNNN__description.sql` naming convention. When adding a migration:

1. Create `migrations/VNNN__description.sql`
2. Update the Rust persistence path if the new schema needs new reads or writes
3. Update protocol types if the new field needs to reach the app
4. Run `make rust-test`

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
