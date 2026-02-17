# OrbitDock Server

The Rust backend that powers OrbitDock. Provides real-time session management over WebSocket, direct Codex integration via codex-rs, and a pure state machine for all session business logic.

Embedded in OrbitDock.app — launched automatically when the app starts.

## Architecture

```
┌───────────────────────────────────────────────────────────────┐
│                    orbitdock-server                             │
│                                                                │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │                 Axum HTTP + WebSocket                     │  │
│  │  GET /ws      → WebSocket upgrade                        │  │
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

### Key Design Decisions

**Actor-per-session** — Each session runs in its own tokio task. External callers interact via `SessionActorHandle` which sends `SessionCommand` over mpsc. Zero cross-session contention.

**Lock-free reads** — Session state is published to `ArcSwap<SessionSnapshot>` after every command. WebSocket handlers read snapshots without holding any locks.

**Pure transitions** — All business logic lives in `transition(state, input) -> (state, effects)`. No IO, no async, no locking. Fully unit-testable. The actor executes effects after transitioning.

**Broadcast fan-out** — `tokio::broadcast` for event distribution. One slow client never blocks others. Automatic cleanup when receivers drop.

**Revision tracking** — Monotonic revision counter per session. Clients send `since_revision` on subscribe to get incremental replay instead of a full snapshot.

## Crates

```
orbitdock-server/crates/
├── server/        # Main binary — actors, registry, persistence, WebSocket
├── protocol/      # Shared types for client ↔ server messages
└── connectors/    # AI provider connectors (codex-rs integration)
```

### server

The main binary. Key modules:

| Module | Purpose |
|--------|---------|
| `main.rs` | Startup, session restoration, Axum routing |
| `websocket.rs` | WebSocket message handling — pure routing, no locks |
| `session_actor.rs` | Per-session actor (passive sessions, command handling) |
| `codex_session.rs` | Active Codex sessions (connector event loop) |
| `claude_session.rs` | Claude session management (hook-based) |
| `transition.rs` | Pure state machine — `transition(state, input) -> effects` |
| `session_command.rs` | Actor command enum + persistence ops |
| `session.rs` | `SessionHandle` — owned state within actor task |
| `state.rs` | `SessionRegistry` — DashMap + list broadcast |
| `persistence.rs` | Async SQLite writer (batched channel) |
| `migration_runner.rs` | Reads `migrations/*.sql`, tracks versions |
| `rollout_watcher.rs` | FSEvents watcher for Codex rollout files |
| `shell.rs` | User-initiated shell command execution |
| `ai_naming.rs` | AI-generated session names |
| `session_naming.rs` | Session name resolution |
| `codex_auth.rs` | Codex authentication flow |
| `git.rs` | Git branch/SHA detection |
| `subagent_parser.rs` | Parse subagent tool data from Claude hooks |
| `logging.rs` | Structured JSON logging to file |

### protocol

Shared message types used by both server and client (Swift app). Defines:

- `ClientMessage` — All client → server messages (tagged JSON enum)
- `ServerMessage` — All server → client messages
- `SessionState`, `SessionSummary`, `StateChanges` — Session data types
- `Message`, `TokenUsage`, `ApprovalRequest` — Domain types
- Serde serialization with `snake_case` tag naming

### connectors

AI provider integrations:

- `codex.rs` — Direct Codex integration via codex-rs. Spawns codex-core sessions, translates events to `ConnectorEvent`
- `claude.rs` — Claude session types (hook-based, no direct connector)

## State Machine

The `WorkPhase` enum models the session lifecycle:

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

Phases map to wire `WorkStatus`:
- `Idle` → `Waiting` (reply/question)
- `Working` → `Working`
- `AwaitingApproval` → `Permission` or `Question`
- `Ended` → `Ended`

## WebSocket Protocol

JSON over WebSocket at `ws://127.0.0.1:4000/ws`.

### Client → Server

**Subscriptions:**

```json
{ "type": "subscribe_list" }
{ "type": "subscribe_session", "session_id": "...", "since_revision": 42 }
{ "type": "unsubscribe_session", "session_id": "..." }
```

**Session actions:**

```json
{ "type": "create_session", "provider": "codex", "cwd": "/path", "model": "o3" }
{ "type": "resume_session", "session_id": "..." }
{ "type": "fork_session", "source_session_id": "...", "nth_user_message": 3 }
{ "type": "send_message", "session_id": "...", "content": "...", "skills": [], "images": [], "mentions": [] }
{ "type": "steer_turn", "session_id": "...", "content": "use postgres instead" }
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
{ "type": "list_review_comments", "session_id": "..." }
{ "type": "update_review_comment", "comment_id": "...", "status": "resolved" }
{ "type": "delete_review_comment", "comment_id": "..." }
```

**Skills and MCP:**

```json
{ "type": "list_skills", "session_id": "...", "cwds": ["/path"] }
{ "type": "list_remote_skills", "session_id": "..." }
{ "type": "download_remote_skill", "session_id": "...", "hazelnut_id": "..." }
{ "type": "list_mcp_tools", "session_id": "..." }
{ "type": "refresh_mcp_servers", "session_id": "..." }
```

**Session config:**

```json
{ "type": "rename_session", "session_id": "...", "name": "Auth refactor" }
{ "type": "update_session_config", "session_id": "...", "approval_policy": "auto-edit" }
```

**Claude hook transport** (server-owned write path for CLI hooks):

```json
{ "type": "claude_session_start", "session_id": "...", "cwd": "...", "model": "opus" }
{ "type": "claude_session_end", "session_id": "...", "reason": "user_ended" }
{ "type": "claude_status_event", "session_id": "...", "hook_event_name": "UserPromptSubmit" }
{ "type": "claude_tool_event", "session_id": "...", "hook_event_name": "PreToolUse", "tool_name": "Bash" }
{ "type": "claude_subagent_event", "session_id": "...", "hook_event_name": "SubagentStart", "agent_id": "..." }
```

**Codex auth:**

```json
{ "type": "codex_account_read", "refresh_token": false }
{ "type": "codex_login_chatgpt_start" }
{ "type": "codex_account_logout" }
{ "type": "list_models" }
```

### Server → Client

```json
{ "type": "sessions_list", "sessions": [...] }
{ "type": "session_added", "summary": {...} }
{ "type": "session_removed", "session_id": "..." }
{ "type": "session_snapshot", "session": {...} }
{ "type": "session_delta", "session_id": "...", "changes": {...} }
{ "type": "message_appended", "session_id": "...", "message": {...} }
{ "type": "message_updated", "session_id": "...", "message_id": "...", "changes": {...} }
{ "type": "approval_requested", "session_id": "...", "request": {...} }
{ "type": "tokens_updated", "session_id": "...", "usage": {...} }
{ "type": "error", "code": "...", "message": "...", "session_id": "..." }
```

## Building

### Development

```bash
cargo build
cargo run
```

### Tests

```bash
cargo test --workspace     # All tests (96 total: 35 protocol + 61 server)
cargo test -p orbitdock-server
cargo test -p orbitdock-protocol
```

### Release (Universal Binary)

```bash
./build-universal.sh
```

Creates `target/universal/orbitdock-server` for both Intel and Apple Silicon.

## Embedding in macOS App

The server binary lives in the app bundle and is managed by `ServerManager.swift`:

```swift
let serverPath = Bundle.main.path(forResource: "orbitdock-server", ofType: nil)!
let process = Process()
process.executableURL = URL(fileURLWithPath: serverPath)
try process.run()
```

The app connects via WebSocket on `ws://127.0.0.1:4000/ws`.

## Persistence

SQLite with WAL mode at `~/.orbitdock/orbitdock.db`. The persistence layer uses a batched async channel — commands are sent from actors and written by a dedicated `PersistenceWriter` task.

Migrations live in `../../migrations/*.sql` and are run by `migration_runner.rs` at startup. The migration runner tracks applied versions in a `schema_versions` table.

## Logging

Structured JSON logs to `~/.orbitdock/logs/server.log`.

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
| `ORBITDOCK_SERVER_LOG_FILTER` | Tracing filter (e.g., `debug,tower_http=warn`) |
| `ORBITDOCK_SERVER_LOG_FORMAT` | `json` (default) or `pretty` |
| `ORBITDOCK_TRUNCATE_SERVER_LOG_ON_START` | Set to `1` to truncate log on boot |
| `RUST_LOG` | Fallback for log filter if server-specific var isn't set |

## Dependencies

Key external crates:

| Crate | Purpose |
|-------|---------|
| `axum` | HTTP/WebSocket server |
| `tokio` | Async runtime + broadcast channels |
| `dashmap` | Lock-free concurrent HashMap for session registry |
| `arc-swap` | Wait-free atomic pointer swap for session snapshots |
| `rusqlite` | SQLite access |
| `serde` / `serde_json` | JSON serialization |
| `codex-rs` | Direct Codex integration (codex-core) |
| `tracing` | Structured logging |
