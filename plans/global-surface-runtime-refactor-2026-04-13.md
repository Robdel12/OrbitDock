# Global Surface Runtime Refactor

Date: 2026-04-13
Status: Active

## Why This Exists

The session/runtime refactor cleaned up the worst local-state problems, but the app still carries old architecture in the global surfaces:

- dashboard
- library
- missions
- global attention and notification state

Those surfaces are still too centralized, too eager, and too willing to share transport/runtime machinery that should stay boring.

The result is predictable:

- too much data loaded when the user only needs one surface
- too many listeners for the same global events
- dashboard and library coupled together when they should not be
- missions split between HTTP owners, runtime registry bootstraps, and bespoke live observables
- global attention inferred from heavy session lists instead of owned as a lightweight control-plane concern

This slice is the same kind of refactor we just did for session surfaces:

delete the mixed global state patterns and replace them with explicit surface-owned contracts.

## Non-Negotiables

1. HTTP is authoritative for global surface bootstrap.
2. WebSocket is follow-up only: replay, small deltas, invalidation, heartbeat.
3. No global service should own multiple unrelated product surfaces by default.
4. No eager loading of cold archive/library data just to keep hot dashboard state current.
5. The app should not hold giant cross-endpoint snapshots in memory when a smaller summary would do.

## Target Surface Model

### 1. Global Control Plane

Purpose:

- attention counts
- urgent session refs
- lightweight endpoint health
- any app-wide notification-driving state

Target contract:

- HTTP: `GET /api/control-plane`
- WS: `control_plane_invalidated(revision)`
- optional tiny deltas only if they are truly tiny and replayable

This surface must stay compact. It should never carry full library lists or heavyweight mission detail.

### 2. Dashboard

Purpose:

- active work only
- sessions that matter right now
- project grouping and active status presentation

Target contract:

- HTTP: `GET /api/dashboard`
- WS: `dashboard_invalidated(revision)`
- optional tiny list delta only if it remains cheap and obvious

Dashboard should not also be the archive system, and it should not be the source for notification state.

### 3. Library

Purpose:

- cold and historical session discovery
- pagination, filters, archive browsing

Target contract:

- HTTP: `GET /api/library?limit=&offset=`
- WS: preferably `library_invalidated(revision)` only

Library should load on demand. It should not piggyback on dashboard refreshes and should not be eagerly fetched just because the app launched.

### 4. Missions List

Purpose:

- lightweight mission list and counts
- mission row summaries only

Target contract:

- HTTP: `GET /api/missions`
- WS: `missions_invalidated(revision)`

### 5. Mission Detail

Purpose:

- one mission's issues, settings, cleanup prompt, worktrees, and heartbeat-related UI

Target contract:

- HTTP: `GET /api/missions/{id}`
- HTTP: `GET /api/missions/{id}/worktrees`
- WS: `mission_invalidated(id, revision)` and optional `mission_heartbeat(id, ...)`

Mission detail should not depend on a global endpoint runtime cache to stay coherent.

## What Needs To Be Deleted

### Dashboard / Library

- [ ] Delete `DashboardDataService` as the shared owner of both dashboard and library product state.
- [ ] Delete library refresh as a side effect of dashboard changes.
- [ ] Delete full multi-endpoint library scans from normal app startup paths.
- [ ] Delete dashboard-specific listener ownership from places that are not the dashboard owner.

### Missions

- [ ] Delete runtime-registry-owned mission bootstrap behavior.
- [ ] Delete `MissionObservable` as a global product-state cache unless a much narrower replacement proves necessary.
- [ ] Delete mission list realtime logic that only exists to compensate for missing explicit invalidation boundaries.

### Global Attention / Notifications

- [ ] Delete notification baselines that depend on full library snapshots as the app-wide truth source.
- [ ] Delete the assumption that global attention must be derived from large session arrays.
- [ ] Delete coupling between global notification state and library refresh timing.

## What Replaces It

### Native Owners

- [ ] Add a dedicated `ControlPlaneDataService` or similarly narrow owner for app-wide attention and endpoint health only.
- [ ] Add a dedicated `DashboardSurfaceModel` for dashboard only.
- [ ] Add a dedicated `LibrarySurfaceModel` for library only.
- [ ] Add a dedicated `MissionListSurfaceModel` for the missions index.
- [ ] Keep `MissionControlViewModel` as the mission-detail owner, but feed it from explicit mission-detail HTTP + mission-specific WS follow-up.

### API / Transport

- [ ] Add `GET /api/control-plane` if the current dashboard payload is too heavy for global app-shell needs.
- [ ] Add `library_invalidated(revision)` if library should update while open without forcing eager refetches elsewhere.
- [ ] Add `mission_invalidated(id, revision)` so mission detail can own its own recovery instead of relying on broad mission-list events.
- [ ] Keep all WS follow-up payloads small enough that replay stays cheap.

## Efficiency Rules

These are part of the definition of done, not nice-to-haves.

- [ ] App launch must not eagerly fetch full library/archive pages unless the library surface is active.
- [ ] Global control-plane data must stay summary-sized.
- [ ] Dashboard payloads should be active-work focused, not cold-history focused.
- [ ] Mission list payloads should stay list-shaped; mission detail belongs on mission detail.
- [ ] No owner should keep duplicate copies of large snapshots when a compact projection is enough.
- [ ] Multi-endpoint merges should happen only in the owner that actually renders the merged surface.

## Execution Order

### Slice 1: Global Control Plane

- [ ] Define the app-wide attention and endpoint-health contract.
- [ ] Replace library-derived notification baselines with control-plane-derived baselines.
- [ ] Move global attention ownership out of dashboard/library state.

### Slice 2: Dashboard Rewrite

- [ ] Replace `DashboardDataService` dashboard ownership with a dashboard-specific surface model.
- [ ] Keep dashboard HTTP bootstrap and WS follow-up local to that model.
- [ ] Remove dashboard/library shared refresh paths.

### Slice 3: Library Rewrite

- [ ] Replace `RootSessionSnapshotLoader`-driven eager library refresh behavior with a library-owned HTTP model.
- [ ] Make pagination explicit and on-demand.
- [ ] Keep library out of app-launch hot paths unless needed.

### Slice 4: Missions Rewrite

- [ ] Replace runtime-registry bootstrap ownership for missions.
- [ ] Keep missions list and mission detail as separate surfaces.
- [ ] Move mission detail follow-up onto mission-specific invalidation or heartbeat contracts.

## Verification

### Functional

- [ ] Launching the app does not fetch library/archive data unless the library surface is active.
- [ ] Dashboard still feels live while only holding active-work data.
- [ ] Notification and attention state update without depending on a full library refresh.
- [ ] Missions list updates while open without forcing mission-detail reloads unnecessarily.
- [ ] Mission detail refreshes only when the selected mission changes or its own contract invalidates.

### Performance / Memory

- [ ] No broad multi-endpoint archive scan runs on every dashboard invalidation.
- [ ] The app does not keep duplicate dashboard + library + notification copies of the same large session set.
- [ ] WS replay remains lightweight and cheap for all global surfaces.

## Definition Of Done

- [ ] Dashboard, library, missions, and global attention have distinct owners.
- [ ] Global app-shell state is summary-sized and cheap.
- [ ] Library is cold/on-demand instead of implicitly hot.
- [ ] Missions list and mission detail are split cleanly.
- [ ] The code matches the boring REST + WS contract we want to keep scaling with.
