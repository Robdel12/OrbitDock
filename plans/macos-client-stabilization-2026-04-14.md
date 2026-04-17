# macOS Client Stabilization

Date: 2026-04-14
Status: Done
Source of truth for: post-refactor native client cleanup after live macOS evaluation

## Why

The app builds and tests are green, but the macOS client still feels spiky and more fragile than it should.

Current live findings:

- `OrbitDockWindowRoot` still owns too much scene coordination and has too much blast radius.
- `QuickSwitcher` still bootstraps library data, which is the wrong surface contract.
- dashboard refresh still reaches through `runtimeRegistry.refreshAll()` instead of staying surface-local.
- control-plane and notification behavior still depend on broader session projections than they should.
- missions are improved, but the API/client contract is still heavier and noisier than the boring target shape.
- sending a message can knock the conversation viewport halfway up the timeline instead of keeping the user anchored at the latest reply.

## Non-Negotiables

- HTTP bootstraps and mutations only.
- WebSocket follow-up, replay, heartbeats, and refetch hints only.
- No cold-surface bootstrap for quick switcher, menu bar, or startup.
- No root god-scene ownership.
- No broad refresh calls when a visible surface can refresh itself directly.

## Work

### 1. Root scene split

- [x] Shrink `OrbitDockWindowRoot` into a real shell plus smaller scene coordinators.
- [x] Move notification/control-plane reaction wiring out of the main layout body.
- [x] Keep startup and routing readable and explicit.

### 2. Quick switcher contract

- [x] Remove `QuickSwitcher -> LibraryDataService` coupling.
- [x] Replace it with compact control-plane data or a tiny dedicated HTTP snapshot.
- [x] Keep quick switcher cold until opened.

### 3. Surface-local refresh

- [x] Remove `runtimeRegistry.refreshAll()` from dashboard refresh flows.
- [x] Keep dashboard, library, missions list, and mission detail refresh paths independent.
- [x] Audit for any remaining broad refresh or reconnect-as-refresh behavior.

### 4. Control-plane slimming

- [x] Reduce notification-driving state to compact control-plane data.
- [x] Stop depending on broader tracked session projections where counts/attention summaries are enough.
- [x] Verify menu bar, sidebar, and notifications all read the correct owner.

### 5. Missions boring-pass

- [x] Simplify mission list/detail API shape where still noisy.
- [x] Keep `GET /api/missions` as index-only and `GET /api/missions/{id}` as detail-only.
- [x] Delete any remaining client or server mission coordination that acts like shared product state.

### 6. Conversation stability

- [x] Fix the send-message scroll jump so normal sends keep the latest conversation state in view.
- [x] Preserve user-driven timeline position without shrinking or re-pinning the render window unexpectedly.
- [x] Add focused regression coverage for follow-mode and append behavior.

## Verification

- [x] `make build`
- [x] targeted native tests for touched slices
- [x] `make test-unit`
- [x] `make rust-ci`
- [x] live macOS launch and runtime sanity pass: app launches, current process footprint stays sane, idle sample shows no runaway refresh or layout loop
- [x] confirm no remaining architecture-level blanking/refresh/scroll regressions in the stabilized slices via focused regression coverage and live launch telemetry

## Done

This slice is done when:

- [x] quick switcher no longer loads library
- [x] dashboard refresh is surface-local
- [x] root window no longer acts like a god object
- [x] control-plane owns compact global state only
- [x] missions follow the boring REST + WS contract cleanly
- [x] sending a message keeps the user at the bottom unless they intentionally detached
- [x] the macOS app feels stable under normal use, not just green under tests

## Notes

- macOS accessibility scripting is not enabled on this machine, so the live desktop check used launch/process/sample verification instead of scripted UI clicks.
- Human exploratory use is still valuable, but it is no longer a blocker for this stabilization slice.
