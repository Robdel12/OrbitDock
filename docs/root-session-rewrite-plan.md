# Root Session Rewrite Plan

## Why We Are Doing This

The current root-session path is still carrying too much baggage.

We already moved off full `[Session]` in a lot of places, and that was the right direction. But profiling is still telling us the same story:

- root SwiftUI surfaces are doing expensive work they should never do
- session list sorting still reaches into computed display semantics
- display-name derivation still does string cleaning and XML stripping on the hot path
- the app is paying detail-view costs for list-view needs

That is not a tuning problem anymore. It is a modeling problem.

The fix is to replace the root session projection spine with a truly inert, projection-first architecture.

## The Design Goal

Make one thing true:

- detail state stays rich
- root state stays tiny
- projections are pure and precomputed
- root UI never performs expensive semantic work at render/sort time

In practice, that means:

- the dashboard
- quick switcher
- menu bar
- attention/toast/notification surfaces
- any root navigation shell

should all run on tiny stored values, not on `Session` and not on "summary types" that still compute their own display semantics.

## What The Current API Gets Right

The server is not the main problem.

What is already good:

- `GET /api/sessions` exists and already returns list-oriented session data
- `GET /api/sessions/{id}` is now metadata-first by default
- conversation history is already separate
- WebSocket already has list and delta concepts:
  - `sessions_list`
  - `session_created`
  - `session_delta`
- the server is already authoritative for status, approvals, unread counts, worker state, and config

So this is not a case where the API forces us into a bad client architecture.

## Where The Contract Still Hurts

Even though the server is not the root cause, the contract still nudges the client into doing too much work:

- `SessionSummary` is still too broad for true root-list use
- it includes many fields that root surfaces do not need
- it does not include a server-authored, precomputed display title
- it does not include a server-authored sort key
- it does not include a server-authored search corpus
- it does not include a server-authored list-status value
- list semantics like title fallback and text cleanup still happen client-side
- the same summary shape is being asked to serve:
  - session list
  - dashboard cards
  - quick switcher
  - toasts/attention
  - creation/resume responses

That is convenient, but it is not cheap.

## Recommended API Adjustments

These are intentionally small and high-leverage.

### 1. Add a true root-list payload

Introduce a dedicated server type for root UI, for example:

- `SessionListItem`

This should be smaller than `SessionSummary` and include only list-safe stored values:

- `id`
- endpoint identity
- provider
- status / work status
- attention reason or list-level display status
- unread count
- started / last-activity timestamps
- project name
- branch
- model
- `display_title`
- `display_title_sort_key`
- `display_search_text`
- one short `context_line`
- `list_status`
- lightweight direct/passive / integration flags

The point is not to make it "comprehensive." The point is to make it inert.

### 2. Use that list item everywhere root state flows

Use `SessionListItem` for:

- `GET /api/sessions`
- `sessions_list`
- `session_created`
- `session_delta` for the root-safe subset of live fields

Keep richer session detail on:

- `GET /api/sessions/{id}`
- `session_snapshot`
- detail-specific REST endpoints

### 3. Move title/sort semantics to the server

The server should author:

- `display_title`
- `display_title_sort_key`
- `display_search_text`

This is a great place to stop client-side `SessionSemantics.displayName(...)` churn for root surfaces.

If XML/tag cleanup is part of the product semantics, do it once on the server.

### 4. Optionally add a root-level display status

We may also want a small server-authored field like:

- `list_status`

This would collapse "active/working/permission/question/reply/ended" into the root-facing display state we actually render.

This is optional, but it would remove one more layer of client-side semantic mapping.

### 5. Add a root-delta shape

The root shell should not need to reinterpret rich session deltas just because one lightweight list field changed.

The clean end state is:

- a `session_list_delta` event or equivalent root-shaped delta payload
- only list-safe fields included
- no transcript or detail baggage

This is not strictly required for the first migration, but it is the right target if we want passive and multi-agent session counts to scale.

### 6. Keep detail contracts rich

Do not try to turn detail/session APIs into list payloads.

That split is healthy:

- list contracts are tiny
- detail contracts are rich

## What We Should Delete Or Stop Using

These are the main patterns to retire:

- using `Session` as a root list model
- using `SessionSummary` computed properties for root sorting or filtering
- any root sorting that calls `displayName`
- any root list code that normalizes strings during comparison
- any shared "one model serves every surface" assumption

## New Client Architecture

### Layer 1: Raw server contracts

Keep these dumb.

- `ServerSessionListItem`
- `ServerSessionState`
- `ServerStateChanges`

### Layer 2: Pure root projections

Create small stored render models, likely one per major root surface:

- `RootSessionRecord`
- `DashboardSessionCardModel`
- `QuickSwitcherSessionModel`
- `AttentionSessionModel`
- `MenuBarSessionModel`
- `LibrarySessionRowModel`

These should be plain stored values.

No expensive computed properties.
No regex.
No fallback chains at render time.

`RootSessionRecord` is the only shared root input. Every other root model is a pure surface-specific projection from that smaller record.

### Layer 3: Detail state stays separate

Keep using:

- `SessionStore`
- `SessionObservable`

for selected-session/detail-only behavior.

That path can stay richer because it is not supposed to power the entire app shell.

## Recommended Ownership Boundaries

### Server side

Own:

- title fallback semantics for root lists
- sort-key generation
- search-text generation
- root-list payload shaping

### Root client state

Own:

- merging endpoint-scoped list payloads
- pure per-surface projection transforms
- selection / navigation state
- endpoint filtering

### Detail client state

Own:

- live session detail
- approvals
- workers
- conversation
- rich session controls

## Migration Plan

### Phase 1: Add the new server payload

Server work:

- add `SessionListItem` in protocol
- include `display_title`, `display_title_sort_key`, `display_search_text`, and `list_status`
- add server adapters from session domain to list item
- change `GET /api/sessions` to return list items
- change WS `sessions_list` and `session_created` to emit list items
- add a list-safe delta path for root updates

Do not remove existing `SessionSummary` yet if detail/create paths still need it.

### Phase 2: Add new Swift contracts and adapters

Client work:

- add `ServerSessionListItem`
- add `RootSessionRecord` as the only shared root input type
- make the root store ingest only the new list item payload

At this phase, detail views still work exactly the same way.

### Phase 3: Replace the root projection spine

Replace:

- `UnifiedSessionsStore`
- `WindowSessionCoordinator`
- root dashboard/menu/quick-switcher inputs

with summary-first root records and small pure projections.

Important:

- root sorting must use stored sort keys only
- root filtering/search must use stored search text only
- root surfaces must not touch `SessionSemantics.displayName(...)`
- root surfaces must not touch `SessionSummaryItem`
- root surfaces must not reach into `SessionObservable`

### Phase 4: Strip old root dependencies

Once the new root path is stable:

- remove old `SessionSummary`-based root adapters
- stop using `SessionSummaryItem` for root-only surfaces
- keep `SessionSummary` only where it still legitimately belongs, or remove it entirely if it becomes redundant
- delete compatibility overloads that still accept `[Session]` for root planners

### Phase 5: Move detail-only semantics out of the root path

This is the cleanup pass that makes the rewrite stick:

- split `SessionSemantics` into root-safe vs detail-only helpers, or remove root usage entirely
- root notification/attention paths stop consulting `SessionObservable`
- library and quick-switcher planners stop supporting both `[Session]` and `[SessionSummary]`
- root views receive already-projected surface models instead of doing last-mile derivation in `body`

### Phase 6: Profile and tighten

After the rewrite:

- profile idle passive sessions
- profile 10+ CLI / passive sessions
- profile 50+ synthetic summaries if we can

The success bar is:

- root CPU stays low when not in a conversation
- passive session churn does not peg the main thread
- session sorting/filtering no longer shows semantic string work on the hot path
- attention/notification updates stay on root-safe data only

### Profiling Targets

These are the concrete signatures we want to disappear from the root path:

- `Session.displayName.getter`
- `SessionSemantics.displayName(...)`
- `String.strippingXMLTags()`
- `NSRegularExpression.init(pattern:options:)`
- `Array<Session>.==`
- broad `WindowSessionCoordinator.refreshSessions()` churn

The first proof pass after the rewrite should capture:

- idle dashboard with 10 passive CLIs
- idle dashboard with 25+ sessions if we can simulate it
- quick switcher open with live query typing
- one burst of root list updates while no conversation is open

And we should add signposts around:

- root snapshot creation
- root sort
- quick switcher projection
- activity stream projection
- attention/toast update

## Parallel Worker Lanes

These can move in parallel with very little overlap.

### Lane A: Server contract lane

Own:

- protocol types
- REST list endpoint
- WS list/create payloads
- server-side title/sort-key shaping

Key files:

- `orbitdock-server/crates/protocol/src/types.rs`
- `orbitdock-server/crates/protocol/src/server.rs`
- `orbitdock-server/crates/server/src/runtime/session_registry.rs`
- `orbitdock-server/crates/server/src/domain/sessions/session.rs`
- `orbitdock-server/crates/server/src/transport/http/sessions.rs`

### Lane B: Root client contracts lane

Own:

- Swift contract decoding for the new list item
- root internal record model
- adapter functions from server list item to root record

Key files:

- `OrbitDockNative/OrbitDock/Services/Server/Protocol/ServerSessionContracts.swift`
- `OrbitDockNative/OrbitDock/Services/Server/ServerTypeAdapters.swift`
- new root-model files under `OrbitDockNative/OrbitDock/Models/`

### Lane C: Root projection lane

Own:

- replacement for `UnifiedSessionsStore`
- replacement for `WindowSessionCoordinator` root list flow
- pure projection builders

Key files:

- `OrbitDockNative/OrbitDock/Services/Server/UnifiedSessionsStore.swift`
- `OrbitDockNative/OrbitDock/Services/WindowSessionCoordinator.swift`
- `OrbitDockNative/OrbitDock/ContentView.swift`

### Lane D: Surface migration lane

Own:

- dashboard
- quick switcher
- menu bar
- attention/toasts/notifications

Key files:

- `OrbitDockNative/OrbitDock/Views/Dashboard/`
- `OrbitDockNative/OrbitDock/Views/QuickSwitcher/`
- `OrbitDockNative/OrbitDock/Views/MenuBar/MenuBarView.swift`
- `OrbitDockNative/OrbitDock/Services/AttentionService.swift`
- `OrbitDockNative/OrbitDock/Services/ToastManager.swift`
- `OrbitDockNative/OrbitDock/Services/NotificationManager.swift`

### Lane E: Verification lane

Own:

- unit tests for pure projections
- integration tests for root session updates
- profiling notes / signposts

Focus:

- root session ordering
- attention state
- search/filter behavior
- endpoint filtering
- idle passive-session CPU behavior

### Lane F: Dead-code and compatibility cleanup lane

Own:

- deleting `[Session]` root overloads
- removing root dependencies on `SessionSummaryItem`
- shrinking `SessionSummary` usage down to real detail or compatibility-only needs

Key files:

- `OrbitDockNative/OrbitDock/Models/SessionSummary.swift`
- `OrbitDockNative/OrbitDock/Views/QuickSwitcher/QuickSwitcherProjection.swift`
- `OrbitDockNative/OrbitDock/Views/Library/LibraryArchivePlanner.swift`
- `OrbitDockNative/OrbitDock/Services/AttentionService.swift`

## Concrete Delete / Hollow-Out List

These are the strongest candidates to replace instead of adapt:

- `OrbitDockNative/OrbitDock/Services/Server/UnifiedSessionsStore.swift`
- `OrbitDockNative/OrbitDock/Services/WindowSessionCoordinator.swift`

These should be hollowed out so root surfaces stop leaning on `SessionSummary` semantics:

- `OrbitDockNative/OrbitDock/Models/SessionSummary.swift`
- `OrbitDockNative/OrbitDock/Views/QuickSwitcher/QuickSwitcherProjection.swift`
- `OrbitDockNative/OrbitDock/Views/Library/LibraryArchivePlanner.swift`

These should remain rich and detail-only:

- `OrbitDockNative/OrbitDock/Models/Session.swift`
- `OrbitDockNative/OrbitDock/Services/Server/SessionStore.swift`
- `OrbitDockNative/OrbitDock/Services/Server/SessionObservable.swift`
- `OrbitDockNative/OrbitDock/Views/SessionDetail/`

## Working Principles For The Rewrite

- root models must be stored-value only
- root search/sort keys must be precomputed
- root updates must be cheap to compare
- detail state must not leak into root invalidation
- if a root feature needs more data, change the API or projection layer instead of reaching sideways into detail state

## Risk Notes

The main risk is temporary duplication while both the old and new root paths coexist.

That is acceptable.

What we should avoid is half-adapting the old model again. If we take this on, the goal should be replacement, not another wrapper layer.

## Definition Of Done

We are done when:

- root UI no longer depends on `Session` or computed `SessionSummary` semantics
- `GET /api/sessions` and root WS list payloads are cheap and purpose-built
- root sorting/filtering uses stored values only
- detail views still use the richer session path
- profiling no longer shows root CPU dominated by session equality, display-name derivation, or regex/string normalization

## Recommendation

Yes, the API should change a little.

But only a little.

This is mostly a client architecture rewrite, and the server should support it by giving the client a better list-shaped contract instead of forcing it to derive list semantics from a richer session object.
