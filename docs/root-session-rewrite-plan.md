# Root Shell Rewrite Plan

## Why We Are Doing This

The current root-session architecture is still paying the wrong costs.

We have already reduced a lot of obvious baggage:
- full session snapshots no longer hydrate conversations
- root surfaces no longer depend on the heaviest `Session` shape
- conversation loading is paged
- detail state is richer and more isolated than it was before

But profiling is still telling us the same core story:
- the main thread is still dominated by SwiftUI graph churn
- root arrays are still being replaced and compared too often
- even the “lighter” root record path is still too broad and too chatty
- passive-session bursts still invalidate too much of the app shell

At this point, this is not a tuning problem.
It is not a sorting problem.
It is not a regex problem.

It is an architecture problem.

The right fix is to delete and replace the root UI underpinning while keeping the visible UI mostly intact.

## The Goal

Make these things true:

- root state is tiny, inert, and incremental
- detail state is rich, isolated, and lazy
- root surfaces never consume session detail models
- root updates are applied by reducer-like transforms, not broad recomputation
- root views render stored values only
- no root hot path computes titles, sort keys, search text, or display semantics

This is the SwiftUI-appropriate shape too:
- tiny observable owners
- narrow invalidation
- stable identity
- pure transforms in the middle
- side effects at the boundaries

## Architectural Principles

### 1. Root and Detail Must Be Separate Systems

The root shell should answer questions like:
- what sessions exist?
- which ones need attention?
- what should the dashboard show?
- what should quick switcher show?
- what should the menu bar show?

The detail layer should answer questions like:
- what is happening in this conversation?
- what approvals are pending?
- what workers exist and what are they doing?
- what is the current timeline state?

Those are different workloads and they should not share the same in-memory model.

### 2. Root State Must Be Stored-Value Only

No computed display semantics on read.
No fallback title logic in view models.
No sort-key construction at compare time.
No search-corpus building at filter time.
No regex or normalization on hot paths.

If the root UI needs a value, that value should already exist.

### 3. Root Updates Must Be Incremental

The root shell should not replace `[Session]`, `[SessionSummary]`, or `[RootSessionRecord]` on every change burst.

It should instead:
- upsert one record
- remove one record
- update one endpoint bucket
- update one attention counter
- update one selected row

The root store can still expose arrays to SwiftUI, but those arrays must be materialized from normalized state only when needed and with very narrow churn.

### 4. Projection Work Should Be Pure

The root shell should be built out of:
- raw server contracts
- a normalized root store
- pure projection functions for each surface

That means:
- mutation at the boundary
- pure transforms in the middle
- dumb render models at the edge

## What We Should Delete

These are the main delete-and-replace targets.

### Delete the current root coordinator spine
- [WindowSessionCoordinator.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Services/WindowSessionCoordinator.swift)
- [UnifiedSessionsStore.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Services/Server/UnifiedSessionsStore.swift)

Why:
- they still centralize too many responsibilities
- they still rebuild root arrays too broadly
- they still mix orchestration, notification, projection, and root selection concerns

### Delete root list ownership from session stores
- [SessionStore.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Services/Server/SessionStore.swift)
- [SessionStore+Events.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Services/Server/SessionStore+Events.swift)

Why:
- the per-session store should not also own root-shell collection state
- this is where detail state leaks into root-state churn

### Delete overloaded root models
- [SessionSummary.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Models/SessionSummary.swift)
- [RootSessionRecord.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Models/RootSessionRecord.swift)

Why:
- they are still trying to serve too many surfaces
- they still carry compatibility baggage
- they still encourage “one root summary for everything” thinking

## What We Should Keep

These are good and should remain the detail path.

### Keep rich detail state
- `SessionStore.session(_:)`
- `SessionStore.conversation(_:)`
- `SessionObservable`
- rich session subscribe/unsubscribe
- conversation paging
- worker and approval detail state

### Keep UI surfaces
- [ContentView.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/ContentView.swift)
- [DashboardView.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/Dashboard/Scene/DashboardView.swift)
- [QuickSwitcher.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/QuickSwitcher/QuickSwitcher.swift)
- [MenuBarView.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/MenuBar/MenuBarView.swift)
- existing navigation shell views

We are replacing the underpinning, not the visual product.

### Keep root-adjacent responsibilities, but re-home them
- [AttentionService.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Services/AttentionService.swift)
- [ToastManager.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Services/ToastManager.swift)

They should survive, but feed from the new root projections, not from a giant root coordinator.

## API Changes We Should Make

The API is not the main problem, but it can make the rewrite much cleaner.

### 1. Introduce a true root-safe list contract

Add a dedicated protocol type, likely:
- `SessionListItem`

This should be the root-shell source of truth.

It should include only stored values needed for root surfaces, such as:
- `id`
- endpoint identity
- provider
- connection/display status
- unread count
- started/last-activity timestamps
- project name
- branch
- model
- `display_title`
- `display_title_sort_key`
- `display_search_text`
- one short `context_line`
- `list_status`
- direct/passive flags
- lightweight attention fields
- lightweight token/cost totals if the dashboard needs them

This should be inert. No root semantics should be left to the client.

### 2. Add a root-safe live delta event

We should add a websocket event like:
- `session_list_item_updated`

It should carry exactly one `SessionListItem`.

The root shell should consume:
- `sessions_list`
- `session_created`
- `session_list_item_updated`
- `session_ended`

The root shell should not interpret rich `session_snapshot` and `session_delta` events.

### 3. Keep detail contracts rich

Do not try to collapse detail and list payloads into one contract.

Keep these rich:
- `GET /api/sessions/{id}`
- `session_snapshot`
- `session_delta`
- conversation/history endpoints
- approval and worker detail endpoints

That split is good.

## The Replacement Architecture

## Layer 1: Raw server contracts

Keep raw contracts dumb.

Examples:
- `ServerSessionListItem`
- `ServerSessionState`
- `ServerStateChanges`
- websocket root events

These are input data, not view models.

## Layer 2: RootShellStore

Build a brand new root store.

### Responsibilities
- ingest root-safe server events
- normalize root items by scoped session id
- maintain endpoint buckets and lightweight counts
- maintain ordered ids separately from record storage
- emit surface-specific projection snapshots

### Non-responsibilities
- conversation data
- approval queue detail
- worker detail
- timeline detail
- session restore/resume behavior
- rich session observables

### Proposed shape
- `recordsByScopedID: [String: RootRecord]`
- `orderedScopedIDs: [String]`
- `endpointBuckets: [UUID: EndpointRootBucket]`
- `selectionState`
- `attentionState`
- `surfaceCaches`

The store should own tiny mutable state.
The transforms inside it should be mostly pure.

## Layer 3: Surface Projections

Build separate stored-value models per root surface.

Examples:
- `DashboardSessionItem`
- `QuickSwitcherSessionItem`
- `MenuBarSessionItem`
- `AttentionSessionItem`
- `LibrarySessionItem`

These should all be projected from `RootRecord` through pure functions.

No one shared “summary” type should serve every surface.

## Layer 4: Detail remains separate

Selected session detail should continue to flow through:
- `SessionStore`
- `SessionObservable`
- `ConversationStore`

The root shell may know the selected session id.
It should not own the selected session’s rich data.

## Ownership Boundaries

### Server owns
- root-safe title fallback semantics
- sort keys
- search corpus
- root-safe status semantics
- root-safe lightweight totals

### Root client store owns
- normalized root records
- endpoint filtering
- ordering
- selection
- attention aggregation
- pure surface projections

### Detail client stores own
- conversation
- approvals
- workers
- live session state
- control-plane detail

## Migration Sequence

### Phase 1: API groundwork

Server:
- add `SessionListItem` if not already fully root-safe
- add server-authored display title / sort key / search text / list status
- add `session_list_item_updated`
- keep existing rich contracts intact

### Phase 2: New root store in parallel

Client:
- build `RootShellStore`
- build normalized storage and reducers
- build pure surface projections
- do not yet swap the UI

### Phase 3: Surface migration

Move these one by one onto the new root store:
- dashboard
- quick switcher
- menu bar
- attention
- toast/notification
- root selection/navigation support

### Phase 4: Delete old spine

Delete:
- `WindowSessionCoordinator`
- `UnifiedSessionsStore`
- root list ownership in `SessionStore`
- old root summary compatibility types

### Phase 5: Validate under load

Run profiling with many passive sessions and confirm:
- root invalidation is narrow
- main-thread CPU stays sane
- dashboard and quick switcher remain responsive
- opening detail views still works correctly

## Worker Lanes

### Lane A: Server contract lane
Own:
- protocol changes for `SessionListItem`
- root-safe websocket delta event
- server adapters and emitters

### Lane B: Root store lane
Own:
- `RootShellStore`
- reducers
- normalized storage
- ordering and filtering
- event ingestion

### Lane C: Surface projection lane
Own:
- `DashboardSessionItem`
- `QuickSwitcherSessionItem`
- `MenuBarSessionItem`
- `AttentionSessionItem`
- `LibrarySessionItem`

### Lane D: Surface migration lane
Own:
- dashboard wiring
- quick switcher wiring
- menu bar wiring
- notification/toast wiring

### Lane E: Cleanup lane
Own:
- deleting `WindowSessionCoordinator`
- deleting `UnifiedSessionsStore`
- deleting old root summary compatibility paths

### Lane F: Verification lane
Own:
- projection tests
- reducer tests
- root event-flow tests
- synthetic passive-session stress fixture
- profiling pass before and after swap

## Definition of Done

We are done when:
- root UI no longer depends on detail models
- root UI no longer rebuilds broad arrays on passive-session bursts
- dashboard, quick switcher, menu bar, attention, and toast all run on root-safe stored values
- the new root store is incremental and normalized
- detail views still behave the same
- profiling confirms passive-session load is cheap enough to scale

## What We Will Not Do

- we will not rewrite the visible dashboard UI from scratch
- we will not collapse detail state into root state again
- we will not keep compatibility shims just because they are familiar
- we will not let root surfaces compute semantics on the fly

The whole point of this rewrite is to stop carrying the old baggage forward.
