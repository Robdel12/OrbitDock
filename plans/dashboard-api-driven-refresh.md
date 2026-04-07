# Dashboard Attention Refresh Plan

Date: 2026-04-05
Owner: Codex
Status: Draft

## 1. Why This Change
- Problem: The native dashboard route fails to surface approval-needed sessions in real time; users only see stale attention states after a manual reload.
- Why now: The rest of the client already follows the `CLIENT_DESIGN_PRINCIPLES.md` flow (HTTP snapshot + WS-triggered refresh). Dashboard is the outlier and is blocking approvals triage.
- User/business impact: Missed attention flags mean approvals age out, creating risk for deployments and human-in-the-loop SLAs.
- Cost of not changing: Continued dashboard blindness plus duplicated logic that will diverge further as soon as we tighten the server contract again.

## 2. Goals And Non-Goals
### Goals
- [ ] Dashboard view model owns all dashboard state via HTTP snapshots from each enabled runtime.
- [ ] Route-scoped WS subscriptions refresh dashboard data within one second of `dashboard_invalidated` without global stores.
- [ ] Approvals or status transitions emit `dashboard_invalidated` on the server so every client stays consistent.
- [ ] Automated coverage proves we don’t regress (Swift unit test + Rust integration test).

### Non-Goals
- [ ] No rewrite of Mission Control or other routes beyond wiring their existing view models to the updated dashboard data source.
- [ ] No resurrection of `DashboardProjectionStore` or any other global projection as a workaround.
- [ ] No speculative UI redesign of Mission Control panes; focus stays on data flow.
- [ ] No polling timers or client-side heuristics for “needs attention.”

## 3. Current State
- Architecture/data flow summary: `DashboardViewModel` (`OrbitDockNative/OrbitDock/Views/Dashboard/Scene/DashboardViewModel.swift`) bootstraps via HTTP, then relies on `ServerRuntimeRegistry` listeners for `.dashboardInvalidated` before issuing another fetch. The registry itself keeps a global projection (`DashboardProjectionStore`) fed by HTTP snapshots it fetches whenever invalidations arrive from `ServerConnection`.
- Pain points:
  - WS is subscribed at the registry level even when the dashboard route is hidden, violating route ownership.
  - Only `.dashboardInvalidated` triggers a refresh, so approval events that fail to emit that signal never reach the dashboard.
  - Multiple runtimes cause redundant serial refreshes without revision guards, so long fetches race each other and temporarily erase attention badges.
- Constraints:
  - Must honor `docs/CLIENT_DESIGN_PRINCIPLES.md`: per-route HTTP ownership, WS as refresh hints only, zero shared mutable stores.
  - Mission Control route must stay decoupled; dashboard route cannot “help” other routes via shared objects.
  - Multi-endpoint deployments must remain supported without starving the UI.

## 4. Proposed Architecture
- System boundaries: Server remains the single source of truth. Each enabled runtime exposes its `SessionStore` + `ServerConnection`, and the dashboard route alone will subscribe/unsubscribe to `subscribe_dashboard` while it is on screen.
- Data model / API changes: No schema change; we only ensure the server always calls `publish_dashboard_snapshot()` whenever approvals or session triage states change, so every event causes a `dashboard_invalidated`.
- Control flow:
  1. `DashboardView` appears → `DashboardViewModel.bind(...)` captures runtimes and kicks off concurrent `fetchDashboardSnapshot()` calls, storing `revision` per endpoint.
  2. View model starts a lightweight `AsyncStream` per endpoint that listens for `ServerEvent.dashboardInvalidated`, `ServerEvent.sessionEnded`, or `ServerEvent.approvalRequested` and coalesces them into a debounced `refreshDashboardData(endpointId:)`.
  3. When dashboard disappears, all per-endpoint listeners and subscriptions are torn down to satisfy the “no global projection” rule.
  4. Filters (`DashboardConversationDeckPlanner`) continue to derive presentation-only artifacts from the latest server snapshots—no client inference.
- Migration strategy:
  - Keep `ServerRuntimeRegistry`’s projection alive for status bar/quick switcher until those surfaces are ported; but remove dashboard’s dependence on it now.
  - Gate the new route-scoped binder behind a feature flag or environment default (`DashboardRealtimeMode.apiDriven`) so we can flip back if we discover missing events during rollout.

## 5. Alternatives Considered
1. Reuse `DashboardProjectionStore` for the dashboard route.
   - Pros: Fewer code changes.
   - Cons: Violates doc guardrails, keeps WS subscriptions global, doesn’t fix stale states because the projection refresh path has the same invalidation gap.
   - Why rejected: User explicitly forbade “weird global state.”
2. Periodic HTTP polling every N seconds.
   - Pros: Simple to implement.
   - Cons: Wastes bandwidth, adds latency, still misses bursts if server throttles.
   - Why rejected: Goes against “WS events trigger refresh” doctrine.
3. Push full dashboard snapshots over WS and apply them client-side.
   - Pros: Removes HTTP refetch.
   - Cons: Requires new server protocol work and larger WS payloads; not needed for this fix.
   - Why rejected: Out of scope and contradicts today’s contract.

## 6. Risks And Mitigations
| Risk | Impact | Mitigation | Owner |
|---|---|---|---|
| Server code paths forget to call `publish_dashboard_snapshot()` (e.g., some approval flows) | High | Audit every approval/status mutation file in `orbitdock-server/crates/server/src/runtime` and add tests that assert the broadcast happens | Server |
| Multiple endpoints fire invalidations simultaneously causing refresh storm | Medium | Add per-endpoint refresh debounce + revision guard in `DashboardViewModel` | Client |
| Route toggles quickly, leaving dangling WS subscriptions | Medium | Keep cancellables tied to a `Task` bag keyed by `UUID` and clear them in `setRealtimeUpdatesEnabled(false)` | Client |
| Build failures/regressions harder to diagnose | Low | On every failing build/test, capture a short summary (command, decision, status) as part of test logging so we satisfy the “Need summary after build failure” request | Both |

## 7. Phased Execution Plan

### Phase 1: Instrument And Confirm Contract
Objective: Reproduce the stale dashboard flow and capture whether `dashboard_invalidated` is missing.
Dependencies: None.
Exit Criteria:
- [ ] Repro steps documented with timestamps showing missing refresh.
- [ ] Temporary logging in `DashboardViewModel.shouldRefreshDashboard` confirms event mix per endpoint.
Tasks:
- [ ] Add structured logging (behind `#if DEBUG`) in `OrbitDockNative/OrbitDock/Views/Dashboard/Scene/DashboardViewModel.swift` to capture incoming server events and queued refreshes.
- [ ] Trigger approval-needed sessions locally and note whether `ServerRuntimeRegistry` receives `dashboardInvalidated`.
- [ ] Share findings so server/client owners agree on whether the bug is in event emission or client listening.

### Phase 2: Server Invalidations Are Authoritative
Objective: Guarantee every triage-changing transition emits `dashboard_invalidated`.
Dependencies: Phase 1 observations.
Exit Criteria:
- [ ] Audit checklist for `publish_dashboard_snapshot` callers is complete.
- [ ] Integration test under `orbitdock-server/crates/server/src/transport/http/session_lifecycle.rs` proves approvals cause an invalidation.
Tasks:
- [ ] Grep for approval/resume/takeover code paths (e.g., `orbitdock-server/crates/server/src/runtime/session_mutations.rs`) and insert missing `state.publish_dashboard_snapshot()` when absent.
- [ ] Extend the websocket handler test suite to assert that `approvalRequested` is accompanied by `dashboard_invalidated`.
- [ ] Document the contract in `docs/data-flow.md` so future changes keep emitting the signal.

### Phase 3: Client Route Owns Dashboard State
Objective: Dashboard view model uses HTTP snapshots + route-scoped WS listeners only.
Dependencies: Server guarantees from Phase 2.
Exit Criteria:
- [ ] Dashboard route no longer references `DashboardProjectionStore`.
- [ ] `DashboardView` subscribes/unsubscribes WS bindings strictly when `.dashboard` is visible.
- [ ] Refreshes are debounced per endpoint and deduped by revision.
Tasks:
- [ ] Introduce a helper (e.g., `DashboardRealtimeBinder`) under `OrbitDockNative/OrbitDock/Views/Dashboard` that wraps `ServerRuntime.connection.addListener` and lifetime-scopes tokens.
- [ ] Update `DashboardViewModel.refreshDashboardData()` to store the latest `revision` returned by each runtime and skip applying stale payloads.
- [ ] Replace the existing `realtimeUpdatesEnabled` flag with a `.task(id:)` driven binding that starts/stops listeners when `router.route` toggles.
- [ ] Ensure mission-control components (e.g., `ProjectNavigator`) read from view model state, not global stores.

### Phase 4: Validation & Regression Suite
Objective: Prove the flow works and remains API-driven.
Dependencies: Phases 1-3.
Exit Criteria:
- [ ] Swift unit/UI test that simulates `dashboardInvalidated` and verifies `filteredDashboardConversations` updates.
- [ ] Rust integration test covering approval invalidations.
- [ ] Manual QA checklist complete (multi-endpoint, offline mode, mission control unaffected).
Tasks:
- [ ] Add a Swift test under `OrbitDockNative/OrbitDockTests/Dashboard` that feeds a fake runtime + mocked events into `DashboardViewModel`.
- [ ] Extend server CLI smoke test to check `dashboard_invalidated` after triggering an approval.
- [ ] Run `make build && npm test` (or platform equivalents) and log “summary after build failure” if anything fails.

## 8. Parallel Worker Lanes
| Lane | Owner | Scope | Can Start After | Integration Point |
|---|---|---|---|---|
| A: Server invalidation sweep | Server engineer | Audit + patch `publish_dashboard_snapshot` callers and add tests | Phase 1 findings | Provides guaranteed events for the client |
| B: Client dashboard binder | Client engineer | Instrument dashboard view model, add per-route listeners, remove global dependencies | Immediately (instrumentation from Phase 1 can be shared) | Merges once server guarantees exist; still safe with old server because HTTP fallback remains |

### Coordination Notes
- Shared contract: HTTP snapshot + `dashboard_invalidated` triggers.
- Merge order: Server (Lane A) ideally lands first, but client code must tolerate old servers by logging when invalidations are missing.
- Conflict risks: Both lanes touch `docs/data-flow.md`; coordinate edits.

## 9. Validation Plan
- Unit/integration/e2e strategy: Swift unit tests for view model, Rust transport tests for invalidations, manual multi-endpoint smoke.
- Commands:
  - `make test-unit` in `orbitdock-server` after server changes.
  - `xcodebuild -project OrbitDock/OrbitDock.xcodeproj -scheme OrbitDock -destination "platform=macOS" test` for client unit tests.
- [ ] Record a short failure summary (command + key decisions/status) whenever either command fails.
- [ ] Manual QA: start dashboard, trigger approval, confirm attention badge flips without manual refresh.

## 10. Rollout And Rollback
- Rollout sequence: land server invalidation fix → land client binder guarded by feature flag → enable flag for internal testers → widen to all users.
- Monitoring/alerts: watch logs for “dashboard invalidation missing” warnings; track approval latency metrics.
- Rollback trigger: dashboard shows stale data or WS reconnect loops.
- Rollback steps: disable the feature flag to fall back to the existing registry-driven refresh while investigating.

## 11. Decision Log
| Date | Decision | Context | Owner | Status |
|---|---|---|---|---|
| 2026-04-05 | Route reclaims dashboard subscription + refresh ownership | Align with CLIENT_DESIGN_PRINCIPLES and user direction to avoid global state | Codex | Resolved |

## 12. Immediate Next Actions
- [ ] Capture repro logs for a missed approval invalidation — Owner: Client eng — Due: 2026-04-06.
- [ ] Audit approval-related server paths for `publish_dashboard_snapshot()` coverage — Owner: Server eng — Due: 2026-04-06.
- [ ] Draft the `DashboardRealtimeBinder` scaffolding (no functional change yet) — Owner: Client eng — Due: 2026-04-07.
