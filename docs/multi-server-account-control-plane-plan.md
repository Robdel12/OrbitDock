# Multi-Server Account And Control Plane Plan

Date: 2026-04-07  
Owner: OrbitDock Core  
Status: Draft

## Context

- [ ] We need true per-endpoint account management (login, logout, account status) across multiple connected servers.
- [ ] We need per-endpoint usage visibility, even when that endpoint is not the device control plane.
- [ ] We must keep one control-plane concept for global UX without making secondary endpoints feel crippled.
- [ ] We are standardizing on scoped usage reads via query params (`scope`), not separate local routes.

## Why This Change

Current gap:

- Usage behavior is effectively control-plane-first, which hides useful data on secondary endpoints.
- Integrations/account management is not explicit enough about endpoint scope in primary UX paths.
- "Primary" semantics are easy to misread (device control plane vs server role primary).

Why now:

- Multi-machine workflows are already active (for example Air + Pro), and this gap now blocks normal operation.

Observable success:

- [ ] You can select any endpoint and manage that endpoint's Codex account directly.
- [ ] You can view endpoint-local usage for any endpoint.
- [ ] Global usage remains control-plane-routed and clearly labeled.

## Target Design

### API Contract

Use scope on existing usage endpoints:

- `GET /api/usage/codex?scope=control_plane|endpoint_local`
- `GET /api/usage/claude?scope=control_plane|endpoint_local`

Rules:

- omitted `scope` defaults to `control_plane` for backward compatibility.
- `scope=control_plane` preserves existing gating and `not_control_plane_endpoint`.
- `scope=endpoint_local` reads usage local to the selected endpoint.

### Client Behavior

- Integrations UI becomes endpoint-scoped for account actions.
- Dashboard/status bar remain global/control-plane scoped for usage.
- Endpoint-local usage appears in endpoint management UX with explicit labeling.

### Ownership Boundaries

- Rust server owns usage probing behavior and error semantics.
- Swift service layer owns scope-aware usage fetching.
- Swift settings UI owns endpoint selection and endpoint-scoped account/usage rendering.

## Ordered Phases

### Phase 0: Contract And Terminology Freeze

Objective: Lock the cross-layer contract before implementation.

Why this phase first:

- Server/client/UI work can run in parallel only after scope and naming are stable.

Tasks:

- [ ] Confirm `scope` enum values and default semantics in API docs.
- [ ] Confirm user-facing terminology: `Control Plane` and `This Endpoint`.
- [ ] Confirm error handling for `scope=endpoint_local` fallback/failure paths.

Exit criteria:

- [ ] API contract is fixed and documented for implementation.
- [ ] UI terminology is fixed for all touched surfaces.

### Phase 1: Endpoint-Scoped Account UX

Objective: Make account state/actions explicitly endpoint-scoped in Integrations.

Why this phase next:

- Account primitives already exist per endpoint and can ship quickly with low server risk.

Tasks:

- [ ] Add endpoint selection state in [SettingsSetupView.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/Settings/SettingsSetupView.swift).
- [ ] Resolve selected endpoint store via runtime registry in settings flow.
- [ ] Bind account panel to selected endpoint store in [CodexAccountSetupPane.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/Settings/CodexAccountSetupPane.swift).
- [ ] Refresh account on endpoint switch.
- [ ] Add UI tests or view-model tests for endpoint-switch correctness.

Exit criteria:

- [ ] Login/logout/cancel-login actions target the selected endpoint only.
- [ ] Account badge/email/plan update when endpoint selection changes.

### Phase 2: Server Usage Scope Support

Objective: Implement scope-aware usage reads in server transport.

Why this phase next:

- Client usage work depends on server support for `scope=endpoint_local`.

Tasks:

- [ ] Add usage scope query parsing in [server_meta.rs](/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/transport/http/server_meta.rs).
- [ ] Preserve current behavior for omitted scope.
- [ ] Route `scope=control_plane` through existing control-plane gating.
- [ ] Route `scope=endpoint_local` through endpoint-local usage probe path.
- [ ] Update usage error mapping in [usage_errors.rs](/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/support/usage_errors.rs) if new scoped error is needed.
- [ ] Update API reference in [API.md](/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/docs/API.md).

Exit criteria:

- [ ] `scope=endpoint_local` works on non-control-plane endpoints.
- [ ] Omitted scope still behaves exactly as before.

### Phase 3: Client Usage Scope Integration

Objective: Wire scope into Swift usage clients/services and render endpoint-local usage in settings.

Why this phase next:

- Depends on Phase 2 API behavior.

Tasks:

- [ ] Add scoped usage methods in [UsageClient.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Services/Server/API/UsageClient.swift).
- [ ] Keep existing global usage path in [UsageServiceRegistry.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Services/UsageServiceRegistry.swift).
- [ ] Add endpoint-local usage fetch path for Integrations endpoint context.
- [ ] Render endpoint-local usage section in settings account/integrations UI.
- [ ] Add tests for scope routing and UI state rendering.

Exit criteria:

- [ ] Settings show usage for selected endpoint regardless of control-plane role.
- [ ] Dashboard/status bar global usage behavior remains unchanged.

### Phase 4: Consistency, Docs, And Hardening

Objective: Finish cross-surface clarity and ship with confidence.

Why this phase next:

- Final labeling/docs/testing should happen once behavior is stable.

Tasks:

- [ ] Add explicit scope labels in usage/account UI where ambiguity is possible.
- [ ] Update [FEATURES.md](/Users/robertdeluca/Developer/OrbitDock/docs/FEATURES.md) and [README.md](/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/README.md) with scoped behavior.
- [ ] Run server + client regression checks.
- [ ] Add manual two-endpoint smoke checklist (Air/Pro style workflow).

Exit criteria:

- [ ] Docs reflect actual shipped behavior.
- [ ] Regression checklist passes.

## Files To Modify

Server:

- [ ] [server_meta.rs](/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/transport/http/server_meta.rs)
- [ ] [usage_errors.rs](/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/support/usage_errors.rs)
- [ ] [router.rs](/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/transport/http/router.rs) (only if route docs/comments need updates)
- [ ] [API.md](/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/docs/API.md)

Swift services:

- [ ] [UsageClient.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Services/Server/API/UsageClient.swift)
- [ ] [UsageServiceRegistry.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Services/UsageServiceRegistry.swift)

Swift UI:

- [ ] [SettingsSetupView.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/Settings/SettingsSetupView.swift)
- [ ] [CodexAccountSetupPane.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Views/Settings/CodexAccountSetupPane.swift)
- [ ] New endpoint-local usage panel file(s) under `/Views/Settings/` as needed

Docs:

- [ ] [FEATURES.md](/Users/robertdeluca/Developer/OrbitDock/docs/FEATURES.md)
- [ ] [README.md](/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/README.md)

## Implementation Order

- [ ] Complete Phase 0 contract freeze.
- [ ] Implement Phase 1 (endpoint-scoped account UX) and Phase 2 (server scope support) in parallel.
- [ ] Implement Phase 3 client scope integration after Phase 2 API merge.
- [ ] Complete Phase 4 consistency/docs/hardening.

## Parallel Work

| Lane | Owner | Scope | Can Start After | Integration Point |
|---|---|---|---|---|
| Worker A | Server | Scope-aware usage transport + API docs | Phase 0 | Server API contract merged |
| Worker B | Swift Services | Usage client/service scoped reads | Worker A contract stable | Usage surfaced to UI |
| Worker C | Swift UI | Endpoint selector + endpoint-scoped account and usage UX | Phase 0 | UI consumes Worker B APIs |
| Worker D | QA/Docs | End-to-end checks + doc updates | Phase 3 | Release-ready docs/checklists |

Coordination notes:

- [ ] Worker A and Worker C align on copy and scope labels before UI strings finalize.
- [ ] Worker B should not finalize without Worker A's error semantics.
- [ ] Merge order: A -> B -> C (or C partial, then finalize after B).

## Decision Log

| Date | Decision | Context | Owner | Status |
|---|---|---|---|---|
| 2026-04-07 | Use query param scope on existing usage endpoints | Avoid route sprawl, keep one resource contract, preserve defaults | Team | Resolved |

## Verification

Server checks:

- [ ] `make rust-check`
- [ ] `make rust-test`
- [ ] Validate `/api/usage/*` behavior for omitted scope, `control_plane`, and `endpoint_local`.

Swift checks:

- [ ] `make test-unit` (or targeted Swift test command for touched modules)
- [ ] Verify endpoint switching updates account state and actions.
- [ ] Verify endpoint-local usage renders for non-control-plane endpoint.
- [ ] Verify dashboard/status bar still show global control-plane usage.

Manual smoke:

- [ ] Configure two endpoints with different account states.
- [ ] Confirm per-endpoint login/logout/account details in Integrations.
- [ ] Confirm endpoint-local usage for each endpoint.
- [ ] Flip control-plane endpoint and confirm global usage follows control plane.

## Definition Of Done

- [ ] Endpoint account management is explicitly endpoint-scoped in settings.
- [ ] Usage endpoints support `scope` query with backward-compatible defaults.
- [ ] Endpoint-local usage is visible in endpoint management UX.
- [ ] Global usage remains control-plane-routed and clearly labeled.
- [ ] Tests and manual smoke checks pass.
- [ ] API/product docs are updated.
