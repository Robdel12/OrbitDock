# Getting Started with OrbitDock

## Prerequisites

- macOS 15.0+
- Xcode 16+
- Rust toolchain (`rustup` — install from [rustup.rs](https://rustup.rs))
- At least one CLI installed (Claude Code or Codex CLI)

## Initial Setup

```bash
git clone https://github.com/Robdel12/OrbitDock.git
cd OrbitDock
```

### Start the Server

```bash
orbitdock init
make rust-run
```

`orbitdock init` creates the data directory, runs migrations, and provisions the local auth token used by hook forwarding and app setup.

Interactive `make rust-run`, `make rust-run-lan`, and `make rust-run-debug` open an in-process dev console by default when attached to a TTY. Set `ORBITDOCK_DEV_CONSOLE=0` if you want the plain terminal experience.

For LAN testing, use `make rust-run-lan`. The server will bind to all interfaces; local clients should connect to `http://127.0.0.1:4000`.

### Build the SwiftUI App

```bash
open OrbitDockNative/OrbitDock.xcodeproj
```

Select your team in **Signing & Capabilities** (or "Sign to Run Locally" for a personal team), then run either the `OrbitDock` macOS scheme or `OrbitDock iOS`.

The app is a client. It does not install or configure the server. Connect to your running local server via the endpoint UI in app settings.

### Native Tooling Cheat Sheet

- iOS simulator run / tap / type / screenshot / logs: `Build iOS Apps` plugin + `build-ios-apps:ios-debugger-agent`
- iOS SwiftUI build patterns: `build-ios-apps:swiftui-ui-patterns`
- iOS SwiftUI cleanup: `build-ios-apps:swiftui-view-refactor`
- iOS SwiftUI perf work: `build-ios-apps:swiftui-performance-audit`
- App Intents / Shortcuts / Siri / Spotlight: `build-ios-apps:ios-app-intents`
- macOS build / run / launch debugging: `Build macOS Apps` plugin + `build-macos-apps:build-run-debug`
- macOS failing tests: `build-macos-apps:test-triage`
- macOS logging / telemetry verification: `build-macos-apps:telemetry`
- AppKit bridges and window behavior: `build-macos-apps:appkit-interop`, `build-macos-apps:window-management`
- Prefer `mcp__xcodebuildmcp__*` tools for simulator control, screenshots, UI snapshots, logs, and Xcode-backed build/test actions

### Build the Rust Server

```bash
cd orbitdock-server
make rust-build
make rust-test
```

By default the server listens on `ws://127.0.0.1:4000/ws`.

## Key Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — Client patterns, server state architecture, and guardrails
- [data-flow.md](data-flow.md) — REST / WebSocket contract
- [OPERATIONS.md](OPERATIONS.md) — Deployment, persistence, debugging, and troubleshooting

Start with ARCHITECTURE.md if you're writing client or server code.

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
├── orbitdock-server/migrations/ # Database migrations (SQL)
└── plans/                       # Living design docs and roadmaps
```

## Daily Commands

From the repo root:

```bash
# App
make build        # Build SwiftUI app (xcodebuild)
make test-unit    # Unit tests only
make test-ui      # UI tests only
make test-all     # Both

# Server
make rust-build   # Build Rust server
make rust-test    # Run all server tests
make rust-check   # Fast compile check
make rust-check-workspace   # Full workspace compile check
make rust-run     # Run server locally
make rust-run-lan # Run server on all interfaces
make rust-run-debug # Run with debug output

# CLI
make cli ARGS='session list'

# Quality
make fmt          # Format Swift + Rust
make lint         # Lint Swift + Rust
```

## Key Patterns

### Swift App

**State management** — Keep state endpoint-scoped. Cache values by scoped session identity (endpoint + session ID) to prevent cross-server bleeding. Always guard async callbacks with a current scoped-id check.

**Per-session observation** — Scope views to single sessions. Access via `serverState.session(scopedId)`. Never share session observables across screens.

**Theme colors** — Always use the cosmic palette from `Theme.swift`. Never use system colors (`.blue`, `.green`, `.purple`). Never use `.foregroundStyle(.tertiary)` — use `Color.textTertiary` instead.

**Animations** — Use `.spring(response: 0.35, dampingFraction: 0.8)`. No timers for animations — use SwiftUI's declarative system only.

### Rust Server

**One mutation path** — Every session state change flows through `ProcessEvent` → pure `transition()` → persist + broadcast. No fire-and-forget mutations, no split persist/broadcast. The database is always the source of truth. See [ARCHITECTURE.md § Server State Architecture](ARCHITECTURE.md#part-2-server-state-architecture) for the full model.

**Actor model** — Each session gets its own actor task. External callers use `SessionActorHandle` which sends commands over mpsc. Lock-free reads via `ArcSwap<SessionSnapshot>`.

**Pure transitions** — All business logic lives in `transition(state, input, now) -> (state, effects)` in `connector-core/src/transition.rs`. No IO in the transition function — it's pure and synchronous. Effects (persist + broadcast) are executed by the actor after transitioning.

**Registry** — `SessionRegistry` backed by `DashMap` for sharded, lock-free lookups. No global mutex.

**Broadcast** — `tokio::broadcast` for event fan-out. One slow client never blocks others.

### Database

**WAL mode required** — All SQLite connections owned by the Rust server must use `PRAGMA journal_mode = WAL` and `PRAGMA busy_timeout = 5000`.

**Migrations** — The Rust server owns schema changes. OrbitDock uses `refinery`, and migration files live in `orbitdock-server/migrations/` with the `VNNN__description.sql` naming convention. When adding a migration:

1. Create `orbitdock-server/migrations/VNNN__description.sql`
2. Update the Rust persistence path if the new schema needs new reads or writes
3. Update protocol types if the new field needs to reach the app
4. Run `make rust-test`

## Important File Locations

All server paths resolve from one data directory:

- `--data-dir`
- `ORBITDOCK_DATA_DIR`
- default `~/.orbitdock`

Common paths:

- server binary: `~/.orbitdock/bin/orbitdock`
- database: `<data_dir>/orbitdock.db`
- auth config: `<data_dir>/hook-forward.json`
- encryption key: `<data_dir>/encryption.key`
- server log: `<data_dir>/logs/server.log`
- codex log: `<data_dir>/logs/codex.log`
- managed sync outbox: `sync_outbox` rows in `<data_dir>/orbitdock.db`
- codex rollout watcher state: `<data_dir>/codex-rollout-state.json`
- launchd plist: `~/Library/LaunchAgents/com.orbitdock.server.plist`

Read-only external inputs:

- Claude transcripts: `~/.claude/projects/<project-hash>/<session-id>.jsonl`
- Codex sessions: `~/.codex/sessions/**/rollout-*.jsonl`

## Hook Transport

Claude Code hooks use `orbitdock hook-forward <type>`. That command injects the event type and POSTs to `/api/hook`.

Hook transport config lives in `<data_dir>/hook-forward.json`.

Hook mapping:

| Claude Hook | Type |
|---|---|
| `SessionStart` | `claude_session_start` |
| `SessionEnd` | `claude_session_end` |
| `UserPromptSubmit`, `Stop`, `Notification`, `PreCompact` | `claude_status_event` |
| `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest` | `claude_tool_event` |
| `SubagentStart`, `SubagentStop` | `claude_subagent_event` |

## CLI Basics

The `orbitdock` binary covers both server admin and client-facing operations.

Useful commands:

```bash
# Server admin
orbitdock init
orbitdock install-hooks
orbitdock start
orbitdock start --managed --workspace-id <WORKSPACE_ID> --sync-url <CONTROL_PLANE_URL> --sync-token <TOKEN>
orbitdock install-service --enable
orbitdock status

# Health and status
orbitdock health
orbitdock server status

# Sessions
orbitdock session list
orbitdock session get <ID>
orbitdock session send <ID> "message"
orbitdock session watch <ID>
orbitdock session interrupt <ID>
orbitdock session end <ID>

# Supporting
orbitdock approval list
orbitdock model list
orbitdock usage show
orbitdock worktree list

# Mission provider management
orbitdock mission provider get
orbitdock mission provider set local
orbitdock mission provider set daytona
orbitdock mission provider config get daytona-api-url
orbitdock mission provider config set daytona-api-url https://daytona.example.com
orbitdock mission provider test
```

Output is human-readable in a TTY and JSON when piped or when you pass `--json`.

Mission provider config commands report the effective value source.
If an `ORBITDOCK_DAYTONA_*` or `ORBITDOCK_PUBLIC_SERVER_URL` env var is set, the command output shows `source=env` to make it clear that persisted settings are currently overridden.

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

## Claude Agent SDK Reference

When you need to reason about Claude Agent SDK behavior, inspect the shipped SDK source in:

`orbitdock-server/docs/node_modules/@anthropic-ai/claude-agent-sdk/`

Use the installed source as the primary reference for plan mode, permissions, hooks, and tool schemas. Treat external docs as secondary if they disagree.
