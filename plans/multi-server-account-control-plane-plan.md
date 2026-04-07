# Multi-Server Account And Control Plane Plan

Status: Draft  
Owner: OrbitDock Core  
Last updated: 2026-04-02

## Why This Exists

OrbitDock supports multiple endpoints, but account and usage management still feel "single control plane first" in key UX paths.

That creates a real gap in multi-machine workflows. Example: your MacBook Air endpoint can run sessions, but you cannot reliably manage its Codex account or inspect usage there unless it is acting as the device control plane.

This plan fixes that while preserving the core architecture:

- HTTP remains the bootstrap/heavy-read path
- WebSocket remains realtime delta/replay/hint only
- server stays authoritative for durable truth

## Problem Statement

Today we have two valid concepts that are easy to conflate:

1. Device control plane endpoint (the endpoint this client treats as primary)
2. Server role primary/secondary (endpoint-declared role metadata)

Usage reads are currently gated by server role primary on the server side, and the client usage registry prefers control-plane runtime first. That makes secondary endpoints feel incomplete for account operations and usage visibility.

## Goals

- Make each endpoint independently manageable for Codex account lifecycle.
- Make endpoint-local usage visible even when the endpoint is not the device control plane.
- Keep one clear control-plane concept for global dashboards and default routing.
- Preserve backward compatibility where practical.
- Keep transport split aligned with `docs/data-flow.md` and `docs/client-networking.md`.

## Non-Goals

- Do not sync Codex credentials between endpoints in this phase.
- Do not introduce cross-endpoint durable state ownership changes.
- Do not move heavy usage snapshots to WebSocket.
- Do not remove current control-plane routing behavior for global views until replacement is proven.

## Terms And Invariants

### Terms

- Endpoint: one OrbitDock server connection target.
- Device control plane: the endpoint selected as default/control-plane for this client device.
- Server role primary: server-declared role metadata (`/api/server/role`).
- Endpoint-local account: Codex auth state stored and managed on that endpoint's server.
- Endpoint-local usage: usage read from that endpoint without requiring it to be global/control-plane primary.

### Invariants

- Every endpoint can expose its own account state and account actions.
- Global/dashboard usage can still prefer control-plane routing.
- Endpoint-local usage and global usage must be explicitly distinguishable in API and UI.
- Mutation responses are authoritative; WS reconciles after.

## Current Architecture Snapshot

- Per-endpoint account primitives already exist in `SessionStore` and server Codex auth endpoints.
- Integrations settings currently bind to `runtimeRegistry.activeSessionStore`, which hides multi-endpoint management ergonomics.
- Usage service picks control-plane/active runtime first, then fetches usage from that single runtime.
- Server usage endpoints return `not_control_plane_endpoint` when endpoint is not primary.

## Target Architecture

### 1) Separate Usage Scopes

Introduce explicit usage scopes:

- `control_plane` for global/control-plane reporting
- `endpoint_local` for per-endpoint reporting

Backward-compatible default should remain current behavior until all clients are migrated.

### 2) Endpoint-Scoped Account Management UX

Integrations must allow selecting an endpoint and managing that endpoint's account directly:

- read account status
- start/cancel login
- logout

### 3) Keep Control Plane For Global Views

Global dashboard/status bar/quick-access usage can remain control-plane routed, but should be labeled clearly and provide a path to endpoint-local inspection.

## Proposed API Contract

Use a scope query on the existing usage endpoints:

- `GET /api/usage/codex?scope=control_plane|endpoint_local`
- `GET /api/usage/claude?scope=control_plane|endpoint_local`

Behavior:

- omitted scope defaults to `control_plane` (backward compatibility)
- `control_plane` keeps current gating semantics
- `endpoint_local` bypasses control-plane gating and returns local endpoint usage

Error codes:

- keep `not_control_plane_endpoint` for `scope=control_plane` mismatch
- add `usage_unavailable_endpoint_local` where local probe cannot be produced

## Client Architecture Changes

### Usage Layer

- Add scope-aware usage client methods.
- Keep existing global usage path for dashboard/status bar.
- Add endpoint-local usage fetch path for endpoint management surfaces.

### Settings Layer

- Add endpoint selector to Integrations pane.
- Render Codex account card per selected endpoint.
- Add endpoint-local usage panel in the same context.

### Runtime/Selection

- Do not overload `activeSessionStore` for endpoint admin tasks.
- Resolve endpoint store explicitly from selected endpoint ID.

## Phased Implementation Plan

## Phase 0: Alignment And Contract Freeze

Goal: lock vocabulary and API direction before coding.

- [ ] Confirm scope query semantics (`control_plane` + `endpoint_local`) and default behavior.
- [ ] Confirm UI copy for "Control Plane" vs "This Endpoint".
- [ ] Confirm error code names and telemetry fields.
- [ ] Add this plan doc to sprint tracking and assign owners.

Exit criteria:

- Team signs off on scope contract and terminology.

## Phase 1: Endpoint-Scoped Account Management UX

Goal: make login/logout/account status manageable on any endpoint.

- [ ] Add endpoint selector state to Integrations settings.
- [ ] Bind `CodexAccountSetupPane` to selected endpoint `SessionStore`.
- [ ] Refresh account state on endpoint switch.
- [ ] Show endpoint context label in card header.
- [ ] Add tests for endpoint switching and action routing.

Exit criteria:

- You can log into Air and Pro independently from one client UI.

## Phase 2: Endpoint-Local Usage Reads

Goal: make usage visible per endpoint regardless of control-plane status.

- [ ] Implement server usage scope handling.
- [ ] Add client usage API support for scope query.
- [ ] Add endpoint-local usage section in Integrations settings.
- [ ] Keep current dashboard/global usage behavior unchanged.
- [ ] Add server + Swift tests for scope behavior and regressions.

Exit criteria:

- Air endpoint shows usage when selected, even if not control plane.

## Phase 3: Global UX Clarity And Cross-Surface Consistency

Goal: remove ambiguity around what usage/account data is being shown.

- [ ] Add explicit badges/labels: `Control Plane`, `Endpoint Local`.
- [ ] Update dashboard/status bar microcopy to clarify scope.
- [ ] Ensure quick-switch/new-session flows do not imply global account coupling.
- [ ] Add telemetry for endpoint-local usage views and auth actions.

Exit criteria:

- No ambiguous "which endpoint am I seeing?" moments in primary flows.

## Phase 4: Hardening, Docs, And Rollout

Goal: ship safely and document operator behavior.

- [ ] Update API docs with scope semantics and examples.
- [ ] Update `docs/FEATURES.md` and `orbitdock-server/README.md`.
- [ ] Add rollout flag if needed for staged release.
- [ ] Run full server/client test matrix and smoke checks on multi-endpoint setup.
- [ ] Publish migration notes for older clients.

Exit criteria:

- Feature shipped with docs, tests, and release notes.

## Parallel Worker Plan

Use disjoint write scopes to minimize conflicts.

### Worker A: Server API + Protocol

Ownership:

- `orbitdock-server/crates/server/src/transport/http/server_meta.rs`
- `orbitdock-server/crates/server/src/support/usage_errors.rs`
- `orbitdock-server/crates/server/src/transport/http/router.rs`
- `orbitdock-server/docs/API.md`

Deliverables:

- usage scope API behavior
- new/updated error codes
- server tests and docs

### Worker B: Swift Networking/Services

Ownership:

- `OrbitDockNative/OrbitDock/Services/Server/API/UsageClient.swift`
- `OrbitDockNative/OrbitDock/Services/UsageServiceRegistry.swift`

Deliverables:

- scope-aware client calls
- global vs endpoint-local usage service logic
- service-level tests

### Worker C: Settings UX + Endpoint Selection

Ownership:

- `OrbitDockNative/OrbitDock/Views/Settings/SettingsSetupView.swift`
- `OrbitDockNative/OrbitDock/Views/Settings/CodexAccountSetupPane.swift`
- new settings subviews/view models as needed

Deliverables:

- endpoint selector in Integrations
- endpoint-scoped account actions
- endpoint-local usage panel UI

### Worker D: QA + Docs + Rollout

Ownership:

- `docs/FEATURES.md`
- `orbitdock-server/README.md`
- integration test plans and release checklist docs

Deliverables:

- test matrix and regression checklist
- product/docs updates
- rollout notes

## Recommended Execution Order

1. Phase 0 decision freeze.
2. Workers A and C start in parallel:
   - C can implement endpoint-scoped account UX immediately (existing APIs already support it).
   - A builds usage scope support.
3. Worker B integrates scoped usage client/service once A's contract is stable.
4. Worker D runs final documentation and rollout pass.

## Testing Strategy

Server:

- unit/integration tests for `scope=control_plane` and `scope=endpoint_local`
- preserve old default behavior when scope missing

Client:

- endpoint switch updates account card state correctly
- login/logout action hits selected endpoint store
- endpoint-local usage renders while control-plane usage remains unchanged in dashboard

Manual smoke:

- two endpoints (Air + Pro), different Codex accounts
- switch control plane without losing endpoint-local account visibility
- verify error messages are scoped and understandable

## Risks And Mitigations

- Risk: users confuse control-plane usage with endpoint-local usage.
  - Mitigation: explicit labeling and endpoint context in UI.

- Risk: older clients break on new response fields.
  - Mitigation: additive contract, default behavior unchanged.

- Risk: conflicting "primary" semantics remain unclear.
  - Mitigation: standardized terminology in UI/docs and settings copy.

## Definition Of Done

- Endpoint account login/logout works for any selected endpoint.
- Endpoint-local usage is visible for any selected endpoint.
- Global usage continues to work via control plane with clear labeling.
- Docs and API references are updated.
- Test coverage exists for server and client contract behavior.
