# Boring REST + WebSocket Native/API Refactor

Date: 2026-04-14
Status: Active
Owners: Native client + Rust server
Supersedes:
- `plans/native-app-architecture-cleanup.md`
- `plans/global-surface-runtime-refactor-2026-04-13.md`

## Status Workflow

Allowed statuses for this plan:

- `Active` — refactor is still in progress
- `Blocked` — a hard blocker prevents safe forward progress
- `Verification` — implementation is complete and we are only proving it out
- `Done` — all completion gates below are satisfied

This plan does not move to `Done` because the app feels better or because a few big bugs are gone.

It moves to `Done` only when every phase exit criterion, every testing gate, and every final completion gate is checked off.

## Why This Plan Exists

We are still carrying too much architecture debt from the first month of the app.

The app is conceptually simple:

- the server owns durable truth
- the client makes normal HTTP requests for snapshots, pagination, and mutations
- WebSocket only handles light realtime follow-up, replay, heartbeats, and explicit refetch hints

What we have today is only partway through that refactor.

We did remove some of the worst patterns, but the current codebase still has enough mixed ownership, eager startup work, and shared runtime reach-through that we are still seeing the same class of bugs:

- blank or stale conversation/detail surfaces
- rows disappearing until a view switch forces a re-read
- duplicate or mistimed refresh work
- cold surfaces loading too eagerly
- global startup paths doing too much work
- test runs exposing runaway startup and memory behavior

This plan exists to stop doing incremental cleanup against bad architecture and instead finish the delete-and-replace refactor all the way through.

## Non-Negotiables

1. HTTP owns bootstrap, pagination, and authoritative mutation responses.
2. WebSocket owns only light realtime follow-up, replay, heartbeats, and resync hints.
3. The Rust server owns durable business truth.
4. The native app renders server state through explicit scene and surface owners.
5. No god objects. No broad shared product-state stores. No legacy compatibility shims.
6. Cold surfaces stay cold. They do not load at app launch unless visible.
7. App startup must stay minimal, explicit, and cheap.
8. Tests must verify real user outcomes and must never require booting the full production app for plain unit coverage.

## Current Honest Status

Latest verification on 2026-04-14:

- `make rust-ci` passes
- `make test-unit` passes
- native unit coverage is hostless and no longer boots the production app runtime
- the latest native failure exposed a real library refresh-queue bug, and that bug is now fixed

### Done enough to keep

- [x] `SessionStore` was removed and replaced with `ServerSessionContext`, `ServerSessionAPI`, and `ServerSessionTransport`.
- [x] Control-deck-specific server/API plumbing was deleted.
- [x] Dashboard and library were split apart at the contract level.
- [x] Control-plane and library invalidation contracts exist on both server and native sides.
- [x] Conversation bootstrap/persistence race handling improved on the server.
- [x] Mac unit tests are no longer allowed to be app-hosted by default.
- [x] A hard XCTest app-start guard exists so test runs cannot silently boot the full app runtime again.

### Still not acceptable

- [ ] App startup still owns too much and starts too much shared work.
- [ ] Global surfaces still reach into shared runtime/data paths too freely.
- [ ] Mission list and mission detail are not yet fully boring and surface-local.
- [ ] Some session surfaces still rely on broader invalidation than they should.
- [ ] The native app still has too many eager refresh paths and too much lifecycle-driven work.
- [ ] Tests are not yet aligned tightly enough to the new architecture slices.
- [ ] The current worktree is too large and mixed to treat as production-ready without another cleanup pass.

## Target Architecture

### App shell

The app shell owns only:

- endpoint/runtime startup
- compact global control-plane state
- routing
- notification plumbing
- focus/background coordination

The app shell does not own:

- library pages
- dashboard conversations
- mission detail payloads
- selected session feature state

### Global surfaces

Each global surface gets one owner and one contract.

| Surface | HTTP authority | WS follow-up | Owner |
| --- | --- | --- | --- |
| Control plane | `GET /api/control-plane` | `control_plane_invalidated(revision)` | app shell summary service |
| Dashboard | `GET /api/dashboard` | `dashboard_invalidated(revision)` or tiny row deltas | dashboard surface model |
| Library | `GET /api/library?limit&offset...` | `library_invalidated(revision)` | library surface model |
| Missions list | `GET /api/missions` | `missions_invalidated(revision)` | mission list surface model |
| Mission detail | `GET /api/missions/{id}` | `mission_invalidated(id, revision)` and optional heartbeat | mission detail surface model |

### Session surfaces

Each session surface gets one owner and one contract.

| Surface | HTTP authority | WS follow-up | Owner |
| --- | --- | --- | --- |
| Session detail shell | `GET /api/sessions/{id}/detail` | detail invalidation | session detail scene/view model |
| Conversation | `GET /api/sessions/{id}/conversation` + page API | row deltas + conversation resync hints | conversation view model |
| Review | `GET /api/sessions/{id}/review` | review invalidation | review view model |
| Skills | `GET /api/sessions/{id}/skills` | capabilities invalidation | skills view model |
| MCP | `GET /api/sessions/{id}/mcp` | capabilities invalidation | MCP view model |
| Control deck UI | composed from detail + conversation + workflow endpoints | detail invalidation only where needed | control-deck view model |

## What Must Be Deleted

### Native client

- [ ] Delete any remaining startup path that eagerly loads dashboard, library, mission, or session data just because the app launched.
- [ ] Delete any remaining shared service that owns multiple unrelated product surfaces.
- [ ] Delete view-driven duplicate bootstrap flows for the same surface.
- [ ] Delete broad invalidation usage where a surface-specific contract exists.
- [ ] Delete remaining placeholder, fallback, or compatibility behavior that keeps old state patterns alive.
- [ ] Delete any test that boots the full app to validate pure logic behavior.

### Rust server / API

- [ ] Delete any remaining endpoint shape that leaks UI component naming or mixed-surface payloads.
- [ ] Delete mission APIs that bundle too much unrelated state into one response.
- [ ] Delete broad WS session events that make the client infer feature state instead of refetching a surface.
- [ ] Delete compatibility branches and deprecated transport code once the new endpoints are the only path.

## Phase 1: Freeze and Simplify App Startup

Why first: if startup is still heavy, every other architecture decision remains hard to trust.

### Goals

- the app shell starts only connection/runtime essentials
- no cold-surface bootstrap at launch
- no menu bar or scene path triggers broad refresh storms implicitly
- XCTest launch stays inert and cheap

### Work

- [x] Audit every app-shell `.task`, `.onAppear`, `.onChange`, and startup coordinator path.
- [x] Keep startup ownership in one place only.
- [x] Remove any duplicate `startIfNeeded()` reach-through patterns that are not needed.
- [ ] Keep control-plane startup summary-sized and dashboard/library/missions out of app launch.
- [x] Ensure menu bar reads compact control-plane state only and never becomes a side-door bootstrap for larger surfaces.
- [x] Add small targeted regression tests for startup behavior without booting the full app.

### Exit criteria

- [x] App launch does not fetch library pages.
- [x] App launch does not fetch mission lists or mission detail unless visible.
- [ ] Global summary state is the only app-shell product data loaded eagerly.
- [x] Unit tests can cover startup orchestration without creating a production app process.

## Phase 2: Finish Global Surface Rewrite

Why next: dashboard, library, and global attention are still where too much data and ownership complexity live.

### Goals

- each global surface owns exactly one HTTP bootstrap path and one WS follow-up path
- library is fully on-demand
- notifications/attention do not depend on library-sized state

### Work

- [x] Finish `ControlPlaneDataService` as a compact app-shell summary owner only.
- [x] Shrink `DashboardDataService` so it is dashboard-only and active-work-only.
- [x] Finish `LibraryDataService` as a cold, paginated, library-only owner.
- [ ] Replace any remaining notification baseline logic that still depends on tracked full session arrays where control-plane summary should own it.
- [ ] Review quick switcher, menu bar, sidebar, and overview usage so each reads the right owner instead of whichever shared service is convenient.
- [x] Add service-level tests for control plane, dashboard, and library focused on user-visible outcomes.

### Exit criteria

- [x] Dashboard and library can be reasoned about independently.
- [x] Library loads only when the library or quick-switch surface explicitly needs it.
- [x] Notification/attention state no longer depends on archive-sized data.
- [ ] Switching among dashboard/library views does not leave stale or blank state behind.

## Phase 3: Replace Missions End To End

Why next: missions still look like old architecture and should be one of the simplest boring REST+WS surfaces in the app.

### Goals

- missions list and mission detail are separate surfaces
- mission detail owns its own refresh path
- no runtime-global mission observable cache remains

### Work

- [ ] Finalize `GET /api/missions` as a lightweight index payload only.
- [ ] Finalize `GET /api/missions/{id}` as the sole mission detail bootstrap.
- [x] Keep mission WS follow-up to `missions_invalidated(revision)`, `mission_invalidated(id, revision)`, and optional heartbeat only.
- [ ] Delete any remaining `MissionObservable`-style or registry-owned mission product state.
- [x] Refactor native mission list/detail owners to use only those contracts.
- [x] Add integration-style tests for mission list invalidation and mission detail resync.

### Exit criteria

- [ ] Mission list does not own mission detail data.
- [ ] Mission detail does not depend on list refresh to stay correct.
- [ ] Mission refreshes are narrow, cheap, and obvious.

## Phase 4: Finish Session Surface Contract Cleanup

Why next: the session refactor is partly done, but lingering broad invalidation still creates fragility.

### Goals

- every visible session surface has one bootstrap path and one follow-up path
- mutation responses are applied immediately
- reconnect and replay stay transport-only and boring

### Work

- [ ] Audit detail, conversation, review, skills, MCP, and control-deck screens for duplicate bootstrap work.
- [ ] Remove remaining broad session invalidation where a narrower surface-specific refresh exists.
- [ ] Keep `ServerSessionTransport` focused on subscriptions, revisions, and invalidation only.
- [ ] Keep `ServerSessionAPI` focused on surface bootstraps and authoritative mutation responses only.
- [ ] Delete any remaining UI-state or feature-state leakage into session transport/runtime types.
- [ ] Add regression tests for session switching, reconnect, and visible-surface refresh behavior.

### Exit criteria

- [ ] Switching sessions does not require view re-entry to become correct.
- [ ] Mutation responses update visible state immediately.
- [ ] Realtime follow-up never serves as a hidden bootstrap path.
- [ ] Session transport code reads like infrastructure, not product state.

## Phase 5: Code Simplifier + Commit Slicing Pass

Why last: the architecture should be correct first, then we make it smaller, cleaner, and easier to maintain.

### Work

- [x] Run a code-simplifier pass across recently replaced native services and server transport modules.
- [ ] Delete dead helpers, old comments, stale TODOs, and no-longer-needed mappers.
- [ ] Collapse naming drift so surfaces, endpoints, and services use the same boring vocabulary.
- [ ] Split the large worktree into focused commits by architecture slice.
- [ ] Update docs to reflect the final contracts only after code is settled.

### Exit criteria

- [ ] No dead compatibility code remains for removed architecture.
- [ ] Core files read like the target model from `docs/ARCHITECTURE.md` and `docs/data-flow.md`.
- [ ] The branch can be reviewed in coherent commits instead of one giant blob.

## Testing Philosophy For This Refactor

### Required

- [x] Prefer logic/service tests over app-hosted unit tests.
- [ ] Mock only network boundaries, time, or randomness.
- [ ] Test outcomes users care about: visible data correctness, refresh timing, no stale state, no duplicate fetch storms.
- [ ] Keep transport tests focused on revisions, subscriptions, replay, and invalidation semantics.
- [ ] Keep API tests focused on contract shape and authoritative mutation responses.

### Explicitly not allowed

- [x] No broad snapshot-the-whole-app tests for unit coverage.
- [x] No arbitrary sleeps.
- [x] No tests that pass only because the app booted and eventually settled.
- [ ] No internal mocking that hides ownership bugs.

### Verification gates

Do not run broad expensive suites until the current phase is structurally safe.

For each phase:

- [ ] run the smallest targeted native tests that prove the slice
- [ ] run the smallest targeted Rust tests that prove the slice
- [ ] only after the slice is stable, run repo-level gates (`make rust-ci`, `make test-unit`)

## Production-Ready Definition Of Done

We are done when all of this is true:

- [ ] app startup is cheap and explicit
- [ ] global surfaces are separate and boring
- [ ] missions are separate and boring
- [ ] session surfaces are separate and boring
- [ ] HTTP is the only bootstrap/heavy-read path
- [ ] WebSocket is only follow-up/replay/resync hint transport
- [ ] there are no god objects and no legacy compatibility layers left
- [ ] tests reflect user-facing correctness instead of implementation accidents
- [x] full repo verification passes without runaway memory or app-hosted unit surprises

## Final Completion Gates

This refactor is only firmly done when every item in this section is true.

### Architecture

- [ ] App startup is minimal and only owns runtime/bootstrap essentials.
- [ ] Control plane, dashboard, library, missions list, mission detail, and session surfaces all have distinct owners.
- [ ] Every surface has one HTTP bootstrap path and one WS follow-up path.
- [ ] No cold surface is eagerly loaded at app launch.
- [ ] No shared service owns multiple unrelated product surfaces.
- [ ] No legacy compatibility branches remain for removed client or API architecture.

### API and transport

- [ ] The server API shape matches the boring REST model described in this plan.
- [ ] Mutation responses are authoritative and applied immediately by the client.
- [ ] WebSocket traffic is limited to light deltas, replay, heartbeats, and refetch hints.
- [ ] The client no longer infers durable product truth from broad WS state or mixed transport side effects.

### Native behavior

- [ ] Conversations, dashboard, library, missions, and session detail all load correctly on first view without requiring a view switch workaround.
- [ ] Session switching does not cause blank, stale, or cross-session state leaks.
- [ ] Reconnect/recovery does not duplicate, drop, or temporarily wipe visible state.
- [ ] Menu bar, quick switcher, sidebar, and notifications read from the correct compact owners and do not create hidden bootstrap work.

### Testing and verification

- [x] Targeted native tests exist for startup, control plane, dashboard, library, missions, and session transport/surface behavior.
- [x] Targeted Rust tests exist for the new surface endpoints and WS invalidation/replay contracts.
- [x] `make rust-ci` passes.
- [x] `make test-unit` passes.
- [x] No test path boots the full production app for plain unit coverage.
- [x] No verification step causes runaway memory or pathological process growth.

### Cleanup and reviewability

- [ ] Dead files, dead helpers, dead endpoints, and dead protocol contracts from the old architecture are deleted.
- [ ] Docs match the final implementation.
- [ ] The worktree is sliced into coherent commits instead of one unreviewable blob.
- [ ] This plan file is updated to reflect the final state and its `Status` is changed to `Done`.

## Sign-Off Rule

If any item in `Still not acceptable`, any phase exit criteria, any verification gate, or any final completion gate is still open, this refactor is not done.

The standard here is firm completion, not “good enough for now.”

## Immediate Work Order

1. Finish Phase 1 before doing more wide feature work.
2. Then finish Phase 2 and Phase 3 before more UI polish.
3. Then finish Phase 4 and clean up the remaining session-surface edge cases.
4. End with Phase 5 cleanup, commit slicing, and full verification.

## Tracking Rule

This file is now the source of truth for the rest of the refactor.

When a slice changes meaningfully, update this plan in the same workstream instead of starting a new partial plan.
