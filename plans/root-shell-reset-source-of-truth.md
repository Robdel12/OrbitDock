# Root Shell Reset

Status: `In progress`
Owner: `OrbitDock reset effort`
Source of truth: `This file replaces the older root-shell rewrite notes.`

## Mission

Delete and replace the client root-session underpinning.

This is not another optimization pass.
This is not an adapter cleanup.
This is not a compatibility migration.

We are building a new root shell that is:

- mobile first
- realtime and WebSocket-native
- able to scale to hundreds of agents
- explicit about hot, warm, and cold state
- pure in the middle, with mutation only at the boundaries
- free of legacy bridges, fallback compatibility models, and dual architectures

We are keeping the visible product where it helps.
We are not keeping the old data flow.

## What This Plan Replaces

This plan supersedes the older exploratory notes in:

- [root-session-rewrite-plan.md](/Users/robertdeluca/Developer/OrbitDock/docs/root-session-rewrite-plan.md)

Those notes were useful to get here.
This file is the actual execution plan.

## Non-Negotiables

- One multiplexed WebSocket connection per endpoint.
- Root shell consumes only root-safe list events.
- Detail views consume only detail subscriptions.
- Hot sessions are few and explicit.
- Warm sessions are summary-only and inert.
- Cold sessions are evicted and fetched on demand.
- No root surface may read rich session detail models.
- No root hot path may compute titles, sort keys, search text, or status semantics on read.
- No legacy compatibility layer survives the reset.
- No mocking of our own code in tests.
- No polling or arbitrary sleeps in tests.
- This is a hard cutover, not a long compatibility migration.
- It is acceptable for the branch to be temporarily broken during the reset.

## Foundational Types

These must be pinned down before Wave 1 coding starts.

### ScopedSessionID

The stable client key for any session across the app.

Definition:

- one endpoint id
- one server session id
- represented as a stored-value type, not a derived string convention sprinkled through the codebase

Purpose:

- root store keys
- hot detail cache keys
- selection state
- promotion and demotion
- deduplication across all surfaces

### RootSessionNode

The inert client-side root record derived from `SessionListItem`.

Definition:

- stored-value only
- no computed display semantics on read
- no regex cleanup
- no fallback derivation at render time

Notes:

- This may be renamed to `RootListRecord` during the reset.
- The important thing is the concept, not the current name.
- We start with one good inert root record and only split it if a surface proves it needs a different shape.

## Product Constraints

### Mobile First

The canonical flow is:

1. session list
2. tap into detail
3. promote that session to hot
4. demote it when leaving

macOS and iPad can add split-view affordances, but the data architecture must work like an iPhone app first.

### Realtime First

The client is event-driven.

- root surfaces update from root-safe WebSocket deltas
- detail surfaces update from detail subscriptions
- REST is for bootstrap and on-demand fetches

We do not rebuild root state from rich detail events.

### Agent Scale

We should assume users will run a lot of agents.
The architecture should remain sane with `100+` warm sessions and bursts of updates.

That means:

- summary rows must be tiny
- root updates must be batched
- detail state must be scarce
- worker-heavy sessions must not churn the root shell

## Architecture

## 1. EndpointSocket

One live WebSocket per configured endpoint.

Responsibilities:

- connect/reconnect
- reconnect backoff
- gap recovery
- auth handshake
- receive root-safe events
- receive detail events for hot sessions
- expose raw protocol messages to the router

Non-responsibilities:

- session storage
- projection
- UI semantics

Reconnect semantics for reset v1:

- on reconnect, perform a fresh root bootstrap
- then resubscribe hot detail sessions explicitly
- do not rely on event replay cursors in v1

If we later need replay cursors, that is a follow-up optimization, not a blocker for the reset.

## 2. EventRouter

Routes protocol messages into the right channel.

Channels:

- root list events
- endpoint status events
- detail session events
- global control-plane events

The router does not interpret UI semantics.
It only classifies protocol events.

## 3. SessionRegistry Actor

The mutation boundary.

Responsibilities:

- own tiered session state
- apply root and detail events
- maintain hot/warm/cold membership
- batch bursts of changes into small change sets
- emit snapshots or incremental updates to the main-actor stores

State shape:

- `warmIndex: [ScopedSessionID: RootListRecord]`
- `hotDetails: LRU<ScopedSessionID, SessionDetailHandle>`
- `subscriptions: Set<ScopedSessionID>`
- `endpointState: [EndpointID: EndpointState]`
- `attentionState`
- `selectionState`

## 4. RootShellStore

`@MainActor` and `@Observable`.

Responsibilities:

- store tiny root-safe snapshots for the UI
- expose inert records to dashboard, quick switcher, menu bar, attention, toast, and navigation shell
- apply already-batched changes from `SessionRegistry`

Non-responsibilities:

- event parsing
- network I/O
- detail state
- fallback semantics
- heavy sorting/filtering logic on read

## 5. Detail Stores

Rich state stays here.

Responsibilities:

- conversation paging
- approvals
- workers
- timeline
- hook/handoff detail
- hot-session live subscriptions

Detail stores are promoted on entry and demoted on exit.

## Tiered State Model

### Hot

Full state, live detail subscription.

Examples:

- currently visible session
- secondary split-view session
- maybe one additional prewarmed session

### Warm

Summary-only.

Fields are all stored, inert values from the server:

- title
- sort key
- search text
- context line
- status
- unread count
- timestamps
- provider/model badges
- lightweight token/cost totals if needed

### Cold

Not kept in memory.

For reset v1, cold means:

- no live detail subscription
- no local disk cache requirement
- fetched on demand through REST/bootstrap when promoted

We are not adding a local disk cache as part of this reset unless a later phase proves we need it.

Promotion happens on explicit user intent.

## Protocol and API

## Root-Safe Contracts

The root shell should consume a dedicated list contract.

Primary payload:

- `SessionListItem`

Required properties:

- stable scoped id
- endpoint id
- provider
- integration mode
- display title
- display title sort key
- display search text
- context line
- list status
- unread count
- started at
- last activity at
- project name
- branch
- model
- direct/passive flags
- lightweight attention fields
- lightweight usage/cost totals for dashboard surfaces

These values must be authored server-side.
The client should not reconstruct them.

## Root WebSocket Stream

Required events:

- `sessions_list_bootstrap`
- `session_list_item_updated`
- `session_removed`
- `endpoint_status_updated`

Optional but likely useful:

- `session_ordering_hint_updated`
- `session_attention_updated`

The root shell must not depend on rich `session_snapshot` or `session_delta`.

For reset v1, the recovery story is:

- root reconnect => full root bootstrap
- hot detail reconnect => explicit resubscribe
- no mixed inference from detail events

## Detail WebSocket Stream

Required for hot sessions only:

- `session_snapshot`
- `session_delta`
- `message_appended`
- `message_updated`
- `approval_requested`
- worker events
- hook/handoff events

## Reset Rules

### Delete, Do Not Adapt

The following are delete-and-replace targets:

- `WindowSessionCoordinator`
- any remaining root compatibility bridge types
- any root state living in `SessionStore`
- any adapter that converts rich session detail back into a root list model
- any root array replacement flow that republishes the full world

### No Dual Architecture

We will not keep:

- old root path plus new root path
- “temporary” compatibility summaries
- root fallback to rich detail models
- root semantics hidden in adapters

If a surface is migrated, it is on the new path.
If it is not migrated, it stays off until rewritten.

### Hard Cutover

We are not optimizing for long-lived support of:

- old client + new server
- new client + old server
- old root shell plus new root shell

This lands as a paired client/server reset.
Short-term breakage on the branch is acceptable while the replacement is underway.

### Preserve Only the Visible Product

We keep:

- existing screen designs when they still fit
- existing navigation affordances where helpful
- detail conversation infrastructure that already works

We do not preserve old state flow just because the UI looks similar.

## Known Delete Targets Right Now

These are the concrete files and concepts that still represent the old world.

### Client

- [WindowSessionCoordinator.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Services/WindowSessionCoordinator.swift)
- root list ownership in [SessionStore.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Services/Server/SessionStore.swift)
- root event handling in [SessionStore+Events.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Services/Server/SessionStore+Events.swift)
- adapter baggage in [ServerTypeAdapters.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Services/Server/ServerTypeAdapters.swift)
- library/dashboard dual architecture around `SessionSummary`
- [RootSessionRecordTests.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDockTests/Models/RootSessionRecordTests.swift)

### Server

- implicit root publication buried inside rich transition handling in [session_command_handler.rs](/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/runtime/session_command_handler.rs)
- any root update path that still depends on detail transitions instead of formal root-stream semantics
- any client-facing path that asks the app to derive root-safe display semantics from rich state

### Keep, But Re-scope

- [RootShellStore.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Services/RootShell/RootShellStore.swift)
- [RootShellReducer.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Services/RootShell/RootShellReducer.swift)
- [RootSessionNode.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Models/RootShell/RootSessionNode.swift)
- `SessionListItem`

These stay only if they fit the reset rules.
If they keep old assumptions alive, they get replaced too.

## Testing Strategy

This reset follows `testing-philosophy`.

### What We Test

User outcomes:

- opening the app with `200` passive sessions stays responsive
- scrolling the session list while updates arrive stays smooth
- opening a session promotes only that session to hot detail state
- leaving a session demotes it
- dashboard badges and counts stay correct under burst updates
- quick switcher finds and opens the right session
- menu bar and notifications react to attention-worthy state correctly
- agent-heavy conversations do not force root churn

### What We Do Not Test

- whether helper method `x` was called
- whether reducer function `y` mutated field `z`
- internal sequencing details that users do not experience

### Test Levels

#### Unit

Pure functions only:

- root reducers
- projection functions
- tier promotion/demotion rules
- ordering and filtering rules

#### Integration

Real boundaries:

- WebSocket root event flow into `SessionRegistry`
- change batching into `RootShellStore`
- hot session subscribe/unsubscribe lifecycle
- REST bootstrap plus live WebSocket continuation

#### Scenario / Performance

Outcome-driven scenarios:

- synthetic `200` session root bootstrap
- burst updates across `100` passive sessions
- one hot session plus many warm sessions
- agent-heavy detail session open/close while root remains calm

We should measure:

- main-thread time
- publication frequency
- memory growth
- detail cache size over time

### Testing Rules

- no mocking internal stores or reducers
- mock only time, randomness, or external transport edges when needed
- no arbitrary sleeps
- wait on concrete events or state transitions
- prefer deterministic fixture streams

### Coverage We Expect Before Calling This Done

- root reducer and registry outcome tests
- root-stream integration tests
- tier promotion and demotion tests
- dashboard and quick switcher scenario tests
- menu bar and attention scenario tests
- synthetic passive-session load tests
- agent-heavy detail open/close performance tests

If a phase ships without user-outcome coverage, it is not done.

## Phases

## Phase 0: Foundations, Spike, and Bridge Deletion

Status: `Completed`

Goal:

- pin down the foundational types
- prove the new vertical slice once
- finish deleting the last compatibility bridge pieces
- get back to one honest starting point

Tasks:

- [x] define `ScopedSessionID`
- [x] define the inert root record shape (`RootSessionNode` or renamed replacement)
- [x] build one protocol spike:
  EndpointSocket -> EventRouter -> dummy SessionRegistry -> RootShellStore from a real `sessions_list_bootstrap`
- [x] delete the final `RootSessionRecord` references
- [x] delete bridge-only tests and replace them with `RootSessionNode` outcome tests
- [x] remove any remaining root state ownership from `SessionStore`
- [x] update this plan if any hidden bridge remains
- [x] verify `QuickSwitcher`, `MenuBar`, and dashboard shell do not depend on bridge-only types

Done when:

- the vertical slice exists and proves the architecture is viable
- the old bridge types are gone
- the app builds
- the test suite is green on the pre-reset baseline

Current note:

- `WindowSessionCoordinator`, `RootSessionRecord`, and `UnifiedSessionsStore` are gone.
- The temporary `WindowRootRuntime` façade has been split into smaller root-shell pieces:
  - `RootShellRuntime`
  - `RootShellEffectsCoordinator`
  - `RootSelectionBridge`
- Root-safe list events no longer hydrate `SessionStore`.
- `SessionStore.sessions` is gone; detail surfaces now project from `SessionObservable` instead of a root mirror.
- The root stream now has an explicit `session_removed` event so removal does not overload `sessionEnded`.
- `SessionStore` now consumes a detail-only WebSocket lane instead of the full event firehose.
- Root-shell flush now coalesces bursty passive updates before publishing to SwiftUI.
- Root-shell effects now react to incremental upsert/remove change sets instead of rescanning entire mission-control arrays.
- `QuickSwitcher`, dashboard stream cards, menu bar, notification/toast flow, and root shell routing are on the new root-safe path.
- The remaining reset work is no longer bridge cleanup; it is finishing the new root shell so it scales cleanly and then hardening the root-stream boundary.

Parallel lanes:

- Lane 0A: foundational types + spike
- Lane 0B: client bridge deletion
- Lane 0C: adapter/test cleanup

## Phase 1: Server Root Stream

Status: `In progress`

Goal:

- give the client a truly root-safe live stream

Tasks:

- [x] finalize `SessionListItem` as the only root list payload
- [x] ensure server authors all display/sort/search fields
- [x] formalize `sessions_list_bootstrap`
- [x] add `session_list_item_updated`
- [x] add `session_removed`
- [x] add `endpoint_status_updated`
- [x] ensure root-visible mutations publish root-safe events without detail leakage
- [x] document root-stream semantics clearly enough that the client never infers root state from detail events
- [x] formalize reconnect behavior: root bootstrap after reconnect, hot detail resubscribe after reconnect
- [x] explicitly document that replay cursors are out of scope for reset v1

Done when:

- a client can stay in sync with root state without reading rich session events

Parallel lanes:

- Lane 1A: protocol contract
- Lane 1B: WebSocket event emission
- Lane 1C: server root-stream tests

## Phase 2: SessionRegistry Actor

Status: `In progress`

Goal:

- create the new tiered mutation core

Tasks:

- [x] add `SessionRegistry` actor
- [x] define hot/warm/cold membership rules
- [x] define promotion/demotion events
- [x] ingest root-safe events into normalized warm state
- [ ] ingest detail events into hot state only
- [x] batch bursts into small change sets
- [ ] implement bounded hot detail cache

Done when:

- the registry can run without any UI and prove tier correctness under load

Parallel lanes:

- Lane 2A: registry core
- Lane 2B: tier policy and cache
- Lane 2C: batching/change-set output
- Lane 2D: actor tests and load fixtures

## Phase 3: RootShellStore

Status: `In progress`

Goal:

- expose tiny inert state to SwiftUI

Tasks:

- [x] add new `RootShellStore`
- [x] accept only batched registry outputs
- [x] expose normalized records plus small derived indexes
- [x] start pushing mission-control and recent-session slices into stored root state
- [x] keep published state minimal
- [x] ensure stored-value-only models for all hot UI paths

Done when:

- root SwiftUI surfaces can observe the store without touching detail state

Parallel lanes:

- Lane 3A: store shape
- Lane 3B: record/index projections
- Lane 3C: store tests

## Phase 4: Surface Projections

Status: `In progress`

Goal:

- start from one good inert root record and split only where the product proves it is useful

Tasks:

- [x] start from one inert root record
- [x] add surface-specific projections only when a surface has materially different needs
- [x] keep any added projection surface-specific and inert
- [x] avoid speculative mapping layers

Done when:

- no root UI surface depends on a compromise shared summary model
- we are not maintaining unnecessary parallel projection types

Parallel lanes:

- Lane 4A: dashboard projection
- Lane 4B: quick switcher projection
- Lane 4C: menu bar + notifications projection
- Lane 4D: projection tests

## Phase 5: Surface Migration

Status: `In progress`

Goal:

- swap visible UI onto the new spine

Tasks:

- [x] migrate dashboard
- [x] migrate quick switcher
- [x] migrate menu bar
- [x] migrate notifications/attention
- [x] migrate app-shell navigation selection
- [x] ensure detail entry promotes a session to hot
- [x] ensure detail exit demotes it back to warm
- [x] split window-root orchestration into smaller root-shell pieces

Done when:

- the visible root product runs entirely on the new root shell

Parallel lanes:

- Lane 5A: dashboard
- Lane 5B: quick switcher
- Lane 5C: menu bar + notifications
- Lane 5D: navigation and hot-detail promotion

## Phase 6: Delete Legacy Root Spine

Status: `In progress`

Goal:

- remove the old architecture completely

Tasks:

- [x] delete `WindowSessionCoordinator`
- [x] delete any remaining root compatibility types
- [x] delete the temporary `WindowRootRuntime` façade
- [ ] delete dead root helper code
- [x] delete root fallback logic from detail stores
- [x] delete tests that only exist for the old architecture

Done when:

- there is exactly one root state path in the app

Parallel lanes:

- Lane 6A: code deletion
- Lane 6B: test deletion and replacement
- Lane 6C: dead-file sweep

## Phase 7: Performance Proof

Status: `Not started`

Goal:

- prove the reset solved the actual problem

Tasks:

- [ ] add synthetic passive-session load fixtures
- [ ] verify `200` warm sessions stay responsive
- [ ] verify hot-detail promotion does not churn the root shell
- [ ] verify memory remains bounded under long-running passive updates
- [ ] capture before/after profile results

Done when:

- the app remains usable under sustained passive load and agent-heavy detail activity

Parallel lanes:

- Lane 7A: synthetic load fixtures
- Lane 7B: performance measurements
- Lane 7C: QA checklist and outcome verification

## Worker Assignment Strategy

We have a lot of parallelism available, but not every phase should fan out to `40` workers at once.

Recommended cadence:

### Wave 1

- 3 workers on Phase 0
- 3 workers on Phase 1
- 4 workers on Phase 2

### Wave 2

- 3 workers on Phase 3
- 4 workers on Phase 4
- 4 workers on Phase 5

### Wave 3

- 3 workers on Phase 6
- 3 workers on Phase 7

That is already enough concurrency to move quickly without creating merge hell.

## Worker Lanes

These are the concrete lanes we can hand out right away.

### Lane A: Server Protocol Contract

Files:

- `orbitdock-server/crates/protocol/src/types.rs`
- `orbitdock-server/crates/protocol/src/server.rs`

Responsibilities:

- freeze the root-safe contract
- ensure `SessionListItem` is truly sufficient for all root surfaces

### Lane B: Server Root Publication

Files:

- `orbitdock-server/crates/server/src/runtime/session_command_handler.rs`
- `orbitdock-server/crates/server/src/runtime/session_activation.rs`
- `orbitdock-server/crates/server/src/runtime/session_resume.rs`
- `orbitdock-server/crates/server/src/runtime/session_mutations.rs`

Responsibilities:

- ensure all root-visible mutations publish root-safe upserts consistently
- stop leaking root publication through accidental detail ownership

### Lane C: Server Root Stream Semantics

Files:

- `orbitdock-server/crates/server/src/transport/websocket/handlers/**`
- `orbitdock-server/crates/server/src/transport/http/sessions.rs`

Responsibilities:

- define endpoint-scoped root bootstrap and live update semantics
- keep detail subscriptions explicit and separate

### Lane D: Server Coalescing

Files:

- `orbitdock-server/crates/server/src/runtime/session_registry.rs`
- any new root-stream broadcaster module

Responsibilities:

- coalesce passive bursts
- prefer latest useful summary over chatty internal churn

### Lane E: Root Runtime

Files:

- new `Services/RootShell/RootShellRuntime.swift`
- new `Services/RootShell/SessionRegistry.swift`
- `Services/RootShell/RootShellStore.swift`
- `Services/RootShell/RootShellReducer.swift`

Responsibilities:

- build the new root state/update spine
- batching, tiering, promotion, demotion

### Lane F: Detail Boundary

Files:

- `Services/Server/SessionStore.swift`
- `Services/Server/SessionStore+Events.swift`
- `Services/Server/SessionStore+Commands.swift`

Responsibilities:

- make `SessionStore` hot-detail only
- remove root-shell ownership completely

### Lane G: Adapter Cleanup

Files:

- `Services/Server/ServerTypeAdapters.swift`
- `Models/RootShell/RootSessionNode.swift`
- bridge-only tests

Responsibilities:

- delete legacy semantics
- keep list-item adaptation stored-value only

### Lane H: Dashboard + Library

Files:

- `Views/Dashboard/**`
- any library views still using `SessionSummary`

Responsibilities:

- migrate both mission control and library onto the new projections

### Lane I: Quick Switcher

Files:

- `Views/QuickSwitcher/**`

Responsibilities:

- finish moving quick switcher to the new runtime-only assumptions
- keep it visually intact, replace the underpinning only

### Lane J: Menu Bar + Attention

Files:

- `Views/MenuBar/**`
- `Services/AttentionService.swift`
- `Services/ToastManager.swift`
- `Services/NotificationManager.swift`

Responsibilities:

- move these surfaces onto root projections only
- remove coordinator coupling

### Lane K: Coordinator Deletion

Files:

- `Services/WindowSessionCoordinator.swift`
- `OrbitDockWindowRoot.swift`
- `ContentView.swift`
- `PreviewRuntime.swift`

Responsibilities:

- remove the old coordinator once the new runtime/store is in place
- re-home environment ownership cleanly

### Lane L: Testing and Perf

Files:

- `OrbitDockTests/RootShell/**`
- dashboard/menu/quick-switcher tests
- integration/perf fixtures

Responsibilities:

- keep the rewrite honest
- verify user outcomes
- measure passive load and hot-detail behavior

## File Ownership Suggestions

### Server lanes

- `orbitdock-server/crates/protocol/src/**`
- `orbitdock-server/crates/server/src/runtime/**`
- `orbitdock-server/crates/server/src/transport/websocket/**`

### Client root lanes

- `OrbitDockNative/OrbitDock/Services/RootShell/**`
- `OrbitDockNative/OrbitDock/Services/Server/EventRouter*`
- `OrbitDockNative/OrbitDock/Services/Server/*Registry*`
- `OrbitDockNative/OrbitDock/Models/RootShell/**`

### Surface lanes

- `OrbitDockNative/OrbitDock/Views/Dashboard/**`
- `OrbitDockNative/OrbitDock/Views/QuickSwitcher/**`
- `OrbitDockNative/OrbitDock/Views/MenuBar/**`
- `OrbitDockNative/OrbitDock/Services/AttentionService.swift`
- `OrbitDockNative/OrbitDock/Services/ToastManager.swift`

### Detail lanes

- `OrbitDockNative/OrbitDock/Services/Server/SessionStore*`
- `OrbitDockNative/OrbitDock/Views/SessionDetail/**`
- `OrbitDockNative/OrbitDock/Views/Conversation/**`

## Definition of Done

We are done when all of these are true:

- the root shell uses only root-safe list events
- detail subscriptions are explicit and scarce
- root state is tiered into hot, warm, and cold
- root surfaces are backed by surface-specific inert models
- the old coordinator/bridge architecture is gone
- passive bursts no longer peg CPU
- large agent counts do not make the app unusable
- tests prove user-facing outcomes, not implementation trivia
- there is no fallback or compatibility path left to resurrect the old root model

## Progress Log

- [x] Phase 0 complete
- [x] Phase 1 complete
- [ ] Phase 2 complete
- [x] Phase 3 complete
- [x] Phase 4 complete
- [ ] Phase 5 complete
- [ ] Phase 6 complete
- [ ] Phase 7 complete
