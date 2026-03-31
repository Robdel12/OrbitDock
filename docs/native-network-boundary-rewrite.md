# Native Client Network Boundary Rewrite

The native client networking layer is doing too much in too many places.

Right now the same connection lifecycle is split across `ServerConnection`, `ServerRuntimeRegistry`, `SessionStore`, and a pile of UI-triggered tasks. That makes crashes and reconnect bugs feel random, even when the underlying problem is deterministic.

This rewrite is about one thing: giving the app a real transport boundary.

## What Is Wrong Today

- WebSocket transport, HTTP gating, reconnect policy, and handshake state are mixed together.
- Dashboard bootstrap is being treated like global readiness for unrelated screens.
- Session recovery is broader than the surfaces the UI actually renders.
- Transport work and snapshot apply work spend too much time on the main actor.
- `SessionObservable` carries too much state, so tiny server events can invalidate large parts of the app.

The result is familiar:

- a socket can look "connected" before the protocol handshake is actually complete
- settings and control-plane screens depend on app-wide runtime state that should be irrelevant to them
- reconnect logic duplicates state and generations across multiple objects
- UI presentation can trigger networking churn that should have been isolated behind a transport boundary

## Target Shape

We want five layers with clear ownership:

1. `EndpointTransport` actor
   Owns raw HTTP, WebSocket lifecycle, pings, receive loops, and task cancellation.
2. `ServerConnection`
   Thin `@MainActor` facade that translates transport events into typed app events and public connection state.
3. Surface coordinators
   Dashboard, missions, session detail, composer, and conversation each own bootstrap revision, subscription, and resync.
4. Stores
   Session and dashboard stores hold normalized server state, not transport machinery.
5. Views
   Views render store state. They should not decide transport readiness or lifecycle.

## Rules For The New Boundary

- HTTP is allowed to answer health, metadata, and settings requests even when dashboard bootstrap is not ready.
- WebSocket is not "connected" until the `hello` handshake is accepted.
- Each surface owns its own `snapshot -> revision -> subscribe -> replay -> refetch` flow.
- Transport actors do transport work. Main-actor stores do apply work.
- UI presentation should never be able to crash the socket by touching shared transport state directly.

## Migration Plan

### Phase 1: Introduce The Transport Actor

This is the first hardening slice.

- Add `EndpointTransport` as the only owner of `URLSession`, `URLSessionWebSocketTask`, receive loops, keepalive pings, and raw HTTP execution.
- Keep the `ServerConnection` public API stable so the rest of the app can keep compiling.
- Stop using "ping succeeded" as the definition of a successful connection.
- Require the `hello` frame to complete the handshake before the facade marks the endpoint as connected.
- Add a handshake timeout so a socket cannot sit in `connecting` forever.

This phase does not solve every higher-level problem, but it gives us a sane foundation.

## Keep Vs Replace

This rewrite should not start from zero.

### Keep

- `EndpointTransport`
  - raw HTTP execution
  - WebSocket lifecycle
  - ping / keepalive / receive loop
  - connection task cancellation
- typed REST clients in `ServerClients`
- protocol models and version handshake rules
- HTTP bootstrap endpoints that already match the server contract

### Replace

- HTTP execution being gated by `ServerConnection`
- endpoint readiness derived from dashboard bootstrap
- registry-level logic that treats dashboard as global truth
- reconnect behavior that resubscribes broad shared state by default
- session recovery that always subscribes `detail`, `composer`, and `conversation`
- UI loading logic that asks raw connection objects whether dashboard bootstrap happened

## Scoped Deliverable

This project is done when the native client has a hardened transport boundary that matches the server contract without requiring a full client state rewrite.

That means:

1. HTTP works independently of dashboard bootstrap and does not require an already-live dashboard socket.
2. WebSocket is used for handshake, subscriptions, replay, heartbeats, and realtime deltas only.
3. Readiness is surface-aware instead of "dashboard loaded means the endpoint is ready for everything."
4. Session recovery subscribes only the surfaces a screen actually renders.
5. The new boundary is covered by focused tests that make regressions obvious.

## Non-Goals

These are important, but they are not required to call this rewrite complete:

- fully splitting `SessionObservable` into multiple smaller stores
- redesigning SwiftUI screens
- changing the server API contract
- removing every last piece of registry aggregation logic
- reworking timeline rendering or scrolling behavior

### Phase 2: Decouple HTTP From WS Readiness

- Remove the `ServerConnection.execute` gate that throws when WS is not connected.
- Let `ServerClients` treat HTTP transport reachability independently from dashboard bootstrap.
- Keep WebSocket as the liveness gate for replay and subscriptions, not for health, settings, updates, or HTTP bootstrap reads.
- Ensure settings and control-plane flows can succeed even when dashboard bootstrap has not happened yet.

Done for this phase means:

- settings and health requests do not depend on dashboard snapshot state
- runtime startup no longer has to "be connected enough" before HTTP can answer
- the transport actor remains the only owner of raw socket and HTTP mechanics

### Phase 3: Split Readiness By Surface

- Replace `queryReady` as a single dashboard-derived bit with surface-oriented readiness.
- Track endpoint readiness separately for:
  - transport
  - control-plane HTTP
  - dashboard
  - missions
- Stop using `hasReceivedInitialDashboardSnapshot` as the global readiness source for unrelated features.
- Move dashboard loading indicators to dashboard-specific state instead of raw connection state.

Done for this phase means:

- dashboard loading only describes dashboard state
- control-plane and settings logic do not wait for dashboard readiness
- endpoint connection state is not downgraded just because a different surface still needs bootstrap

### Phase 4: Scope Session Recovery To Rendered Surfaces

- Introduce explicit session surface subscriptions at the session-store boundary.
- Subscribe only the surfaces a screen actually renders:
  - detail + composer + conversation for full session detail screens
  - composer for composer-only surfaces
  - conversation only when history is actually shown
- Keep HTTP bootstrap as the single authoritative session read.
- On replay gaps, refetch the matching HTTP surface instead of rebuilding unrelated state.

Done for this phase means:

- opening a session no longer automatically fans out all three session surface subscriptions
- reconnect only restores active surfaces
- settings and other control-plane views do not churn session transport state

### Phase 5: Add Confidence Tests

The highest-value tests for this rewrite are:

- handshake must see `hello` before connection becomes ready
- disconnected websocket does not block HTTP-only health and settings reads
- reconnect replays only active surfaces
- opening settings or endpoint management does not crash or mutate unrelated session transport state
- transport disconnects do not create duplicate reconnect loops

Done for this phase means:

- we have regression coverage for the new boundary
- the test names describe user-visible transport behavior, not implementation details

## Clear Done State

We should call this rewrite complete when all of these are true:

- `EndpointTransport` is the only raw transport owner
- `ServerConnection` no longer decides whether HTTP is allowed
- dashboard bootstrap is no longer the global source of endpoint readiness
- dashboard and mission bootstrap are treated as surface-specific state
- session recovery subscribes only requested surfaces
- opening settings, health, or server management does not depend on dashboard bootstrap
- the targeted networking tests pass on macOS

If we reach that point, the client is no longer fundamentally websocket-first.
It may still have follow-up cleanup work, but the transport boundary will be correct and durable.

## After This Rewrite

Once this lands, the most likely follow-up work is state-shape cleanup rather than transport cleanup.

That follow-up work probably includes:

- splitting `SessionObservable` into smaller domain-focused state objects
- reducing registry aggregation responsibilities further
- narrowing event fanout so fewer unrelated views invalidate together
- simplifying dashboard and session presentation models

Those are worth doing, but they are no longer blockers for reliable endpoint connectivity.
This rewrite is specifically about making server connection and recovery reliable first.

## Immediate Success Criteria

The first slice is a win if it gives us these properties:

- one actor owns raw transport state
- one facade owns app-facing connection state
- handshake readiness is no longer inferred from ping
- low-level socket task races stop living on the main actor

That is the line between "we moved code around" and "we actually hardened the boundary."
