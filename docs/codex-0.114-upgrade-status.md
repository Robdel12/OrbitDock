# Codex 0.114 Upgrade Status

This note tracks the practical state of the Codex direct-session upgrade to upstream `rust-v0.114.0`.

## Current Status

OrbitDock now builds and passes the Rust workspace tests against Codex `rust-v0.114.0`.

Latest-working scope completed:

- dependency bump to `rust-v0.114.0`
- `ThreadManager::new` migration to the new `&Config` constructor
- `OverrideTurnContext` updates for `service_tier`
- realtime event handling updates for the latest `RealtimeEvent` shape
- MCP elicitation updates for the newer `ElicitationRequestEvent`
- test coverage updates for intentionally ignored latest-only `EventMsg` variants

Validation completed:

- `make rust-check`
- `make rust-test`

## Files Touched For Latest-Working

- `orbitdock-server/Cargo.toml`
- `orbitdock-server/Cargo.lock`
- `orbitdock-server/crates/connector-codex/src/lib.rs`
- `orbitdock-server/crates/connector-codex/src/rollout_parser.rs`
- `orbitdock-server/crates/connector-codex/tests/eventmsg_coverage.rs`

## What Is Still Not At Feature Parity

These are the biggest remaining gaps relative to latest Codex. They are intentionally not part of the initial unblock.

### Completed: `request_permissions`

OrbitDock now supports Codex `request_permissions` end to end.

Completed scope:

- dedicated `Permissions` approval type in the shared protocol
- Codex action and runtime handling for `RequestPermissionsResponse`
- HTTP and WebSocket response paths
- persisted permission request metadata in approval history
- Swift client and composer UI for reviewing requested permissions
- `turn` vs `session` grant scope support

That closes the largest approval-model mismatch from the `0.114` upgrade.

### 1. Hooks

Latest Codex emits hook lifecycle events like `HookStarted` and `HookCompleted`. OrbitDock currently ignores them safely, which is fine for stability, but it means users cannot see hook activity or failures in the timeline.

Key OrbitDock files:

- `orbitdock-server/crates/connector-codex/src/lib.rs`
- `orbitdock-server/crates/connector-codex/src/rollout_parser.rs`

Recommended epic:

- decide whether hooks should appear as timeline events, debug-only events, or both
- decide whether hook failures should change attention state

### 2. Realtime Transcript And Handoff Parity

Latest Codex has transcript delta events and richer handoff payloads. OrbitDock now compiles by safely ignoring the new realtime-only variants, but it does not surface them.

Key OrbitDock files:

- `orbitdock-server/crates/connector-codex/src/lib.rs`
- `OrbitDockNative/OrbitDock/Views/Conversation/`

Recommended epic:

- decide whether transcript deltas should render live
- decide whether handoff activity should become user-visible
- add UI only after the product behavior is clear

### 3. Personality And Collaboration Controls

OrbitDock already passes some collaboration-mode concepts through, but it does not yet expose the full latest Codex control plane around personality and richer collaboration behavior.

Key OrbitDock files:

- `orbitdock-server/crates/connector-codex/src/lib.rs`
- `orbitdock-server/crates/server/src/transport/websocket/handlers/messaging.rs`
- `OrbitDockNative/OrbitDock/Views/Codex/`

Recommended epic:

- audit what latest Codex exposes for personality and collaboration presets
- decide which settings belong in session setup versus per-turn overrides
- move toward server-driven collaboration metadata instead of UI-local assumptions

### 4. Apps And Auth-Gated MCP Behavior

Latest Codex is more explicit about auth-dependent app availability. ChatGPT-authenticated sessions can expose app tooling differently than API-key-authenticated ones.

This is not a latest-working blocker, but it is important product behavior to document and eventually surface.

Key OrbitDock files:

- `orbitdock-server/crates/connector-codex/src/lib.rs`
- `orbitdock-server/crates/server/src/transport/http/capabilities.rs`
- `OrbitDockNative/OrbitDock/Views/Codex/McpServersTab.swift`
- `OrbitDockNative/OrbitDock/Views/Codex/SkillsTab.swift`

Recommended epic:

- document auth-dependent app/tool availability
- verify model and MCP inventory behavior across ChatGPT auth and API key auth
- decide whether the UI should explain unavailable app/tool surfaces explicitly

## Suggested Parallel Workstreams

Once the latest-working upgrade ships, these are the safest parallel lanes:

1. Realtime lane
   Transcript deltas, handoff visibility, hook visibility, and timeline behavior

2. Session-controls lane
   Personality, collaboration, and richer turn/session configuration surfaces

3. Apps/auth lane
   Auth-dependent app and MCP behavior, capability reporting, and UX clarity

## Recommended Next Step

The next best Codex parity wins are:

1. explicit collaboration/personality controls
2. hooks, handoffs, and realtime visibility
3. auth-aware apps and MCP capability behavior
