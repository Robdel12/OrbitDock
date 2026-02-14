# Server Architecture v2 — Implementation Roadmap

> Goal: Refactor the OrbitDock Rust server from mutex-heavy shared state to a pure state machine + actor architecture. Handle 100+ concurrent agents with zero cross-session contention.
>
> Each phase is a shippable unit. The system stays running between phases — no big bang rewrite.
>
> For the full design rationale, types, and diagrams, see `plans/server-architecture-v2.md`.

---

## Current Architecture (what we're migrating from)

| Component | Pattern | Problem |
|-----------|---------|---------|
| AppState | `Arc<Mutex<AppState>>` | Global lock blocks ALL sessions during any single session's IO |
| SessionHandle | `Arc<Mutex<SessionHandle>>` per session | Locks held across awaits in `handle_event` |
| ~~Broadcast~~ | ~~`Vec<mpsc::Sender<ServerMessage>>`~~ | ~~One slow client blocks all others; manual cleanup~~ ✅ Phase 2 |
| ~~Reconnection~~ | ~~Full snapshot on every subscribe~~ | ~~No revision tracking, no event replay~~ ✅ Phase 1 |
| ~~Business logic~~ | ~~27 match arms mixing state + IO in handle_event~~ | ~~Untestable without IO mocking~~ ✅ Phase 3 |
| Event loop | `select!` on events + actions | Long connector calls starve event processing |
| Session cleanup | None | 12+ dictionaries leaked per ended session |

---

## Phase 1: Revision Tracking + Event Log ✅

**Status**: Complete. Shipped in commit `e72dd28`.

Revision counter + bounded event log on SessionHandle. Clients can send `since_revision` on subscribe to get incremental replay instead of a full snapshot. Pre-serialized JSON with revision injected for replay events.

Key decisions:
- Event log stores pre-serialized JSON strings (not `ServerMessage` values) to avoid re-serialization on replay
- Revision injected at top level of JSON via `serialize_with_revision()` for event log entries
- Live broadcast events do NOT carry revision (only replay events do)
- Capacity: 1000 events per session

---

## Phase 2: Replace Broadcast Mechanism ✅

**Status**: Complete.

Replaced `Vec<mpsc::Sender>` with `tokio::broadcast` across all 6 server files. One slow client no longer blocks others. Subscriber cleanup is automatic when receivers are dropped.

Key decisions:
- Session broadcast capacity: 512 events
- List broadcast capacity: 64 events
- `spawn_broadcast_forwarder()` handles `Lagged` errors by logging a warning and continuing (client may have a gap but handlers are idempotent)
- `broadcast()` is now sync (no async/await) — single non-blocking `send()`
- `broadcast_to_list()` takes `&self` instead of `&mut self`, simplifying several call sites
- `UnsubscribeSession` handler is a no-op — receivers self-cleanup on disconnect
- ~70 `.await` removals across websocket.rs, codex_session.rs, rollout_watcher.rs, main.rs
- All 57 tests pass, zero warnings

---

## Phase 3: Extract Pure Transition Function ✅

**Status**: Complete. Shipped in commit `c8f7fb1`.

Extracted all business logic from `handle_event()` (27 match arms) into a pure, synchronous `transition(state, input, now) -> (state, effects)` function in `transition.rs`. The existing `handle_event()` is now ~15 lines: convert → transition → execute.

Key decisions:
- `WorkPhase` enum: `Idle`, `Working`, `AwaitingApproval { request_id, approval_type, proposed_amendment }`, `Ended { reason }`
- `TransitionState` is a pure data snapshot; `extract_state()`/`apply_state()` bridge to `SessionHandle` (temporary until Phase 4)
- Effects are `Box<PersistOp>` and `Box<ServerMessage>` (clippy-clean enum sizes)
- `Input` enum is 1:1 with `ConnectorEvent` via `From` impl
- `PersistOp::into_persist_command()` converts to existing `PersistCommand`
- Pass-through events (skills, MCP, context compacted) go through transition too — they produce `Effect::Emit` with no state change
- 12 unit tests: all pure, sync, zero mocks
- All 70 tests pass (45 server + 25 protocol), zero clippy warnings

---

## Phase 4: Session Actor Refactor

**Why**: Replace `Arc<Mutex<SessionHandle>>` with a single-threaded actor that owns its state directly. Eliminates all session-level locking. Each actor is independently scheduled by tokio.

**Depends on**: Phase 3 (pure transition function)

### New file: `crates/server/src/actor.rs`

- [ ] Define `SessionActor` struct:
  - `state: SessionState` (owned, no Arc/Mutex)
  - `connector: CodexConnector`
  - `inbox: mpsc::Receiver<SessionCommand>` (unified inbound channel)
  - `event_rx: mpsc::Receiver<ConnectorEvent>` (from codex-core)
  - `event_bus: broadcast::Sender<SessionEvent>` (outbound events)
  - `persist_tx: mpsc::Sender<PersistCommand>`
  - `snapshot: Arc<ArcSwap<SessionSnapshot>>` (lock-free reads)
  - `event_log: VecDeque<SessionEvent>` (bounded replay buffer)
- [ ] Define `SessionCommand` enum: `Action(Input)`, `Subscribe { since_revision, reply_tx }`
- [ ] Define `SubscribeResponse` enum: `Snapshot(SessionSnapshot)`, `Replay(Vec<SessionEvent>)`
- [ ] Define `SessionEvent` struct: `revision`, `session_id`, `payload: EventPayload`
- [ ] Implement `SessionActor::run()` — the main select loop:
  - `event_rx.recv()` → convert to Input → transition → execute effects
  - `inbox.recv()` → match Action/Subscribe → transition or handle_subscribe
  - Update `snapshot` after every transition
- [ ] Implement `execute(&mut self, effect: Effect)` — effect executor:
  - `Persist(op)` → send to `persist_tx`
  - `Emit(payload)` → push to `event_log`, send to `event_bus`
  - `Connector(call)` → dispatch to `self.connector`
- [ ] Implement `handle_subscribe(since_revision, reply_tx)` — replay or snapshot

### Dependencies

- [ ] Add `arc-swap = "1"` to `crates/server/Cargo.toml`

### Migrate `codex_session.rs`

- [ ] Replace `start_event_loop` → `SessionActor::spawn()` returning `SessionHandle`
- [ ] `SessionHandle` now holds: `inbox: mpsc::Sender<SessionCommand>`, `event_bus`, `snapshot`
- [ ] Remove `Arc<Mutex<SessionHandle>>` pattern — actor owns state directly
- [ ] Remove old `handle_event` / `handle_action` — replaced by actor's transition + execute
- [ ] Keep `CodexSession::new()` for connector creation, but move event loop into actor

### Update `session.rs`

- [ ] `SessionHandle` struct becomes thin routing handle (no more session state):
  - `inbox: mpsc::Sender<SessionCommand>`
  - `event_bus: broadcast::Sender<SessionEvent>`
  - `snapshot: Arc<ArcSwap<SessionSnapshot>>`
- [ ] Remove `messages`, `token_usage`, `work_status`, etc. from `SessionHandle` — all in actor
- [ ] `subscribe()` → sends `SessionCommand::Subscribe` to actor inbox
- [ ] Remove `broadcast()` from SessionHandle — actor does this internally

### Tests

- [ ] `test_actor_processes_connector_events` — feed events, verify state transitions
- [ ] `test_actor_handles_client_actions` — send via inbox, verify effects
- [ ] `test_actor_snapshot_updates_on_transition` — verify ArcSwap snapshot changes
- [ ] `test_actor_replay_from_event_log` — subscribe with revision, verify replay
- [ ] `test_actor_snapshot_fallback` — subscribe with revision=0, verify snapshot

### Verification

- [ ] `cargo test` — all tests pass
- [ ] No `Arc<Mutex<SessionHandle>>` remains for session state access
- [ ] Actor is single-threaded — no data races possible
- [ ] Snapshot reads from WebSocket layer are lock-free

---

## Phase 5: Replace AppState with SessionRegistry

**Why**: The final piece. Replace the global `Arc<Mutex<AppState>>` with a lock-free `DashMap`. WebSocket handlers become pure routing — no locks held, no IO blocking.

**Depends on**: Phase 4 (session actor)

### Dependencies

- [ ] Add `dashmap = "6"` to `crates/server/Cargo.toml`

### New file: `crates/server/src/registry.rs`

- [ ] Define `SessionRegistry` struct:
  - `sessions: DashMap<String, SessionHandle>` (lock-free concurrent map)
  - `persist_tx: mpsc::Sender<PersistCommand>`
  - `list_bus: broadcast::Sender<ServerMessage>` (list-level events)
- [ ] Implement `send(session_id, input) -> Result<()>` — route to actor inbox, no lock
- [ ] Implement `snapshot(session_id) -> Option<Arc<SessionSnapshot>>` — lock-free ArcSwap read
- [ ] Implement `list_summaries() -> Vec<SessionSummary>` — iterate DashMap, read snapshots
- [ ] Implement `subscribe_events(session_id) -> Option<broadcast::Receiver>` — get event stream
- [ ] Implement `subscribe_list() -> broadcast::Receiver<ServerMessage>` — list-level events
- [ ] Implement `register_session(id, handle)` — insert into DashMap
- [ ] Implement `remove_session(id)` — remove from DashMap (cleanup on session end)
- [ ] Implement `spawn_session(config) -> SessionHandle` — create connector, spawn actor, register

### Migrate `state.rs` → `registry.rs`

- [ ] Replace `HashMap<String, Arc<Mutex<SessionHandle>>>` with `DashMap<String, SessionHandle>`
- [ ] Replace `HashMap<String, mpsc::Sender<CodexAction>>` — action channels now inside actor
- [ ] Move `codex_threads` mapping into registry
- [ ] Replace `list_subscribers: Vec<mpsc::Sender>` with `list_bus: broadcast::Sender`
- [ ] Remove all `Mutex` usage from AppState

### Migrate `websocket.rs`

- [ ] Replace `State(state): State<Arc<Mutex<AppState>>>` with `State(registry): State<Arc<SessionRegistry>>`
- [ ] `SubscribeSession` → `registry.subscribe_events(id)` + snapshot/replay
- [ ] `SendMessage` → `registry.send(id, Input::UserSentMessage { ... })`
- [ ] `ApproveTool` → `registry.send(id, Input::UserApproved { ... })`
- [ ] `SteerTurn` → `registry.send(id, Input::UserSteered { ... })`
- [ ] All other actions → route through registry, no lock, no await on IO
- [ ] `CreateSession` → `registry.spawn_session(config)`, broadcast to list
- [ ] `SubscribeList` → `registry.subscribe_list()` + send current summaries
- [ ] Remove all `state.lock().await` calls

### Migrate `main.rs`

- [ ] Replace `Arc::new(Mutex::new(AppState::new(persist_tx)))` with `Arc::new(SessionRegistry::new(persist_tx))`
- [ ] Update session restoration to use registry
- [ ] Update router state type
- [ ] Clean up ended sessions on startup (or add TTL-based cleanup)

### Session cleanup

- [ ] Add cleanup for ended sessions: remove from DashMap after grace period
- [ ] Track ended session count, log when cleanup runs
- [ ] Ensure forked-from references survive cleanup (persist to SQLite, not in-memory only)

### Tests

- [ ] `test_registry_route_to_actor` — send action, verify actor receives it
- [ ] `test_registry_snapshot_read` — read snapshot without blocking
- [ ] `test_registry_list_summaries` — verify concurrent session list
- [ ] `test_registry_remove_session` — verify cleanup
- [ ] `test_concurrent_session_access` — spawn 10 sessions, send actions in parallel

### Verification

- [ ] `cargo test` — all tests pass
- [ ] No `Arc<Mutex<AppState>>` in codebase
- [ ] No `state.lock().await` in websocket.rs
- [ ] `DashMap` lookups are lock-free on read path
- [ ] Manual test: create 5+ sessions concurrently, verify no blocking

---

## Phase 6: Swift Client Updates

**Why**: Complete the feedback loop. The Swift client tracks revisions, requests replay on reconnect, and handles the new event streaming protocol.

**Depends on**: Phase 1 (revision tracking), Phase 2 (broadcast mechanism — for Lagged handling)

### ServerProtocol.swift

- [ ] Add `revision: UInt64?` field to all server message types that carry it
- [ ] Add `sinceRevision: UInt64?` to `ClientToServerMessage.subscribeSession`
- [ ] Add `ServerToClientMessage.eventReplay` case with events array
- [ ] Add `ServerToClientMessage.lagged` case (server signals client fell behind)
- [ ] Decode `revision` from server messages

### ServerConnection.swift

- [ ] Pass `sinceRevision` parameter to `subscribeSession()` method
- [ ] Handle `eventReplay` response: apply events in order via existing callbacks
- [ ] Handle `lagged` response: trigger full re-subscribe with `sinceRevision: nil`

### ServerAppState.swift

- [ ] Add `lastRevision: [String: UInt64]` dictionary
- [ ] Update `lastRevision[sessionId]` from every received server message
- [ ] Pass `lastRevision[sessionId]` to `subscribeSession()` on reconnect
- [ ] Remove `messageRevisions` counter (dead code — incremented but never read)
- [ ] On `lagged`: clear local state for session, re-subscribe with `sinceRevision: nil`

### Tests

- [ ] Manual test: connect, send messages, kill server, restart, verify replay
- [ ] Manual test: pause client for 30s during heavy activity, verify lagged → re-snapshot
- [ ] Verify backward compatibility: old server (no revision) + new client still works

### Verification

- [ ] Xcode clean build
- [ ] Reconnection is seamless — no duplicate messages, no missing events
- [ ] `messageRevisions` removed, `lastRevision` used consistently
- [ ] Works with both revision-aware server and pre-revision server (graceful fallback)

---

## Not Planned (deferred beyond v2)

| Feature | Reason |
|---------|--------|
| Multi-node clustering | Single-machine is sufficient for 100+ agents |
| Event sourcing (full replay from persistence) | Ring buffer covers reconnection; full replay adds complexity |
| Persistent data structures (`im` crate) | Single-writer actor doesn't benefit; Vec has better cache locality |
| Typestate pattern for WorkPhase | Runtime event dispatch defeats the purpose |
| State machine libraries | 4 phases x 15 events is manageable hand-rolled |

---

## Dependencies to Add

```toml
# Phase 4
arc-swap = "1"

# Phase 5
dashmap = "6"

# tokio::sync::broadcast is already available via tokio
```

---

## Files Affected (summary)

### New files
| File | Phase | Purpose |
|------|-------|---------|
| `crates/server/src/transition.rs` | 3 | Pure transition function + types |
| `crates/server/src/transition_tests.rs` | 3 | Unit tests for all transitions |
| `crates/server/src/actor.rs` | 4 | SessionActor impl |
| `crates/server/src/registry.rs` | 5 | SessionRegistry (replaces state.rs) |
| `migrations/015_session_revision.sql` | 1 | Add revision column |

### Modified files
| File | Phases | Changes |
|------|--------|---------|
| `crates/server/src/session.rs` | 1, 2, 4 | Revision → broadcast → thin handle |
| `crates/server/src/state.rs` | 2, 5 | List broadcast → replaced by registry |
| `crates/server/src/codex_session.rs` | 3, 4 | Extract transitions → actor |
| `crates/server/src/websocket.rs` | 1, 2, 5 | Replay → broadcast drain → stateless routing |
| `crates/server/src/persistence.rs` | 1 | Persist/restore revision |
| `crates/server/src/main.rs` | 5 | Registry instead of AppState |
| `crates/protocol/src/server.rs` | 1 | Add revision field |
| `crates/protocol/src/client.rs` | 1 | Add since_revision field |
| `ServerProtocol.swift` | 6 | Revision fields + replay message |
| `ServerConnection.swift` | 6 | Pass since_revision on subscribe |
| `ServerAppState.swift` | 6 | Track revision, handle replay |

---

## Implementation Order

```
Phase 1 ─────────────────────► Phase 2 ────────────────────► Phase 5
  (revision + event log)         (broadcast channel)           (registry)
         │                              │                          │
         └──────► Phase 3 ──────► Phase 4 ─────────────────────────┘
                   (pure fn)       (actor)

Phase 6 can start after Phase 1, runs in parallel with 3-5
```

Phases 1 and 3 are independent of each other.
Phase 2 depends on Phase 1 (uses revision for lagged recovery).
Phase 4 depends on Phase 3 (actor uses transition function).
Phase 5 depends on Phase 4 (registry holds actor handles).
Phase 6 depends on Phase 1, can be done any time after.

### Estimated test count: 50 existing + ~30 new = ~80 total
