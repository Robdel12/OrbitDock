# Client Networking Architecture

This is the client-side networking contract for OrbitDock after the session-contract rewrite.

Companion to [`data-flow.md`](data-flow.md), which describes the shared HTTP/WS data model.

## Principles

1. WebSocket is the liveness gate.
   If WS is not connected, the client does not treat the endpoint as query-ready.
2. HTTP owns initial and heavy reads.
   Dashboard, session bootstrap, and pagination start from HTTP.
3. WebSocket owns realtime updates and replay.
   The client subscribes only after it already has a snapshot revision.
4. One endpoint, one runtime.
   `ServerRuntime` owns the shared connection, typed clients, and `SessionStore`.
5. Surface state is explicit.
   Dashboard, detail, composer, and conversation are loaded and updated independently.

## Endpoint Lifecycle

`ServerRuntime` owns both transport sides for one endpoint:

- `ServerConnection`
  - WebSocket lifecycle
  - request execution gate for HTTP
  - event fanout to stores
- `ServerClients`
  - typed REST clients
- `SessionStore`
  - per-session observables
  - approvals, conversation history, and realtime event routing

## Readiness Model

An endpoint is only query-ready when:

1. the WebSocket is connected
2. the connection handshake has completed
3. the client has loaded the required bootstrap surface for the workflow it is entering

This matters because “server reachable” is not enough. A healthy socket without a loaded dashboard snapshot should not be treated as a fully bootstrapped client state.

The handshake itself is part of readiness. The first WebSocket frame must be `hello`. The client should treat connection and bootstrap failures as normal transport errors instead of trying to infer a protocol-version mismatch from them.

## Dashboard Flow

Dashboard must use one bootstrap owner.

### Current boot sequence

1. WebSocket connects.
2. `ServerRuntimeRegistry` fetches `GET /api/dashboard`.
3. The snapshot is applied to `DashboardProjectionStore`.
4. The client subscribes to dashboard WS updates with `since_revision = snapshot.revision`.

The important rule is: we do not simultaneously bootstrap dashboard from both REST and an eager WS snapshot path.

Some websocket handlers still emit snapshot-shaped reconciliation payloads on reconnect or lifecycle changes. The client should treat those as server-authored corrections, not as permission to reintroduce a parallel bootstrap path.

### Dashboard ownership

- `DashboardProjectionStore` is the single app-facing dashboard projection.
- `AppStore`, Mission Control, and root-window notification flow should read from that projection.
- Registry-level aggregate arrays are implementation detail and should not be used as separate UI truth.

## Session Surface Flow

The client should subscribe only to the surfaces it actually renders.

### Detail screens

Load:

1. HTTP session bootstrap

Then subscribe:

1. detail surface replay/deltas
2. conversation surface replay/deltas

### Composer screens

Load:

1. HTTP session bootstrap

Then subscribe:

1. composer surface replay/deltas

Only add conversation bootstrap/subscription if that composer surface also renders history.

### Session bootstrap

For native session screens, bootstrap with one HTTP read:

1. `GET /api/sessions/{id}/conversation?limit=...`
2. Apply the returned `session` to detail and composer state.
3. Apply the returned rows to conversation state.
4. Subscribe to the surfaces the screen renders using `since_revision = session.revision`.

We do not fan this out into separate detail and composer HTTP reads. They carry the same `SessionState`, so the extra round-trips only add latency and duplicate decode/apply work.

### Unsubscribe

When a session view goes away, the client must explicitly unsubscribe every active surface:

- `detail`
- `composer`
- `conversation`

## SessionStore Responsibilities

`SessionStore` should be the transport coordinator and normalized server-state holder, not a catch-all presentation cache.

Good responsibilities:

- hold `SessionObservable`
- apply HTTP snapshots
- apply WS deltas
- manage in-flight bootstrap/recovery tasks
- manage approval history and conversation pagination

Bad responsibilities:

- duplicating server state into multiple cached presentation observables
- inventing control semantics from local heuristics
- rebuilding whole render trees for every tiny event

## Mutation Handling

The client treats mutation responses as authoritative state.

Example for send:

1. `POST /api/sessions/{id}/messages`
2. if success, apply returned row immediately
3. later WS events reconcile any additional changes

If the mutation fails:

- keep the draft
- show the error
- do not invent a successful local state and wait for WS to disagree

## Reconnect Behavior

Reconnect should be surface-local and revision-aware.

For each active surface:

1. keep the last accepted revision
2. reconnect WS
3. resubscribe with `since_revision`
4. if replay succeeds, apply missing events
5. if replay cannot satisfy the gap, refetch the matching HTTP snapshot

The client should not recover by rebuilding unrelated surfaces or by depending on a full catch-all session snapshot.

## Error Handling Rules

- HTTP auth/bootstrap failures are real endpoint failures and should be surfaced as such.
- A JSON decode failure from an API route is not a “maybe empty” state.
- `connector_unavailable` is distinct from `not_found`.
- Transport errors should not be silently swallowed if they prevent the client from loading a required surface.

## Testing Expectations

The highest-value client networking tests are:

- dashboard boot uses HTTP snapshot first, then WS replay
- session reconnect resubscribes all active surfaces
- successful mutations apply their HTTP response immediately
- failed sends do not create local ghost rows
- unrelated surface updates do not rebuild whole presentation state
