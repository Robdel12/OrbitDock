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

## Proposed Architecture: Embedded Rust Server + Swift Client

A Rust server handles the heavy lifting. The macOS app becomes a thin, responsive UI layer. **The server is a single native binary embedded in the .app bundle** - users download, double-click, it works.

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
│                    Unix Domain Socket                              │
│                  ~/.orbitdock/server.sock                          │
│                                │                                   │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │              OrbitDock Server (Rust + Axum)                   │ │
│  │   Session tasks, event channels, connectors, persistence     │ │
│  │                                                               │ │
│  │   🦀 Can integrate directly with codex-rs!                   │ │
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
| **Codex integration** | **codex-rs is Rust - direct integration possible!** |

### Embeddability (Solved)

```swift
class ServerManager {
    private var serverProcess: Process?

    func startServer() {
        let serverPath = Bundle.main.path(forResource: "orbitdock-server", ofType: nil)!

        serverProcess = Process()
        serverProcess.executableURL = URL(fileURLWithPath: serverPath)
        serverProcess.arguments = ["--socket", socketPath]
        serverProcess.launch()

        waitForSocket()
    }

    func stopServer() {
        serverProcess?.terminate()
    }
}
```

---

## Technology Stack

| Layer | Technology | Why |
|-------|------------|-----|
| **Runtime** | Tokio | Industry standard async runtime |
| **Web/WebSocket** | Axum | From Tokio team, clean API, great WS support |
| **Channels** | tokio::sync::mpsc | Actor-like message passing |
| **Database** | rusqlite + spawn_blocking | Async-safe SQLite access |
| **Serialization** | serde + serde_json | Fast, ergonomic JSON |
| **Codex** | codex-rs (direct) | Reuse existing Rust code! |

### The Actor Pattern with Tokio

No framework needed - tasks + channels = actors:

```rust
use tokio::sync::mpsc;

struct SessionActor {
    id: String,
    state: SessionState,
    subscribers: Vec<mpsc::Sender<ServerMessage>>,
}

impl SessionActor {
    async fn run(mut self, mut rx: mpsc::Receiver<SessionCommand>) {
        while let Some(cmd) = rx.recv().await {
            match cmd {
                SessionCommand::Event(event) => {
                    self.state.apply(event);
                    self.broadcast_delta().await;
                }
                SessionCommand::Subscribe { tx, reply } => {
                    self.subscribers.push(tx);
                    let _ = reply.send(self.state.snapshot());
                }
                SessionCommand::SendMessage { content } => {
                    // Forward to Codex connector
                }
            }
        }
    }

    async fn broadcast_delta(&self) {
        let delta = ServerMessage::SessionDelta {
            session_id: self.id.clone(),
            changes: self.state.pending_changes(),
        };
        for sub in &self.subscribers {
            let _ = sub.send(delta.clone()).await;
        }
    }
}

// Spawn a session "actor"
let (tx, rx) = mpsc::channel(100);
tokio::spawn(actor.run(rx));

// Send commands to it from anywhere
tx.send(SessionCommand::Event(event)).await?;
```

---

## Codex Integration: The Big Win 🎯

Codex (`codex-rs`) is written in Rust. We can integrate directly instead of spawning a subprocess!

### Current Architecture (subprocess)
```
OrbitDock Server ──stdio JSON-RPC──► codex app-server process
     (Rust)                              (Rust, separate)
```

### Future Architecture (direct)
```
OrbitDock Server
     (Rust)
        │
        ├── codex-rs as library dependency
        │   └── Direct function calls, shared types
        │
        └── No IPC overhead, no process management
```

### Integration Path

```toml
# Cargo.toml
[dependencies]
codex-core = { path = "../codex-rs/core" }  # or git dependency
```

```rust
// Direct integration with Codex
use codex_core::{Thread, Config, Event};

impl CodexConnector {
    async fn create_session(&self, cwd: &str) -> Result<String> {
        let config = Config::new(cwd);
        let thread = Thread::new(config).await?;

        // Subscribe to events directly
        let mut events = thread.subscribe();
        tokio::spawn(async move {
            while let Some(event) = events.recv().await {
                // Translate to OrbitDock events
                let od_event = translate_codex_event(event);
                event_bus.send(od_event).await;
            }
        });

        Ok(thread.id().to_string())
    }
}
```

This eliminates:
- Process spawning/management
- JSON-RPC serialization overhead
- stdout/stdin buffering issues
- Separate error handling

---

## The Protocol

### Server → Client (WebSocket messages)

```rust
#[derive(Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ServerMessage {
    // Full state sync
    SessionsList { sessions: Vec<SessionSummary> },
    SessionSnapshot { session: SessionState },

    // Incremental updates
    SessionDelta { session_id: String, changes: StateChanges },
    MessageAppended { session_id: String, message: Message },
    MessageUpdated { session_id: String, message_id: String, changes: MessageChanges },
    ApprovalRequested { session_id: String, request: ApprovalRequest },
    TokensUpdated { session_id: String, usage: TokenUsage },

    // Lifecycle
    SessionCreated { session: SessionSummary },
    SessionEnded { session_id: String, reason: String },
}
```

### Client → Server (WebSocket messages)

```rust
#[derive(Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ClientMessage {
    // Subscriptions
    SubscribeSession { session_id: String },
    UnsubscribeSession { session_id: String },
    SubscribeList,

    // Actions
    SendMessage { session_id: String, content: String },
    ApproveTool { session_id: String, request_id: String, approved: bool },
    AnswerQuestion { session_id: String, request_id: String, answer: String },
    InterruptSession { session_id: String },
    EndSession { session_id: String },

    // Session management
    CreateSession { provider: Provider, cwd: String, model: Option<String> },
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Provider {
    Claude,
    Codex,
}
```

---

## Implementation Phases

### Phase 0: Rust Project Setup ✅ COMPLETE
> Get the foundation right before building.

- [x] **Create Rust workspace**
  ```
  orbitdock-server/
  ├── Cargo.toml          # Workspace root
  ├── crates/
  │   ├── server/         # Main server binary
  │   ├── protocol/       # Shared types (Server ↔ Client)
  │   └── connectors/     # Claude, Codex connectors
  └── build-universal.sh  # Universal binary build script
  ```
  - [x] `cargo new orbitdock-server`
  - [x] Add workspace members
  - [x] Configure for release builds (LTO, strip, codegen-units=1)

- [x] **Add core dependencies**
  ```toml
  [dependencies]
  tokio = { version = "1", features = ["full"] }
  axum = { version = "0.8", features = ["ws"] }
  tower = "0.5"
  tower-http = { version = "0.6", features = ["cors", "trace"] }
  serde = { version = "1", features = ["derive"] }
  serde_json = "1"
  rusqlite = { version = "0.32", features = ["bundled"] }
  tracing = "0.1"
  tracing-subscriber = { version = "0.3", features = ["env-filter"] }
  ```

- [x] **Build universal binary script**
  ```bash
  ./build-universal.sh  # Creates target/universal/orbitdock-server (2.8MB)
  ```

- [x] **Verify server runs**
  - [x] Build universal binary (arm64 + x86_64)
  - [x] Server starts and listens on port 4000
  - [ ] Copy to Swift app bundle (Phase 4)
  - [ ] Code sign and verify (Phase 6)

---

### Phase 1: Spike - Prove the Round Trip ✅ COMPLETE
> Goal: Swift app talks to Rust server via WebSocket. One hardcoded session.

**Deliverable**: Demo showing Swift UI updating in real-time from Rust events.

#### Server (Rust) ✅ COMPLETE

- [x] Create basic Axum server with WebSocket endpoint
- [x] Implement protocol types in `protocol` crate
- [x] Add tracing/logging (dual: stderr compact + JSON file at `~/.orbitdock/logs/server.log`)
- [x] Handle client messages (subscribe, create session, etc.)

#### Client (Swift) ✅ COMPLETE

- [x] Add WebSocket client (`ServerConnection.swift` with URLSessionWebSocketTask)
- [x] Parse ServerMessage JSON (`ServerProtocol.swift`)
- [x] Display in simple SwiftUI view (`ServerTestView` in SettingsView Debug tab)
- [x] Send test message back to server (ClientToServerMessage)

#### Verification ✅
- [x] `cargo run` starts server
- [x] Health endpoint responds (GET /health → 200)
- [x] Swift app connects (WebSocket 101 upgrade confirmed in logs)
- [x] Server auto-starts on app launch via ServerManager
- [x] WebSocket ping/pong handling (server responds to Swift client pings)
- [x] Bidirectional round trip: Swift sends `subscribe_list`, server responds with `sessions_list`
- [ ] Real-time updates flowing to UI (requires Phase 4 state management)

---

### Phase 2: Core Server Architecture ✅ COMPLETE
> Goal: Real session management with actor-like tasks.

**Deliverable**: Server that can manage multiple sessions with proper isolation.

#### Session Management ✅

- [x] Create `SessionHandle` struct with state + subscribers (`session.rs`)
- [x] Create `AppState` for session storage + list subscriptions (`state.rs`)
- [x] Basic WebSocket routing for all client messages (`websocket.rs`)
- [x] Subscription flow: subscribe → receive snapshot → get updates
  ```rust
  pub struct SessionActor {
      id: String,
      provider: Provider,
      status: SessionStatus,
      messages: Vec<Message>,
      pending_approval: Option<ApprovalRequest>,
      token_usage: TokenUsage,
      subscribers: Vec<mpsc::Sender<ServerMessage>>,
  }

  pub enum SessionCommand {
      Event(SessionEvent),
      Subscribe { tx: mpsc::Sender<ServerMessage>, reply: oneshot::Sender<SessionSnapshot> },
      Unsubscribe { tx: mpsc::Sender<ServerMessage> },
      SendMessage { content: String },
      Approve { request_id: String, approved: bool },
  }
  ```

#### Session Lifecycle (Remaining)

- [ ] Convert to actor pattern (spawn tasks per session vs Mutex) - DEFERRED
  - Current: All sessions in `Arc<Mutex<AppState>>` - works fine for MVP
  - Target: Each session as `tokio::spawn(session.run(rx))` with `mpsc::Sender<SessionCommand>`
- [x] End session → graceful cleanup + notify subscribers + persist

#### WebSocket Routing ✅ DONE

- [x] Route messages to correct session (via session_id lookup)
  ```rust
  async fn handle_socket(
      mut socket: WebSocket,
      session_manager: Arc<Mutex<SessionManager>>,
  ) {
      let (ws_tx, mut ws_rx) = socket.split();
      let (client_tx, mut client_rx) = mpsc::channel(100);

      // Forward server messages to WebSocket
      tokio::spawn(async move {
          while let Some(msg) = client_rx.recv().await {
              let text = serde_json::to_string(&msg).unwrap();
              ws_tx.send(Message::Text(text)).await;
          }
      });

      // Handle client messages
      while let Some(Ok(Message::Text(text))) = ws_rx.next().await {
          let msg: ClientMessage = serde_json::from_str(&text)?;
          match msg {
              ClientMessage::SubscribeSession { session_id } => {
                  if let Some(tx) = session_manager.lock().await.get_session(&session_id) {
                      tx.send(SessionCommand::Subscribe {
                          tx: client_tx.clone(),
                          reply: oneshot::channel().0,
                      }).await;
                  }
              }
              // ... handle other messages
          }
      }
  }
  ```

#### Persistence ✅ COMPLETE

- [x] Create `PersistenceWriter` task (`persistence.rs`)
  - Batched writes (50 commands or 100ms flush interval)
  - Uses `spawn_blocking` for async-safe SQLite access
  - WAL mode + busy timeout for concurrent access
- [x] Reuse existing SQLite schema (`~/.orbitdock/orbitdock.db`)
  - Sessions table (create, update, end)
  - Messages table (append, update)
  - Token usage columns
- [x] Wire up persistence to WebSocket handlers
  - SessionCreate persists on CreateSession
  - SessionEnd persists on EndSession

---

### Phase 3: Codex Connector ✅ COMPLETE
> Goal: Codex sessions work through the new architecture.

**Deliverable**: Codex sessions running through Rust server.

#### Subprocess Connector ✅ COMPLETE

- [x] Port `CodexAppServerClient` logic to Rust (`connectors/src/codex.rs`)
  - Process spawning with `codex app-server`
  - JSON-RPC request/response with correlation
  - Event reading and translation
  - Binary discovery (homebrew, /usr/local, which)
- [x] Translate Codex events to OrbitDock events
  - Turn lifecycle (started, completed, aborted)
  - Items (created, updated) → Messages
  - Token usage, diff, plan updates
  - Approval requests (exec, patch, question)
- [x] Handle approval flow via submissions
- [x] Handle user messages via turn/start
- [x] Wire into WebSocket handler (`codex_session.rs`)
  - Event loop forwards events to session subscribers
  - Action channel receives commands from WebSocket

#### Direct Integration (Future - Phase 7)

- [ ] Add codex-rs as dependency
- [ ] Use Codex types directly
- [ ] Subscribe to events without IPC

#### Testing (TODO)
- [ ] Create Codex session through server
- [ ] Verify events flow to Swift UI
- [ ] Test approval flow
- [ ] Test message sending

---

### Phase 4: Swift Client Integration 🔄 IN PROGRESS
> Goal: Replace current Swift architecture with thin client.

**Deliverable**: macOS app works entirely through server connection.

#### Server Process Management ✅ COMPLETE

- [x] Create `ServerManager` - spawns embedded binary, monitors health, auto-restart
- [x] Start server on app launch (AppDelegate)
- [x] Stop server on app termination
- [x] Connect WebSocket after server ready
- [x] Debug settings page with server status (`SettingsView` → Debug tab)
- [x] Find binary in dev paths (debug → release → universal priority)
- [x] RUST_LOG=debug for development builds

#### WebSocket Connection ✅ COMPLETE

- [x] Stable connection with proper ping/pong handling
- [x] Auto-subscribe to session list on connect
- [x] No resource timeout on long-lived WebSocket (`timeoutIntervalForResource = 0`)
- [x] Message routing with logging

#### New State Management (TODO - depends on Phase 2)

- [ ] Create `AppState`
  ```swift
  @Observable
  @MainActor
  class AppState {
      var sessions: [String: SessionState] = [:]
      var sessionList: [SessionSummary] = []
      var activeSessionId: String?
      var connectionStatus: ConnectionStatus = .disconnected

      private let connection: ServerConnection

      init() {
          connection = ServerConnection()
          connection.onMessage = { [weak self] message in
              Task { @MainActor in
                  self?.handleMessage(message)
              }
          }
      }

      func handleMessage(_ message: ServerMessage) {
          switch message {
          case .sessionsList(let sessions):
              sessionList = sessions
          case .sessionSnapshot(let session):
              sessions[session.id] = session
          case .sessionDelta(let id, let changes):
              sessions[id]?.apply(changes)
          case .messageAppended(let id, let message):
              sessions[id]?.messages.append(message)
          case .approvalRequested(let id, let request):
              sessions[id]?.pendingApproval = request
          case .tokensUpdated(let id, let usage):
              sessions[id]?.tokenUsage = usage
          default:
              break
          }
      }

      // Actions - just send to server
      func sendMessage(_ content: String) {
          guard let id = activeSessionId else { return }
          connection.send(.sendMessage(sessionId: id, content: content))
      }

      func approve(_ requestId: String, approved: Bool) {
          guard let id = activeSessionId else { return }
          connection.send(.approveTool(sessionId: id, requestId: requestId, approved: approved))
      }
  }
  ```

#### Server Process Management

- [ ] Create `ServerManager`
  ```swift
  class ServerManager {
      private var process: Process?
      private var healthCheckTimer: Timer?

      func start() throws {
          let serverPath = Bundle.main.path(forResource: "orbitdock-server", ofType: nil)!

          process = Process()
          process?.executableURL = URL(fileURLWithPath: serverPath)
          process?.arguments = [
              "--socket", socketPath,
              "--db", dbPath,
          ]

          // Capture stderr for logging
          let pipe = Pipe()
          process?.standardError = pipe

          try process?.run()

          // Wait for socket
          try waitForSocket(timeout: 5.0)

          // Start health monitoring
          startHealthCheck()
      }

      func stop() {
          process?.terminate()
          process?.waitUntilExit()
      }

      private func startHealthCheck() {
          healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
              if self?.process?.isRunning != true {
                  // Server crashed, restart it
                  try? self?.start()
              }
          }
      }
  }
  ```

- [ ] Bundle server binary in Xcode project (for production release)
- [ ] Add to Copy Files build phase (for production release)
  - Note: Development uses path detection to find binary in repo

#### Migrate Views

- [ ] Update `ContentView` → use `AppState`
- [ ] Update `SessionListView` → read from `state.sessionList`
- [ ] Update `ConversationView` → subscribe on appear
- [ ] Update `CodexApprovalView` → send via connection
- [ ] Update all other views

#### Remove Old Code

- [ ] Remove `DatabaseManager`
- [ ] Remove `SessionStore`
- [ ] Remove `CodexDirectSessionManager`
- [ ] Remove `CodexAppServerClient`
- [ ] Remove `CodexEventHandler`
- [ ] Clean up unused models

---

### Phase 5: Claude Connector
> Goal: Claude sessions work through the server.

**Deliverable**: Both Claude and Codex unified.

#### Implementation

- [ ] Create `ClaudeConnector`
  ```rust
  pub struct ClaudeConnector {
      watcher: RecommendedWatcher,
      event_tx: mpsc::Sender<SessionEvent>,
  }

  impl ClaudeConnector {
      pub fn watch_session(transcript_path: &Path) -> Result<Self> {
          // Use notify crate for file watching
          // Parse JSONL on changes
          // Emit events
      }
  }
  ```

- [ ] File watching with `notify` crate
- [ ] JSONL transcript parsing
- [ ] Hook integration (HTTP endpoint for CLI)

---

### Phase 6: Packaging & Distribution
> Goal: Ship a working .app.

**Deliverable**: DMG that just works.

#### Build Pipeline

- [ ] Create `build.sh` script
  ```bash
  #!/bin/bash
  set -e

  # Build universal Rust binary
  cd orbitdock-server
  ./build-universal.sh

  # Copy to Swift project
  cp target/universal/orbitdock-server ../CommandCenter/Resources/

  # Build Swift app
  cd ../CommandCenter
  xcodebuild -scheme OrbitDock -configuration Release archive

  # Create DMG
  create-dmg ...
  ```

- [ ] Universal binary (arm64 + x86_64)
- [ ] Code signing
- [ ] Notarization
- [ ] DMG creation

#### Testing

- [ ] Fresh macOS install
- [ ] Intel Mac
- [ ] Apple Silicon Mac
- [ ] Upgrade from previous version

---

### Phase 7: Direct Codex Integration
> Goal: Eliminate subprocess, integrate codex-rs directly.

**Deliverable**: Native Codex integration, better performance.

- [ ] Fork or depend on codex-rs
- [ ] Extract core library
- [ ] Integrate as Rust dependency
- [ ] Remove subprocess connector
- [ ] Benchmark improvements

---

### Phase 8: Enhancements (Future)

- [ ] **Web dashboard** - Axum already serves HTTP, add a web UI
- [ ] **iOS companion** - Same WebSocket protocol
- [ ] **CLI client** - `orbitdock status`, `orbitdock approve`
- [ ] **Multi-machine** - TCP instead of Unix socket
- [ ] **Team features** - Auth, shared sessions

---

## Server Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                  OrbitDock Server (Rust + Tokio)                 │
│                                                                  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                    Axum HTTP/WebSocket                     │  │
│  │                                                            │  │
│  │   GET /ws → WebSocket upgrade                             │  │
│  │   GET /health → Health check                              │  │
│  │   POST /hook → Claude CLI hook events                     │  │
│  └───────────────────────────────────────────────────────────┘  │
│                              │                                   │
│                              ▼                                   │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │              SessionManager (Arc<Mutex<...>>)              │  │
│  │                                                            │  │
│  │   sessions: HashMap<String, mpsc::Sender<SessionCommand>>  │  │
│  └───────────────────────────────────────────────────────────┘  │
│        │              │              │                           │
│        ▼              ▼              ▼                           │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                       │
│  │ Session  │  │ Session  │  │ Session  │                       │
│  │ Task     │  │ Task     │  │ Task     │   tokio::spawn        │
│  │          │  │          │  │          │                       │
│  │ state    │  │ state    │  │ state    │                       │
│  │ subs[]   │  │ subs[]   │  │ subs[]   │                       │
│  └──────────┘  └──────────┘  └──────────┘                       │
│        │              │              │                           │
│        ▼              ▼              ▼                           │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                      Connectors                            │  │
│  │                                                            │  │
│  │  ┌─────────────────┐  ┌─────────────────┐                 │  │
│  │  │ CodexConnector  │  │ ClaudeConnector │                 │  │
│  │  │                 │  │                 │                 │  │
│  │  │ - subprocess    │  │ - file watcher  │                 │  │
│  │  │ - JSON-RPC      │  │ - JSONL parser  │                 │  │
│  │  │                 │  │                 │                 │  │
│  │  │ (future: direct │  │                 │                 │  │
│  │  │  codex-rs)      │  │                 │                 │  │
│  │  └─────────────────┘  └─────────────────┘                 │  │
│  └───────────────────────────────────────────────────────────┘  │
│                              │                                   │
│                              ▼                                   │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │              PersistenceWriter (tokio task)                │  │
│  │                                                            │  │
│  │   Batches events, writes to SQLite via spawn_blocking     │  │
│  └───────────────────────────────────────────────────────────┘  │
│                              │                                   │
│                              ▼                                   │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                   SQLite (rusqlite)                        │  │
│  │                                                            │  │
│  │   ~/.orbitdock/orbitdock.db                               │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Data Flow Examples

### User sends message to Codex session

```
Swift UI                Server                    Codex
   │                       │                         │
   │ ClientMessage::       │                         │
   │ SendMessage ─────────►│                         │
   │                       │                         │
   │                       │ SessionCommand::        │
   │                       │ SendMessage ───────────►│
   │                       │                         │
   │                       │◄─── turn/started ───────│
   │                       │                         │
   │◄── SessionDelta ──────│                         │
   │    (status: working)  │                         │
   │                       │◄─── item/created ───────│
   │                       │     (agentMessage)      │
   │                       │                         │
   │◄── MessageAppended ───│                         │
   │                       │                         │
   │                       │◄─── turn/completed ─────│
   │                       │                         │
   │◄── SessionDelta ──────│                         │
   │    (status: waiting)  │                         │
```

### Codex requests tool approval

```
Swift UI                Server                    Codex
   │                       │                         │
   │                       │◄─── requestApproval ────│
   │                       │     (exec: npm install) │
   │                       │                         │
   │◄── ApprovalRequested ─│                         │
   │                       │                         │
   │ (User clicks Approve) │                         │
   │                       │                         │
   │ ApproveTool ─────────►│                         │
   │ (approved: true)      │                         │
   │                       │                         │
   │                       │ exec/approve ──────────►│
   │                       │                         │
   │◄── SessionDelta ──────│                         │
   │    (pendingApproval:  │                         │
   │     null)             │                         │
```

---

## Success Criteria

- [ ] User downloads DMG, drags to Applications, double-clicks, it works
- [ ] 50+ concurrent sessions with smooth UI (60fps)
- [ ] Events processed in <10ms
- [ ] Server crash doesn't lose data
- [ ] Clean architecture, easy to extend
- [ ] Direct Codex integration (Phase 7)

---

## Open Questions

1. **Unix socket vs TCP?** Start with Unix for simplicity, TCP later for multi-machine
2. **Codex fork or upstream?** Ideally contribute library extraction upstream
3. **Quest/Inbox?** Keep in server for consistency
4. **Migration?** Need to handle existing SQLite data

---

## References

- [Tokio Tutorial](https://tokio.rs/tokio/tutorial) - Async Rust
- [Axum Guide](https://docs.rs/axum/latest/axum/) - Web framework
- [codex-rs](https://github.com/openai/codex/tree/main/codex-rs) - Codex Rust implementation
- [rusqlite](https://docs.rs/rusqlite/) - SQLite for Rust

---

*Created: 2025-02-04*
*Updated: 2025-02-04 - Switched from Elixir to Rust/Axum*
*Status: Planning - Ready for Phase 0*
