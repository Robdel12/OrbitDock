# OrbitDock Tailscale Remote MVP Roadmap

> Goal: Connect OrbitDock macOS to remote `orbitdock-server` instances over a private Tailscale network, with a tight MVP we can test quickly from real-world networks (including phone hotspot).
>
> This plan intentionally avoids iOS/iPad targets for now. We focus on reliable remote connectivity first.

## Why this plan

Current state is local-only by design:

- **Server binds localhost only**: `orbitdock-server/crates/server/src/main.rs:483` hardcodes `127.0.0.1:4000`
- **Client URL is hardcoded**: `CommandCenter/CommandCenter/Services/Server/ServerConnection.swift:37` points at `ws://127.0.0.1:4000/ws`
- **App assumes one embedded server**: `CommandCenterApp.swift` starts `ServerManager.shared` on launch, waits for health check, then connects the singleton `ServerConnection.shared`
- **Three coupled singletons**: `ServerManager.shared`, `ServerConnection.shared`, and `MCPBridge.shared` all assume a single local server
- **Health check assumes localhost**: `ServerManager.waitForReady()` probes `http://127.0.0.1:4000/health`
- **Reconnection gives up fast**: 3 retries with short backoff — fine for local, bad for flaky remote networks

That is a solid local baseline. Now we want controlled remote access without turning this into a public internet service.

## Recommendation Snapshot

- Network: **Tailscale tailnet only** (not public internet).
- Transport security: `ws://` over Tailscale is fine — Tailscale encrypts the tunnel with WireGuard. No need for app-level TLS in MVP.
- MVP topology: **single selected endpoint** in the app (local or one remote).
- Security stance (MVP): tailnet identity + ACLs first, app-level auth token in Phase 4.
- Future-ready direction: endpoint abstraction now, multi-server merged UI later.

## Scope

### In scope (MVP)

- Make server bind address configurable.
- Add configurable server endpoints in macOS app.
- Allow connecting to a remote Tailscale endpoint.
- Keep local server flow working as default.
- Add a clear "active endpoint" switch in Settings.
- Adjust connection resilience for remote networks.
- Add a practical Tailscale setup + test runbook in docs.

### Out of scope (MVP)

- iOS/iPad app targets.
- Merged multi-server session dashboard.
- Public internet exposure.
- Full authn/authz system redesign.
- `wss://` / TLS termination (Tailscale handles encryption).

---

## Phase 1: Server-Side Configurability

### Objective

Make `orbitdock-server` bindable to non-localhost addresses so a remote client can reach it at all.

### Changes

1. **Configurable bind address**:
   - Add `ORBITDOCK_BIND_ADDR` env var (default: `127.0.0.1:4000` — unchanged behavior).
   - Parse and validate on startup, log the resolved address.
   - When running on a Tailscale host, user sets `ORBITDOCK_BIND_ADDR=0.0.0.0:4000`.

2. **Version handshake on WebSocket connect**:
   - Server sends a `{"type": "hello", "version": "0.1.0", "server_id": "<uuid>"}` message on new WebSocket connections.
   - Client can detect incompatible servers or wrong endpoints early instead of getting opaque parse errors.

### Files touched

- `orbitdock-server/crates/server/src/main.rs` — bind address from env
- `orbitdock-server/crates/server/src/websocket.rs` — hello message on connect

### Acceptance criteria

- Server binds to env-configured address and accepts remote connections.
- Default behavior (no env var) is identical to current localhost-only.
- Client receives version info on connect.

### How to validate

```bash
# Terminal 1: start server on all interfaces
ORBITDOCK_BIND_ADDR=0.0.0.0:4000 cargo run -p orbitdock-server

# Terminal 2: connect from another machine on the same network
websocat ws://<tailscale-ip>:4000/ws
# Should receive {"type":"hello","version":"0.1.0",...}
```

---

## Phase 2: Endpoint Model + Client Connection Refactor

### Objective

Replace hardcoded localhost in the macOS app with a persisted endpoint config. Make connection behavior endpoint-aware.

### Changes

1. **Endpoint model** persisted in UserDefaults (or a small plist):
   - `id: UUID`
   - `name: String` (e.g. "Local OrbitDock", "Home Server")
   - `wsURL: String` (e.g. `ws://127.0.0.1:4000/ws`)
   - `isLocalManaged: Bool` — true means app owns the server process
   - `isActive: Bool`
   - Seed default: `Local OrbitDock` / `ws://127.0.0.1:4000/ws` / `isLocalManaged = true`.

2. **ServerConnection takes a URL parameter**:
   - Remove hardcoded `ws://127.0.0.1:4000/ws`.
   - `connect(to url: URL)` instead of `connect()`.
   - On endpoint switch: disconnect current -> reset subscriptions/state -> connect to new URL.

3. **Coordinated singleton teardown on switch**:
   - `ServerConnection` disconnects and resets callbacks.
   - `ServerAppState` clears all cached sessions/state and re-wires callbacks.
   - `MCPBridge` resets (it proxies to Codex through the current server — for remote endpoints, MCP bridge may not apply; gate it behind `isLocalManaged`).

4. **ServerManager gating**:
   - Only run `ServerManager.shared.start()` when active endpoint has `isLocalManaged = true`.
   - For remote endpoints, skip process startup and connect directly.
   - On switch from remote back to local: start the server process, wait for health check, then connect.

5. **Health check strategy**:
   - Local endpoints: existing HTTP probe to `/health` (unchanged).
   - Remote endpoints: skip HTTP health check; use WebSocket connect with timeout as the readiness signal. Validate the `hello` message from Phase 1.

6. **Remote-friendly reconnection policy**:
   - Local endpoints: keep current 3-retry limit (server crash = real problem).
   - Remote endpoints: exponential backoff up to 30s, retry indefinitely. Surface connection state in UI so user can see "Reconnecting..." vs "Connected".

### Files touched

- New: `Endpoint.swift` (model + persistence)
- `ServerConnection.swift` — parameterized URL, reconnection policy per endpoint type
- `ServerManager.swift` — gated by `isLocalManaged`
- `CommandCenterApp.swift` — startup flow branches on endpoint type
- `ServerAppState.swift` — teardown/re-wire on endpoint switch
- `MCPBridge.swift` — gated behind local-only

### Acceptance criteria

- User can define and persist multiple endpoints.
- Selecting a local endpoint starts the embedded server and connects (current behavior).
- Selecting a remote endpoint skips server startup and connects directly.
- Switching endpoints tears down cleanly — no stale state, no leaked subscriptions.
- Remote connections retry gracefully on transient failures.
- MCPBridge only runs for local endpoints.

### How to validate

1. Launch app with default local endpoint — everything works as before.
2. Add a remote endpoint pointing to a Tailscale IP.
3. Switch to remote — app connects, sessions load.
4. Switch back to local — embedded server starts, app reconnects.
5. Kill the remote server — app shows reconnecting state, recovers when server comes back.

---

## Phase 3: Settings UI + Connection Status

### Objective

Give the user a clear interface to manage endpoints and see connection health.

### Changes

1. **Settings > Endpoints pane**:
   - List of configured endpoints with active indicator.
   - Add / Edit / Remove endpoints.
   - "Set Active" button or radio selection.
   - For each endpoint: name, WebSocket URL, local-managed toggle.

2. **Connection test button**:
   - Attempts WebSocket connect + validates `hello` handshake.
   - Shows success/failure with actionable error message.
   - For remote `ws://` URLs: note that Tailscale encrypts the connection (not a warning — informational).

3. **Connection status in header/toolbar**:
   - Current endpoint name + connection state always visible.
   - States: Connected / Connecting / Reconnecting / Failed.
   - Click to open Settings > Endpoints.

4. **Loading states for remote**:
   - Session list shows a loading indicator during initial sync from remote server.
   - Handles higher latency gracefully (no empty-state flash).

### Files touched

- New: `EndpointSettingsView.swift`
- `HeaderView.swift` — connection status indicator
- `DashboardView.swift` — loading state for remote initial sync
- `SessionDetailView.swift` — loading state awareness

### Acceptance criteria

- User can add/edit/remove/select endpoints entirely from Settings UI.
- Connection test gives clear pass/fail feedback.
- Active endpoint + connection state is always visible.
- No raw error dumps — all errors have human-readable copy.

---

## Phase 4: Security Hardening + Docs

### Objective

Make remote setup safe, repeatable, and documented for self-hosted users.

### Changes

1. **Tailscale setup runbook** (`docs/tailscale-remote-setup.md`):
   - Prerequisites (Tailscale installed on both machines).
   - Server host setup: install orbitdock-server, configure `ORBITDOCK_BIND_ADDR`, start as service.
   - Tailnet ACL guidance (restrict to your devices/user).
   - Client setup: add remote endpoint in OrbitDock Settings.
   - Verification steps.
   - "Do not expose to public internet" warning with explanation.

2. **Optional bearer token auth**:
   - Endpoint model gets optional `authToken: String?` stored in Keychain.
   - Client sends token as query param on WebSocket upgrade (`?token=<token>`) or as `Authorization` header.
   - Server validates token when `ORBITDOCK_AUTH_TOKEN` env var is set; rejects connections without valid token.
   - When env var is unset, server accepts all connections (current behavior, local-only default).

3. **Phone hotspot validation script**:
   - Simple script that verifies Tailscale connectivity and tests WebSocket handshake from the command line.
   - Included in docs as a troubleshooting tool.

### Files touched

- New: `docs/tailscale-remote-setup.md`
- `Endpoint.swift` — optional auth token field + Keychain storage
- `ServerConnection.swift` — attach token on connect
- `orbitdock-server/crates/server/src/main.rs` — token validation middleware
- `orbitdock-server/crates/server/src/websocket.rs` — reject unauthorized connections

### Acceptance criteria

- A technical user can go from zero to working remote connection following the docs alone.
- Remote endpoint works from a phone hotspot with Tailscale active on both devices.
- Token auth works end-to-end when configured on both sides.
- Without token configured, behavior is unchanged.

### How to validate

1. Follow the runbook on a fresh machine — should work without asking for help.
2. Connect from MacBook on home WiFi to server on desk.
3. Switch MacBook to phone hotspot — connection drops, Tailscale re-establishes, app reconnects.
4. Set auth token on server, try connecting without token in app — rejected.
5. Add token to endpoint config — connection succeeds.

---

## Test Plan

### Automated

- **Unit tests**:
  - Endpoint model: create, persist, load, update, delete
  - Active endpoint switching logic
  - `isLocalManaged` gates ServerManager startup
  - Reconnection policy selection (local vs remote)
  - Token attachment on WebSocket upgrade
  - Server bind address parsing from env var

- **Integration tests**:
  - Connection lifecycle on endpoint swap (local -> remote -> local)
  - State cleanup between endpoint switches (no session bleed)
  - Hello handshake validation
  - Auth token rejection/acceptance

### Manual (MVP sign-off)

1. Start app on local endpoint. Verify current behavior is identical.
2. Add remote endpoint pointing to Tailscale host server.
3. Switch endpoint; verify connect and session list loads.
4. Move client machine to phone hotspot (Tailscale active on both devices).
5. Verify connection recovers after network transition.
6. Kill remote server — verify app shows reconnecting, recovers on restart.
7. Toggle back to local endpoint — verify embedded server starts and works.
8. Test with auth token configured on both sides.
9. Test with wrong/missing auth token — verify rejection with clear error.

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Singleton assumptions make endpoint switch flaky | Explicit coordinated teardown of all three singletons + integration tests |
| Remote misconfiguration gives poor UX | Test button + clear error messages + setup docs |
| Accidental public exposure | Tailscale-only docs, local-first default, no `wss://` complexity |
| Transient network failures feel broken | Remote-specific retry policy with unlimited backoff + visible reconnection state |
| MCP bridge confusion on remote endpoints | Gate MCPBridge behind `isLocalManaged` — only runs for local server |
| Protocol mismatch between app and remote server | Version handshake on connect catches this immediately |

---

## Definition of Done (MVP = Phases 1-4 complete)

- `orbitdock-server` is bindable to configurable addresses.
- One macOS app can connect to either local OrbitDock server or one remote Tailscale server.
- Switching endpoints is reliable and does not require app restart.
- Connection state is always visible and reconnection is resilient for remote networks.
- Real-world remote validation completed over phone hotspot.
- Docs are sufficient for another technical user to self-host and connect.
- Optional auth token works end-to-end when configured.

---

## Future: Multi-Server Foundation (post-MVP)

Once MVP is validated, the next step is supporting multiple simultaneous server connections. This means replacing the singleton pattern with endpoint-scoped runtime objects (`ServerConnection` + `ServerAppState` per endpoint) and adding a server picker in the UI. Detailed planning deferred until MVP is proven.
