# Architecture

This is the source of truth for OrbitDock's system design.

If the code and this doc disagree, treat this doc as the target architecture for new work and refactors. Don't cargo-cult the current implementation if it fights the model described here.

OrbitDock has two architectural halves:

- the Rust server owns durable business state
- the native SwiftUI app renders that state through explicit scene and surface boundaries

## Part 1: Native Client Architecture

The Swift app should feel like a native macOS and iOS app, not a web app port with a pile of global state.

That means:

- scenes own composition, routing, and stable dependencies
- feature view models own one surface worth of state
- `ServerSessionContext` scopes one session to one endpoint runtime
- `ServerSessionAPI` owns HTTP bootstrap and mutations
- `ServerSessionTransport` owns realtime follow-up and replay
- the server owns business truth

## The Shape Of The App

Think in two layers:

1. scene owners
2. feature surfaces

### Scene Owners

Scene owners are the top-level SwiftUI entry points that decide:

- what screen or split layout is visible
- which endpoint-scoped dependencies are active
- which session surfaces should be subscribed while the scene is on screen
- which state is scene-scoped instead of feature-scoped

Examples:

- app root window
- dashboard scene
- session detail scene
- mission scene
- settings scene

Scene owners do not parse protocol payloads, synthesize business state, or own multiple feature snapshots in one giant mutable object.

### Feature Surfaces

A surface is a renderable feature with one owner and one contract.

Examples:

- dashboard
- library
- mission control
- session detail
- conversation
- review canvas
- session runtime / controls
- skills
- MCP servers

Each surface should have:

- one view model
- one authoritative snapshot model
- one HTTP bootstrap path
- one realtime follow-up path

The surface owner may be a feature view model, or a scene-level coordinator when a single HTTP payload intentionally hydrates multiple closely related surfaces.

## Client Rules

### 1. Scene ownership comes first

Resolve real dependencies before mounting the subtree that uses them.

In practice:

- resolve the `ServerEndpointRuntime` in the scene owner
- pass stable typed dependencies downward
- avoid remounting child surfaces against placeholder stores

Do not hide dependency resolution inside multiple child view models. That creates unstable identity and lifecycle bugs.

### 2. Feature state is surface-local

Each feature view model owns only the state needed to render its surface.

Good:

- `ConversationViewModel` owns conversation rows and presentation state
- `SessionInteractionModel` maps selected-session detail snapshots and mutation responses into composer presentation state
- `ReviewCanvasViewModel` owns review snapshot and review-specific UI state

Bad:

- one shared session observable holding everything
- one god object that every screen reads from
- one transport store that also becomes product state

### 3. Session runtime stays split and boring

The session runtime exists to do transport work:

- `ServerSessionContext` scopes endpoint + session identity
- `ServerSessionAPI` handles HTTP bootstrap and mutations
- `ServerSessionTransport` handles async streams, replay, and reconnect recovery

Selected-session boot order lives in [data-flow.md](data-flow.md). The short version: conversation HTTP bootstrap records the replay cursor before realtime subscription, and the control deck stays composer UI only.

That runtime does not:

- own UI state
- decide presentation
- synthesize feature state for every screen
- become a shared mutable session model

### 4. The server owns business truth

The Swift app renders server state. It does not infer durable state by scanning connector output, transcript history, or missing channels.

If the client needs a new durable fact, add it to the server contract.

### 5. Mutation responses are authoritative

For user-initiated mutations:

1. send an HTTP request
2. apply the successful response immediately
3. let WS reconcile afterward

Do not wait for a later websocket event before updating the visible surface when the HTTP response already contains authoritative state.

## SwiftUI Ownership Rules

These rules align with the native Swift skills OrbitDock should follow.

### Use modern Observation

- use `@Observable` for reference-type UI models
- own created observable models with `@State`
- pass observable models explicitly to children
- use `@Bindable` when a child needs bindings into an injected observable model

Do not introduce new:

- `ObservableObject`
- `@Published`
- `@StateObject`
- `@ObservedObject`
- `@EnvironmentObject`

### Keep identity stable

- use stable `.id(...)` values only when they represent real identity
- prefer `@ViewBuilder` and enums over `AnyView`
- keep scene ownership and dependency resolution stable so child tasks do not flap

Do not use `AnyView` in core feature composition. It destroys structural identity and makes SwiftUI lifecycle bugs much harder to reason about.

### Use `.task` for effectful work

- use `.task` for lifecycle-bound async work
- use `.task(id:)` when the work should restart from a stable dependency change
- use `.onChange` only for lightweight synchronous synchronization

Do not use `.onAppear` as the default place for async bootstrap logic.

### Keep service injection separate from feature ownership

Shared app services are fine in `@Environment(Type.self)`:

- runtime registry
- router
- pricing service
- usage registry

But feature view models should still receive their real dependencies explicitly from the owning scene or parent feature.

### Prefer native scene patterns

For desktop flows:

- use explicit selection-driven layouts
- prefer `NavigationSplitView` or deliberate split layouts over touch-first push stacks
- keep commands, toolbars, inspectors, and keyboard behavior first-class

## Surface Ownership Map

This is the intended ownership model.

| Surface | Owner | HTTP authority | Realtime follow-up |
| --- | --- | --- | --- |
| Global sessions summary | app runtime shell owner | `GET /api/sessions/summary` | sessions-summary invalidation |
| Dashboard | dashboard scene/view model | `GET /api/sessions/active` | dashboard invalidation |
| Library | library scene/view model | `GET /api/sessions/archive` | library invalidation or explicit refresh while open |
| Missions list | mission list scene/view model | `GET /api/missions` | missions invalidation |
| Mission detail | mission control scene/view model | `GET /api/missions/{id}` | mission-specific invalidation or heartbeat |
| Session detail shell | session detail scene/view model | selected-session detail snapshot | detail-specific invalidation |
| Conversation | conversation view model | conversation bootstrap + pagination | conversation row deltas + explicit conversation resync |
| Composer UI | session interaction model owned by the session detail scene | selected-session detail snapshot + mutation responses | parent session detail invalidation |
| Review canvas | review view model | review/diff snapshot | review-specific invalidation |
| Session runtime / controls | session runtime view model | runtime support snapshot (`/controls`, instructions, collaboration modes) | detail/capability invalidation + explicit runtime refresh |
| Skills | skills view model | skills snapshot | skills-specific invalidation |
| MCP servers | MCP view model | MCP snapshot | MCP-specific invalidation |

Two important notes:

- The selected session bootstrap may intentionally hydrate multiple related surfaces once. That is fine when one owner does it on purpose.
- What is not fine is each child surface independently inventing another bootstrap path for the same session state.

## Transport Follow-Up Model

By default:

- HTTP loads authoritative state
- WebSocket tells the client what changed
- the owning surface decides whether to apply a delta directly or refresh from HTTP

### The only normal data-carrying exception

Conversation rows are allowed to arrive incrementally over WebSocket because the server owns their IDs, ordering, and replay semantics.

That means conversation may:

- bootstrap from HTTP
- append or update rows from WS deltas
- refetch from HTTP only on explicit conversation resync or pagination

### Everything else should be refresh-driven

For approvals, config, session status, review data, skills, and MCP capability changes:

- treat WS as a signal
- refresh the owning HTTP snapshot
- replace the local surface state with the new authoritative snapshot

That same rule applies to normalized session controls and Codex runtime support reads. The client should not guess control availability from provider names, turn counts, or local UI state when the server already exposes an explicit runtime-support contract.

Do not build a parallel client-side state machine out of websocket payloads.

### Global surfaces must stay cheap

Dashboard, library, missions, and notification-driving attention state are not allowed to become one giant in-memory product blob.

That means:

- do not eagerly load library or archive pages just to keep dashboard fresh
- do not derive global notification state from heavyweight session arrays if a smaller sessions-summary surface can own it
- do not let runtime registries become cross-surface product stores
- do not hold duplicate large snapshots when a compact projection is enough

## What The Native App Should Not Do

Do not add:

- shared mutable session objects
- placeholder production session contexts like `ServerSessionContext.preview()` as real runtime ownership
- broad per-session refresh loops for unrelated surfaces
- giant scene roots that own routing, composition, dependency lookup, and feature logic all at once
- `AnyView` in core composition paths
- async work primarily driven by `.onAppear`
- feature services whose main job is mutating a shared observable blob

## Recommended File Shape

For non-trivial SwiftUI features:

- scene shell file: composition and lifecycle wiring only
- feature view model file: one surface, one snapshot model
- section/chrome files: visual decomposition
- planner/mapper files: pure shaping logic
- service files: transport or platform integration

If a file starts collecting unrelated views, models, stores, networking code, and helpers, split it.

## Part 2: Server Architecture

The Rust server owns all durable session state. Every mutation follows one path:

1. validate
2. transition
3. persist
4. broadcast

The database is always the source of truth.

## The Transition System

All session state mutations flow through a pure transition function:

```rust
fn transition(state: TransitionState, input: Input, now: DateTime) -> (TransitionState, Vec<Effect>)
```

This function is pure and synchronous.

It decides:

- the next state
- what to persist
- what to broadcast

Effects are executed by the session actor after the transition completes.

## Session Actor Model

Each session gets its own actor task.

That gives us:

- no lock-based mutation races
- sequential command handling
- lock-free snapshot reads through `ArcSwap<SessionSnapshot>`

Connectors and handlers must not mutate session state directly. They feed inputs into the actor, and the actor runs the transition.

### Compile-Time Mutation Fence

In-memory session state is allowed only as an actor-owned projection of durable server truth.

That projection has one write boundary:

- `SessionCoreState` fields stay private
- runtime, HTTP, WebSocket, connector, and native-facing code cannot assign session fields directly
- non-durable affordances are derived while building snapshots or deltas, not stored as parallel mutable truth
- transport code must never "repair" business state before sending it
- mutable infrastructure caches and registries are allowed only for resource ownership, never as alternate business truth

If a future change needs to mutate session memory, it should fail to compile until the mutation is expressed as an actor command or domain transition. That compiler failure is intentional. It is the guardrail that keeps OrbitDock from drifting back into random in-memory state patches.

## Server Rule

Every durable session mutation must go through the transition system.

Do not bypass it for:

- simple field updates
- convenience broadcasts
- approval flow shortcuts
- connector-specific mutations

If a mutation needs to exist, it needs:

- an input variant
- transition logic
- persist effects
- broadcast effects

## Server Anti-Patterns

Do not reintroduce:

- fire-and-forget in-memory mutations
- split persist and broadcast paths
- connector-owned direct state mutation
- caller-side duplicate persistence after a handler already owns the update
- transport-layer state normalization
- duplicated mutable affordance flags that can drift from the primary state

## Part 3: Cross-Layer Guardrails

### Typed boundaries

Keep the Swift side strongly typed to match server contracts.

- avoid schema-free payload bags where a real type exists
- keep protocol boundaries explicit
- keep forward-compatible decoding resilient

### SQLite ownership

Only the Rust server reads and writes SQLite directly.

The app and CLI should go through server APIs.

### Endpoint scoping

All client state must be scoped by endpoint plus session identity.

Always guard async callbacks against stale binding context before applying results.

### Runtime versus product truth

Connector runtime is operational plumbing.

It may help the server produce product truth, but it is not product truth by itself. The client should not treat runtime artifacts as durable UI authority.

## Practical Summary

If you're touching the Swift app:

- start from the owning scene
- keep dependencies stable before mounting children
- give each feature one owner and one contract
- use HTTP for authority and WS for follow-up
- keep `ServerSessionContext` narrow
- keep `ServerSessionAPI` and `ServerSessionTransport` narrow
- write SwiftUI the native way, not the web-app way

If you're touching the server:

- put durable state changes through the transition system
- persist and broadcast together
- keep the database authoritative

For transport details, read [data-flow.md](data-flow.md).
