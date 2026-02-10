# OrbitDock Real-Time Architecture

> Mission Control for AI Coding Agents - at scale.

## The Problem

OrbitDock needs to handle many concurrent AI agent sessions (10-100+) with real-time state updates. The current architecture has bottlenecks:

```
Current: All events → Single Actor → Main Thread → UI
         (serialized)   (queued)     (blocked)
```

With 50 agents generating 5-10 events/second each, that's 250-500 events/second all competing for:
1. Single DatabaseManager actor (write serialization)
2. MainActor SessionStore (UI thread blocking)
3. SQLite write lock

## The Insight

**Separate the UI update path from the persistence path.**

```
UI Path:        Event → Memory → UI        (microseconds)
Persist Path:   Event → Queue → Batch → DB (milliseconds, async)

These should NEVER block each other.
```

---

## Architecture: Embedded Rust Server + Swift Client

A Rust server handles the heavy lifting. The macOS app is a thin, responsive UI layer. **The server is a single native binary embedded in the .app bundle** - users download, double-click, it works.

```
┌────────────────────────────────────────────────────────────────────┐
│                     OrbitDock.app Bundle                           │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │                   macOS App (SwiftUI)                         │ │
│  │   Pure UI - renders state, sends actions                     │ │
│  │   Launches + monitors embedded server                        │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                │                                   │
│                         WebSocket :4000                            │
│                                │                                   │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │              OrbitDock Server (Rust + Axum)                   │ │
│  │   Session tasks, event channels, connectors, persistence     │ │
│  │   codex-core integrated directly as Rust dependency          │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                    │
│  Contents/MacOS/orbitdock-server  ← Single native binary          │
└────────────────────────────────────────────────────────────────────┘
```

### Why Rust?

| Requirement | Rust Solution |
|-------------|---------------|
| Single binary | Native compilation, no runtime needed |
| No dependencies | Statically linked, just works |
| Universal binary | `lipo` to combine arm64 + x86_64 |
| Code signing | Standard macOS signing works |
| Performance | Fastest option, low memory |
| **Codex integration** | **codex-core is Rust - direct library calls, no IPC** |

---

## Technology Stack

| Layer | Technology | Why |
|-------|------------|-----|
| **Runtime** | Tokio | Industry standard async runtime |
| **Web/WebSocket** | Axum | From Tokio team, clean API, great WS support |
| **Channels** | tokio::sync::mpsc | Actor-like message passing |
| **Database** | rusqlite + spawn_blocking | Async-safe SQLite access |
| **Serialization** | serde + serde_json | Fast, ergonomic JSON |
| **Codex** | codex-core (direct) | Library dependency from GitHub |

---

## Codex Integration: Direct Library Calls

codex-core is a direct Rust dependency — no subprocess, no IPC, no JSON-RPC.

```toml
# Cargo.toml workspace deps
codex-core = { git = "https://github.com/openai/codex", rev = "4ee0397" }
codex-protocol = { git = "https://github.com/openai/codex", rev = "4ee0397" }
```

```rust
// connectors/src/codex.rs - CodexConnector
impl CodexConnector {
    pub async fn new(cwd: &str, model: Option<&str>, ...) -> Result<Self> {
        let config = CodexConfig { cwd, model, approval_policy, sandbox_mode, ... };
        let (thread_manager, events_rx) = ThreadManager::new(config);
        // Events flow directly, no serialization
    }
}
```

This eliminates: process spawning, JSON-RPC serialization, stdout/stdin buffering, separate error handling.

---

## The Protocol

### Server → Client (WebSocket)

```rust
enum ServerMessage {
    SessionsList { sessions: Vec<SessionSummary> },
    SessionSnapshot { session: SessionState },
    SessionDelta { session_id: String, changes: StateChanges },
    MessageAppended { session_id: String, message: Message },
    MessageUpdated { session_id: String, message_id: String, changes: MessageChanges },
    ApprovalRequested { session_id: String, request: ApprovalRequest },
    TokensUpdated { session_id: String, usage: TokenUsage },
    SessionCreated { session: SessionSummary },
    SessionEnded { session_id: String, reason: String },
    Error { code: String, message: String, session_id: Option<String> },
}
```

### Client → Server (WebSocket)

```rust
enum ClientMessage {
    SubscribeList,
    SubscribeSession { session_id: String },
    UnsubscribeSession { session_id: String },
    SendMessage { session_id: String, content: String },
    ApproveTool { session_id: String, request_id: String, decision: String },
    AnswerQuestion { session_id: String, request_id: String, answer: String },
    InterruptSession { session_id: String },
    EndSession { session_id: String },
    UpdateSessionConfig { session_id: String, approval_policy: Option<String>, sandbox_mode: Option<String> },
    CreateSession { provider: Provider, cwd: String, model: Option<String>, ... },
    ResumeSession { session_id: String },
}
```

---

## Implementation Phases

### Phase 0: Rust Project Setup ✅ COMPLETE

- [x] Rust workspace with 3 crates: `server`, `protocol`, `connectors`
- [x] Core dependencies (tokio, axum, rusqlite, serde, tracing)
- [x] Universal binary build script (`build-universal.sh`)
- [x] Server starts and listens on port 4000
- [x] Structured JSON logging to `~/.orbitdock/logs/server.log`

---

### Phase 1: Spike ✅ COMPLETE

- [x] Axum server with WebSocket + health endpoints
- [x] Protocol types in shared `protocol` crate
- [x] Swift WebSocket client (`ServerConnection.swift`)
- [x] JSON message parsing (`ServerProtocol.swift`)
- [x] Bidirectional round trip verified
- [x] Server auto-starts via `ServerManager`

---

### Phase 2: Core Server Architecture ✅ COMPLETE

- [x] `SessionHandle` with state + subscribers (`session.rs`)
- [x] `AppState` for session storage + list subscriptions (`state.rs`)
- [x] WebSocket routing for all 11 client message types (`websocket.rs`)
- [x] Subscription flow: subscribe → snapshot → incremental deltas
- [x] `PersistenceWriter` with batched writes (50 cmds / 100ms flush)
- [x] Session create/update/end persistence
- [x] Message append/update persistence
- [x] Token usage persistence
- [x] Turn state (diff/plan) persistence
- [x] Session restoration from DB on startup

---

### Phase 3: Codex Connector ✅ COMPLETE

- [x] `CodexConnector` with direct codex-core integration
- [x] Event translation: codex-core → ConnectorEvent (15+ event types)
- [x] Streaming assistant messages (content deltas)
- [x] Tool execution events (exec, patch, MCP calls)
- [x] Approval flow (exec, patch, question types)
- [x] Token usage and rate limit events
- [x] Diff and plan update events
- [x] Live config changes (approval_policy, sandbox_mode)
- [x] Graceful shutdown

---

### Phase 4: Swift Client Integration ✅ COMPLETE

- [x] `ServerManager` - spawns binary, monitors health, auto-restart (3 attempts w/ exponential backoff)
- [x] `ServerConnection` - WebSocket with auto-reconnect, ping/pong, message routing
- [x] `ServerAppState` (@Observable) - full state management with per-session messages, tokens, diffs, plans
- [x] `ServerTypeAdapters` - protocol types → app model conversion
- [x] `ServerProtocol` - 11 server message types + 11 client message types
- [x] Session list subscription on connect + resubscription on reconnect
- [x] Views use server state for Codex sessions (codexActionBar, approval views, input bar)
- [x] Hybrid session loading: DB sessions (Claude) + server sessions (Codex) merged in ContentView
- [x] Resume ended sessions via ResumeSession protocol message

#### Not Yet Done (Phase 4)

- [ ] Bundle server binary in Xcode project (currently uses dev path detection)
- [ ] Add to Copy Files build phase for production release

#### Deliberately Deferred

The plan originally called for removing old Swift code (DatabaseManager, SessionStore, etc). This is deferred because Claude sessions still use the existing architecture. Old code removal happens if/when Phase 5 (Claude Connector) is completed.

---

### Phase 5: Claude Connector — NOT STARTED
> Goal: Claude sessions work through the Rust server too.

Claude Code sessions currently flow through the old path:
```
Claude Code hooks → orbitdock-cli → SQLite → DatabaseManager → SessionStore → UI
```

To unify, we'd need:
- [ ] Create `ClaudeConnector` in Rust (file watching + JSONL parsing)
- [ ] Hook integration (HTTP endpoint for CLI, or pipe stdin events)
- [ ] Transcript parsing in Rust (port from TranscriptParser.swift)
- [ ] Remove old Swift infrastructure (DatabaseManager, SessionStore, TranscriptParser, etc.)

**Status**: Low priority. The current Claude path works well and doesn't have scaling issues. The benefit of unifying is simpler code, but the cost is significant (re-implementing all the JSONL parsing, hook integration, etc.).

---

### Phase 6: Packaging & Distribution — NOT STARTED
> Goal: Ship a working .app / DMG.

- [ ] Build script (Rust universal binary → Xcode resources → archive → DMG)
- [ ] Code signing
- [ ] Notarization
- [ ] Test on Intel + Apple Silicon
- [ ] Upgrade path from previous versions

---

### Phase 7: Direct Codex Integration ✅ COMPLETE

This was the "future" goal — it's already the current architecture:

- [x] codex-core as direct Rust dependency (from GitHub)
- [x] Direct function calls, shared types
- [x] No IPC, no subprocess management
- [x] Event subscription without serialization overhead

---

### Phase 8: Enhancements (Future)

- [ ] **Web dashboard** - Axum already serves HTTP, add a web UI
- [ ] **iOS companion** - Same WebSocket protocol
- [ ] **CLI client** - `orbitdock status`, `orbitdock approve`
- [ ] **Multi-machine** - TCP instead of localhost
- [ ] **Team features** - Auth, shared sessions

---

## Current Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                  OrbitDock Server (Rust + Tokio)                 │
│                                                                  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                    Axum HTTP/WebSocket                     │  │
│  │                                                            │  │
│  │   GET  /ws     → WebSocket upgrade                        │  │
│  │   GET  /health → Health check                             │  │
│  └───────────────────────────────────────────────────────────┘  │
│                              │                                   │
│                              ▼                                   │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │            AppState (Arc<Mutex<...>>)                      │  │
│  │                                                            │  │
│  │   sessions: HashMap<String, SessionHandle>                 │  │
│  │   action_channels: HashMap<String, Sender<CodexAction>>   │  │
│  │   list_subscribers: Vec<Sender<ServerMessage>>            │  │
│  └───────────────────────────────────────────────────────────┘  │
│                              │                                   │
│                              ▼                                   │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │              CodexConnector (codex-core)                   │  │
│  │                                                            │  │
│  │   Direct Rust library calls - no subprocess               │  │
│  │   codex-core events → ConnectorEvent translation          │  │
│  │   Handles: messages, tools, approvals, tokens, diffs      │  │
│  └───────────────────────────────────────────────────────────┘  │
│                              │                                   │
│                              ▼                                   │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │              PersistenceWriter (tokio task)                │  │
│  │                                                            │  │
│  │   Batches: 50 commands or 100ms flush interval            │  │
│  │   Uses spawn_blocking for async-safe SQLite                │  │
│  │   WAL mode + busy_timeout for concurrent access            │  │
│  └───────────────────────────────────────────────────────────┘  │
│                              │                                   │
│                              ▼                                   │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                   SQLite (rusqlite)                        │  │
│  │   ~/.orbitdock/orbitdock.db                                │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Data Flow: User Sends Message

```
Swift UI                Server                    codex-core
   │                       │                         │
   │ SendMessage ─────────►│                         │
   │                       │ CodexAction::           │
   │                       │ SendMessage ───────────►│
   │                       │                         │
   │                       │◄── TurnStarted ─────────│
   │◄── SessionDelta ──────│    (status: working)    │
   │                       │                         │
   │                       │◄── AgentMessageDelta ───│
   │◄── MessageAppended ───│    (streaming content)  │
   │                       │                         │
   │                       │◄── TurnComplete ────────│
   │◄── SessionDelta ──────│    (status: waiting)    │
```

---

## Success Criteria

- [x] Rust server handles Codex sessions with real-time updates
- [x] Swift app is a thin WebSocket client for Codex
- [x] Direct codex-core integration (no subprocess)
- [x] Events processed in <10ms
- [x] Server crash auto-restarts (3 attempts)
- [ ] User downloads DMG, drags to Applications, it works (Phase 6)
- [ ] 50+ concurrent sessions at 60fps (not yet tested at scale)
- [ ] Claude sessions unified through server (Phase 5)

---

*Created: 2025-02-04*
*Updated: 2026-02-07 - Reflects actual state: Phases 0-4 and 7 complete*
*Status: Codex integration fully operational. Claude connector and packaging remain.*
