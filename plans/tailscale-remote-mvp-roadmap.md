# OrbitDock Tailscale Remote MVP Roadmap

> Goal: Connect OrbitDock macOS to remote `orbitdock-server` instances over a private Tailscale network, with a tight MVP we can test quickly from real-world networks (including phone hotspot).
>
> Status: Active. This was previously archived too early.
>
> Updated scope: iOS/iPad **shell bring-up** is in scope as Phase 0. iOS/iPad **live server connectivity** remains out of scope for the Tailscale MVP itself.

## Why this plan

Current state is local-only by design:

- **Server binds localhost only**: `orbitdock-server/crates/server/src/main.rs:483` hardcodes `127.0.0.1:4000`
- **Server has no signal handling**: SIGTERM kills it mid-write — sessions left inconsistent, DB writes lost
- **Server paths are hardcoded**: database locked to `~/.orbitdock/orbitdock.db`, no CLI args at all
- **No deployment story**: no systemd unit, no launchd plist, no Dockerfile — only runs as an embedded subprocess
- **Client URL is hardcoded**: `OrbitDock/OrbitDock/Services/Server/ServerConnection.swift:37` points at `ws://127.0.0.1:4000/ws`
- **App assumes one embedded server**: `OrbitDockApp.swift` starts `ServerManager.shared` on launch, waits for health check, then connects the singleton `ServerConnection.shared`
- **Three coupled singletons**: `ServerManager.shared`, `ServerConnection.shared`, and `MCPBridge.shared` all assume a single local server
- **Health check assumes localhost**: `ServerManager.waitForReady()` probes `http://127.0.0.1:4000/health`
- **Reconnection gives up fast**: 3 retries with short backoff — fine for local, bad for flaky remote networks

That is a solid local baseline. Now we want controlled remote access without turning this into a public internet service.

## Recommendation Snapshot

- Network: **Tailscale tailnet only** (not public internet).
- Transport security: `ws://` over Tailscale is fine — Tailscale encrypts the tunnel with WireGuard. No need for app-level TLS in MVP.
- MVP topology: **single selected endpoint** in the app (local or one remote).
- Security stance (MVP): tailnet identity + ACLs first, app-level auth token in Phase 5.
- Future-ready direction: endpoint abstraction now, multi-server merged UI later.

## Scope

### In scope (MVP)

- Phase 0 universal-shell groundwork (PAL + runtime modes + capability gates) so iOS/iPad can boot without a live server.
- Harden server for standalone daemon deployment (signals, CLI args, service files).
- Make server bind address configurable.
- Add configurable server endpoints in macOS app.
- Allow connecting to a remote Tailscale endpoint.
- Keep local server flow working as default.
- Add a clear "active endpoint" switch in Settings.
- Adjust connection resilience for remote networks.
- Add a practical Tailscale setup + test runbook in docs.

### Out of scope (MVP)

- iOS/iPad live endpoint connectivity and production parity.
- Merged multi-server session dashboard.
- Public internet exposure.
- Full authn/authz system redesign.
- `wss://` / TLS termination (Tailscale handles encryption).
- Docker / container images (defer until someone needs it).
- Cross-compilation for ARM Linux (defer until Pi deployment is attempted).

---

## Phase 0: Universal Shell + PAL (Pre-Server)

### Objective

Get OrbitDock building and running in iOS Simulator before server work by introducing platform seams and capability-driven feature gating.

### Changes

1. **Platform Abstraction Layer (PAL)**:
   - Wrap macOS-only APIs behind platform services (open URL, reveal path, file picker, clipboard, sound, terminal integration).
   - Keep AppKit code in macOS adapters only.

2. **Capability model**:
   - Introduce explicit capability flags (`canRunEmbeddedServer`, `canUseAppleScript`, `canFocusTerminal`, `canManageHooks`, etc.).
   - Gate UI affordances by capability, not ad hoc `#if` checks.

3. **Runtime mode split**:
   - Add `live` and `mock` runtime modes.
   - iOS defaults to `mock` so app can boot without `orbitdock-server`.

4. **App bootstrap cleanup**:
   - Route server startup/connection and MCP bridge startup through runtime mode + capabilities.
   - Leave macOS behavior unchanged in `live` mode.

### Acceptance criteria

- OrbitDock can launch in iOS Simulator without crashing.
- Shared services/state layers no longer import AppKit directly for functionality that should be cross-platform.
- macOS-only features are clearly identified and gated.

---

## Phase 1: Server Daemon Hardening

### Objective

Make `orbitdock-server` a well-behaved daemon that can run standalone on any machine — not just as an embedded subprocess managed by the macOS app.

### Changes

1. **Graceful shutdown on signals**:
   - Handle SIGTERM and SIGINT via `tokio::signal`.
   - On signal: log shutdown intent, close active WebSocket connections with a close frame, flush pending DB writes, mark in-progress sessions as interrupted, then exit cleanly.
   - This is critical — without it, `systemctl stop` or `launchctl unload` corrupts state.

2. **CLI arguments via `clap`**:
   - `--bind <addr>` — bind address (default: `127.0.0.1:4000`). Also readable from `ORBITDOCK_BIND_ADDR` env var.
   - `--data-dir <path>` — data directory (default: `~/.orbitdock`). Database, logs, and state files all live here.
   - Keep all existing env vars working as fallbacks. CLI args take priority.

3. **PID file**:
   - Write PID to `<data-dir>/orbitdock-server.pid` on startup.
   - Remove on clean shutdown.
   - On startup, check for stale PID file and warn (don't block — the old process may have crashed).

4. **Log rotation**:
   - Switch from `rolling::never` to `rolling::daily` with max 7 files retained.
   - Also add stderr output when not running as a daemon (detect via `--foreground` flag or TTY check), so systemd journal and manual runs get output too.

5. **Service file templates**:
   - `deploy/orbitdock-server.service` — systemd unit for Linux (Pi, servers).
   - `deploy/com.orbitdock.server.plist` — launchd plist for macOS.
   - Both reference configurable `--bind` and `--data-dir`.

### Files touched

- `orbitdock-server/crates/server/src/main.rs` — signal handling, CLI args, PID file
- `orbitdock-server/crates/server/src/logging.rs` — log rotation, stderr fallback
- `orbitdock-server/Cargo.toml` — add `clap` dependency
- New: `deploy/orbitdock-server.service`
- New: `deploy/com.orbitdock.server.plist`

### Acceptance criteria

- `kill <pid>` and `kill -TERM <pid>` trigger clean shutdown with log message.
- `--bind 0.0.0.0:4000` works; default (no flag) is identical to current behavior.
- `--data-dir /opt/orbitdock` puts DB + logs in that directory.
- PID file is created on startup, removed on clean shutdown.
- Logs rotate daily, old logs are cleaned up.
- `stderr` gets log output when running in a terminal.
- Service files are valid (`systemd-analyze verify`, `plutil -lint`).

### How to validate

```bash
# Test signal handling
cargo run -p orbitdock-server -- --bind 127.0.0.1:4000 &
kill -TERM $!
# Should see "shutting down gracefully" in logs, clean exit

# Test custom data dir
cargo run -p orbitdock-server -- --data-dir /tmp/orbitdock-test
ls /tmp/orbitdock-test/
# Should contain: orbitdock.db, logs/, orbitdock-server.pid

# Test systemd unit (on a Linux box)
sudo cp deploy/orbitdock-server.service /etc/systemd/system/
sudo systemctl start orbitdock-server
sudo systemctl status orbitdock-server  # should be active
sudo systemctl stop orbitdock-server    # should stop cleanly
```

---

## Phase 2: Server Connectivity + Handshake

### Objective

Make `orbitdock-server` reachable from remote clients and identifiable on connect.

### Changes

1. **Configurable bind address** (building on Phase 1's `--bind` flag):
   - When running on a Tailscale host, user sets `--bind 0.0.0.0:4000`.
   - Log the resolved bind address clearly on startup.
   - Update `ServerManager.swift` to pass `--bind` when launching the embedded server (keeps local behavior unchanged).

2. **Version handshake on WebSocket connect**:
   - Server sends a `{"type": "hello", "version": "0.1.0", "server_id": "<uuid>"}` message immediately on new WebSocket connections.
   - `server_id` is a stable UUID generated on first run and persisted in `<data-dir>/server-id`.
   - Client can detect incompatible servers or wrong endpoints early instead of getting opaque parse errors.

### Files touched

- `orbitdock-server/crates/server/src/main.rs` — bind address passthrough
- `orbitdock-server/crates/server/src/websocket.rs` — hello message on connect
- `OrbitDock/OrbitDock/Services/Server/ServerManager.swift` — pass `--bind` to embedded server

### Acceptance criteria

- Server binds to configured address and accepts connections from other machines.
- Default behavior (no flags) is identical to current localhost-only.
- Client receives version info on connect.
- `ServerManager` passes `--bind 127.0.0.1:4000` to the embedded binary (explicit, not implicit).

### How to validate

```bash
# Terminal 1: start server on all interfaces
cargo run -p orbitdock-server -- --bind 0.0.0.0:4000

# Terminal 2: connect from another machine on the same network
websocat ws://<tailscale-ip>:4000/ws
# Should receive {"type":"hello","version":"0.1.0","server_id":"..."}
```

---

## Phase 3: Endpoint Model + Client Connection Refactor

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
   - Remote endpoints: skip HTTP health check; use WebSocket connect with timeout as the readiness signal. Validate the `hello` message from Phase 2.

6. **Remote-friendly reconnection policy**:
   - Local endpoints: keep current 3-retry limit (server crash = real problem).
   - Remote endpoints: exponential backoff up to 30s, retry indefinitely. Surface connection state in UI so user can see "Reconnecting..." vs "Connected".

### Files touched

- New: `Endpoint.swift` (model + persistence)
- `ServerConnection.swift` — parameterized URL, reconnection policy per endpoint type
- `ServerManager.swift` — gated by `isLocalManaged`
- `OrbitDockApp.swift` — startup flow branches on endpoint type
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

## Phase 4: Settings UI + Connection Status

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

## Phase 5: Security Hardening + Docs

### Objective

Make remote setup safe, repeatable, and documented for self-hosted users.

### Changes

1. **Tailscale setup runbook** (`docs/tailscale-remote-setup.md`):
   - Prerequisites (Tailscale installed on both machines).
   - Server host setup: install orbitdock-server, configure `--bind`, start as service using the templates from Phase 1.
   - Tailnet ACL guidance (restrict to your devices/user).
   - Client setup: add remote endpoint in OrbitDock Settings.
   - Verification steps.
   - "Do not expose to public internet" warning with explanation.

2. **Optional bearer token auth**:
   - Endpoint model gets optional `authToken: String?` stored in Keychain.
   - Client sends token as query param on WebSocket upgrade (`?token=<token>`) or as `Authorization` header.
   - Server validates token when `ORBITDOCK_AUTH_TOKEN` env var is set (or `--auth-token` flag); rejects connections without valid token.
   - When not configured, server accepts all connections (current behavior, local-only default).

3. **Phone hotspot validation script**:
   - Simple script that verifies Tailscale connectivity and tests WebSocket handshake from the command line.
   - Included in docs as a troubleshooting tool.

### Files touched

- New: `docs/tailscale-remote-setup.md`
- `Endpoint.swift` — optional auth token field + Keychain storage
- `ServerConnection.swift` — attach token on connect
- `orbitdock-server/crates/server/src/main.rs` — `--auth-token` flag + validation middleware
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

- **Unit tests (Rust)**:
  - CLI arg parsing (bind address, data dir, auth token)
  - Bind address validation
  - Signal handler triggers clean shutdown
  - Hello handshake message format
  - Auth token validation (accept/reject)
  - PID file lifecycle

- **Unit tests (Swift)**:
  - Endpoint model: create, persist, load, update, delete
  - Active endpoint switching logic
  - `isLocalManaged` gates ServerManager startup
  - Reconnection policy selection (local vs remote)
  - Token attachment on WebSocket upgrade

- **Integration tests**:
  - Server starts with custom `--data-dir` and creates expected files
  - Server shuts down cleanly on SIGTERM
  - Connection lifecycle on endpoint swap (local -> remote -> local)
  - State cleanup between endpoint switches (no session bleed)
  - Hello handshake validation
  - Auth token rejection/acceptance

### Manual (MVP sign-off)

1. Start server standalone with `--bind 0.0.0.0:4000` — verify it accepts remote connections.
2. `kill -TERM` the server — verify clean shutdown, no corrupt state.
3. Start app on local endpoint — verify current behavior is identical.
4. Add remote endpoint pointing to Tailscale host server.
5. Switch endpoint; verify connect and session list loads.
6. Move client machine to phone hotspot (Tailscale active on both devices).
7. Verify connection recovers after network transition.
8. Kill remote server — verify app shows reconnecting, recovers on restart.
9. Toggle back to local endpoint — verify embedded server starts and works.
10. Test with auth token configured on both sides.
11. Test with wrong/missing auth token — verify rejection with clear error.

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Signal handling breaks embedded mode | ServerManager already kills child process; signals only affect standalone mode |
| Singleton assumptions make endpoint switch flaky | Explicit coordinated teardown of all three singletons + integration tests |
| Remote misconfiguration gives poor UX | Test button + clear error messages + setup docs |
| Accidental public exposure | Tailscale-only docs, local-first default, no `wss://` complexity |
| Transient network failures feel broken | Remote-specific retry policy with unlimited backoff + visible reconnection state |
| MCP bridge confusion on remote endpoints | Gate MCPBridge behind `isLocalManaged` — only runs for local server |
| Protocol mismatch between app and remote server | Version handshake on connect catches this immediately |
| clap dependency conflicts with existing setup | Server has no CLI framework today — clean addition |

---

## Definition of Done (MVP = Phases 1-5 complete)

- `orbitdock-server` shuts down gracefully on SIGTERM/SIGINT.
- Server accepts `--bind` and `--data-dir` flags for flexible deployment.
- Service file templates exist for systemd and launchd.
- `orbitdock-server` is bindable to configurable addresses.
- One macOS app can connect to either local OrbitDock server or one remote Tailscale server.
- Switching endpoints is reliable and does not require app restart.
- Connection state is always visible and reconnection is resilient for remote networks.
- Real-world remote validation completed over phone hotspot.
- Docs are sufficient for another technical user to self-host and connect.
- Optional auth token works end-to-end when configured.

---

## Future (post-MVP)

### Multi-Server Foundation

Supporting multiple simultaneous server connections. Replace the singleton pattern with endpoint-scoped runtime objects (`ServerConnection` + `ServerAppState` per endpoint) and add a server picker in the UI. Detailed planning deferred until MVP is proven.

### Zero-Config Deployment CLI

Once the server has `clap` and daemon behavior from Phase 1, add a `orbitdock-server setup` subcommand that bootstraps the full environment on a fresh machine. Check if Tailscale is installed (prompt to install if not), configure tailnet ACLs, generate an auth token, write and enable the appropriate service file (systemd or launchd), and verify connectivity — one command from bare machine to running endpoint. Eventually this could extend to Docker/container deployment too.
