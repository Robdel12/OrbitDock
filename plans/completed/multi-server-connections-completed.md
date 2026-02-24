# OrbitDock Multi-Server Connections: Completed Execution Summary

This document replaces the active plan now that the multi-server rollout landed across 21 commits.

## Goal Recap

Support multiple simultaneous `orbitdock-server` connections in macOS and iOS with deterministic routing, endpoint-safe identities, and clear control-plane behavior.

## What Shipped

### Phase 1: Endpoint Model + Migration
- Implemented durable endpoint persistence with default local endpoint seeding.
- Added legacy remote-host migration into endpoint list storage.
- Added CRUD and migration test coverage.

### Phase 2: Endpoint-Scoped Runtime
- Replaced singleton connection flow with endpoint-scoped `ServerRuntime` instances.
- Added `ServerRuntimeRegistry` orchestration for start/stop/reconnect per endpoint.
- Added endpoint-isolated runtime tests.

### Phase 3: Composite Session Identity + Routing
- Landed `SessionRef` endpoint+session identity model.
- Updated selection and routing surfaces to carry endpoint context.
- Removed collision risk for duplicate session IDs across endpoints.

### Phase 4: Request-Scoped Transport APIs
- Replaced callback-slot request flows with one-shot async request/response APIs.
- Added request correlation hardening tests to prevent cross-talk.

### Phase 5: Unified Aggregation Layer
- Added merged multi-endpoint session projection (`UnifiedSessionsStore`).
- Added deterministic endpoint health + sorting/filter behavior.
- Added aggregation tests for projection and sort semantics.

### Phase 6: macOS Multi-Server Integration
- Added endpoint management UX and endpoint-aware labels/badges.
- Added default endpoint selection behavior for creation flows.
- Added runtime primary-role controls and conflict visibility.
- Added create-sheet UX polish for single-endpoint scenarios.

### Phase 7: iOS Multi-Server Integration
- Reused endpoint-aware runtime/selection model on iOS.
- Verified iOS build + behavior parity with endpoint-aware creation and routing.
- Added runtime memory-pressure trimming coverage.

### Control-Plane + Usage Hardening (cross-phase)
- Added server usage probe RPCs for Claude/Codex usage.
- Routed usage requests through control-plane endpoint.
- Added per-device client primary claims (`set_client_primary_claim`) and server claim tracking.
- Enforced server-side usage gating for non-primary claims (`not_control_plane_for_client`).
- Kept usage provider cards visible when usage requests error, so auth issues remain visible in UI.

### Timeline/Transport Stability
- Hardened WebSocket transport behavior for long conversations.
- Fixed duplicate approval rows and deduped turn diff rendering.
- Trimmed inactive payloads across endpoint runtimes.

## Commit Range Covered

Top of stack:
- `0ab1747` `✨ Polish create-session UX and keep usage cards visible on errors`

Foundation start in this execution:
- `8fad083` `♻️ Add endpoint store with legacy remote-host migration`

Related non-plan but included in the 21-commit push:
- `6c30311` docs seed for initial plan/post draft
- `bb9a291` quick-launch/project picker improvements
- `9a32954` direct-session compact context tracker reset

## Final Architecture Decisions

- Multi-server is the default model; single-server is just a one-endpoint case.
- Session identity is endpoint-scoped (`SessionRef`) everywhere critical.
- Control-plane selection is client-local (`isDefault` endpoint on that device).
- Server role (`set_server_role`) and per-device primary claims are metadata + gating signals, not UI selection state.
- Usage requests run through the selected control-plane endpoint and expose server auth errors directly in UI.

## Follow-Ups

- MCP bridge endpoint contract docs should continue evolving as multi-endpoint controls expand.
- Notification/deep-link endpoint assertions should be periodically revalidated as new routes are added.

