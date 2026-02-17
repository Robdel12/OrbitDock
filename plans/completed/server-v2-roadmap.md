# Server Architecture v2 — Implementation Roadmap

> Goal: Refactor the OrbitDock Rust server from mutex-heavy shared state to a pure state machine + actor architecture. Handle 100+ concurrent agents with zero cross-session contention.
>
> Each phase is a shippable unit. The system stays running between phases — no big bang rewrite.
>
> For the full design rationale, types, and diagrams, see `plans/completed/server-architecture-v2.md`.

---

## Current Architecture (what we migrated from)

| Component | Pattern | Problem | Fixed |
|-----------|---------|---------|-------|
| AppState | `Arc<Mutex<AppState>>` | Global lock blocks ALL sessions during any single session's IO | Phase 5 |
| SessionHandle | `Arc<Mutex<SessionHandle>>` per session | Locks held across awaits in `handle_event` | Phase 4 |
| Broadcast | `Vec<mpsc::Sender<ServerMessage>>` | One slow client blocks all others; manual cleanup | Phase 2 |
| Reconnection | Full snapshot on every subscribe | No revision tracking, no event replay | Phase 1 |
| Business logic | 27 match arms mixing state + IO in handle_event | Untestable without IO mocking | Phase 3 |
| Event loop | `select!` on events + actions | Long connector calls starve event processing | Phase 4 |
| Session cleanup | None | 12+ dictionaries leaked per ended session | Phase 6 (Swift) |

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
- `spawn_broadcast_forwarder()` handles `Lagged` errors by sending a `lagged` error to the client with the affected session ID, enabling automatic re-subscribe
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

## Phase 4: Session Actor Refactor ✅

**Status**: Complete. Actor owns `SessionHandle` directly (no `Arc<Mutex>`). External callers use `SessionActorHandle` which sends `SessionCommand` over mpsc. Lock-free reads via `ArcSwap<SessionSnapshot>`.

Key decisions:
- `SessionActorHandle` is the thin routing handle: `command_tx`, `snapshot: Arc<ArcSwap<SessionSnapshot>>`
- `SessionHandle` retains all state fields (messages, tokens, etc.) — owned by actor task
- `handle_session_command()` shared by both `CodexSession` event loop and passive `SessionActor`
- `ProcessEvent` command bridges to transition function for connector events
- `session_actor.rs` for passive sessions, `codex_session.rs` for active Codex connector sessions
- 4 actor tests: sequential commands, snapshot updates, subscribe, connector events

---

## Phase 4b: Actor Command Cleanup ✅

**Status**: Complete.

Cleaned up the command layer that was designed 1:1 with setter methods during Phase 4 migration. Three problems fixed:

1. **Unconditional `refresh_snapshot()`** — removed 10 per-command `refresh_snapshot()` calls, added single unconditional call at end of `handle_session_command`. Every command now gets a fresh snapshot automatically.

2. **Compound commands replace multi-send patterns** — callers no longer need 3-11 separate commands for one logical operation:
   - `ApplyDelta { changes, persist_op }` — apply StateChanges + persist + broadcast SessionDelta
   - `EndLocally` — status=Ended, work_status=Ended, broadcast delta
   - `SetCustomNameAndNotify { name, persist_op, reply }` — set name + persist + broadcast + return summary

3. **Dead code removed** — `SetWorkStatusAndBroadcast` (unused, carried redundant `persist_tx`)

Supporting additions:
- `SessionHandle::apply_changes(&StateChanges)` — applies each `Some` field from delta
- `PersistOp` enum — actor converts to `PersistCommand` internally, callers don't need `persist_tx`
- Individual `Set*` commands kept for standalone fire-and-forget metadata updates (rollout_watcher, session creation)

---

## Phase 5: Replace AppState with SessionRegistry ✅

**Status**: Complete. Shipped in commit `79f8dd9`.

Replaced `Arc<Mutex<AppState>>` with lock-free `SessionRegistry` backed by `DashMap`. WebSocket handlers are now pure routing — no locks held, no IO blocking.

Key decisions:
- `DashMap<String, SessionActorHandle>` for sharded, lock-free lookups
- `ArcSwap<SessionSnapshot>` for wait-free snapshot reads
- `tokio::broadcast` for list-level events
- Session cleanup on end: remove from DashMap after actor exits
- All lock contention eliminated from the hot path

---

## Phase 6: Swift Client Updates ✅

**Status**: Complete.

The Swift client now fully supports the v2 server protocol: revision tracking, incremental replay, per-session observation, memory cleanup, and automatic recovery from broadcast lag.

### What was implemented

**Revision tracking (during Phase 1):**
- `revision: UInt64?` field on `ServerSessionState`
- `sinceRevision: UInt64?` on `subscribeSession` client message
- `lastRevision: [String: UInt64]` tracking in `ServerAppState`
- Pass `lastRevision[sessionId]` on reconnect

**Revision extraction (Phase 6):**
- `onRevision` callback on `ServerConnection` — extracts revision from replay events via JSON
- `lastRevision` updated from both snapshots and replay events

**Per-session @Observable (Phase 6):**
- `SessionObservable` — per-session `@Observable` class with all session-scoped state
- `@ObservationIgnored` registry on `ServerAppState` with `session(_:)` accessor
- 15 per-session dictionaries removed from `ServerAppState`
- Views observe only the session they display — no cascading re-renders
- `ConversationView` observes `messagesRevision` (scoped to displayed session)
- 13 view files updated to use `serverState.session(id)` pattern

**Memory cleanup (Phase 6):**
- `clearTransientState()` on session end — clears pending approval, MCP, skills, diff, plan, fork/undo flags
- Keeps messages/tokens/history alive for viewing ended sessions
- Full eviction of `SessionObservable` when sessions disappear from server list
- Internal tracking cleaned: `subscribedSessions`, `lastRevision`, `approvalPolicies`, `sandboxModes`, `sessionStates`

**Lagged handling (Phase 6):**
- Server: `spawn_broadcast_forwarder()` sends `Error { code: "lagged", session_id }` to client when broadcast buffer overflows
- Client: `handleError` catches `"lagged"` code, unsubscribes and re-subscribes to get fresh snapshot
- All 9 `spawn_broadcast_forwarder` call sites pass session ID (except `SubscribeList` which passes `None`)

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

## Dependencies Added

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
| `SessionObservable.swift` | 6 | Per-session @Observable class |

### Modified files
| File | Phases | Changes |
|------|--------|---------|
| `crates/server/src/session.rs` | 1, 2, 4 | Revision → broadcast → thin handle |
| `crates/server/src/state.rs` | 2, 5 | List broadcast → replaced by registry |
| `crates/server/src/codex_session.rs` | 3, 4 | Extract transitions → actor |
| `crates/server/src/websocket.rs` | 1, 2, 5, 6 | Replay → broadcast drain → stateless routing → lagged notification |
| `crates/server/src/persistence.rs` | 1 | Persist/restore revision |
| `crates/server/src/main.rs` | 5 | Registry instead of AppState |
| `crates/protocol/src/server.rs` | 1 | Add revision field |
| `crates/protocol/src/client.rs` | 1 | Add since_revision field |
| `ServerProtocol.swift` | 6 | Revision fields |
| `ServerConnection.swift` | 6 | Pass since_revision, extract revision from replay |
| `ServerAppState.swift` | 6 | Registry pattern, per-session observables, memory cleanup, lagged recovery |
| 13 SwiftUI view files | 6 | Use `serverState.session(id)` pattern |

---

## Implementation Order (completed)

```
Phase 1 ────► Phase 2 ────► Phase 5
  (revision)    (broadcast)    (registry)
     │               │            │
     └──► Phase 3 ──► Phase 4 ───┘
           (pure fn)   (actor)

Phase 6 ran in parallel with 3-5 (Swift client)
```

All 6 phases complete. Server v2 architecture is fully shipped.
