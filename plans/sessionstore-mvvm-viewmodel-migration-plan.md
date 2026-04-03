# SessionStore MVVM Decomposition Plan

Date: 2026-04-03
Owner: OrbitDock Native Team
Status: Complete (Phase 1-4 Complete)

## 1. Why This Change
- Problem:
  - `SessionStore` is still the central coordinator for transport wiring, event fanout, mutable app state, and mutation commands.
  - Several SwiftUI screens still read `SessionStore` directly from environment, which couples UI behavior to a broad global object.
- Why now:
  - Session data-layer refactor is complete enough that native-layer ownership can now be split without changing server contracts.
  - We already marked `SessionStore` as frozen/legacy and need to enforce that with architecture, not just comments.
- User/business impact:
  - Lower regression risk when adding features.
  - Faster onboarding and easier ownership by feature teams.
  - Better testability with narrower view model responsibilities.
- Cost of not changing:
  - `SessionStore` remains a long-term bottleneck and accidental sink for new feature logic.
  - Every UI change risks unrelated behavior in other surfaces.

## 2. Goals And Non-Goals
### Goals
- [x] Move remaining direct `SessionStore`-driven UI surfaces to dedicated feature view models.
- [x] Keep architecture as plain SwiftUI MVVM (`@Observable` + focused services/view models), no reducer framework.
- [x] Shrink `SessionStore` to transport coordination and session-observable access only.
- [x] Define a sequenced path to remove `SessionStore` as a central coordinator.

### Non-Goals
- [ ] Rewriting server contracts or websocket protocol behavior.
- [ ] Introducing external architecture frameworks.
- [ ] Reworking dashboard projection store and registry topology in this tranche.

## 3. Current State
- Architecture/data flow summary:
  - `ServerRuntime` owns transport and clients; `SessionStore` receives events and mutates `SessionObservable`/global state.
  - Feature view models now own the migrated capabilities/worktree/settings lanes and consume `SessionStore` through explicit injection.
- Pain points:
  - Feature UI logic and transport-state concerns are mixed.
  - Global `SessionStore` methods expose broad command surface to many views.
  - Event switch remains broad and easy to grow.
- Constraints:
  - Preserve current behavior and visual output.
  - Keep ws/http readiness model unchanged.
  - Maintain iOS/macOS parity.

## 4. Proposed Architecture
- System boundaries:
  - `SessionStore` (legacy shell): connection listener, session subscription lifecycle, hydration/recovery.
  - Feature view models: own presentation state and user actions for one screen/surface.
  - Feature services (thin wrappers): typed calls for capabilities/worktrees/account operations.
- Data model / API changes:
  - No wire-contract changes.
  - New local view model structs/classes only.
- Control flow:
  - View binds to feature view model.
  - View model reads narrow `SessionObservable` snapshots and calls narrow service methods.
  - `SessionStore` remains an injected dependency, but only behind feature view model boundaries.
- Migration strategy:
  - Start with disjoint surfaces that currently use environment `SessionStore` directly.
  - Validate each slice with compile + behavioral smoke checks.
  - Continue moving command and event-specific logic from store extensions into feature-owned modules.

## 5. Alternatives Considered
1. Introduce reducer/store architecture everywhere
- Pros:
  - Strong event/state discipline.
- Cons:
  - Team preference mismatch.
  - Larger conceptual migration cost.
- Why rejected:
  - Explicitly not desired; plain MVVM is the target.

2. Keep `SessionStore` and only add comments/guardrails
- Pros:
  - Minimal code churn.
- Cons:
  - Does not enforce ownership boundaries.
- Why rejected:
  - Does not actually reduce coordinator risk.

3. Big-bang rewrite away from `SessionStore`
- Pros:
  - Fastest theoretical end-state.
- Cons:
  - High break risk and difficult review.
- Why rejected:
  - Incremental feature-lane migration is safer and testable.

## 6. Risks And Mitigations
| Risk | Impact | Mitigation | Owner |
|---|---|---|---|
| View model extraction changes behavior subtly | High | Keep UI behavior parity checks and focused smoke tests per screen | Native UI |
| Ownership overlap during parallel edits | Medium | Disjoint lane file ownership and explicit merge order | Migration lead |
| Hidden dependencies on environment `SessionStore` | Medium | Audit with `rg` and migrate one surface at a time | Native UI |
| Regressions in session/event update flow | Medium | Keep data sourcing on `SessionObservable` unchanged in early phases | Runtime team |

## 7. Phased Execution Plan

### Phase 1: Disjoint View Model Extraction
Objective: Remove direct environment `SessionStore` usage from high-churn surfaces.
Dependencies: None
Exit Criteria:
- [x] Capabilities views use dedicated view models.
- [x] Worktree list view uses a dedicated view model.
- [x] Settings Codex account pane uses a dedicated view model.
Tasks:
- [x] Add `CapabilitiesSkillsViewModel` and bind in `OrbitDockNative/OrbitDock/Views/Sessions/Capabilities/SkillsTab.swift`.
- [x] Add `McpServersViewModel` and bind in `OrbitDockNative/OrbitDock/Views/Sessions/Capabilities/McpServersTab.swift`.
- [x] Add `WorktreeListViewModel` and bind in `OrbitDockNative/OrbitDock/Views/Worktrees/WorktreeListView.swift`.
- [x] Add `CodexAccountSetupViewModel` and bind in `OrbitDockNative/OrbitDock/Views/Settings/CodexAccountSetupPane.swift` and `OrbitDockNative/OrbitDock/Views/Settings/SettingsSetupView.swift`.
- [x] Validate compilation for touched native target.

### Phase 2: Command Surface Extraction
Objective: Move feature-specific command methods out of `SessionStore+Commands` into feature services.
Dependencies: Phase 1
Exit Criteria:
- [x] Capabilities/worktree/account commands are no longer called directly from `SessionStore` in feature view models.
Tasks:
- [x] Add `CapabilitiesService`, `WorktreeService`, and `CodexAccountService` under `OrbitDockNative/OrbitDock/Services/Server/`.
- [x] Migrate corresponding methods from `SessionStore+Commands.swift` consumers to these services.
- [x] Keep `SessionStore+Commands.swift` as a compatibility shim only where still needed.

### Phase 3: Event Fanout Decomposition
Objective: Split large event router into focused, feature-owned handlers.
Dependencies: Phase 2
Exit Criteria:
- [x] `SessionStore+Events.swift` delegates to feature handlers rather than owning business mutations directly.
Tasks:
- [x] Extract capabilities/missions/worktree/account event handling helpers.
- [x] Keep `routeEvent` as dispatch-only wiring.
- [x] Add lightweight tests/smoke checks for extracted handlers.

### Phase 4: Coordinator Finalization
Objective: Make `SessionStore` non-central and remove remaining cross-domain coordination.
Dependencies: Phase 3
Exit Criteria:
- [x] New feature work no longer needs `SessionStore` edits.
- [x] Remaining responsibilities are transport lifecycle + session observable registry only.
Tasks:
- [x] Audit all direct `SessionStore` UI references and migrate remaining surfaces.
- [x] Trim public API surface on `SessionStore`.
- [x] Update architecture docs to reflect final ownership.

## 8. Parallel Worker Lanes
| Lane | Owner | Scope | Can Start After | Integration Point |
|---|---|---|---|---|
| Worker A | Native UI | `SkillsTab` + `McpServersTab` view model extraction | Immediate | Merge into capabilities folder + verify UI parity |
| Worker B | Native UI | `WorktreeListView` view model extraction | Immediate | Merge into worktrees folder + verify actions |
| Worker C | Native UI | `CodexAccountSetupPane` + settings view model extraction | Immediate | Merge into settings folder + verify auth actions |
| Worker D | Native UI | SessionStore API pruning + NewSessionSheet store ownership cleanup + architecture docs | Phase 3 | Merge into server/services + new session + docs; run consolidated build/tests |

### Coordination Notes
- Shared contracts:
  - `SessionObservable` read model remains source of truth.
  - Existing `SessionStore` command methods remain callable during this phase.
- Merge order:
  - A, B, C can merge in any order; run one consolidated build afterward.
- Conflict risks:
  - Avoid editing shared design tokens/utilities unless required.

## 9. Validation Plan
- Unit/integration/e2e strategy:
  - Compile-level validation plus manual smoke checks on capabilities/worktrees/settings surfaces.
- Commands:
- [x] `xcodebuild -project OrbitDockNative/OrbitDock.xcodeproj -scheme OrbitDock -destination 'platform=macOS' build`
- [x] `xcodebuild -project OrbitDockNative/OrbitDock.xcodeproj -scheme OrbitDock -destination 'platform=macOS' -only-testing:OrbitDockTests/SessionStoreControlStateSyncTests test`
- [x] `xcodebuild -project OrbitDockNative/OrbitDock.xcodeproj -scheme OrbitDock -destination 'platform=macOS' -only-testing:OrbitDockTests/CodexAccountRefreshPolicyTests test`
- [ ] `make rust-test`
- [ ] Manual smoke: capabilities refresh actions, worktree discover/create/remove, codex account sign-in/out controls.

## 10. Rollout And Rollback
- Rollout sequence:
  - Ship phase slices behind existing UI paths without feature flags.
- Monitoring/alerts:
  - Watch client logs for settings/capabilities/worktree action failures.
- Rollback trigger:
  - Compile regressions or behavior parity failures in migrated surfaces.
- Rollback steps:
  - Revert individual slice commits (A/B/C) independently due disjoint ownership.

## 11. Decision Log
| Date | Decision | Context | Owner | Status |
|---|---|---|---|---|
| 2026-04-03 | Use plain SwiftUI MVVM, no reducer architecture | Team preference and lower migration overhead | Robert + Codex | Resolved |
| 2026-04-03 | Execute migration in disjoint parallel UI lanes | Faster progress with low merge conflict risk | Codex | Resolved |
| 2026-04-03 | Keep `SessionStore` as temporary shell during migration | Preserve transport stability while extracting ownership | Codex | Resolved |

## 12. Immediate Next Actions
- [x] Execute Worker A lane (Capabilities view models) — Owner: Codex Worker A — Due: 2026-04-03
- [x] Execute Worker B lane (Worktree view model + worktree/mission event handlers) — Owner: Codex Worker B — Due: 2026-04-03
- [x] Execute Worker C lane (Settings account view model + codex account service/events) — Owner: Codex Worker C — Due: 2026-04-03
- [x] Integrate, build, and run focused session/codex tests — Owner: Codex Main — Due: 2026-04-03
- [x] Migrate remaining direct `@Environment(SessionStore.self)` UI surface (`NewSessionSheet`) to explicit injected store ownership — Owner: Native UI — Due: 2026-04-03
- [x] Prune legacy compatibility shims from `SessionStore` after migrated consumers moved — Owner: Native UI — Due: 2026-04-03
- [x] Update client architecture docs with final ownership map for services/view models/event handlers — Owner: Native UI — Due: 2026-04-03

## 13. Completion Notes (2026-04-03)
- Removed direct `@Environment(SessionStore.self)` usage from migrated surfaces; dependencies are now explicitly injected.
- Added focused feature services (`CapabilitiesService`, `WorktreeService`, `CodexAccountService`) and moved feature callers to those boundaries.
- Decomposed event fanout into focused handlers (`SessionStore+CapabilitiesEvents`, `+WorktreeEvents`, `+MissionEvents`, `+CodexAccountEvents`) with `routeEvent` staying dispatch-focused.
- Pruned legacy SessionStore compatibility methods that no longer had active callers.
- Added architecture guardrail docs:
  - `docs/SWIFT_CLIENT_ARCHITECTURE.md`
  - `docs/CLIENT_DESIGN_PRINCIPLES.md`
