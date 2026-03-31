# Dashboard Server-First Refactor Plan

Status: In progress (Phases 1-3 largely complete, Phase 4 pending)
Owner: Codex + Robert
Last updated: 2026-03-30

## Why this exists

Dashboard correctness is currently brittle because we mix:

- a generic session delta payload as dashboard transport,
- client-side business-state patching,
- and reconnect/replay timing that can miss or reorder intent.

This plan resets dashboard to a server-authoritative contract and then simplifies the Swift client around that contract.

## North Star

1. Rust server is the single source of truth for dashboard business state.
2. Dashboard transport is surface-specific and API-driven.
3. Swift client renders authoritative dashboard snapshots/projections and does not infer business truth from generic session deltas.

## Phase 0 - Alignment (done)

- [x] Audit current server and client dashboard realtime path.
- [x] Identify architectural smells and race windows.
- [x] Define server-first direction.

## Phase 1 - Server Stabilization (done)

Goal: make dashboard updates driven by server dashboard revision + invalidation flow so client-side state patching is no longer required for correctness.

Tasks:

- [x] Emit `DashboardInvalidated` on session list-relevant transitions from the session actor path.
- [x] Route dashboard websocket subscription to invalidation/replay hints (not generic session deltas).
- [x] Add Rust tests proving dashboard invalidation is emitted for session transitions.
- [x] Validate with targeted Rust tests.

Exit criteria:

- Dashboard can converge correctly from HTTP snapshot + invalidation refresh even if session deltas are dropped.

## Phase 2 - Server Contract Hardening

Goal: remove dashboard dependence on `StateChanges` as transport shape.

Tasks:

- [x] Define dedicated dashboard WS contract (typed dashboard events or strict invalidation-only mode).
- [x] Keep backward compatibility window if needed.
- [ ] Add integration tests for active/working/permission/ended transitions.
- [ ] Add reconnect + replay gap tests.

Exit criteria:

- Dashboard transport no longer relies on generic all-surface delta semantics.

## Phase 3 - Swift Client Rewrite

Goal: simplify client architecture to render server dashboard truth only.

Tasks:

- [x] Remove dashboard business-state patching from runtime registry.
- [x] Keep `DashboardProjectionStore` as single app-facing dashboard projection.
- [x] Ensure `DashboardViewModel` is presentation-only (filter/sort/group).
- [ ] Add tests for refresh/reconnect and projection updates.

Exit criteria:

- No client-side dashboard business inference from generic session deltas.

## Phase 4 - Cleanup

- [ ] Delete dead compatibility branches and unused helpers.
- [ ] Update docs: `docs/data-flow.md`, `docs/client-networking.md`, and architecture notes.
- [ ] Add regression test matrix to prevent reintroduction.

## Risks and mitigations

1. Risk: invalidation storms increase HTTP load.
   Mitigation: coalesce refreshes per endpoint and/or narrow invalidation triggers.

2. Risk: temporary mixed contract during migration.
   Mitigation: strict test coverage and explicit deprecation window.

3. Risk: reconnect gaps during rollout.
   Mitigation: revision-based replay and deterministic HTTP refetch fallback.

## Immediate next step

Close the remaining test coverage gap: add dashboard transition integration tests and reconnect/replay gap tests, then finish Phase 4 cleanup/docs.
