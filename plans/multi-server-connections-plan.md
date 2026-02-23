# OrbitDock Multi-Server Connections Plan (macOS + iOS)

> Goal: Let OrbitDock connect to multiple `orbitdock-server` instances at the same time, with a clean architecture that supports merged session views and endpoint-scoped actions.
>
> This plan is organized into completable phases. Each phase is intentionally scoped so a developer or an LLM can finish it end-to-end and leave the app in a working state.

## Why This Exists

OrbitDock can connect to one server today. That works for local + remote switching, but it breaks down when you want to monitor multiple hosts in parallel.

The core blockers are identity and ownership:
- connection is singleton-based
- app state is singleton-based
- session identity is `sessionId` only (no server dimension)
- action routing assumes one active transport

This plan introduces endpoint-scoped runtime objects and composite session identity so multi-server behavior is explicit, safe, and testable.

---

## Success Criteria

- OrbitDock can maintain active WebSocket connections to multiple servers at once.
- Session list can merge sessions across servers without ID collisions.
- Every session action routes to the correct server deterministically.
- macOS and iOS both support multi-server runtime behavior.
- Existing single-server behavior still works with one configured endpoint.

---

## Guardrails

- No destructive migration of user config. Old endpoint settings must auto-migrate.
- No global callback overwrite patterns for endpoint-specific requests.
- No session action should execute without endpoint context.
- MCP bridge behavior must be explicit (active endpoint only, or endpoint parameterized).

---

## How To Execute Each Phase

For each phase:
- implement only that phase scope
- run phase-targeted tests
- ship as one PR
- do not start the next phase until “Done When” is true

This keeps progress chunked and reviewable, whether the implementer is a developer or an LLM.

---

## Phase 1: Endpoint Model + Config Migration

### Objective

Replace single remote host config with a durable endpoint list model.

### Tasks

- Add a `ServerEndpoint` model with `id`, `name`, `wsURL`, `isLocalManaged`, `isEnabled`, and `isDefault`.
- Add endpoint store + persistence layer (`UserDefaults` first; no DB migration required).
- Add migration path from `ServerEndpointSettings.remoteHost` into endpoint list.
- Seed default local endpoint (`ws://127.0.0.1:4000/ws`) when no config exists.
- Keep read compatibility for old keys during migration window.

### Done When

- App boots with migrated endpoints from existing installs.
- New installs get one default local endpoint.
- Endpoint CRUD works in isolation (unit tests pass).

### Output Artifacts

- `ServerEndpoint` model
- endpoint persistence service
- migration tests for legacy `remoteHost`

---

## Phase 2: Endpoint-Scoped Runtime (Connection + App State)

### Objective

Replace global singleton runtime with endpoint-scoped runtime objects.

### Tasks

- Introduce `ServerRuntime` (connection + app state per endpoint).
- Introduce `ServerRuntimeRegistry` to manage all active runtimes.
- Refactor `ServerConnection` to non-singleton instances bound to one endpoint.
- Refactor `ServerAppState` to be endpoint-scoped and injected by runtime.
- Add endpoint lifecycle methods: `start`, `stop`, `reconnect`, and optional `suspendInactive`.
- Keep one compatibility adapter for legacy call sites during migration.

### Done When

- Two runtimes can be started concurrently in tests.
- Disconnect/reconnect is isolated per endpoint.
- No shared mutable callback state across runtimes.

### Output Artifacts

- `ServerRuntime`
- `ServerRuntimeRegistry`
- endpoint-scoped connection tests

---

## Phase 3: Composite Session Identity + Routing

### Objective

Make session identity globally unique by adding endpoint dimension everywhere.

### Tasks

- Add `SessionRef` (or equivalent) with `endpointId` + `sessionId`.
- Extend `Session` model with endpoint metadata (endpoint id, endpoint display name, optional server badge metadata).
- Replace all session lookups keyed by `sessionId` with endpoint-aware lookups.
- Update action APIs to require endpoint context for send message, approve/answer, interrupt/end/resume/takeover, review comments, MCP, and skills.
- Update notification payloads/deep links to carry endpoint id.

### Done When

- Session collisions across servers are impossible in memory.
- Every action has endpoint context at compile time.
- Existing flows still work for single endpoint.

### Output Artifacts

- `SessionRef` type + adapters
- endpoint-aware action interfaces
- routing regression tests

---

## Phase 4: Transport API Cleanup (Request-Scoped Responses)

### Objective

Remove callback overwrite hazards and make request/response handling safe with many endpoints.

### Tasks

- Replace mutable callback setters for request-style APIs with request-scoped async APIs.
- Cover high-risk request APIs first: recent projects listing, directory browsing, and OpenAI key status checks.
- Add per-request correlation IDs where needed.
- Ensure endpoint + request correlation is mandatory at the transport layer.
- Keep stream/event subscriptions separate from request-response APIs.

### Done When

- Concurrent requests to different endpoints can run without cross-talk.
- No features depend on mutating shared callback slots at runtime.

### Output Artifacts

- request/response transport wrappers
- concurrency tests for parallel endpoint requests

---

## Phase 5: Unified Session Aggregation Layer

### Objective

Add one merge layer that turns N endpoint states into one UI-friendly store.

### Tasks

- Implement `UnifiedSessionsStore` (read-only projection over all runtimes).
- Normalize sort/filter/grouping across endpoints.
- Add endpoint-level health summary (connected, connecting, failed, disconnected).
- Add server-aware derived data for attention counts, working counts, ready counts, and activity ordering.
- Expose selected endpoint filters (`all` + per-endpoint).

### Done When

- Dashboard can render sessions from 2+ endpoints.
- Filters and sorting are deterministic with mixed endpoint data.
- No direct view code reaches into per-endpoint runtime internals.

### Output Artifacts

- `UnifiedSessionsStore`
- aggregation tests

---

## Phase 6: macOS UI Integration

### Objective

Ship multi-server UX on macOS with safe defaults and minimal friction.

### Tasks

- Add endpoint management UI in Settings: list endpoints, add/edit/remove endpoint, enable/disable endpoint, optional default endpoint for new sessions.
- Update command strip and status surfaces to show multi-endpoint health.
- Add endpoint badges in dashboard rows, quick switcher, and session detail header.
- Update session selection/navigation to use `SessionRef` instead of bare `sessionId`.
- Update MCP bridge UI copy to reflect endpoint behavior.

### Done When

- macOS can manage endpoints and show merged sessions clearly.
- Selecting and controlling sessions always targets the right endpoint.
- No ambiguous UI when duplicate `sessionId` exists across servers.

### Output Artifacts

- endpoint management views
- `SessionRef`-based selection flow
- macOS interaction tests

---

## Phase 7: iOS UI Integration

### Objective

Bring iOS to the same runtime and routing model as macOS.

### Tasks

- Update iOS shell to use unified multi-endpoint session store.
- Add endpoint picker/filter UX suitable for compact layouts.
- Update conversation and approval flows to use endpoint-aware session refs.
- Ensure low-memory behavior trims inactive payloads per endpoint runtime.
- Keep iOS ergonomics tight: minimal chrome, fast switching, clear connection state.

### Done When

- iOS can display and operate sessions from multiple endpoints.
- Approval/question actions are correctly routed across endpoints.
- Memory pressure handling remains stable.

### Output Artifacts

- iOS endpoint-aware views
- iOS routing and memory regression tests

---

## Phase 8: Notifications, Toasts, Deep Links

### Objective

Make alerts and deep links endpoint-safe.

### Tasks

- Extend notification payloads with endpoint id.
- Extend toast model identity from `sessionId` to `SessionRef`.
- Update dedupe keys to include endpoint id.
- Update `.selectSession` notifications (or replace with typed router event) to include endpoint id.
- Validate launch-from-notification routes to the correct runtime/session.

### Done When

- Alerts from same session id on different servers do not collide.
- Notification taps always open the correct session on the correct endpoint.

### Output Artifacts

- endpoint-aware notification router
- notification/toast regression tests

---

## Phase 9: MCP Bridge + External Control Behavior

### Objective

Define and implement explicit bridge behavior in a multi-endpoint world.

### Tasks

- Choose one bridge contract: active endpoint only, endpoint parameter required, or endpoint inferred from session ref.
- Update bridge routes and responses to include endpoint id where needed.
- Ensure bridge session lookups are endpoint-aware.
- Update bridge docs and examples.

### Done When

- Bridge can safely control sessions without endpoint ambiguity.
- Bridge behavior is documented and test-covered.

### Output Artifacts

- bridge routing updates
- bridge integration tests
- updated docs

---

## Phase 10: Cleanup + Hardening

### Objective

Remove compatibility shims and lock in the new architecture.

### Tasks

- Remove old singleton-only code paths.
- Remove deprecated endpoint settings keys after migration stabilization.
- Add invariants/assertions that actions require endpoint context and session refs are always normalized.
- Add end-to-end scenarios for duplicate session ids across endpoints, endpoint disconnect while selected, and endpoint reconnect with pending approvals.
- Update architecture docs in `README.md` and `CLAUDE.md`.

### Done When

- No legacy single-server-only routing remains.
- Multi-endpoint behavior is the default architecture, not a bolt-on.
- Docs match implementation.

### Output Artifacts

- simplified runtime codebase
- full regression suite updates
- documentation updates

---

## Suggested Implementation Order (Strict)

1. Phase 1
2. Phase 2
3. Phase 3
4. Phase 4
5. Phase 5
6. Phase 6 and Phase 7 (parallel after Phase 5)
7. Phase 8
8. Phase 9
9. Phase 10

---

## Definition of Complete

- Multi-server is fully supported on macOS and iOS.
- Session identity and action routing are endpoint-safe across the app.
- External control surfaces (notifications, MCP bridge, deep links) are endpoint-aware.
- The single-server path remains solid through endpoint defaults, not special-case runtime logic.
