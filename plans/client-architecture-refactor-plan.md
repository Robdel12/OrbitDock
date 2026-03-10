# Client Architecture Refactor Plan

This is the client-side version of the server cleanup we just finished.

The goal is not to chase line counts or move files around for the sake of it. The goal is to give the Swift client a structure that scales:

- clear ownership boundaries
- one obvious place for new code to go
- less duplicated state
- less transport logic leaking into views
- smaller feature surfaces that are easier to reason about and test

This plan is intentionally phased. We want real progress with low-risk checkpoints, not one giant rewrite.

---

## Current Status

This plan is now an active execution document, not just a roadmap.

### Done

- **Phase 0: Guardrails and Architecture Notes**
  - the client now has a real architecture doc and README surface
- **Phase 1: Split Transport Contracts**
  - `ServerProtocol.swift` has been split into focused transport/domain contract files
  - the old `APIClient` center has been deleted
  - typed client surfaces now own API behavior by capability
- **Core conversation recovery outcome from Phase 3**
  - reopening a previously broken Claude session now loads the real conversation instead of a sparse subset
  - the server conversation bootstrap contract is now authoritative and covered by regression tests
- **Phase 9, composer phase 1**
  - `DirectSessionComposer` now has a real input state model instead of hand-managed completion/focus flags in the root view
  - send-mode decisions now go through a pure action planner instead of living inline in the feature view
  - deterministic unit tests cover input transitions, completion behavior, and send planning
- **Review phase 1a**
  - review workflow extraction is underway with pure workflow helpers for comment send behavior and addressed-file tracking
  - review cursor and navigation logic now live in dedicated helpers with deterministic tests
- **Review phase 1b**
  - comment-composer interaction state and range planning now live in dedicated review helpers instead of raw state inside `ReviewCanvas`
  - deterministic planner and interaction-state tests now cover mark selection, drag ranges, removed-only rejection, and composer reset rules
- **Review phase 1c**
  - review-send coordination, message formatting, and review-round banner tracking now live in dedicated helpers instead of `ReviewCanvas`
  - deterministic unit tests now cover the send plan, banner progression, and addressed-file tracking
- **Review phase 1d**
  - file header and compact file-strip rendering now live in dedicated review helpers instead of `ReviewCanvas`
  - the review shell now owns less mixed presentation/workflow code, making the remaining routing and interaction seams easier to isolate
- **Review phase 1e**
  - navigation/file-selection routing and editor-opening actions now live in dedicated review helpers instead of `ReviewCanvas`
  - deterministic unit tests now cover file-id routing and selected-file projection behavior
- **Window-local external navigation cleanup**
  - app-internal `.selectSession` broadcast routing has been replaced with a typed app-level external navigation center
  - external session selection now enters through a typed channel while actual navigation stays window-local
- **Phase 6 / Phase 7, lifecycle ownership**
  - `WindowSessionCoordinator` now owns startup/runtime-graph refresh behavior instead of `ContentView`
  - the app delegate now talks to `OrbitDockAppRuntime` instead of reaching for global runtime singletons during notifications and shutdown
- **Composer phase 2a**
  - pending approval panel state and pure approval/question planning now live in focused composer helpers instead of the root view
  - deterministic unit tests now cover pending answer selection, collection, primary-answer fallback, and per-request state reset
- **Composer phase 2b**
  - attachment state and mention/image send planning now live in focused composer helpers instead of the root send path
  - deterministic unit tests now cover mention expansion, attachment reset, and image preservation through send planning
- **Composer phase 2c**
  - skill resolution, send payload preparation, and async send execution now live in focused composer helpers instead of `DirectSessionComposer+Helpers.swift`
  - deterministic unit tests now cover inline skill parsing, skill-input resolution, shell-context preparation, and send/steer request preparation
- **Composer phase 2d**
  - provider controls and workflow overflow menus now live in dedicated composer helpers instead of the main footer file
  - the remaining composer cleanup is now mostly display-only polish and any last provider-specific action drift
- **Testing baseline**
  - `make build` is green
  - `make test-unit` is green
  - the conversation timeline image-row regression is now covered at the projection boundary

### In Progress

- **Phase 2: Fix Session State Ownership**
  - session/detail mirroring is much better than before
  - shared session-delta projection helpers now own a real chunk of list/detail state application
  - `SessionStore` still has more responsibility to peel away
- **Phase 4: Make Runtime State Explicit**
  - runtime readiness and connection state are now much more explicit, but the app shell still owns too much coordination
- **Phase 5: Fix Control-Plane Reconciliation**
  - the coordinator exists and the worst duplicate-write behavior is gone
  - we still want to keep simplifying the surrounding runtime ownership
- **Phase 5B: Rebuild the Networking Boundary and Startup Phases**
  - this is the current architectural focus
  - the old generic networking center is gone, readiness is explicit, and startup is improving
  - we still need to keep simplifying boot, query readiness, and background service startup
- **Phase 6 / Phase 7**
  - service lifecycles and window-local state are moving in the right direction
  - app-internal session refresh now uses typed per-store update streams instead of a global `serverSessionsDidChange` notification
  - external session selection now uses a typed app-level navigation center instead of a process-wide notification hop
  - internal fork navigation is starting to move onto window-local typed paths instead of broadcast notifications
  - approval-card to composer routing is moving onto typed feature callbacks instead of process-wide notifications
  - these phases are not finished yet, but the shell now owns much less runtime lifecycle wiring than before
- **Phase 10: Refactor the Review Feature**
  - workflow, cursor/navigation, projection, comment composition, send coordination, file chrome, and routing/editor actions are now extracted from `ReviewCanvas`
  - the main remaining work is mouse/composer interaction cleanup so the root view becomes a true shell

### Next

- finish the remaining window-local routing cleanup and remove the last app-internal notification paths
- keep thinning `SessionStore` and related store/runtime ownership
- clean up the last obvious app-global leftovers, especially dead singletons and preview/runtime `.shared` leakage
- then land complete feature phases in this order:
  - review interaction cleanup
  - app-global ownership cleanup
  - larger screen decomposition

### Next complete phases

- **Composer phase 1: Extract the input + command engine**
  - done
  - input/completion state now lives in a dedicated composer model
  - send-mode and command routing now have a pure planner with unit tests
  - the remaining composer work is pending-approval state, attachments, and provider/action boundaries
- **Review phase 1: Extract projection + workflow**
  - in progress
  - review workflow, cursor/navigation, projection/state, comment composition/range-selection state, send coordination, file chrome, and routing/editor actions are now extracted into dedicated helpers
  - the remaining work is mouse/composer interaction cleanup so `ReviewCanvas` becomes a real feature shell
  - unit tests now cover workflow behavior, cursor/navigation, review projection, comment-composer planning, and review send coordination
- **Composer phase 2: Extract pending approval + action boundaries**
  - in progress
  - pending approval presentation state, pure approval/question planning, attachment state/planning, skill resolution, send payload preparation, async send execution, provider controls, and workflow menus are now extracted
  - the remaining work is a final pass over display-only helpers and any last provider-specific action drift
  - keep the root view focused on rendering bindings into the composer model
  - add deterministic tests for pending-action routing, attachment behavior, and provider-aware send execution

---

## What is wrong today

The biggest issues are architectural, not cosmetic.

### 1. Protocol and transport surfaces were too centralized, and the remaining work is cleanup

The old hotspots were:

- `OrbitDockNative/OrbitDock/Services/Server/ServerProtocol.swift`
- `OrbitDockNative/OrbitDock/Services/Server/APIClient.swift`

That old structure concentrated too much transport logic in too few files.

We have already broken that center apart. The remaining work now is making sure the typed client surfaces and protocol files stay clean, narrow, and easy to extend without growing a new giant transport hub.

### 2. Session state ownership is too blurry

These files are the main hotspot:

- `OrbitDockNative/OrbitDock/Services/Server/SessionStore.swift`
- `OrbitDockNative/OrbitDock/Services/Server/SessionObservable.swift`
- `OrbitDockNative/OrbitDock/Models/Session.swift`
- `OrbitDockNative/OrbitDock/Services/Server/ConversationStore.swift`

Right now the app is mutating overlapping session state in multiple models and manually keeping them in sync. That is a drift trap.

### 3. Runtime state leaks too far upward

These files are telling the story:

- `OrbitDockNative/OrbitDock/Services/Server/ServerRuntimeRegistry.swift`
- `OrbitDockNative/OrbitDock/ContentView.swift`
- `OrbitDockNative/OrbitDock/Services/Server/UnifiedSessionsStore.swift`

Connection state, runtime lifecycle, and store refresh logic are still coordinated too often from view code or app-shell code.

### 4. Views are carrying too much workflow logic

The largest offenders today are:

- `OrbitDockNative/OrbitDock/Views/Codex/DirectSessionComposer.swift`
- `OrbitDockNative/OrbitDock/Views/Review/ReviewCanvas.swift`
- `OrbitDockNative/OrbitDock/Views/SessionDetailView.swift`
- `OrbitDockNative/OrbitDock/Views/SettingsView.swift`
- `OrbitDockNative/OrbitDock/Views/NewSessionSheet.swift`
- `OrbitDockNative/OrbitDock/Views/QuickSwitcher.swift`

These are feature modules in disguise. They work, but they are too easy to grow in the wrong direction.

### 5. NotificationCenter is doing app-internal coordination

That is acceptable for OS integration. It is not a good long-term app architecture.

We should not keep using global notifications as a substitute for typed runtime or navigation actions.

---

## Target Architecture

The client should follow a structure that is close in spirit to the server:

- transport code owns wire formats and request/response mechanics
- runtime/store code owns orchestration and app-facing state
- models own durable domain concepts
- views render feature state and send intents
- side effects live behind feature models, stores, or runtime services

### Layer rules

#### Transport

Files under `Services/Server` that deal with HTTP, WebSocket, and wire DTOs should stay transport-focused.

They should:

- encode and decode wire payloads
- expose typed request/response functions
- avoid app-shell behavior
- avoid view logic

They should not:

- own navigation
- mutate multiple app-level stores directly
- contain feature workflow logic

#### Runtime and Stores

Runtime/store code should:

- own endpoint lifecycle
- own connection state
- own event routing
- own authoritative mutable session state
- expose feature-friendly intents to the UI

Runtime/store code should not:

- reach into SwiftUI views
- use NotificationCenter for normal app coordination
- duplicate state across multiple mutable models unless there is a very clear projection boundary

#### Views

Views should:

- render state
- hold ephemeral presentation state
- emit user intents

Views should not:

- orchestrate multi-step async flows
- manually reconcile transport/runtime state
- hide large feature modules in one file unless the feature is genuinely tiny

---

## Target File Shape

This is not a hard final tree, but it is the direction we want.

```text
OrbitDockNative/OrbitDock/
  Models/
    Session/
    Conversation/
    Review/
    Worktrees/

  Services/
    Server/
      Transport/
        API/
          Sessions.swift
          Conversation.swift
          Approvals.swift
          Worktrees.swift
          Usage.swift
          Settings.swift
        Protocol/
          Sessions.swift
          Conversation.swift
          Approvals.swift
          Worktrees.swift
          Usage.swift
          Auth.swift
        EventStream.swift
      Runtime/
        ServerRuntimeRegistry.swift
        ServerRuntime.swift
        ConnectionState.swift
      Stores/
        SessionListStore.swift
        SessionDetailStore.swift
        ConversationStore.swift
        ApprovalStore.swift
        WorktreeStore.swift
        UnifiedSessionsStore.swift

  Views/
    App/
      ContentView.swift
      AppShell.swift
    Codex/
      Composer/
      SessionActions/
    Review/
      Canvas/
      Comments/
      Navigation/
    Settings/
      General/
      Notifications/
      Setup/
      Diagnostics/
    Sessions/
    Worktrees/
```

The exact names can change. The important part is the ownership model.

---

## Refactor Principles

### 1. One mutable owner per piece of state

If session detail state changes, there should be one authoritative mutable owner.

If the app also needs a lighter list model, that should be projected from the authoritative state instead of being manually dual-written.

### 2. Views emit intents, stores handle workflows

Async flows like:

- create session
- continue in new session
- subscribe/unsubscribe
- refresh approvals
- fork to worktree
- send review comments

should be owned by a feature store/coordinator, not spread across views.

### 3. Transport is a boundary, not the center of the app

`ServerProtocol` and `APIClient` should be easy to grep and easy to change, but they should not be the place where feature behavior accumulates.

### 4. Split by responsibility, not just by size

We should not split files only because they are long.

We should split when they mix concerns like:

- DTOs + app logic
- rendering + workflow orchestration
- caching + event routing + action dispatch
- multiple independent settings panes in one file

### 5. Prefer functional state transforms where possible

For reducers, projectors, and patch application:

- explicit inputs
- explicit outputs
- minimal hidden state
- deterministic transforms

This will make the client easier to test and easier to reason about.

---

## Phases

## Phase 0: Guardrails and Architecture Notes

Before touching code, write down the rules the refactor is trying to enforce.

### Deliverables

- a short client architecture doc
- a short “where new code goes” section
- state ownership rules for session data
- a rule about NotificationCenter only being used for true cross-system integration

### Done when

- contributors can tell where a new transport type, runtime concern, or feature view belongs
- the rules are short enough to use in code review

---

## Phase 1: Split Transport Contracts

This is the safest high-value starting point.

### Scope

- split `ServerProtocol.swift` into smaller protocol/domain files
- replace the old generic API center with typed clients by server capability
- keep behavior the same while changing structure aggressively

### Why first

This reduces blast radius fast without forcing a state rewrite immediately.

### Expected output

- smaller protocol files with clearer ownership
- typed client files that are easy to grep by feature
- fewer unrelated changes touching the same transport file

### Testing

- codec roundtrip tests stay green
- no user-facing behavior change
- existing integration tests still pass

---

## Phase 2: Fix Session State Ownership

This is the most important architectural phase.

### Scope

- reduce or remove duplicated mutable ownership across:
  - `Session`
  - `SessionObservable`
  - `ConversationStore`
  - `SessionStore`
- introduce explicit projection or reducer helpers
- make token/approval/message/session fields update from one authoritative path

### Recommended direction

Use one authoritative mutable detail owner per session, then project:

- lightweight list/session summary state
- conversation state
- derived UI-friendly values

### Expected output

- fewer `sess.foo = ...; obs.foo = ...` update pairs
- fewer drift bugs
- cleaner event application logic

### Testing

- state reducer/unit tests for session patches and token updates
- outcome tests for event application
- regression test for list/detail token consistency
- projection tests for shared list/detail state application

---

## Phase 3: Fix Conversation Hydration and State Recovery

This is the user-visible reliability phase.

The bug we are explicitly trying to kill here is:

- if the user is not sitting in the conversation view watching events stream live,
- then comes back later,
- the client still needs to load the complete conversation state it should show,
- including missed messages, tools, and tool outputs
- without depending on having watched those events in real time

### Progress

- conversation reopen/hydration is now driven by an explicit recovery path instead of relying on live-stream presence
- the server conversation bootstrap contract was tightened so reopened Claude sessions now return authoritative full history instead of sparse runtime subsets
- the client has been verified against a real previously-broken Claude session (`od-9fab8463-c640-432f-9bfa-bdd3dd5d78db`) and now renders the full conversation correctly
- regression coverage now exists both at the runtime query seam and the HTTP endpoint seam on the server side
- the remaining work here is cleanup and simplification, not proving the core recovery design

The app should not depend on having watched events in real time to reconstruct the conversation correctly.

### Scope

- make conversation hydration an explicit runtime/store concept instead of a best-effort side effect
- define clear loading states for:
  - retained in-memory conversation
  - restored cached conversation
  - bootstrap from server
  - backfill in progress
  - fully hydrated vs partially hydrated conversation state
- stop forcing refresh paths that discard usable local state without a good reason
- tighten trim/cache/unsubscribe behavior so returning to a session is deterministic
- make `ConversationView` render against explicit hydration state instead of only `hasReceivedSnapshot`

### Files

- `ConversationStore.swift`
- `SessionStore.swift`
- `SessionDetailView.swift`
- `ConversationView.swift`

### Recommended direction

Use `ConversationStore` as the single owner of conversation payload and hydration state.

That store should expose an intentional loading model, for example:

- no data yet
- restored from cache
- bootstrapping latest window
- backfilling older history
- hydrated enough for display
- fully hydrated
- failed

`SessionStore` should choose a clear subscription/hydration policy instead of branching ad hoc between retained data, cache restore, fresh bootstrap, and WebSocket replay.

### Expected output

- opening a session later shows the same conversation/tool history the user missed while away
- returning to a session is deterministic whether the data came from memory, cache, bootstrap, or replay
- less ambiguity around whether the client has “some” conversation data or the conversation data it actually needs
- fewer state bugs caused by trimming payloads and rebuilding them inconsistently

### Testing

- regression test for “messages/tools still appear after not watching live”
- tests for restore-from-cache plus bootstrap reconciliation
- tests for trim/unsubscribe then reopen
- tests for long conversations that require multiple backfill pages
- tests that verify tool-heavy turns and assistant messages load correctly even without live observation

---

## Phase 4: Make Runtime State Explicit

### Scope

- move connection state ownership into runtime
- separate derived runtime state from applied remote control-plane state
- stop letting runtime recomputation paths trigger ad hoc remote mutations
- reduce view-led refresh orchestration
- make unified session state derive from runtime/store signals instead of ad hoc shell hooks

### Files

- `ServerRuntimeRegistry.swift`
- `ServerRuntime.swift`
- `UnifiedSessionsStore.swift`
- `ContentView.swift`

### Expected output

- connection state becomes observable and explicit
- runtime recomputation becomes deterministic and side-effect aware
- fewer shell-level `onAppear` / `onChange` coordination hacks
- runtime setup becomes more testable

### Testing

- runtime status tests
- reconnect/disconnect UI state tests
- endpoint switching tests
- window-local session update tests that do not rely on global notifications

---

## Phase 5: Fix Control-Plane Reconciliation

This is the runtime ownership phase for endpoint-primary state and client primary claims.

The bug class we are explicitly trying to eliminate here is:

- runtime recomputation spawning overlapping network mutations
- duplicate `setClientPrimaryClaim` writes during startup or endpoint changes
- transport crashes or race conditions caused by uncontrolled control-plane reconciliation

This should be solved as an architecture problem, not a request-transport patch.

### Scope

- move primary endpoint / client primary-claim reconciliation out of incidental runtime recomputation paths
- stop using one fire-and-forget `Task` per endpoint update
- introduce one explicit owner for control-plane reconciliation
- separate:
  - desired primary assignment state
  - last applied remote state
  - in-flight reconciliation state
- remove control-plane mutations from generic session-store paths where possible

### Files

- `ServerRuntimeRegistry.swift`
- `ServerRuntime.swift`
- `SessionStore.swift`
- `API/ControlPlaneClient.swift`
- `API/ServerClients.swift`

### Recommended direction

Use a dedicated coordinator for server-role and client primary-claim reconciliation.

That coordinator should:

- accept desired state from runtime planning
- coalesce repeated recomputations
- serialize remote writes in a stable order
- make stale/in-flight reconciliation visible and testable

`ServerRuntimeRegistry` should stay responsible for planning runtime state, not directly spawning mutation tasks from recomputation methods like `recomputePrimaryEndpoint()`.

### Expected output

- one obvious owner for primary-claim reconciliation
- no duplicate concurrent claim writes during startup or endpoint changes
- primary endpoint changes become deterministic and easier to reason about
- transport code stops being the place where control-plane crashes surface first

### Testing

- pure planner tests for desired primary assignment changes
- coordinator tests that verify:
  - repeated recomputes are coalesced
  - duplicate writes are not emitted
  - writes happen in stable order
  - stale reconciliation work is ignored
- runtime integration tests for:
  - startup bootstrap
  - endpoint enable/disable changes
  - default endpoint changes
- reconnect flows without duplicate primary-claim writes

---

## Phase 5B: Rebuild the Networking Boundary and Startup Phases

This is the transport-foundation phase.

The bug class we are explicitly trying to eliminate here is:

- boot-time crashes surfacing from the generic HTTP request path
- control-plane mutations and normal app reads sharing the same implicit transport boundary
- startup code treating "runtime exists" or "endpoint is enabled" as enough reason to issue REST traffic
- Foundation async request bridging being the place where architectural bugs surface first

This should be solved as a networking and startup-design problem, not a localized request patch.

At this point we should assume we are free to replace the current client networking/runtime path outright if that yields a cleaner design. The goal is not to preserve the old `APIClient` shape out of habit. The goal is to end up with a networking/runtime stack that is explicit, Swift 6-safe, and easy to reason about.

### Progress

- the old `APIClient` center of gravity has been removed in favor of narrower typed client surfaces
- control-plane reconciliation now has an explicit owner instead of ad hoc mutation tasks
- runtime readiness is modeled explicitly enough to gate startup work and background reads
- the server bootstrap contract bug for sparse Claude conversations is fixed, which gives this client phase a trustworthy query foundation
- the remaining work in this phase is cleanup and simplification, not proving the architecture direction

### Scope

- make the client networking layer an explicit boundary instead of an inline closure plus generic request helpers
- normalize transport results and transport errors before they leave the callback boundary
- separate control-plane mutation traffic from normal query traffic where it improves lifecycle clarity
- define explicit startup phases for:
  - endpoint configuration
  - runtime creation
  - runtime connection
  - readiness for control-plane reconciliation
  - readiness for background reads like usage refresh
- stop issuing generic REST work during bootstrap until the owning runtime phase says it is allowed
- separate app-global infrastructure from window-scoped state and lifecycle
- make the startup pipeline explicit enough that a new window can get its own shell state without inheriting hidden boot work

### Files

- `API/ServerClients.swift`
- `API/ControlPlaneClient.swift`
- `API/ServerAPICommon.swift`
- `API/SessionsClient.swift`
- `API/ConversationClient.swift`
- `API/ApprovalsClient.swift`
- `API/UsageClient.swift`
- `API/WorktreesClient.swift`
- `ServerRuntime.swift`
- `ServerRuntimeRegistry.swift`
- `ServerControlPlaneCoordinator.swift`
- `UsageRuntimeContext.swift`
- `SubscriptionUsageService.swift`
- `CodexUsageService.swift`
- `OrbitDockApp.swift`
- `OrbitDockWindowRoot.swift`
- `ContentView.swift`

### Recommended direction

Use explicit transport and startup boundaries, even if that means deleting and replacing parts of the current stack.

That means:

- one narrow transport layer owns request execution and result normalization
- one query client surface owns ordinary reads
- one control-plane client surface owns server-role and primary-claim mutation
- app-global runtime infrastructure is explicit
- window-scoped shell state is explicit
- runtime code plans startup state first, then opts into control-plane sync and background reads only when the runtime is actually ready

The ownership rule should be:

- app-global: endpoint definitions, shared runtime registry, shared event connectivity
- window-scoped: router, selection, sheets, quick switcher, transient attention/toast state
- lifecycle-scoped: usage refresh, control-plane reconciliation, and any background work that should start and stop explicitly

If the old `APIClient` composition root makes that harder to express cleanly, we should replace it with a smaller set of types instead of preserving it.

The important design rule is:

- "configured" is not "connected"
- "connected" is not "ready for mutation"
- "ready for mutation" is not "ready for background refresh"

### Expected output

- boot no longer issues incidental REST traffic just because runtime objects exist
- control-plane writes have a narrower, easier-to-debug path
- transport crashes stop surfacing from generic request helpers during startup
- networking becomes easier to instrument, test, and reason about
- a new window can boot with its own shell state without accidentally inheriting global side effects

### Testing

- transport tests for normalized success/error behavior
- startup/runtime tests that verify:
  - no control-plane mutation before readiness
- no usage/background reads before readiness
- endpoint enable/configure does not imply immediate REST traffic
- control-plane tests that verify startup sequencing stays deterministic
- window/runtime tests that verify creating a new window does not trigger shared hidden navigation or startup work

---

## Phase 6: Make Service Lifecycles Explicit

This is the “stop hidden startup work” phase.

The bug class we are explicitly trying to eliminate here is:

- global singleton access triggering network work
- usage polling starting from `init()` instead of an explicit lifecycle
- process-wide services reaching into shared runtime state before app bootstrap is actually settled

### Scope

- remove eager observer/refresh work from singleton initializers
- make usage services explicitly startable/stoppable
- make `UsageServiceRegistry` an explicit composition dependency instead of an eager global composition root
- stop treating `shared` access as a valid place to start real background work

### Files

- `SubscriptionUsageService.swift`
- `CodexUsageService.swift`
- `UsageServiceRegistry.swift`
- `OrbitDockApp.swift`

### Expected output

- touching a service singleton no longer starts network traffic
- usage polling only starts when the app/window runtime chooses to start it
- startup becomes easier to reason about and easier to test
- transport crashes stop surfacing from hidden singleton init paths

### Testing

- tests for explicit `start` / `stop` lifecycle behavior
- tests that verify refresh does not start from initialization alone
- tests that verify endpoint updates only trigger refresh after lifecycle start

---

## Phase 7: Make Windows Truly Independent

This is the scene-ownership phase.

The goal is:

- a new OrbitDock window gets its own navigation, selection, quick switcher state, and sheet state
- while shared runtime/server truth remains shared across the app

### Scope

- add a real window-root scene model
- move router/navigation/presentation state out of `OrbitDockApp`
- move toast ownership out of global shared state
- stop using shared runtime selection as a substitute for window-local focus

### Files

- `OrbitDockApp.swift`
- `ContentView.swift`
- `AppRouter.swift`
- `ToastManager.swift`
- `UnifiedSessionsStore.swift`

### Expected output

- each window gets its own router and local shell state
- shared runtime stays shared, but window focus does not
- selecting a session in one window does not hijack another window’s navigation state
- the app shell becomes much easier to reason about

### Testing

- window-root state tests for independent router/presentation state
- tests for external navigation handling against a window-local router
- tests for toast/session-selection behavior staying local to a window

---

## Phase 8: Thin the App Shell

### Scope

- turn `ContentView.swift` into a composition root
- move quick-launch/session-creation orchestration out of the root view
- reduce global NotificationCenter usage for app-internal flow

### Expected output

- shell becomes easier to reason about
- fewer invisible dependencies between services and views
- less singleton-driven behavior hidden in the UI layer

### Testing

- app-shell composition tests where useful
- navigation and selection outcome tests

---

## Phase 9: Refactor the Composer Feature

### Scope

- reorganize `DirectSessionComposer` into a real feature module
- extract state/actions from the root view
- split pending approval, attachments, completions, and continuation/fork flows into focused files

### Expected output

- root composer view becomes much smaller
- state is easier to reason about
- provider-specific behavior becomes easier to isolate

### Testing

- feature tests around:
  - send/steer behavior
  - approval handling
  - mention/attachment behavior
  - connection-status presentation

---

## Phase 10: Refactor the Review Feature

### Scope

- split `ReviewCanvas` into review state, navigation/cursor helpers, comment composition, and render sections
- reduce side effects directly in the giant view file

### Expected output

- clearer review feature boundaries
- easier keyboard/navigation maintenance
- less fear when touching review UX

### Testing

- pure cursor/navigation tests
- review selection/composition state tests
- integration tests for comment workflows

---

## Phase 11: Decompose Large Screens

### Scope

- `SettingsView`
- `QuickSwitcher`
- `NewSessionSheet`
- `SessionDetailView`
- `LibraryView` if still warranted after earlier phases

### Expected output

- screens become feature folders
- sections/panes live in their own files
- transport/workflow logic moves into local feature models

### Testing

- behavior tests at the feature level
- avoid tests that inspect internal section decomposition

---

## Phase 12: Conversation Rendering Architecture Pass

This should happen after the store/runtime work, not before.

### Scope

- tighten boundaries across:
  - timeline projection
  - tool-cell models
  - platform-specific cell/view wrappers
  - height/layout helpers

### Why later

This area is large and important, but it is also already more structured than the store/runtime side. The biggest risk today is state ownership and orchestration, not rendering correctness.

### Expected output

- cleaner platform-neutral render model
- less duplication between AppKit/UIKit wrappers
- easier future performance work

---

## Testing Philosophy for the Client Refactor

Use the same testing philosophy we used on the server.

### Test outcomes, not structure

Prefer tests like:

- when this event arrives, the session list and detail state agree
- when the socket disconnects, the UI shows reconnecting/failed state
- when a session is launched, the correct screen state appears

Avoid tests like:

- store A called helper B then helper C
- view X toggled internal local boolean Y before calling method Z

### Prefer pure reducers and projectors

If we extract:

- event reducers
- state projectors
- patch application helpers
- selection/navigation helpers

those should get direct unit tests.

### Use feature-level tests for workflows

Examples:

- session creation
- session continuation
- approval handling
- review comment creation
- connection-state transitions

### Avoid test duplication across layers

Do not test the same behavior at:

- protocol codec level
- store reducer level
- view model level
- view snapshot level

unless each layer is catching a genuinely different failure mode.

---

## Worker Lanes

This refactor splits well if we are disciplined about ownership.

### Lane A: Transport split

- `ServerProtocol`
- `APIClient`

### Lane B: Runtime/store ownership

- `SessionStore`
- `SessionObservable`
- `ConversationStore`
- `ServerRuntimeRegistry`
- `UnifiedSessionsStore`

### Lane C: App shell and coordination

- `ContentView`
- `OrbitDockApp`
- app-level navigation/runtime coordination
- NotificationCenter cleanup where it touches shell concerns

### Lane D: Composer feature

- `DirectSessionComposer`
- composer subviews/helpers

### Lane E: Review feature

- `ReviewCanvas`
- review subviews/helpers

### Lane F: Large screen decomposition

- `SettingsView`
- `QuickSwitcher`
- `NewSessionSheet`
- `SessionDetailView`

### Lane G: Conversation rendering

- conversation projector/model stack
- AppKit/UIKit wrappers
- height/layout helpers

Important rule:

Do not run all lanes at once.

Start with:

1. Lane A
2. Lane B
3. Lane C

Then do feature lanes once the state/runtime boundaries are cleaner.

---

## Recommended Execution Order

1. Phase 0
2. Phase 1
3. Phase 2
4. Phase 3
5. Phase 4
6. Phase 5 and Phase 6 in parallel if write sets are clean
7. Phase 7
8. Phase 8

---

## Success Criteria

We should call this refactor successful when:

- `ServerProtocol` is no longer a mega-file
- `APIClient` is split by capability
- session detail state has one authoritative mutable owner
- runtime connection state is explicit and observable
- `ContentView` is a thin shell
- `DirectSessionComposer` and `ReviewCanvas` are feature modules, not giant root views
- NotificationCenter is no longer a normal app-internal coordination mechanism
- large screens are organized by feature section
- new contributors can tell where code belongs without guessing

---

## Bottom Line

The client does not need a rescue. But it does need the same kind of architectural thought we just gave the server.

That is the opportunity here.

If we do this now, we get a codebase that is easier to extend, easier to test, and much less likely to drift into duplicated state and giant SwiftUI files that nobody wants to touch.
