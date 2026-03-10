# Swift Client Architecture

This is the durable guardrails doc for the Swift client. Use it when you're deciding where code belongs, who owns state, and how parts of the app are allowed to talk to each other.

## The Shape Of The Client

The Swift client is a thin, endpoint-aware UI over a server-authoritative system.

- `Views/` renders state and sends user intent upward. Views should stay dumb about transport details and cross-session coordination.
- `Navigation/` owns navigation state. `AppRouter` is the app's navigation control plane.
- `Services/Server/` owns endpoint runtimes, transport clients, session lists, per-session stores, and event routing.
- `Models/` holds app-facing domain types and view data.
- `Platform/` holds OS-specific glue.

The client should not invent business state that the server already owns. If a workflow needs durable session truth, add it to the server contract and render it here.

## State Ownership Rules

- `ServerRuntimeRegistry` owns the set of configured endpoints, the active endpoint, and runtime lifecycle.
- Each `ServerRuntime` owns one endpoint-scoped `SessionStore`.
- `SessionStore` owns endpoint-scoped collections, request orchestration, and event routing for that endpoint.
- `SessionObservable` owns view-facing state for one session only.
- `ConversationStore` owns conversation loading, caching, and message reconciliation for one session only.
- `AppRouter` owns app navigation state, not server data.
- Views may keep local presentation state, but not shared app state or server truth.

If state must survive view redraws, be shared across screens, or stay consistent across events, it belongs in a store or router, not in a view.

## Layer Boundaries

- Views call store and router APIs. They do not coordinate other views directly.
- Stores talk to transport (`ServerClients`, `EventStream`, focused capability clients) and translate server events into observable client state.
- Navigation does not fetch or mutate server data.
- Models stay transport-friendly and UI-friendly. Keep side effects out of them.
- Platform code adapts OS behavior into the app. It should not become a second app-state system.

Prefer explicit method calls or shared observable state over ad hoc event fan-out.

## Preferred Client Pattern

The client architecture should feel like SwiftUI at the edges and functional design in the middle.

- Use views as renderers plus small amounts of ephemeral UI state.
- Use `@Observable` stores, coordinators, and routers as the mutable ownership boundary for shared app state.
- Use actors for async coordination, serialized side effects, and long-lived runtime processes.
- Use pure structs and functions for planners, reducers, projections, selectors, and layout math.

That gives us a practical shape:

- **functional core** for decisions and state transforms
- **observable shell** for app state SwiftUI needs to mutate
- **actor/service boundary** for network, disk, and async orchestration

If a new rule can be expressed as a pure function, prefer that. If a new feature needs shared mutable state, give it one obvious owner instead of mirroring it across views.

## Where New Code Goes

- Add endpoint/server transport, runtime, and session orchestration under `OrbitDockNative/OrbitDock/Services/Server/`.
- Add provider-specific client behavior under `OrbitDockNative/OrbitDock/Services/Codex/` or another focused service area.
- Add reusable app models under `OrbitDockNative/OrbitDock/Models/`.
- Add navigation state or routing rules under `OrbitDockNative/OrbitDock/Navigation/`.
- Add OS-specific adapters under `OrbitDockNative/OrbitDock/Platform/`.
- Add UI under the matching feature area in `OrbitDockNative/OrbitDock/Views/`.

If you're adding a new feature, default to this split: model or protocol type first, store logic second, view last.

## Coordination Rule

`NotificationCenter` is for OS and cross-system integration only. Good uses include app lifecycle notifications, memory pressure, user notifications, menu bar entry points, and other external system bridges.

Do not use `NotificationCenter` as a general app coordination bus between SwiftUI views, stores, or feature modules. For app-internal coordination, use one of these:

- shared `@Observable` state owned by the right store or router
- explicit method calls across well-defined boundaries
- environment-injected dependencies with clear ownership

If a new flow needs `NotificationCenter` just so two client-owned components can find each other, the ownership is probably wrong.

## Practical Defaults

- Keep state endpoint-scoped unless it is truly global.
- Keep session state session-scoped. Do not let one session infer another session's truth.
- Prefer REST for client-initiated actions and WebSocket for server-pushed updates, matching the existing transport split.
- When the client needs new truth, change the server contract instead of deriving it locally from history.
- Keep the logic functional where SwiftUI does not need mutability: planners, reducers, projections, selectors, and layout math should prefer pure structs and functions.
- Keep mutation at explicit boundaries: `@Observable` stores for shared client state, actors for async coordination, and typed clients for network side effects.
