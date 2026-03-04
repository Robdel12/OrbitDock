# OrbitDock Server

The Rust backend behind OrbitDock. Handles realtime session management over WebSocket, serves REST APIs for reads, mutations, and async actions, runs Codex sessions directly via codex-core, and keeps business logic in a pure state machine.

Runs as a **standalone binary** you can drop on any macOS or Linux box. OrbitDock macOS and iOS clients use HTTP + WebSocket and may connect to multiple servers at once.

## Getting Started

### Install in One Line

Install the server without building or running the macOS app:

```bash
curl -fsSL https://raw.githubusercontent.com/Robdel12/OrbitDock/main/orbitdock-server/install.sh | bash
```

The installer downloads a prebuilt binary for macOS, Linux x86_64, and Linux aarch64 (Raspberry Pi 64-bit). Falls back to building from source if no prebuilt is available (requires the [Rust toolchain](https://rustup.rs)).

- Installs `orbitdock` to `~/.orbitdock/bin/`
- Ensures `~/.orbitdock/bin` is on shell `PATH`
- Runs `orbitdock init`
- Runs `orbitdock install-hooks`
- Runs `orbitdock install-service --enable`

Optional flags:

- `--skip-hooks` skip Claude hook setup
- `--skip-service` skip launchd/systemd install
- `--server-url <url>` hooks-only mode for a remote server (skips service install)
- `--version <tag>` install a specific release tag (for example `v1.2.3`)
- `--force-source` skip prebuilt download and build from source with Cargo

### Standalone Setup

The binary is fully self-contained — database migrations are baked in at compile time. No source tree, no Xcode, no app bundle.

```bash
# Bootstrap everything: data dir + database
orbitdock init

# Wire up Claude Code hooks (you'll need Claude Code installed already)
orbitdock install-hooks

# Start the server
orbitdock start
```

That's it. Codex direct sessions work immediately — the server embeds codex-core, so you can create and control Codex sessions without a separate CLI install.

### Running Remotely

For a dev server or headless machine:

```bash
# Interactive setup (generates token, binds 0.0.0.0)
orbitdock setup --remote

# Or manually:
orbitdock generate-token
orbitdock start --bind 0.0.0.0:4000
```

Connect a remote developer machine (hooks only — no local server needed):

```bash
orbitdock install-hooks \
  --server-url https://your-server:4000 \
  --auth-token <token>
```

Or run it as a system service so it survives reboots:

```bash
orbitdock install-service --enable --bind 0.0.0.0:4000
```

### Cloudflare Tunnel

Zero-config HTTPS exposure with no firewall changes:

```bash
# Quick tunnel (temporary URL, no account)
orbitdock tunnel

# Named tunnel (persistent URL, requires cloudflared login)
orbitdock tunnel --name my-tunnel
```

### Native TLS

```bash
orbitdock start \
  --bind 0.0.0.0:4000 \
  --tls-cert /path/to/cert.pem \
  --tls-key /path/to/key.pem
```

### Client Pairing

Generate a connection URL and QR code:

```bash
orbitdock pair --tunnel-url https://your-tunnel.trycloudflare.com
```

For the full deployment guide covering all topologies, security, and operations, see [DEPLOYMENT.md](../docs/DEPLOYMENT.md).

### OrbitDock Client Connectivity

Clients connect to:

- **WebSocket** (`ws://127.0.0.1:4000/ws`) for real-time subscriptions, session interaction (create, send, approve, interrupt), and server-pushed events
- **REST** (`http://127.0.0.1:4000/api/...`) for reads, mutations (config, worktrees, review comments, codex auth), and async fire-and-forget actions (skill download, MCP refresh)

Clients can keep multiple endpoints connected simultaneously.

Control-plane metadata:

- `PUT /api/server/role` — mark this server as primary/secondary (broadcasts `server_info` via WS)
- `set_client_primary_claim` (WS) — register whether a specific client device currently treats this server as its control plane

Usage reads are served via HTTP (`GET /api/usage/*`) and return `not_control_plane_endpoint` when the endpoint is not primary.

### Worktree Include Copying

When creating a worktree via OrbitDock (`POST /api/worktrees` or fork-to-worktree flows), the server checks for `repo_root/.worktreeinclude`.

- Patterns use gitignore syntax.
- A path is copied only when it matches `.worktreeinclude` **and** is git-ignored by standard rules (`.gitignore`, excludes, etc).
- Tracked files are never copied.
- Copying is best-effort per entry: failures are logged, skipped, and do not fail worktree creation.

## CLI Reference

```
orbitdock [--data-dir PATH] <command>
```

| Command | What it does |
|---------|-------------|
| `start` | Start the server (also the default when you omit the subcommand) |
| `setup` | Interactive wizard (init + hooks + token + service) |
| `init` | Create data directory and run migrations |
| `ensure-path` | Persist the server binary directory on your shell `PATH` |
| `install-hooks` | Merge OrbitDock hooks into `~/.claude/settings.json` |
| `install-service` | Generate a launchd plist (macOS) or systemd unit (Linux) |
| `status` | Check if the server is running |
| `generate-token` | Create a secure auth token (stored hashed in DB) |
| `doctor` | Run diagnostics and check system health |
| `tunnel` | Expose the server via Cloudflare Tunnel |
| `pair` | Generate a connection URL and QR code for clients |

`--data-dir` is global — it applies to every subcommand. You can also set it via `ORBITDOCK_DATA_DIR`.

### Backward Compatibility

The old form still works:

```bash
orbitdock --bind 127.0.0.1:4000   # same as: orbitdock start --bind ...
```

## Architecture

```
┌───────────────────────────────────────────────────────────────┐
│                       orbitdock                                 │
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
├── server/            # Binary — orchestration, persistence, WebSocket, CLI
├── protocol/          # Shared types for client ↔ server messages
├── connector-core/    # Provider-agnostic event types + transition state machine
├── connector-codex/   # Codex provider — auth, session types, rollout parser
└── connector-claude/  # Claude provider — session types, CLI protocol parsing
```

### server

The main binary. Provider-agnostic orchestration — it doesn't import codex-core or Claude SDK directly.

| Module | What it does |
|--------|---------|
| `main.rs` | CLI subcommands, startup, session restoration, Axum routing |
| `paths.rs` | Central data dir resolution (`--data-dir` / env / default) |
| `auth.rs` | Optional Bearer token middleware for `/ws` and `/api/hook` |
| `http_api.rs` | REST API endpoints — reads, mutations, async actions |
| `websocket.rs` | WebSocket message handling — subscriptions, session commands, routing |
| `ws_handlers/` | Domain-scoped WS handlers (config, rest_only rejections) |
| `session_actor.rs` | Per-session actor (passive sessions, command dispatch) |
| `session_command_handler.rs` | Shared command + event dispatch (used by both providers) |
| `codex_session.rs` | Codex event loop (thin — delegates to shared dispatch) |
| `claude_session.rs` | Claude event loop (thin — delegates to shared dispatch) |
| `transition.rs` | Re-exports connector-core's state machine + `PersistOp` mapping |
| `session_command.rs` | Actor command enum + persistence ops |
| `session.rs` | `SessionHandle` — owned state within an actor task |
| `state.rs` | `SessionRegistry` — DashMap + list broadcast |
| `persistence.rs` | Async SQLite writer (batched channel) |
| `migration_runner.rs` | Embedded migrations via `include_str!` |
| `rollout_watcher.rs` | FSEvents driver for Codex rollout files (dispatches parsed events) |
| `cmd_*.rs` | CLI subcommands (`init`, `install-hooks`, `setup`, `doctor`, etc.) |
| `metrics.rs` | `/metrics` — Prometheus text format endpoint |

### protocol

Shared message types for server and client (Swift app):

- `ClientMessage` / `ServerMessage` — tagged JSON enums
- `SessionState`, `SessionSummary`, `StateChanges`
- `Message`, `TokenUsage`, `ApprovalRequest`
- `TokenUsageSnapshotKind` — explicit semantics for token snapshots (context vs totals)

Usage architecture reference: `docs/token-context-architecture.md`

### connector-core

Provider-agnostic vocabulary shared by all connectors and the server:

- `ConnectorEvent` — unified event enum (turns, messages, approvals, errors)
- `ConnectorError` — shared error type
- `transition.rs` — pure state machine: `transition(state, input) -> (state, effects)`

### connector-codex

Codex-specific logic. Depends on `codex-core`, `codex-login`, `codex-protocol`.

- `session.rs` — `CodexSession`, `CodexAction`, connector lifecycle
- `auth.rs` — `CodexAuthService` (OAuth flow via codex-login)
- `rollout_parser.rs` — typed JSONL parser using `codex-protocol` types (replaces raw Value matching)

### connector-claude

Claude-specific logic. Depends on `claude-agent-sdk` protocol types.

- `session.rs` — `ClaudeSession`, `ClaudeAction`, CLI subprocess management
- `lib.rs` — stdin/stdout NDJSON protocol parsing, image transforms

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

Each session maintains a monotonic `approval_version` counter that increments on every approval state change (enqueue, decide, clear). All approval-related messages include this version so clients can reject stale or out-of-order events. See `session.rs` for queue management and `session_command_handler.rs` for version injection.

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

If auth is enabled, send it via `Authorization` header during the WebSocket handshake:

```
Authorization: Bearer <your-token>
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
{ "type": "cancel_shell", "session_id": "...", "request_id": "..." }
```

**Review comments** (REST — see API.md for payloads):

```http
POST   /api/sessions/{session_id}/review-comments
PATCH  /api/review-comments/{comment_id}
DELETE /api/review-comments/{comment_id}
GET    /api/sessions/{session_id}/review-comments
```

Server broadcasts `review_comment_created` / `review_comment_updated` / `review_comment_deleted` via WS after mutations.

**Claude hook transport** (how `orbitdock hook-forward` delivers events):

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
{ "type": "shell_started", "session_id": "...", "request_id": "...", "command": "..." }
{ "type": "shell_output", "session_id": "...", "request_id": "...", "stdout": "...", "stderr": "...", "exit_code": 0, "duration_ms": 1234, "outcome": "completed" }
{ "type": "error", "code": "...", "message": "...", "session_id": "..." }
```

## Data Directory

Everything lives under one directory. Default is `~/.orbitdock/`, override with `--data-dir`.

```
~/.orbitdock/
├── orbitdock.db              # SQLite database (WAL mode)
├── orbitdock.pid             # PID file (created after bind, removed on shutdown)
├── hook-forward.json         # Hook transport target config (server_url, encrypted auth token)
├── codex-rollout-state.json  # Codex file watcher offsets
├── logs/
│   └── server.log            # Structured JSON logs
└── spool/                    # Queued hook events (retried by hook-forward; drained on startup)
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
make rust-build               # dev build
make rust-run                 # run locally (127.0.0.1:4000)
make rust-run-lan             # run on LAN without auth (trusted network/dev only)
make rust-run-remote          # run on 0.0.0.0:4000 (requires DB token or ORBITDOCK_AUTH_TOKEN)
make rust-generate-token      # issue and print a secure token
make rust-check               # fast compile check
make rust-ci                  # fmt + clippy + tests
```

Use `make rust-*` targets for routine development. Avoid plain `cargo` commands unless you're adding a missing Make target, because direct cargo invocations can bypass repo cache settings and create duplicate `target` directories.

### Build Cache + Disk Hygiene

Rust artifacts now live in `.cache/rust/target` (gitignored), and optional sccache data lives in `.cache/rust/sccache`.

```bash
make rust-env                 # print active Rust build/caching settings
make rust-size                # inspect target + sccache disk usage
make rust-clean-incremental   # remove only incremental caches
make rust-clean-debug         # remove dev/test artifacts only
make rust-clean-sccache       # clear sccache files
```

`sccache` is opt-in (`RUST_SCCACHE=on`) so local builds remain stable even when wrapper tooling is unavailable.

You usually do not need `cargo clean`. Use the partial-clean targets above first.

### macOS Binary (arm64)

```bash
make rust-build-darwin
```

Produces `${CARGO_TARGET_DIR:-target}/darwin-arm64/orbitdock` for Apple Silicon.

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
| `axum-server` | TLS support via rustls |
| `qrcode` | QR code generation for `pair` command |
| `tracing` | Structured logging |
