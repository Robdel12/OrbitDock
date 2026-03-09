# Client Networking and State Rewrite

This is a clean-break rewrite plan for OrbitDock's client networking and state architecture.

The goal is not to patch the current model. The goal is to replace it with a store-first architecture that treats REST and WebSocket as complementary transports feeding one authoritative client state model.

This plan assumes:

- We are free to restructure the Swift client however we want.
- We are free to make breaking API changes on the server.
- We do not need legacy compatibility shims.
- We do not carry forward tech debt just to reduce migration cost.

This also means server-side structural debt is in scope. We are not building a clean client architecture on top of giant server monoliths that are already hard to reason about.

---

## Outcome We Want

When this rewrite is complete:

- Every endpoint has exactly one authoritative client state owner.
- Views never call `APIClient` directly.
- Views never manually patch local state after requests.
- Dashboard, detail views, toasts, and attention UI all read from the same live state graph.
- Every REST mutation has an explicit contract.
- Every replicated server event has revision/version semantics.
- Reconnect, replay, delayed events, and out-of-order events are deterministic and testable.

---

## Non-Negotiable Rules

These rules apply to every phase.

- No `NotificationCenter` for core state propagation.
- No direct `APIClient` usage from SwiftUI views.
- No duplicate state authorities for the same entity.
- No view-owned server caches.
- No "temporary" dual paths where both old and new stores mutate the same state.
- No arbitrary sleeps or polling in tests.
- No mocking OrbitDock's own state logic.
- No legacy fallbacks once a phase is migrated.
- No keeping giant multi-domain server files around just because they already work.

---

## Target Architecture

### Transport Layer

- `APIClient`
  - Pure HTTP transport.
  - Stateless.
  - No callbacks.
  - No state mutation.

- `EventStream`
  - Pure WebSocket transport.
  - Responsible only for connection lifecycle and decoding frames into typed events.
  - No store updates.

### Endpoint State Layer

- `EndpointStore`
  - `@Observable`
  - `@MainActor`
  - The single authority for one configured server endpoint.
  - Owns:
    - transport instances
    - connection lifecycle
    - query hydration
    - mutation intents
    - event reconciliation
    - per-domain state buckets

- `EndpointState`
  - Plain Swift structs where possible.
  - Broken into domain slices:
    - `SessionsIndexState`
    - `SessionStateByID`
    - `ConversationStateBySessionID`
    - `ApprovalStateBySessionID`
    - `ReviewStateBySessionID`
    - `WorktreeStateByRepoRoot`
    - `AccountState`
    - `ModelsState`
    - `ServerInfoState`

### App-Level Projection Layer

- `AppStore`
  - `@Observable`
  - Projects across endpoint stores.
  - Owns no duplicated server entities.
  - Computes:
    - dashboard session lists
    - endpoint health
    - quick switcher data
    - attention/toast state
    - active selection and routing support

### View Layer

- Views only:
  - observe state
  - send intents
  - render loading/error/operation state

- Views never:
  - fetch directly
  - patch server state locally
  - subscribe to ad hoc notifications
  - coordinate refreshes themselves

---

## State Contract Rules

Every endpoint operation must be classified into one of these buckets.

### 1. Query / Hydrate

The REST response is authoritative and is applied immediately to the store.

Examples:

- fetch sessions list
- fetch session snapshot
- fetch conversation bootstrap/history
- list approvals
- list review comments
- list worktrees
- list models
- read account state

### 2. Mutate / Response Authoritative

The REST response returns the updated entity or updated slice. The store applies it immediately. WebSocket may still replicate to other clients, but the initiating client does not wait for WS to update itself.

Examples:

- rename session
- update session config
- create review comment
- update review comment
- delete review comment
- create worktree
- remove worktree
- mark session read
- set server role
- set client primary claim

### 3. Mutate / Accepted + Eventual WS

REST only acknowledges that work started. WebSocket is authoritative for state changes.

Examples:

- send message
- steer turn
- interrupt session
- compact context
- undo
- rollback
- shell execute
- provider-driven turn actions

### 4. Mutate / Response + WS Replication

REST updates the initiating client immediately. WebSocket replicates the same change to all other subscribers.

Use this only when there is clear value in immediate response application plus cross-client replication.

---

## Required Server Contract Changes

These changes should happen early and intentionally.

### Revisions and Versions

Approval versioning is good. The rest of the system needs the same discipline.

Add explicit revision/version fields for:

- `sessions_revision`
- `session_revision` per session
- `conversation_revision` per session
- `review_revision` per session
- `worktree_revision` per repo root
- `account_revision`
- `models_revision`

### Endpoint Response Rules

The following endpoints should return authoritative state and emit matching replicated events where needed:

- `PATCH /api/review-comments/{id}`
  - Return updated comment
  - Broadcast `review_comment_updated`

- `DELETE /api/review-comments/{id}`
  - Return deleted comment metadata including `comment_id` and `session_id`
  - Broadcast `review_comment_deleted`

- `POST /api/worktrees`
  - Return created worktree
  - Broadcast `worktree_created`

- `DELETE /api/worktrees/{id}`
  - Return removed worktree metadata
  - Broadcast `worktree_removed`

- `POST /api/worktrees/discover`
  - Treat as a query hydrate endpoint, not an ambiguous mutation
  - Return full worktree list for the repo root

- approval decision endpoints
  - Return authoritative approval outcome
  - Return next active approval identity if one exists
  - Include approval version

- create/fork/resume/takeover endpoints
  - Return authoritative session summary
  - Broadcast matching session list/session state events when cross-client visibility matters

### Event Taxonomy

WebSocket events should be domain-specific and reconciler-friendly.

Examples:

- `sessions_list_replaced`
- `session_upserted`
- `session_removed`
- `session_state_changed`
- `conversation_snapshot`
- `conversation_message_appended`
- `conversation_message_updated`
- `approval_state_changed`
- `review_comment_created`
- `review_comment_updated`
- `review_comment_deleted`
- `worktree_list_replaced`
- `worktree_created`
- `worktree_updated`
- `worktree_removed`
- `server_info_updated`

If an event exists only to preserve an old client shape, delete it.

---

## Testing Philosophy for This Rewrite

This rewrite follows the `testing-philosophy` skill explicitly.

Every phase must follow the same testing rules.

### What We Test

Test user-visible outcomes:

- sessions appear where expected
- detail views reflect server changes
- approval UI advances correctly
- reconnect produces consistent state
- review/worktree changes appear immediately and replicate correctly

Do not test implementation details like:

- a specific helper being called
- a specific array mutation
- a private cache being updated

This is the standard for the entire rewrite:

- test like a user
- minimize mocking
- prefer functional/state-machine style logic where possible
- test at the right level
- wait for concrete state or concrete events, never arbitrary time

### Allowed Test Doubles

Mocks are acceptable only at external boundaries:

- network transport
- time
- randomness

Do not mock our own stores, reducers, or reconcilers. If they are hard to test, refactor them.

### Test Levels

- Unit
  - pure reducers
  - revision gating
  - merge/reconcile logic
  - routing/projection logic

- Integration
  - store + transport + event reconciliation together
  - REST response application plus WS replication
  - reconnect and replay flows

- E2E / UI
  - high-value end-to-end user workflows only
  - use concrete state changes, not sleeps

### Event-Driven Testing Rule

When testing async state, wait for concrete state transitions or concrete emitted events. Never use arbitrary delays.

---

## Phase 0: Architecture Spec and Deletion Map

Status: Complete

Source of truth: `plans/client-networking-state-phase-0.md`

### Objective

Lock the target architecture and the server/client contracts before code starts moving.

### Deliverables

- Written architecture spec for:
  - `EndpointStore`
  - `AppStore`
  - domain state slices
  - intent APIs
  - event taxonomy
  - revision model
- Deletion map for current client-side state infrastructure
- Endpoint contract matrix for every REST endpoint and WS event

### Tasks

- [x] Inventory every current REST endpoint and classify it as hydrate, response-authoritative mutate, accepted+eventual WS, or response+WS replication.
- [x] Inventory every current WS event and map it to its target domain state.
- [x] Define new store boundaries and ownership rules.
- [x] Define which current types will be deleted rather than migrated.
- [x] Define phase-level cut lines so old and new architecture do not overlap ambiguously.

### Testing

- Unit-test the pure contract classification helpers if code is introduced.
- No UI work yet.
- No mocks of internal state logic.

### Exit Criteria

- A developer can answer "where does this state live?" for every major entity with one sentence.
- A developer can answer "what updates the initiating client?" for every mutation without reading implementation code.

---

## Phase 1: Server Contract Hardening

Status: Specs complete, implementation in progress

Source of truth:

- `plans/client-networking-state-phase-1-server-contract.md`
- `plans/client-networking-state-phase-1-server-decomposition.md`

### Objective

Make the API and WS contracts explicit enough that the new client can be simple.

Make the server codebase reflect those domain boundaries so the contract stays understandable and maintainable.

### Deliverables

- Revised REST response shapes
- Revised WS event taxonomy
- Revision/version fields added where needed
- Removal of ambiguous or legacy-only response/event patterns
- Domain-oriented server module layout for HTTP, persistence, and websocket transport

### Tasks

- [ ] Add revisions for sessions, conversation, review comments, worktrees, account/model state.
- [ ] Change review comment update/delete to return authoritative entities and replicate via WS.
- [ ] Change worktree create/remove/discover to have explicit authoritative behavior.
- [ ] Ensure approval decision responses are sufficient for immediate local application.
- [ ] Ensure create/fork/resume/takeover responses return authoritative session summaries.
- [ ] Remove or rename ambiguous WS events so the client reconciler logic is straightforward.
- [ ] Extract HTTP routing from `main.rs` into a dedicated router module.
- [ ] Split `http_api.rs` into domain modules that match the contract rewrite.
- [ ] Split `persistence.rs` into domain modules that match the contract rewrite.
- [ ] Thin websocket transport so domain handling stays in `ws_handlers/` and transport concerns live elsewhere.

### Testing

- Integration tests around each changed endpoint:
  - initiating client sees immediate correct state
  - another subscribed client sees replicated state
  - stale/out-of-order revisions are rejected correctly
- Structural moves are verified through public behavior:
  - REST contracts still match
  - WS events still match
  - persistence-backed state still behaves the same
- Outcome-based tests only.

### Exit Criteria

- The server contract matrix is true in code.
- No client phase needs undocumented server behavior to function.
- The server code is decomposed enough that domain ownership is obvious without reading giant monolith files.

---

## Phase 2: EndpointStore Foundation

### Objective

Build the new per-endpoint state owner and transport orchestration without migrating views yet.

### Deliverables

- New `EndpointStore`
- New `EndpointState`
- Store-owned transport lifecycle
- Central event reconciliation entry point
- Intent API skeletons

### Tasks

- [ ] Create `EndpointStore` with endpoint-scoped ownership.
- [ ] Move connection lifecycle ownership into the store.
- [ ] Introduce per-domain state buckets.
- [ ] Build a single event reconciliation path from `EventStream` into state slices.
- [ ] Build a single mutation path from view intent to store intent to transport to reconcile/apply.
- [ ] Add operation-state modeling for in-flight mutations where needed.

### Testing

- Unit tests for:
  - revision gating
  - event reconciliation
  - session upsert/removal
  - connection status transitions
- Integration tests for:
  - connect -> hydrate -> subscribe
  - disconnect -> reconnect -> replay
  - accepted+eventual WS operations

### Exit Criteria

- An endpoint can fully hydrate and reconcile state without `NotificationCenter`.
- An endpoint can handle reconnect deterministically.

---

## Phase 3: AppStore and Routing Rewrite

### Objective

Replace copied global session snapshots with live projections across endpoint stores.

### Deliverables

- New `AppStore`
- live dashboard projections
- live quick-switcher projections
- live endpoint health projections
- routing support that resolves directly against endpoint stores

### Tasks

- [ ] Replace copied aggregate session snapshots with computed projections.
- [ ] Remove `serverSessionsDidChange` as a core state dependency.
- [ ] Make dashboard and global UI consume app-level projections from endpoint stores.
- [ ] Make route selection explicitly endpoint-aware.
- [ ] Remove any reliance on "active endpoint happens to equal selected session endpoint".

### Testing

- Unit tests for projection logic:
  - sorting
  - filtering
  - counts
  - selected session resolution
- Integration tests for multi-endpoint behavior:
  - selecting a session from endpoint B uses endpoint B state
  - dashboard updates when either endpoint changes

### Exit Criteria

- Global UI no longer depends on manual reload notifications.
- Cross-endpoint selection is deterministic and store-driven.

---

## Phase 4: Sessions Index Migration

### Objective

Move session list, session summaries, and session lifecycle UI onto the new store model.

### Deliverables

- session list hydration via new store
- session summary reconciliation via new store
- create/fork/resume/end/takeover flows through store intents

### Tasks

- [ ] Migrate session list views and dashboard rows to the new app/endpoint stores.
- [ ] Migrate session lifecycle intents into `EndpointStore`.
- [ ] Remove view-level lifecycle REST calls.
- [ ] Ensure initiating-client responses are applied immediately when contract says they should be.
- [ ] Ensure cross-client session list replication works via WS.

### Testing

- Integration tests for:
  - create session shows up immediately
  - fork/resume/update flows reflect authoritative session summary
  - end session removes or marks ended in all projections
- UI tests for:
  - dashboard list updates
  - selecting a newly created session

### Exit Criteria

- Session index behavior is entirely store-owned.
- No session list view reaches directly into `APIClient`.

---

## Phase 5: Session Detail, Conversation, and Approvals

### Objective

Rebuild the most important runtime path on top of the new state model.

### Deliverables

- new session detail state flow
- new conversation hydration/replay model
- new approval lifecycle model
- removal of old `subscribeToSession` bootstrap branching

### Tasks

- [ ] Rebuild conversation state as a clear hydrate/replay/reconcile domain.
- [ ] Replace the current multi-path bootstrap logic with an explicit conversation loading model.
- [ ] Apply approval decision REST responses immediately in the store.
- [ ] Reconcile approval WS events with approval version gates.
- [ ] Move send/steer/interrupt/compact/undo/rollback intents into the store.
- [ ] Ensure detail headers, transcript, approval overlays, and composer all observe the same session state.

### Testing

- Unit tests for:
  - approval version gating
  - conversation message append/update reconciliation
  - stale event rejection
- Integration tests for:
  - send message -> streamed updates -> completion
  - approval requested -> decision -> next approval promotion
  - reconnect while viewing a live session
- UI tests for:
  - approval overlay advances correctly
  - conversation reflects streaming updates without manual refresh

### Exit Criteria

- Session detail no longer depends on legacy `SessionStore` behavior.
- Approval and conversation state are deterministic under reconnect and replay.

---

## Phase 6: Review Comments and Worktrees

### Objective

Move the two most obviously inconsistent secondary domains onto explicit store ownership.

### Deliverables

- review domain state and intents
- worktree domain state and intents
- immediate initiating-client updates plus cross-client replication

### Tasks

- [ ] Migrate review comment create/update/delete/list into store-owned intents.
- [ ] Apply response-authoritative review changes immediately.
- [ ] Reconcile replicated review events for other clients.
- [ ] Migrate worktree list/create/remove/discover into store-owned intents.
- [ ] Model per-repo worktree revision and list replacement semantics.
- [ ] Remove direct worktree/review REST calls from all views.

### Testing

- Integration tests for:
  - create comment appears immediately
  - resolve/unresolve comment updates correctly
  - delete comment disappears on initiating and subscribed clients
  - create/remove worktree updates repo-scoped worktree state correctly
- UI tests for:
  - review canvas
  - worktree sheet
  - session detail cleanup banner

### Exit Criteria

- No review or worktree view talks to `APIClient` directly.
- Review and worktree state behave correctly without manual reloads.

---

## Phase 7: Secondary Domains

### Objective

Finish the long tail so the entire app uses one architectural model.

### Deliverables

- MCP state migration
- skills/models/account migration
- server role/primary claim migration
- shell/subagent domain migration

### Tasks

- [ ] Move skills and MCP lists/refresh flows behind store intents.
- [ ] Move Codex/Claude model and account state behind store ownership.
- [ ] Move server-info and primary-claim flows behind store ownership.
- [ ] Move shell execution state behind store ownership.
- [ ] Move subagent tool loading behind store ownership.

### Testing

- Integration tests for each domain using real store logic and external-boundary doubles only.
- Prefer outcome assertions such as:
  - visible model list updates
  - account status changes propagate
  - shell state moves from started to completed
  - MCP refresh updates tool/resource state

### Exit Criteria

- All major networked domains now share one client architecture.

---

## Phase 8: Delete the Old Architecture

### Objective

Finish the rewrite by removing the old state model completely.

### Deliverables

- removal of legacy `SessionStore` paths
- removal of manual notification-based propagation
- removal of direct view-level networking
- updated documentation

### Tasks

- [ ] Delete obsolete store types and compatibility shims.
- [ ] Delete `NotificationCenter` core state propagation paths.
- [ ] Delete dead event handling and obsolete protocol shapes.
- [ ] Delete unused bootstrap/cache logic carried over from the old architecture.
- [ ] Update repository docs to describe the new client architecture.

### Testing

- Full regression pass across unit, integration, and targeted UI workflows.
- Confirm there are no behavior regressions in:
  - dashboard
  - session detail
  - approvals
  - review comments
  - worktrees
  - multi-endpoint behavior

### Exit Criteria

- The old client architecture is gone.
- The app is simpler to reason about than before the rewrite began.

---

## Suggested File/Type Deletion Candidates

These are likely deletion or replacement candidates, not sacred migration targets.

- current `SessionStore` architecture
- current `UnifiedSessionsStore` copied projection model
- `NotificationCenter` state fan-out for server session updates
- view-level direct networking patterns
- ad hoc bootstrap/reconcile branches that exist only to paper over transport ambiguity

Do not preserve a type just because it already exists. Preserve only what still fits the target model.

---

## Definition of Done

The rewrite is done when all of the following are true:

- Every networked domain has one authoritative client state owner.
- Every mutation has one documented contract.
- Every replicated event has revision/version semantics where ordering matters.
- No SwiftUI view performs direct server mutation calls.
- No core UI depends on `NotificationCenter` to observe server state.
- Reconnect and replay are deterministic and covered by tests.
- The architecture is simpler than the code it replaced.

---

## Handoff Instructions for Any Developer or LLM

If you are picking up a single phase:

1. Read this plan fully.
2. Read the target phase and the phase immediately before it.
3. Confirm the server contract required by your phase already exists. If it does not, do that work first.
4. Do not preserve old patterns for convenience.
5. Keep all new state changes flowing through store intents and reconcilers.
6. Follow the `testing-philosophy` skill:
   test outcomes, minimize mocking, and wait on concrete events/state instead of sleeps.
7. Do not mark the phase complete until its exit criteria are true in code.

If a phase reveals a missing contract or architecture rule, update this plan before continuing.
