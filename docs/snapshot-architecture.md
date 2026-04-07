# Snapshot Architecture

OrbitDock's real-time state architecture. This document describes how live session state flows from server mutation to client render with zero stale reads.

---

## The Core Principle

**In-memory state is the source of truth for live serving. The database is the recovery journal.**

The server maintains authoritative session state in memory. Pure functions project that state into wire types. The database persists mutations for crash recovery but is never read to serve live dashboard, sidebar, or status data.

This eliminates the class of bugs where:
- DB writes are batched (100ms flush) but WS events fire immediately
- Client fetches HTTP after a WS signal and reads stale DB state
- Two code paths (DB-based and memory-based) produce different results because one falls behind

---

## Server: Immutable Snapshots

### The Mutation Flow

Every session state change follows one path:

```
Connector event (hook, transcript line, API call)
    ↓
SessionHandle (mutable, actor-isolated — only the actor can touch it)
    ↓  broadcast() — single mutation gate
    ↓
to_snapshot() — pure function, extracts immutable snapshot
    ↓
ArcSwap::store() — atomic publish, lock-free
    ↓
Arc<SessionSnapshot> — immutable, cannot be modified after publish
    ↓
Pure projection functions — one per surface concern
    ↓
Wire type (DashboardConversationItem, etc.) — sent over WS or returned via HTTP
```

### Structural Guarantees

These aren't conventions — they're enforced by Rust's type system and ownership model:

1. **`SessionHandle`** is owned by the actor task. No reference escapes. No lock needed because only one task can access it.

2. **`broadcast()`** is the single gate. Every mutation ends here. It calls `to_snapshot()`, stores to `ArcSwap`, and emits WS events. There is no other publish path.

3. **`Arc<SessionSnapshot>`** is immutable after publish. `Arc` provides shared ownership. The snapshot struct has no interior mutability. Once published, it cannot change — readers always see a consistent state.

4. **`ArcSwap`** provides atomic replacement. Readers never see a half-written snapshot. A reader either gets the old snapshot or the new one, never a mix.

5. **Projection functions** are pure: `fn surface_item_from_snapshot(&SessionSnapshot) -> WireType`. No `&self`, no DB handle, no async, no side effects. They physically cannot reach for stale state because they have no access to anything except their input.

### Projection Modules

Each surface concern gets a pure projection module in the domain layer and a registry-level aggregation function in the runtime layer:

```rust
// domain/sessions/dashboard_projection.rs — pure projection, no IO, no DB

/// The ONLY way to build a DashboardConversationItem from live state.
pub fn dashboard_item_from_snapshot(snap: &SessionSnapshot) -> DashboardConversationItem { ... }

/// Sorting priority for dashboard ordering.
pub(crate) fn dashboard_priority(item: &DashboardConversationItem) -> u8 { ... }

/// Whether this conversation is a direct (non-passive) session.
pub(crate) fn is_direct_conversation(item: &DashboardConversationItem) -> bool { ... }
```

```rust
// runtime/dashboard.rs — aggregation over the registry

/// Builds a complete DashboardSnapshot by iterating all active session snapshots.
pub fn dashboard_snapshot_from_registry(registry: &SessionRegistry) -> DashboardSnapshot { ... }
```

The projection module lives in `domain/sessions/` (not `runtime/`) so that `SessionHandle::broadcast()` can call it without a cross-layer dependency. Helper functions (`dashboard_preview_text`, `dashboard_activity_summary`, `dashboard_alert_context`, `dashboard_grouping_details`) are private to the projection module.

### WS Event Emission

There are exactly two server paths that emit dashboard WS events. Both use the same pure projection function:

**Path 1: `SessionHandle::broadcast()`** — the normal path. When a state change is dashboard-relevant (via `should_emit_dashboard_invalidation()`), broadcast:

1. Calls `to_snapshot()` to capture the current state
2. Calls `dashboard_item_from_snapshot()` to project the wire type
3. Emits `DashboardConversationUpdated { revision, item }` via the list broadcast channel

**Path 2: `SessionRegistry::notify_dashboard_session_updated(session_id)`** — for code paths that mutate state without going through broadcast (session creation, resume completion, materialization). It:

1. Reads the session's `ArcSwap<SessionSnapshot>` from the registry
2. Calls `dashboard_item_from_snapshot()` to project the wire type
3. Emits `DashboardConversationUpdated { revision, item }`
4. Falls back to `DashboardInvalidated` if the session isn't in the registry

Both paths produce the same wire type through the same pure function. The client receives the complete, pre-computed item inline. No HTTP round-trip needed.

`DashboardInvalidated` is emitted only on WS subscribe (reconnection bootstrap) — never during normal operation.

### HTTP Handlers

HTTP dashboard/status endpoints read from in-memory state:

```rust
pub async fn get_dashboard_snapshot(
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<DashboardSnapshot> {
    Ok(Json(dashboard_snapshot_from_registry(&state)))
}
```

No `ReadPool`. No SQL query. No async DB call. The function iterates the `DashMap`, reads each session's `ArcSwap<SessionSnapshot>`, and projects through the pure function.

### What the DB Is For

The database is read in exactly two scenarios:

1. **Server startup** — hydrate `SessionHandle` from persisted state. Once hydrated, the DB is not consulted for live serving.
2. **Library/history** — paginated queries over ended sessions and historical data that isn't held in memory.

For live active sessions, the DB is write-only. Persist commands flow through the `PersistenceWriter` (batched, async) and exist solely for crash recovery.

---

## Client: Snapshot Replacement

### The SwiftUI Contract

SwiftUI's `@Observable` requires mutable stored properties to trigger view updates. The architecture satisfies this with a single pattern: **snapshot replacement**.

```
WS event (DashboardConversationUpdated) ──→ DataService.snapshot = newValue
HTTP response (full snapshot) ──→ DataService.snapshot = newValue
```

The mutation is always a full property replacement. Never a partial field update. Never assembly from parts.

### The Data Flow

```
┌─────────────── Server ──────────────────┐
│                                          │
│  SessionHandle → ArcSwap<Snapshot>       │
│       ↓                                  │
│  Pure projection fn → Wire type          │
│       ↓                                  │
│  WS push / HTTP response                │
└────────┬─────────────────────────────────┘
         │
    ── wire ──
         │
┌────────┴──── Client ────────────────────┐
│                                          │
│  DataService (@Observable)               │
│    private(set) var snapshot: T?         │
│    ← single mutable property             │
│                                          │
│  ViewModel (thin computed layer)         │
│    var items: [Item] { snapshot.items }  │
│    var counts: Counts { snapshot.counts }│
│    ← all computed, no stored duplicates  │
│                                          │
│  View (declarative render)              │
│    ForEach(viewModel.items) { ... }     │
│    ← reads computed, triggers on change  │
└──────────────────────────────────────────┘
```

### Client Rules

1. **DataService** owns exactly one `private(set) var snapshot: T?` per concern. This is the only mutable property that holds server state. WS events and HTTP responses both funnel into replacing this property.

2. **ViewModel** is a thin computed layer over the data service. Server-derived state is always computed from `dataService.snapshot`. Local UI state (filters, sort order, selection) is stored in the ViewModel — that's client-only state, not server truth.

3. **Views** read from ViewModel. `@Observable` tracking propagates through the computed property chain automatically — SwiftUI sees the stored property change on `DataService`, traces through the computed chain, and invalidates only the views that read the affected data.

4. **No assembly from parts.** The client never combines data from multiple sources to construct what a session looks like. The server sends complete, pre-computed items. The client renders them.

5. **No parallel state trees.** There is one path from server to screen. WS events don't write to different properties than HTTP responses. Both write to the same `snapshot` property.

### Incremental vs Full Snapshot

The client supports two update modes:

- **Incremental** (`DashboardConversationUpdated`): upsert a single item into the existing snapshot. Used for real-time updates during normal operation.
- **Full** (HTTP `GET /api/dashboard`): replace the entire snapshot. Used for initial load, reconnection, and resync.

Both modes end the same way: `self.snapshot = newSnapshot`. The incremental path builds the new snapshot from the old one + the updated item, then replaces. There is no in-place mutation.

---

## Extending to New Surfaces

Every new real-time surface follows the same pattern:

### Server Side

1. Add a pure projection function: `fn surface_item_from_snapshot(&SessionSnapshot) -> SurfaceWireType`
2. Emit the projected item via the list broadcast channel in `broadcast()` when relevant fields change
3. Add an HTTP handler that iterates snapshots and calls the projection function

### Client Side

1. Add a stored property on the relevant DataService: `private(set) var surfaceSnapshot: SurfaceType?`
2. Handle the WS event by replacing the property
3. Add computed accessors in the ViewModel
4. Views read from ViewModel

### Current Surface Map

| Surface | Server projection | WS event (incremental) | WS event (resync) | Client property |
|---|---|---|---|---|
| Dashboard | `dashboard_item_from_snapshot()` | `DashboardConversationUpdated` | `DashboardInvalidated` | `DashboardDataService.snapshot` |
| Session detail | per-session WS subscription | `SessionDelta` | subscribe | `SessionDetailStore.state` |
| Library | DB query (cold/historical data) | — | `DashboardInvalidated` | `DashboardDataService.librarySessions` |
| Menu bar | reads dashboard snapshot | — | — | derives from `DashboardDataService.snapshot` |

---

## Hard Rules

These are not suggestions. Violating any of them reintroduces the class of bugs this architecture was built to eliminate.

### Server

1. **Never read from the DB to serve live data.** If a field is needed on the dashboard or any real-time surface, it must live on `SessionSnapshot`. The DB is for startup hydration and historical queries only.

2. **Never build a wire type by hand.** Every `DashboardConversationItem` (or future surface wire type) must come from the pure projection function. No constructing items inline in handlers, hooks, or registry methods.

3. **Never emit `DashboardInvalidated` during normal operation.** It exists only for WS reconnection bootstrap (subscribe handler). All state changes emit `DashboardConversationUpdated` with the projected item, either via `broadcast()` or `notify_dashboard_session_updated()`.

4. **New fields go on `SessionSnapshot`, not just `SessionHandle`.** If you add a field to `SessionHandle` that affects any surface, also add it to `SessionSnapshot` and `to_snapshot()`. Otherwise the projection function can't see it, and you'll end up reaching around the architecture.

5. **Projection functions stay pure.** No `&self`, no DB handle, no `async`, no side effects. Input is `&SessionSnapshot`, output is the wire type. If you need data the snapshot doesn't have, add it to the snapshot — don't add a DB call to the projection.

### Client

1. **One stored property per concern.** `DashboardDataService.snapshot` is the single mutable property for dashboard state. Don't add a second property that tracks the same data differently.

2. **Server state is always computed, never stored, on the ViewModel.** If you find yourself writing `var sessions: [Session]` on a ViewModel and manually keeping it in sync, you're creating a parallel state tree. Read from `dataService.snapshot` via computed properties.

3. **Both WS and HTTP write to the same property.** Incremental updates and full refetches both end at `self.snapshot = newValue`. Don't create separate paths that write to different properties.

---

## What This Architecture Kills

- **DB read-after-write staleness** — live state never reads from the DB
- **Dual code paths** — there is one projection function per surface, not a DB path and a memory path
- **Client-side state assembly** — the server sends complete items, the client renders them
- **Multiple mutation points** — server has `broadcast()`, client has `snapshot = newValue`
- **Invisible state drift** — `ArcSwap` is atomic, snapshots are immutable, pure functions have no side effects
