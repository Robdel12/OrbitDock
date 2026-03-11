# Codex 0.114 Upgrade Status

This note tracks the practical state of the Codex direct-session upgrade to upstream `rust-v0.114.0`.

## Current Status

OrbitDock now builds and passes the Rust workspace tests against Codex `rust-v0.114.0`.

The upgrade is no longer just "latest works." OrbitDock now has a substantial amount of real Codex parity on top of the baseline bump.

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
- `make build-all`
- `make test-unit`

## Files Touched For Latest-Working

- `orbitdock-server/Cargo.toml`
- `orbitdock-server/Cargo.lock`
- `orbitdock-server/crates/connector-codex/src/lib.rs`
- `orbitdock-server/crates/connector-codex/src/rollout_parser.rs`
- `orbitdock-server/crates/connector-codex/tests/eventmsg_coverage.rs`

## What Landed After The Initial Upgrade

These are the biggest parity wins that landed after the first `0.114` unblock.

### Completed: Worker And Agent Foundation

OrbitDock now has a real Codex worker foundation instead of treating agent activity like loose tool output.

Completed scope:

- persisted worker lifecycle state and richer worker metadata
- reload-safe worker hydration
- a session-level worker companion panel
- conversation-side worker linkage and worker-aware timeline rows
- stronger worker completion/result precedence on the server
- restore/resume paths that preserve Codex thread identity and control-plane settings

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

### Completed: Codex Control Plane

OrbitDock now has real end-to-end support for the modern Codex control plane.

Completed scope:

- `collaboration_mode`
- `multi_agent`
- `personality`
- `service_tier`
- durable `developer_instructions`
- resume and restore paths that preserve those settings for direct Codex sessions

The remaining work here is mostly UX polish and validation, not missing transport.

### Completed: Passive Realtime Parity

Passive Codex rollout sessions now preserve more of the modern runtime state instead of silently dropping it.

Completed scope:

- passive handoff visibility
- passive background-event handling
- passive plan updates
- passive turn-diff updates
- immediate passive shutdown handling

That closes a meaningful gap between passive rollout sessions and direct live sessions.

## What Is Still Not At Feature Parity

These are the biggest remaining gaps relative to latest Codex.
### 1. Realtime Transcript And Handoff Polish

OrbitDock now carries the important passive realtime state forward and surfaces readable handoff events, but it still intentionally suppresses transcript delta churn and other noisy realtime transport details.

Key OrbitDock files:

- `orbitdock-server/crates/connector-codex/src/lib.rs`
- `orbitdock-server/crates/connector-codex/src/rollout_parser.rs`
- `OrbitDockNative/OrbitDock/Views/Conversation/`

Recommended epic:

- decide whether transcript deltas should stay hidden, become ephemeral, or surface in a lighter live-progress treatment
- refine handoff visibility now that the core mapping exists

### 2. Worker Experience Polish

OrbitDock now has real workers, but the experience is still maturing.

Key OrbitDock files:

- `orbitdock-server/crates/connector-codex/src/lib.rs`
- `OrbitDockNative/OrbitDock/Views/Conversation/`
- `OrbitDockNative/OrbitDock/Views/SessionDetail/`

Recommended epic:

- deepen conversation-to-worker linkage
- make the worker sidecar a richer drill-in surface
- explore direct worker interaction if upstream Codex exposes a durable control surface

### 3. Hooks

The earlier roadmap assumed Codex hook lifecycle events were available through the same stable public event surface OrbitDock already consumes. That no longer looks true.

So the current status is:

- hook visibility is not a simple missing mapping in OrbitDock
- it appears to be blocked on upstream Codex exposing a clean consumable hook-lifecycle surface, or on OrbitDock choosing a different source of truth

That makes this a watch-and-revisit item, not the highest-value immediate implementation lane.

### 4. Apps And Auth-Gated MCP Behavior

Latest Codex is more explicit about auth-dependent app availability. ChatGPT-authenticated sessions can expose app tooling differently than API-key-authenticated ones.

Key OrbitDock files:

- `orbitdock-server/crates/connector-codex/src/lib.rs`
- `orbitdock-server/crates/server/src/transport/http/capabilities.rs`
- `OrbitDockNative/OrbitDock/Views/Codex/McpServersTab.swift`
- `OrbitDockNative/OrbitDock/Views/Codex/SkillsTab.swift`

Recommended epic:

- validate model and MCP inventory behavior across ChatGPT auth and API key auth
- keep the current capability messaging honest and visible
- only add more code if the current messaging proves insufficient

## Suggested Parallel Workstreams

Now that the big transport and approval gaps are closed, these are the safest parallel lanes:

1. Worker UX lane
   Timeline integration, sidecar drill-in, and richer agent result presentation

2. Realtime lane
   Transcript delta strategy and handoff polish

3. Apps/auth lane
   Auth-dependent app and MCP behavior, capability reporting, and UX clarity

## Recommended Next Step

The next best Codex parity wins are:

1. worker UX polish and deeper worker interaction
2. handoffs and realtime visibility
3. auth-aware apps and MCP capability behavior
