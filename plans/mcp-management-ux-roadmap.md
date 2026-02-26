# MCP Management + UX Roadmap

## Why this plan exists

OrbitDock currently gives partial MCP visibility for direct Codex sessions, but does not yet provide full MCP management across both direct providers (Claude and Codex). Authentication is also uneven across providers and endpoints.

This roadmap defines small, completeable phases that move us from visibility to full MCP operations and auth with a cohesive UI.

## Product goals

1. Give users one place to understand MCP state across Claude and Codex.
2. Let users manage MCP servers and auth directly from OrbitDock.
3. Keep server-authoritative behavior intact across local and remote endpoints.
4. Ship in slices where each phase is independently useful and testable.

## Non-goals for this roadmap

1. Full provider account management redesign beyond MCP needs.
2. Multi-user org permissions model.
3. Replacing existing session-level MCP tool rendering in conversation history.

## Done definition for every phase

1. Backend/API contract is documented and covered by tests.
2. Swift client state is endpoint-scoped and server-authoritative.
3. UI states are complete: loading, empty, success, degraded, error, retry.
4. Remote endpoint behavior is validated (not just local happy path).
5. A short operator runbook exists in docs.

---

## Phase 0: Contract + UX spec lock (XS)

### Goal

Lock the domain model and UX before implementation to avoid rework.

### In scope

1. Canonical MCP domain model shared across providers.
2. Provider capability matrix (Claude vs Codex, local vs remote).
3. UX information architecture for MCP surfaces.
4. Event/state diagrams for startup status and auth state.

### Out of scope

1. Production code changes beyond feature flags and scaffolding.

### Backend deliverables

1. Protocol proposal doc for unified MCP server snapshot and MCP action messages.
2. Status and auth state enums with transition table.
3. Error taxonomy with user-facing mapping.

### UI/UX deliverables

1. Wireframes for Global MCP Console (Settings-level).
2. Wireframes for Session MCP panel (direct session context).
3. Wireframes for MCP auth flow modal/sheet.
4. Copy deck for key states and failure messages.

### Exit criteria

1. RFC approved.
2. Ticket breakdown created for Phases 1-5.

### Suggested size

1. 1-2 days.

---

## Phase 1: Unified MCP visibility (M)

### Goal

Ship a single read-only MCP visibility model across Claude and Codex.

### In scope

1. Provider-agnostic MCP server list and details.
2. Startup status, auth status, tool/resource/template counts.
3. Consistent MCP visibility in both session and settings contexts.

### Out of scope

1. Mutating MCP config.
2. Auth login/logout actions.

### Backend deliverables

1. Add a unified MCP read endpoint per session.
2. Codex adapter maps existing MCP list/startup events.
3. Claude adapter maps `mcp_status` into unified snapshot.
4. Add protocol tests for both adapters and message roundtrips.

### UI/UX deliverables

1. New `MCP Console` section in Settings with endpoint selector.
2. Reuse/upgrade existing Codex `Servers` rail into provider-neutral MCP panel.
3. MCP server detail view with status indicator, auth chip, last error text, and tool/resource counts.
4. Basic filter/sort: provider, status, auth state.

### Testing

1. Rust unit tests for adapter translation and error mapping.
2. Swift tests for decoding and state updates in `ServerAppState`.
3. UI smoke tests for empty/loading/error/ready.

### Exit criteria

1. User can inspect MCP health for both providers from OrbitDock.
2. No session-specific Codex-only assumptions remain in MCP UI model.

### Suggested size

1. 4-6 days.

---

## Phase 2: MCP lifecycle operations (M)

### Goal

Allow users to run core MCP server operations directly in OrbitDock.

### In scope

1. Refresh server list.
2. Reconnect failed server.
3. Enable/disable configured server.
4. Add/remove server config entries where provider supports dynamic config.

### Out of scope

1. Deep auth credential acquisition.

### Backend deliverables

1. Add action endpoints/messages for MCP operations.
2. Codex adapter uses existing refresh plus config mutation where supported.
3. Claude adapter uses `mcp_reconnect` and `mcp_set_servers`.
4. Add action result events with operation id and outcome.

### UI/UX deliverables

1. Action toolbar in MCP Console with Refresh, Reconnect, Add Server, and Remove Server.
2. Inline optimistic action states with per-server progress.
3. Confirm dialogs for destructive actions.
4. Activity feed row for recent MCP operations and outcomes.

### Testing

1. Server integration tests for operation dispatch and outcomes.
2. Client tests for operation state machine.
3. UI tests for optimistic-to-authoritative reconciliation.

### Exit criteria

1. Users can recover and maintain MCP server connectivity without leaving OrbitDock.

### Suggested size

1. 5-7 days.

---

## Phase 3: MCP auth flows (L)

### Goal

Complete MCP authentication lifecycle management for both providers.

### In scope

1. Auth required detection and auth challenge surfaces.
2. Auth start/cancel/complete/logout actions.
3. OAuth and token-based flows via provider adapters.
4. Secure credential handling boundaries.

### Out of scope

1. General provider account UI redesign outside MCP flows.

### Backend deliverables

1. Unified auth challenge/result protocol using `auth_required`, `auth_in_progress`, `auth_completed`, and `auth_failed`.
2. Codex MCP auth bridging via codex-core capabilities.
3. Claude MCP auth bridging via control message path.
4. Persist only non-secret auth metadata in DB/logs.

### UI/UX deliverables

1. MCP auth sheet with flow-specific UI.
2. Browser-based OAuth launch and callback confirmation state.
3. Token input with validation and secure handling.
4. Cancel/retry controls.
5. Per-server auth badge and last success/failure timestamps.
6. Recovery guidance text for common auth failures.

### Testing

1. Auth flow integration tests for both providers.
2. Failure path tests: expired token, denied auth, callback timeout.
3. Security tests to verify secrets are not logged or persisted in plaintext.

### Exit criteria

1. User can fully authenticate MCP servers from OrbitDock for both providers.
2. Auth failures are actionable and visibly recoverable.

### Suggested size

1. 7-10 days.

---

## Phase 4: Remote endpoint hardening + security (M)

### Goal

Make MCP management reliable and secure across remote control-plane endpoints.

### In scope

1. Endpoint auth token support in app transport.
2. Endpoint-scoped MCP operation routing.
3. Better conflict and stale-state handling for multi-device usage.
4. Audit-friendly operation logging.

### Out of scope

1. Enterprise RBAC.

### Backend deliverables

1. Validate bearer/query token auth paths for REST and WS.
2. Add operation correlation ids across endpoint + session + provider.
3. Add server-side safeguards for stale operation requests.

### UI/UX deliverables

1. Endpoint trust and auth indicators in MCP Console.
2. Remote latency/failure affordances.
3. Conflict banner when endpoint authority or server state changes mid-operation.

### Testing

1. Remote endpoint integration tests with auth on/off and wrong token.
2. Multi-client concurrency test for conflicting MCP operations.

### Exit criteria

1. Remote MCP management behaves predictably with clear trust and error signals.

### Suggested size

1. 4-6 days.

---

## Phase 5: UX polish + rollout (S)

### Goal

Ship confidence, docs, and supportability.

### In scope

1. Empty states and onboarding copy.
2. In-app “what happened” diagnostics for MCP failures.
3. Support docs and troubleshooting runbook.
4. Feature flag rollout strategy and fallback.

### Out of scope

1. Net-new capability not already implemented in prior phases.

### Backend deliverables

1. Telemetry hooks for MCP action outcomes and auth failures.
2. Additional structured logs for support triage.

### UI/UX deliverables

1. Guided first-run walkthrough for MCP management.
2. “Fix it” shortcuts for the most common failure cases.
3. Final copy and visual pass for consistency with OrbitDock patterns.

### Testing

1. Regression sweep across Codex and Claude direct sessions.
2. Manual QA checklist for all core user journeys.

### Exit criteria

1. Feature is releasable behind a default-on flag for target users.

### Suggested size

1. 2-3 days.

---

## UX surface map

1. `Settings > MCP Console` for endpoint and provider-wide management.
2. MCP panel in direct session sidebar for session-context visibility and quick actions.
3. MCP Auth Sheet for flow execution and recovery.

## Primary code touchpoints

1. `orbitdock-server/crates/protocol/src/client.rs`
2. `orbitdock-server/crates/protocol/src/server.rs`
3. `orbitdock-server/crates/protocol/src/types.rs`
4. `orbitdock-server/crates/server/src/websocket.rs`
5. `orbitdock-server/crates/server/src/http_api.rs`
6. `orbitdock-server/crates/server/src/transition.rs`
7. `orbitdock-server/crates/connectors/src/codex.rs`
8. `orbitdock-server/crates/connectors/src/claude.rs`
9. `OrbitDock/OrbitDock/Services/Server/ServerProtocol.swift`
10. `OrbitDock/OrbitDock/Services/Server/ServerConnection.swift`
11. `OrbitDock/OrbitDock/Services/Server/ServerAppState.swift`
12. `OrbitDock/OrbitDock/Views/Codex/McpServersTab.swift`
13. `OrbitDock/OrbitDock/Views/Codex/CodexTurnSidebar.swift`
14. `OrbitDock/OrbitDock/Views/SettingsView.swift`
15. `OrbitDock/OrbitDock/Views/MCP/MCPConsoleView.swift`

## Sequencing notes

1. Phase 0 is required before implementation.
2. Phase 1 must land before any write actions to avoid fragmented UI.
3. Phase 3 depends on Phase 2 operation framework.
4. Phase 4 can start once Phase 2 is stable, but should complete before default-on rollout.

## Release strategy

1. Ship behind `mcp_management_v1` feature flag.
2. Enable for local endpoints first.
3. Expand to remote endpoints after Phase 4 validation.
4. Remove old Codex-only MCP panel path after full parity and migration.
