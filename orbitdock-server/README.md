# OrbitDock Server

The Rust backend behind OrbitDock. Handles realtime session management over WebSocket, serves REST APIs for bootstrap/read flows, runs Codex sessions directly via codex-core, and keeps business logic in a pure state machine.

Runs as a **standalone binary** you can drop on any macOS or Linux box. OrbitDock macOS and iOS clients use HTTP + WebSocket and may connect to multiple servers at once.

## Getting Started

### Install in One Line

Install the server without building or running the macOS app:

```bash
curl -fsSL https://raw.githubusercontent.com/Robdel12/OrbitDock/main/orbitdock-server/install.sh | bash
```

The installer:

- Downloads a prebuilt binary from GitHub Releases when available
- Verifies SHA-256 checksums when checksum files are present
- Installs `orbitdock-server` to `~/.orbitdock/bin/`
- Runs `orbitdock-server init`
- Runs `orbitdock-server install-hooks`
- Runs `orbitdock-server install-service --enable`

Optional flags:

- `ORBITDOCK_SKIP_HOOKS=1` skip Claude hook setup
- `ORBITDOCK_SKIP_SERVICE=1` skip launchd/systemd install
- `ORBITDOCK_SERVER_VERSION=<tag>` install a specific release (for example `v1.2.3`)
- `ORBITDOCK_FORCE_SOURCE=1` skip prebuilt download and build from source with Cargo
- `ORBITDOCK_SERVER_REF=<branch>` source fallback branch (default: `main`)

### Standalone Setup

The binary is fully self-contained — database migrations are baked in at compile time. No source tree, no Xcode, no app bundle.

```bash
# Bootstrap everything: data dir, database, hook script
orbitdock-server init

# Wire up Claude Code hooks (you'll need Claude Code installed already)
orbitdock-server install-hooks

# Start the server
orbitdock-server start
```

That's it. Codex direct sessions work immediately — the server embeds codex-core, so you can create and control Codex sessions without a separate CLI install.

### Running Remotely

For a dev server or headless machine:

```bash
# Generate an auth token first
orbitdock-server generate-token

# Bind to all interfaces with auth
orbitdock-server start --bind 0.0.0.0:4000 --auth-token $(cat ~/.orbitdock/auth-token)
```

Or run it as a system service so it survives reboots:

```bash
orbitdock-server install-service --enable --bind 0.0.0.0:4000
```

This generates a launchd plist on macOS or a systemd unit on Linux.

### OrbitDock Client Connectivity

Clients connect to:

- WebSocket (default local endpoint: `ws://127.0.0.1:4000/ws`) for realtime subscriptions/events
- HTTP (default local endpoint: `http://127.0.0.1:4000/api/...`) for bootstrap/read requests

Clients can keep multiple endpoints connected simultaneously.

The server also accepts control-plane metadata from clients:

- `set_server_role` - mark this server as primary/secondary server metadata
- `set_client_primary_claim` - register whether a specific client device currently treats this server as its control plane

Usage reads are served via HTTP (`GET /api/usage/*`) and return `not_control_plane_endpoint` when the endpoint is not primary.

## CLI Reference

```
orbitdock-server [--data-dir PATH] <command>
```

| Command | What it does |
|---------|-------------|
| `start` | Start the server (also the default when you omit the subcommand) |
| `init` | Create data directory, run migrations, install hook script |
| `install-hooks` | Merge OrbitDock hooks into `~/.claude/settings.json` |
| `install-service` | Generate a launchd plist (macOS) or systemd unit (Linux) |
| `status` | Check if the server is running |
| `generate-token` | Create a random auth token |

`--data-dir` is global — it applies to every subcommand. You can also set it via `ORBITDOCK_DATA_DIR`.

### Backward Compatibility

The old form still works:

```bash
orbitdock-server --bind 127.0.0.1:4000   # same as: orbitdock-server start --bind ...
```

## Architecture

```
┌───────────────────────────────────────────────────────────────┐
│                    orbitdock-server                             │
│                                                                │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │                 Axum HTTP + WebSocket                     │  │
│  │  GET /ws      → WebSocket upgrade                        │  │
│  │  POST /api/hook → Claude Code hook events                │  │
│  │  GET /api/sessions → Session summaries (REST bootstrap)  │  │
│  │  GET /api/sessions/{session_id} → Full session state      │  │
│  │  GET /api/approvals, DELETE /api/approvals/{approval_id}  │  │
│  │  GET /api/server/openai-key, /api/usage/*, /api/models/* │  │
│  │  GET /api/codex/account, /api/fs/*, /api/sessions/*/...  │  │
│  │  GET /health  → Health check                             │  │
│  └────────────────────────┬────────────────────────────────┘  │
│                           │                                    │
│                           ▼                                    │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │              SessionRegistry (DashMap)                    │  │
│  │     Lock-free, sharded session lookup + list broadcast   │  │
│  └────────────────────────┬────────────────────────────────┘  │
│                           │                                    │
│              ┌────────────┼────────────┐                      │
│              ▼            ▼            ▼                       │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐            │
│  │ SessionActor│ │ SessionActor│ │ SessionActor│  ...        │
│  │  (task A)   │ │  (task B)   │ │  (task C)   │            │
│  └──────┬──────┘ └──────┬──────┘ └──────┬──────┘            │
│         │               │               │                     │
│         ▼               ▼               ▼                     │
│  ┌──────────────────────────────────────────────────────┐    │
│  │              transition(state, input) → effects       │    │
│  │              Pure function — no IO, no async           │    │
│  └──────────────────────────────────────────────────────┘    │
│         │               │               │                     │
│         ▼               ▼               ▼                     │
│  ┌─────────────┐ ┌─────────────┐ ┌──────────────┐           │
│  │   Codex     │ │   Claude    │ │  Persistence  │           │
│  │  Connector  │ │   Session   │ │   Writer      │           │
│  │ (codex-rs)  │ │ (hooks/FS)  │ │  (SQLite)     │           │
│  └─────────────┘ └─────────────┘ └──────────────┘           │
└───────────────────────────────────────────────────────────────┘
```

### Why This Design

**Actor-per-session** — Each session gets its own tokio task. Callers interact through `SessionActorHandle` which sends commands over mpsc. No cross-session contention.

**Lock-free reads** — Session state publishes to `ArcSwap<SessionSnapshot>` after every command. WebSocket handlers read snapshots without locks.

**Pure transitions** — All business logic lives in `transition(state, input) -> (state, effects)`. No IO, no async, no locking. The actor runs effects after transitioning. This makes everything unit-testable.

**Broadcast fan-out** — `tokio::broadcast` distributes events. One slow client can't block others.

**Revision tracking** — Each session has a monotonic revision counter. Clients send `since_revision` on subscribe and get incremental replay instead of a full snapshot.

## Crates

```
orbitdock-server/crates/
├── server/        # Binary — actors, registry, persistence, WebSocket, CLI
├── protocol/      # Shared types for client ↔ server messages
└── connectors/    # AI provider connectors (codex-rs integration)
```

### server

The main binary. Key modules:

| Module | What it does |
|--------|---------|
| `main.rs` | CLI subcommands, startup, session restoration, Axum routing |
| `paths.rs` | Central data dir resolution (`--data-dir` / env / default) |
| `auth.rs` | Optional Bearer token middleware for `/ws` and `/api/hook` |
| `websocket.rs` | WebSocket message handling — routing, no locks |
| `session_actor.rs` | Per-session actor (passive sessions, command dispatch) |
| `codex_session.rs` | Active Codex sessions (connector event loop) |
| `claude_session.rs` | Claude session management (hook-based) |
| `transition.rs` | Pure state machine — `transition(state, input) -> effects` |
| `session_command.rs` | Actor command enum + persistence ops |
| `session.rs` | `SessionHandle` — owned state within an actor task |
| `state.rs` | `SessionRegistry` — DashMap + list broadcast |
| `persistence.rs` | Async SQLite writer (batched channel) |
| `migration_runner.rs` | Embedded migrations via `include_str!` |
| `rollout_watcher.rs` | FSEvents watcher for Codex rollout files |
| `cmd_init.rs` | `init` — bootstrap dirs, DB, hook script |
| `cmd_install_hooks.rs` | `install-hooks` — merge into Claude settings.json |
| `cmd_install_service.rs` | `install-service` — launchd/systemd generation |
| `cmd_status.rs` | `status` + `generate-token` |

### protocol

Shared message types for server and client (Swift app):

- `ClientMessage` / `ServerMessage` — tagged JSON enums
- `SessionState`, `SessionSummary`, `StateChanges`
- `Message`, `TokenUsage`, `ApprovalRequest`
- `TokenUsageSnapshotKind` — explicit semantics for token snapshots (context vs totals)

Usage architecture reference:
- `docs/token-context-architecture.md`

### connectors

AI provider integrations:

- `codex.rs` — Direct Codex via codex-core. Spawns sessions, translates events to `ConnectorEvent`.
- `claude.rs` — Claude session types (hook-based, no direct connector)

## State Machine

The `WorkPhase` enum models each session's lifecycle:

```
          TurnStarted
   Idle ──────────────► Working
    ▲                      │
    │  TurnCompleted       │  ApprovalRequested
    │                      ▼
    │               AwaitingApproval
    │                      │
    │  Approved/Denied     │
    └──────────────────────┘

   Any phase ──SessionEnded──► Ended
```

These map to the wire `WorkStatus` that clients see:
- `Idle` → `Waiting` (reply/question)
- `Working` → `Working`
- `AwaitingApproval` → `Permission` or `Question`
- `Ended` → `Ended`

Each session maintains a monotonic `approval_version` counter that increments on every approval state change (enqueue, decide, clear). All approval-related messages include this version so clients can reject stale or out-of-order events. See `session.rs` for queue management and `codex_session.rs` for version injection.

## WebSocket Protocol

JSON over WebSocket at `ws://127.0.0.1:4000/ws`.

For the HTTP contract (endpoints + payloads), see `docs/API.md`.
For transport rationale and migration notes, see `docs/api-transport-split.md`.

WebSocket is reserved for:

- subscriptions (`subscribe_list`, `subscribe_session`, `unsubscribe_session`)
- command/actions (create/send/approve/interrupt/etc.)
- realtime events (`session_delta`, `message_appended`, `approval_requested`, ...)

Read/list utility requests now live on HTTP. Legacy WS request/response variants return
`error.code = "http_only_endpoint"`.

### Handshake

The server sends a `hello` immediately on connect:

```json
{ "type": "hello", "version": "0.1.0", "protocol_version": 1 }
```

If auth is enabled, pass the token as a query param:

```
ws://127.0.0.1:4000/ws?token=<your-token>
```

### Client → Server

**Subscriptions:**

```json
{ "type": "subscribe_list" }
{ "type": "subscribe_session", "session_id": "...", "since_revision": 42 }
{ "type": "subscribe_session", "session_id": "...", "since_revision": 42, "include_snapshot": false }
{ "type": "unsubscribe_session", "session_id": "..." }
```

**Session actions:**

```json
{ "type": "create_session", "provider": "codex", "cwd": "/path", "model": "o3" }
{ "type": "resume_session", "session_id": "..." }
{ "type": "fork_session", "source_session_id": "...", "nth_user_message": 3 }
{ "type": "send_message", "session_id": "...", "content": "..." }
{ "type": "steer_turn", "session_id": "...", "content": "use postgres instead", "images": [], "mentions": [] }
{ "type": "approve_tool", "session_id": "...", "request_id": "...", "decision": "approved" }
{ "type": "answer_question", "session_id": "...", "request_id": "...", "answer": "yes" }
{ "type": "interrupt_session", "session_id": "..." }
{ "type": "end_session", "session_id": "..." }
```

**Context management:**

```json
{ "type": "compact_context", "session_id": "..." }
{ "type": "undo_last_turn", "session_id": "..." }
{ "type": "rollback_turns", "session_id": "...", "num_turns": 3 }
```

**Shell execution:**

```json
{ "type": "execute_shell", "session_id": "...", "command": "ls -la", "timeout_secs": 30 }
```

**Review comments:**

```json
{ "type": "create_review_comment", "session_id": "...", "file_path": "src/main.rs", "line_start": 42, "body": "This needs error handling" }
{ "type": "update_review_comment", "comment_id": "...", "status": "resolved" }
{ "type": "delete_review_comment", "comment_id": "..." }
```

List review comments over HTTP:

```http
GET /api/sessions/{session_id}/review-comments
```

**Claude hook transport** (how `hook.sh` delivers events):

```json
{ "type": "claude_session_start", "session_id": "...", "cwd": "...", "model": "opus" }
{ "type": "claude_session_end", "session_id": "...", "reason": "user_ended" }
{ "type": "claude_status_event", "session_id": "...", "hook_event_name": "UserPromptSubmit" }
{ "type": "claude_tool_event", "session_id": "...", "hook_event_name": "PreToolUse", "tool_name": "Bash" }
{ "type": "claude_subagent_event", "session_id": "...", "hook_event_name": "SubagentStart", "agent_id": "..." }
```

### Server → Client

```json
{ "type": "hello", "version": "0.1.0", "protocol_version": 1 }
{ "type": "sessions_list", "sessions": [...] }
{ "type": "session_snapshot", "session": {...} }
{ "type": "session_delta", "session_id": "...", "changes": {...} }
{ "type": "message_appended", "session_id": "...", "message": {...} }
{ "type": "message_updated", "session_id": "...", "message_id": "...", "changes": {...} }
{ "type": "approval_requested", "session_id": "...", "request": {...} }
{ "type": "tokens_updated", "session_id": "...", "usage": {...} }
{ "type": "session_created", "session": {...} }
{ "type": "session_ended", "session_id": "...", "reason": "..." }
{ "type": "error", "code": "...", "message": "...", "session_id": "..." }
```

## Data Directory

Everything lives under one directory. Default is `~/.orbitdock/`, override with `--data-dir`.

```
~/.orbitdock/
├── orbitdock.db              # SQLite database (WAL mode)
├── orbitdock.pid             # PID file (created after bind, removed on shutdown)
├── auth-token                # Auth token if generated (0600 permissions)
├── hook.sh                   # Hook script for Claude Code
├── codex-rollout-state.json  # Codex file watcher offsets
├── logs/
│   └── server.log            # Structured JSON logs
└── spool/                    # Queued hook events (drained on startup)
```

## Persistence

SQLite with WAL mode. Writes are batched through an async channel — actors send `PersistCommand` messages, and a dedicated `PersistenceWriter` task flushes them in batches.

Migrations are embedded in the binary via `include_str!` and run at startup. No filesystem access needed.

## Logging

Structured JSON to `<data_dir>/logs/server.log`.

```bash
# Watch live
tail -f ~/.orbitdock/logs/server.log | jq .

# Filter by event
tail -f ~/.orbitdock/logs/server.log | jq 'select(.event == "session.resume.connector_failed")'

# Errors only
tail -f ~/.orbitdock/logs/server.log | jq 'select(.level == "ERROR")'
```

### Environment Variables

| Variable | Description |
|----------|-------------|
| `ORBITDOCK_DATA_DIR` | Data directory (same as `--data-dir`) |
| `ORBITDOCK_BIND_ADDR` | Bind address (same as `--bind`) |
| `ORBITDOCK_AUTH_TOKEN` | Auth token (same as `--auth-token`) |
| `ORBITDOCK_SERVER_LOG_FILTER` | Tracing filter (e.g. `debug,tower_http=warn`) |
| `ORBITDOCK_SERVER_LOG_FORMAT` | `json` (default) or `pretty` |
| `ORBITDOCK_TRUNCATE_SERVER_LOG_ON_START` | Set to `1` to truncate log on boot |

## Building

```bash
cargo build                   # dev build
cargo run -- start            # run locally
cargo run -- status           # check if running
cargo test --workspace        # all tests
```

### Universal Binary (macOS)

```bash
./build-universal.sh
```

Produces `target/universal/orbitdock-server` for both Intel and Apple Silicon.

## Dependencies

| Crate | Why |
|-------|-----|
| `axum` | HTTP/WebSocket server |
| `tokio` | Async runtime + broadcast channels |
| `clap` | CLI parsing + subcommands |
| `dashmap` | Lock-free concurrent HashMap for the session registry |
| `arc-swap` | Wait-free pointer swap for session snapshots |
| `rusqlite` | SQLite (bundled, no system dep) |
| `serde` / `serde_json` | JSON serialization |
| `codex-core` | Direct Codex integration |
| `tracing` | Structured logging |
