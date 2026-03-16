# Client Networking Architecture

Authoritative spec for the OrbitDock client networking layer. Covers connection lifecycle, readiness gating, circuit breaker, and HTTP request policy.

Companion to [`data-flow.md`](data-flow.md) which covers server-side data shapes and WebSocket protocol.

---

## 1. Principles

| ID | Rule |
|----|------|
| P1 | **WS is the liveness probe** — no HTTP without WS `.connected` |
| P2 | **Single URLSession per endpoint** — shared between WS + HTTP |
| P3 | **Readiness gates everything** — `ServerRuntimeReadiness.queryReady` |
| P4 | **No fire-and-forget into the void** — every HTTP callsite checks readiness or awaits it |
| P5 | **Fail together, recover together** — WS down = HTTP stops |
| P6 | **Backoff is mandatory** — circuit breaker after N consecutive failures |

---

## 2. Connection Lifecycle

Ordered phases from cold boot to steady state:

```
Boot
 │
 ▼
WS Connect ── ping ack ──► Connected
 │                            │
 │                            ▼
 │                     subscribeList()
 │                            │
 │                            ▼
 │                     Sessions List arrives
 │                            │
 │                            ▼
 │                      queryReady = true
 │                            │
 │                            ▼
 │                      HTTP requests allowed
 │                            │
 │                      ┌─────┴──────┐
 │                      │ Steady     │
 │                      │ State      │
 │                      └─────┬──────┘
 │                            │
 │                      disconnect / error
 │                            │
 │                            ▼
 │                    Circuit Breaker
 │                    evaluates attempt
 │                            │
 │               ┌────────────┴────────────┐
 │               │ allowed                 │ blocked
 │               ▼                         ▼
 │          Reconnect                 Wait cooldown
 │          (back to WS Connect)     then halfOpen probe
 │
 ▼
Failed (breaker open) ── user reconnect ──► Reset breaker, WS Connect
```

### Phase Details

1. **Boot** — `ServerRuntime.start()` creates shared `URLSession`, passes to `EventStream` + `HTTPTransport`
2. **WS Connect** — `EventStream.connect(to:)` opens WebSocket task, sends ping
3. **Connected** — Ping ACK received, status = `.connected`, `subscribeList()` fires
4. **Sessions List** — Server sends `sessionsList` event, `hasReceivedInitialSessionsList = true`
5. **Query Ready** — `ServerRuntimeReadiness.derive()` → `queryReady = true`, HTTP requests unblocked
6. **Steady State** — Keep-alive pings every 30s, HTTP requests flow, subscriptions active
7. **Reconnect** — On disconnect, circuit breaker checks, exponential backoff if allowed
8. **Failed** — Circuit breaker open, no connection attempts until cooldown expires

---

## 3. Readiness Model

`ServerRuntimeReadiness.derive()` computes three flags:

| Flag | Condition | Meaning |
|------|-----------|---------|
| `transportReady` | WS `.connected` | Socket is alive |
| `controlPlaneReady` | `transportReady` + initial sessions list received | Server handshake complete |
| `queryReady` | `controlPlaneReady` | Safe to make HTTP requests |

### Enforcement Patterns

**Synchronous check (stores):**
```swift
func refreshAll() async {
  guard let runtime = resolvedRuntime(),
        runtimeRegistry.runtimeReadiness(for: runtime.endpoint.id).queryReady
  else { return }
  // ... HTTP calls
}
```

**Async await (view `.task {}`):**
```swift
.task {
  await runtimeRegistry.waitForAnyQueryReadyRuntime()
  await registry.refreshAll()
}
```

---

## 4. Circuit Breaker

Replaces the old `connectAttempts` / `maxConnectAttempts` counters with a proper state machine.

### States

```
closed ──failure──► open(until: Date)
  ▲                      │
  │                  cooldown expires
  │                      │
  │                      ▼
  └──success──── halfOpen
```

| State | Behavior |
|-------|----------|
| `closed` | All connection attempts allowed |
| `open(until:)` | Blocked until cooldown expires, then transitions to `halfOpen` |
| `halfOpen` | One probe attempt allowed; success → `closed`, failure → `open` with longer cooldown |

### Parameters

| Param | Local | Remote |
|-------|-------|--------|
| `failureThreshold` | 3 | 3 |
| `initialCooldown` | 5s | 10s |
| `maxCooldown` | 60s | 120s |
| `multiplier` | 2x | 2x |

### Reset Conditions

- **Stable connection**: Connected for 30s continuously → `recordSuccess()` → `closed`
- **User reconnect**: Explicit action → `reset()` → `closed`

### Owner

`ConnectionCircuitBreaker` is owned by `EventStream`. Created during init with params based on `isRemote`.

---

## 5. Session Subscription Flow

### Subscribe

1. HTTP bootstrap: `GET /api/sessions/{id}` fetches full state
2. WS: `subscribeSession(sinceRevision:)` for live deltas
3. `inFlightBootstraps` dict coalesces concurrent requests for same session

### Unsubscribe

1. Cancel in-flight bootstrap task
2. WS: `unsubscribeSession`
3. Trim stored payload

### Reconnect

1. Cancel all existing subscription tasks
2. REST: `GET /api/sessions` refreshes session list
3. Sequential re-bootstrap for active subscriptions

---

## 6. HTTP Request Policy

| Category | Examples | Gate |
|----------|----------|------|
| **Gated** | Usage refresh, session bootstrap, sessions list | Check `queryReady` before firing |
| **User-initiated** | Send message, approve tool, answer question | Fire immediately via WS, surface errors |

**Gated requests** silently skip if `queryReady` is false. They will naturally fire once readiness arrives (via `.task {}` + `waitForAnyQueryReadyRuntime()`).

**User-initiated requests** go through WebSocket, which is only active when connected. No additional gate needed — WS `send()` already guards on `webSocket != nil`.

---

## 7. Shared URLSession

One `URLSession` per endpoint, created in `ServerRuntime.init`:

```swift
private static func makeSharedSession() -> URLSession {
  let config = URLSessionConfiguration.default
  config.timeoutIntervalForRequest = 10
  config.timeoutIntervalForResource = 60
  config.requestCachePolicy = .reloadIgnoringLocalCacheData
  config.urlCache = nil
  return URLSession(configuration: config)
}
```

Passed to both:
- `EventStream(authToken:urlSession:)` — for WebSocket tasks
- `ServerClients(serverURL:authToken:urlSession:)` → `HTTPTransport(urlSession:)` — for HTTP data tasks

This eliminates the previous pattern where `EventStream` and `HTTPTransport` each created independent sessions, doubling the connection pool.

---

## 8. Scale Path

### 100+ agents scenario

- **WS** delivers hints (session deltas, status changes) — lightweight
- **REST** handles data fetches (bootstrap, usage) — gated by readiness
- **Readiness gating** prevents HTTP flood when server is unreachable
- **Circuit breaker** caps socket errors at ~3 per endpoint

### Subscription tiering (future)

- **Visible sessions**: Full fidelity — conversation rows, token updates, diffs
- **Background sessions**: State-only — status changes, approval requests

---

## Key Files

| File | Role |
|------|------|
| `Services/Server/ServerRuntime.swift` | Creates shared URLSession, owns lifecycle |
| `Services/Server/EventStream.swift` | WS connection, circuit breaker integration |
| `Services/Server/ConnectionCircuitBreaker.swift` | Circuit breaker state machine |
| `Services/Server/API/HTTPTransport.swift` | Accepts shared URLSession |
| `Services/Server/API/ServerClients.swift` | Threads URLSession to transport |
| `Services/Server/ServerRuntimeReadiness.swift` | Readiness derivation |
| `Services/Server/NetworkFileLogger.swift` | `.circuit` log category |
| `Services/UsageServiceRegistry.swift` | Readiness-gated HTTP example |
