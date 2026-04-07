# Architecture

OrbitDock has two architectural halves — a Rust server that owns all business state, and native clients (SwiftUI) that render it. This doc covers both.

---

## Part 1: Client Architecture

The OrbitDock client is organized around one core pattern and a set of guardrails to prevent common pitfalls.

### The Core Pattern

Every UI surface follows the same data-flow architecture:

1. **HTTP snapshot on view appear** — the view model fetches its data from a REST endpoint and owns it.
2. **WebSocket subscription while on screen** — server events signal that something changed; the client re-fetches the HTTP snapshot.
3. **View model is the single source of truth** — for that surface only. No shared mutable session objects.

When the user navigates away, the subscription tears down. No background state accumulation.

#### Example Flow

```swift
@Observable
final class SurfaceViewModel {
  var snapshot: SurfaceSnapshot?

  func refresh() async {
    // Coalesce: skip if already refreshing, queue one more
    let payload = try await store.clients.surface.fetch(sessionId)
    // Revision guard: never regress
    guard payload.revision >= (snapshot?.revision ?? 0) else { return }
    snapshot = SurfaceMapper.map(payload)
  }
}

// In the view:
.task(id: sessionId) {
  viewModel.bind(...)
  await viewModel.refresh()
}
.task(id: sessionId + ":ws") {
  let stream = store.sessionChanges(for: sessionId)
  for await _ in stream {
    await viewModel.refresh()
  }
}
```

### Surface Model

Each screen in the app maps to one view model and one HTTP endpoint:

| Surface | HTTP Endpoint | WS Triggers |
|---------|---|---|
| Dashboard | `GET /api/dashboard` | `dashboardInvalidated` |
| Library | `GET /api/library` | `dashboardInvalidated` |
| Mission Control | `GET /api/missions` | `missionsInvalidated` |
| Session Detail | `GET /api/sessions/{id}/detail` | `sessionDelta`, `sessionEnded` |
| Control Deck | `GET /api/sessions/{id}/control-deck` | `sessionDelta`, `approvalRequested`, `tokensUpdated` |
| Conversation | `GET /api/sessions/{id}/conversation` | `conversationRowsChanged` (data-carrying exception) |
| Skills/MCP | `GET /api/sessions/{id}/skills`, `/mcp/tools` | `skillsList`, `mcpToolsList` |
| Review Canvas | `GET /api/sessions/{id}/diffs` | `turnDiffSnapshot`, `reviewComment*` |

### Ownership Rules

**The server owns all business state.** The Swift client should render server state, not reconstruct business logic by scanning history or guessing queue state. If the client needs new durable truth, change the server contract.

**Each view model owns its screen state** via HTTP snapshots. There is no shared mutable session object. Each surface fetches and owns its own data.

- `SessionStore` is a transport shell. It manages the WS connection and exposes change streams. It does not hold session state.
- View models own screen-specific state and orchestration.
- Views stay declarative — render state, forward gestures.

### WebSocket Semantics

**WS events are signals, not state.**

When a WebSocket event arrives (approval requested, config changed, session status), the client should re-fetch the owning HTTP snapshot and apply it as the single source of truth. Do not bridge WS event payloads directly into view model properties — that creates a parallel state tree that drifts from the server and causes bugs where the UI shows stale or missing state until the user navigates away and back.

**The only exception:** conversation row deltas, which carry server-assigned sequence numbers and are applied incrementally by design.

### Global WebSocket

One lightweight global WS connection handles infrastructure events only:

- `connectionStatusChanged` — triggers reconnect/recovery
- `error` — server error handling and resync
- `serverInfo` — server metadata
- `modelsList` — global model catalog
- `revision` — revision tracking for replay

These are not per-surface. They affect the transport layer, not UI state.

### What Does NOT Exist

- No `SessionObservable` — no shared mutable object holding all session state.
- No `SessionStateProjection` — no layer that applies server snapshots to a shared object.
- No `SessionControlStateReducer` — no state machine processing WS events into transitions.
- No `CapabilitiesService` — view models call HTTP clients directly.
- No `withObservationTracking` on shared objects — view models own their state.

### `SessionStore` Role

`SessionStore` is a thin transport shell:

- Manages the WS connection lifecycle
- Exposes `sessionChanges(for:)` — an `AsyncStream<Void>` per session that yields when any WS event arrives
- Exposes `conversationRowChanges(for:)` — an `AsyncStream<ConversationRowDelta>` per session for row deltas
- Exposes typed HTTP clients via `store.clients`
- Handles connection recovery and session re-subscription

`SessionStore` does NOT:

- Hold session state
- Mutate shared observables
- Own feature logic
- Decide what UI should show

### REST And WebSocket Split

Default to REST for client-initiated reads and mutations.

Use WebSocket for:

- subscriptions
- streaming turn interaction
- server-pushed real-time events

If a REST mutation needs to notify other clients, let the server broadcast the result afterward. Do not send the mutation itself over WebSocket just because a broadcast follows.

### Client Mutation Flow

1. View model receives user intent (tap, submit, config change).
2. View model calls the typed HTTP client (`store.clients.controlDeck.updateConfig(...)`)
3. The HTTP response is the authoritative state — view model applies it as the new snapshot.
4. WS events reconcile any remaining drift via the next refresh cycle.

---

## Part 2: Server State Architecture

The Rust server owns all durable session state. Every mutation follows one path: **validate → persist → broadcast**. The database is always the source of truth.

### The Transition System

All session state mutations flow through a pure transition function:

```rust
fn transition(state: TransitionState, input: Input, now: DateTime) -> (TransitionState, Vec<Effect>)
```

This function is pure and synchronous — no IO, no side effects. It takes the current state and an input event, and returns the new state plus a list of effects to execute. The effects are:

- `Effect::Persist(PersistOp)` — write to the database
- `Effect::Emit(ServerMessage)` — broadcast to WebSocket subscribers

The session actor executes these effects after the transition completes. Persist and broadcast always happen together — if the transition says to persist, it also says to broadcast, so clients never see stale state and the database never misses a mutation.

**Location:** `connector-core/src/transition.rs`

### How Events Flow

```
Connector event (hook, transcript line, API response)
    ↓
SessionCommand::ProcessEvent { event: Input }
    ↓
Session actor receives command
    ↓
extract_state() — pull current TransitionState from SessionHandle
    ↓
transition(state, input, now) — pure function, returns (new_state, effects)
    ↓
apply_state() — write new TransitionState back to SessionHandle
    ↓
Execute effects:
  - Persist → send to persistence actor via mpsc
  - Emit → broadcast to WebSocket subscribers via tokio::broadcast
```

Every connector (Claude hooks, Codex hooks, direct sessions) feeds events into `ProcessEvent`. The transition function decides what changes, what persists, and what broadcasts. No connector code should persist or broadcast directly.

### Session Actor Model

Each session gets its own actor task. External callers interact through `SessionActorHandle`, which sends commands over an mpsc channel. This means:

- **No locks** — the actor processes commands sequentially
- **Lock-free reads** — `ArcSwap<SessionSnapshot>` lets any thread read the latest snapshot without blocking the actor
- **No shared mutable state** — the actor owns `SessionHandle`, nobody else touches it

The actor loop:

```
loop {
  select! {
    cmd = command_rx.recv() => handle_session_command(cmd, &mut handle, &persist_tx),
    event = connector_rx.recv() => dispatch_transition_input(event, &mut handle, &persist_tx),
  }
}
```

### Input Variants

The `Input` enum covers every kind of state change:

| Category | Examples |
|----------|---------|
| Lifecycle | `Started`, `Ended`, `Paused`, `Resumed` |
| Work progress | `WorkingOnTool`, `ToolCompleted`, `ThinkingStarted` |
| Approvals | `ApprovalRequested`, `AttentionUpdated` |
| Config | `ModelUpdated`, `EffortUpdated`, `PermissionModeChanged` |
| Environment | `EnvironmentChanged`, `TranscriptPathUpdated` |
| Content | `SummaryUpdated`, `FirstPromptCaptured`, `PlanUpdated` |
| Subagents | `SubagentStarted`, `SubagentStopped` |

When adding a new state mutation, add a new `Input` variant and handle it in the transition function. Do not bypass the transition system.

### The One Rule

**Every state mutation must go through `ProcessEvent`.** No exceptions for "simple" fields or "just a broadcast."

The transition function is the only place that decides:
- What the new state looks like
- What gets persisted
- What gets broadcast to clients

This guarantees:
- The database is always consistent with in-memory state
- Every client sees every change
- Server restart recovers the exact state that was last persisted
- Business logic is testable in isolation (the transition function is pure)

### Approved Exceptions

A small number of `ApplyDelta { persist_op: None }` calls remain. These are intentional and documented:

| Location | Reason |
|----------|--------|
| `handler.rs` (2 sites) | Ephemeral UI broadcasts (tool_result/tool_error working status) — the real persist happens through the transition that follows |
| `session_resume.rs` | Timing-sensitive init — permission_mode must broadcast before the connector loop starts |
| `session_direct_start.rs` | Same timing-sensitive init pattern as resume |
| `git_refresh.rs` | Filesystem-derived state (git status), not business truth |
| Test-only sites | Test helpers that need lightweight state setup |

If you're adding a new `ApplyDelta { persist_op: None }`, stop and route through `ProcessEvent` instead.

### Approval Flow

Approvals follow the same transition path:

**Request:** Connector detects a tool needing approval → `ProcessEvent(Input::ApprovalRequested { ... })` → transition atomically sets pending_approval, work_status, persists the approval row AND the session update, and broadcasts to all subscribers.

**Resolve:** HTTP handler calls `SessionCommand::ResolvePendingApproval` → the handler resolves in-memory, persists the updated work_status, broadcasts the delta, and returns the result. Callers do not need to separately persist — the handler owns the full persist + broadcast cycle.

### Anti-Patterns

These patterns were eliminated during the refactor. Do not reintroduce them:

**Fire-and-forget commands** — Commands like `SetModel`, `SetLastTool`, `SetPendingApproval` that mutated in-memory state without persisting or broadcasting. State was lost on restart and clients saw stale data.

**Split persist + broadcast** — Sending `ApplyDelta { persist_op: None }` for the broadcast, then a separate `PersistCommand` for the persist. If either failed, the database and in-memory state would diverge.

**Caller-side persist after resolve** — Callers of `ResolvePendingApproval` separately sending `PersistCommand::SessionUpdate` for work_status. The handler now owns this, so callers should not persist work_status themselves.

**Direct state mutation from connectors** — Connector code reaching into `SessionHandle` to mutate fields directly instead of routing through the transition system.

---

## Part 3: Engineering Guardrails

### Server-Authoritative State

The Rust server owns durable session and approval truth. The Swift client should render server state, not reconstruct business logic by scanning history or guessing queue state. If the client needs new durable truth, change the server contract.

### Typed Protocol Boundaries

Keep the Swift side strongly typed to match Rust serde models.

- do not introduce `AnyCodable` for payloads that have a real schema
- keep unknown server message variants resilient so the connection does not crash on forward-compatible changes
- prefer explicit typed payloads over generic bags of fields

For detailed protocol contracts, see [data-flow.md](data-flow.md).

### SQLite Ownership

Only the Rust server reads from and writes to SQLite directly.

The app and CLI should go through server APIs. If a workflow needs direct DB access to function, that is usually a design smell.

### Conversation Row Persistence

Conversation row writes must follow the server's single-writer path.

Do not introduce side paths that write rows directly and race sequence assignment. This is one of the easiest ways to create subtle ordering bugs.

For the persistence model and database operations, see [OPERATIONS.md](OPERATIONS.md).

### State Scoping

Keep state endpoint-scoped. Cache values by scoped session identity (endpoint + session ID) to prevent cross-server bleeding. Always guard async callbacks with a current scoped-id check.

Per-session observation uses per-session `@Observable` classes. Access via `serverState.session(scopedId)`. Views observe only the session they display.

### Shared Mutable State Anti-Pattern

Do not create:

- shared mutable session objects (no god objects)
- `withObservationTracking` on shared state stores
- feature services that wrap HTTP clients just to mutate a shared observable
- global event processing for surfaces that aren't on screen

View models call HTTP clients directly.
