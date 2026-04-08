# Codex Server-First Policy Alignment Plan

Date: 2026-04-07  
Owner: OrbitDock Server  
Status: Draft

## Context
- [ ] OrbitDock should align 1:1 with Codex policy semantics and act as a light normalization wrapper.
- [ ] Current server paths flatten or lose Codex policy detail (approval details, sandbox/network semantics, network approval context).
- [ ] We need a server-first fix so clients can adopt the canonical contract without introducing OrbitDock-specific policy logic.
- [ ] Migration must be additive and backward-compatible for existing clients.

## Why This Change
- [ ] Current mapping drift causes behavior mismatch and user confusion, especially around network restrictions and approval handling.
- [ ] Silent fallback behavior can hide invalid policy states and make debugging harder.
- [ ] Missing network context in approval payloads limits actionable approval UX.
- [ ] Success means OrbitDock preserves Codex semantics end-to-end, including update, event, and decision paths.

## Target Design
- [ ] Codex protocol policy types become the canonical representation in OrbitDock server internals.
- [ ] A single translation boundary in `connector-codex` handles conversion to/from OrbitDock wire contracts.
- [ ] Legacy fields (`approval_policy`, `sandbox_mode`) remain compatibility views only during migration.
- [ ] Canonical fields are authoritative when present; legacy fallback is explicit and validated.
- [ ] No silent defaults for unknown values in policy updates.
- [ ] Approval payload mapping preserves network host/protocol and proposed policy amendments.
- [ ] Approval decision mapping supports Codex network policy amendment decisions.

## Ordered Phases

### Phase 0: Contract Freeze
Objective: lock canonical policy contract and migration rules before implementation.

What changes:
- [ ] Define canonical server-side contract for Codex approval/sandbox policy fields.
- [ ] Define precedence rules between canonical and legacy fields.
- [ ] Define compatibility signaling capability (for example `codex_permissions_v2`).

Where:
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/protocol/src/types.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/protocol/src/client.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/docs/API.md`

Why next:
- [ ] All later implementation depends on a stable cross-layer contract.

Done criteria:
- [ ] Canonical fields and precedence rules are documented and approved.
- [ ] Compatibility behavior is explicit in docs and tests plan.

### Phase 1: Connector Translation Boundary
Objective: centralize Codex policy translation and remove scattered lossy mapping.

What changes:
- [ ] Add dedicated translation modules (for example `policy_bridge` and `approval_bridge`) in `connector-codex`.
- [ ] Replace manual string match conversions in `update_config` flow.
- [ ] Replace unknown-value fallback with explicit validation errors.

Where:
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/connector-codex/src/session_ops.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/connector-codex/src/event_mapping/approvals.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/connector-codex/src/lib.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/connector-codex/tests/`

Why next:
- [ ] This is the highest drift concentration and blocks reliable contract rollout.

Done criteria:
- [ ] One translation path exists for update and approval-event mapping.
- [ ] Tests prove round-trip fidelity for supported values.

### Phase 2: Canonical Policy Through Server Runtime
Objective: propagate canonical policy fields through create/update/readback paths.

What changes:
- [ ] Add additive canonical policy fields to session create/update and control-deck updates.
- [ ] Keep legacy compatibility fields as derived outputs, not authoritative storage.
- [ ] Stop flattening canonical policy into strings for provider update truth.

Where:
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/transport/http/session_lifecycle.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/runtime/session_mutations.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/runtime/codex_config.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/domain/control_deck.rs`

Why next:
- [ ] Server runtime must carry canonical types before UI and tooling can rely on them.

Done criteria:
- [ ] Canonical policy survives create, update, and readback without lossy conversion.
- [ ] Legacy field derivation remains backward compatible.

### Phase 3: Approval Event And Decision Fidelity
Objective: preserve full Codex approval context and decision space.

What changes:
- [ ] Map network approval context (`host`, `protocol`) into OrbitDock approval payloads.
- [ ] Map proposed network policy amendments and available decisions into structured suggestions.
- [ ] Add additive decision variant for network policy amendment and map 1:1 to Codex review decisions.

Where:
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/connector-codex/src/event_mapping/approvals.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/protocol/src/types.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/connector-codex/src/session.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/connector-codex/src/session_ops.rs`

Why next:
- [ ] Event and decision fidelity is required to remove behavior divergence under approvals.

Done criteria:
- [ ] Approval payloads include network context whenever Codex emits it.
- [ ] Network policy amendment decision is persisted and forwarded correctly.

### Phase 4: Persistence, Replay Safety, And Observability
Objective: ensure migration safety and detect regressions early.

What changes:
- [ ] Add additive persistence support for new canonical fields where needed.
- [ ] Verify replay/resync behavior for pending approvals and stale decisions.
- [ ] Add metrics for approval/network failures, stale decisions, and loop signals.

Where:
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/infrastructure/persistence/approvals.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/runtime/approval_dispatch.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/runtime/session_command_handler.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/infrastructure/metrics.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/migrations/`

Why next:
- [ ] Rollout without observability and replay safety is high risk.

Done criteria:
- [ ] Restart/replay tests pass for pending approval and stale decision paths.
- [ ] Metrics are emitted and validated in staging.

### Phase 5: Progressive Rollout And Cleanup
Objective: ship safely and remove transitional duplication.

What changes:
- [ ] Rollout by capability-gated stages (dogfood -> partial -> full).
- [ ] Track error budgets for approval/network and replay issues at each stage.
- [ ] Remove obsolete duplicate mapping logic after stabilization.

Where:
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/docs/API.md`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/connector-codex/src/`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/`

Why next:
- [ ] Cleanup should happen only after compatibility and stability are proven.

Done criteria:
- [ ] 100% rollout complete with no regression spikes.
- [ ] Transitional mapping code removed and tests still green.

## Files To Modify
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/protocol/src/types.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/protocol/src/client.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/connector-codex/src/session_ops.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/connector-codex/src/event_mapping/approvals.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/connector-codex/src/session.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/transport/http/session_lifecycle.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/runtime/session_mutations.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/runtime/codex_config.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/domain/control_deck.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/runtime/approval_dispatch.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/infrastructure/persistence/approvals.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/infrastructure/metrics.rs`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/docs/API.md`
- [ ] `/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/migrations/`

## Implementation Order
- [ ] 1. Freeze canonical contract and compatibility rules.
- [ ] 2. Add connector translation boundary and tests.
- [ ] 3. Propagate canonical fields through server runtime paths.
- [ ] 4. Add approval event and decision fidelity.
- [ ] 5. Add persistence/replay safeguards and metrics.
- [ ] 6. Roll out progressively and remove transitional code.

## Parallel Work
- [ ] Lane A: Protocol contracts and API docs.
- [ ] Lane B: Connector translation boundary and mapping tests.
- [ ] Lane C: Runtime propagation + control-deck/session mutation paths.
- [ ] Lane D: Metrics, replay safety tests, rollout automation.
- [ ] Integration checkpoint after each phase boundary before advancing.

## Verification
- [ ] `cd /Users/robertdeluca/Developer/OrbitDock/orbitdock-server && make rust-test`
- [ ] `cd /Users/robertdeluca/Developer/OrbitDock/orbitdock-server && cargo test -p orbitdock-connector-codex`
- [ ] `cd /Users/robertdeluca/Developer/OrbitDock/orbitdock-server && cargo test -p orbitdock-server runtime::approval_dispatch`
- [ ] Validate create/update/readback round-trip for canonical policy fields.
- [ ] Validate approval event payload includes network context and suggestions when emitted by Codex.
- [ ] Validate network amendment decision maps 1:1 to Codex review decision.
- [ ] Validate restart/replay behavior for pending approvals and stale decisions.
- [ ] Validate metrics emission in staging dashboards and alert thresholds.

## Definition Of Done
- [ ] OrbitDock server preserves Codex policy semantics without lossy conversion.
- [ ] No OrbitDock-specific policy logic is introduced beyond normalization/compatibility.
- [ ] Legacy clients remain functional during migration window.
- [ ] Approval event and decision fidelity includes network context and amendments.
- [ ] Replay/restart behavior is stable and tested.
- [ ] Rollout reaches 100% with no sustained regression signal.

## Rollout / Rollback
- [ ] Rollout by capability gate with staged exposure.
- [ ] Hold gate if stale approval rate, network denial errors, or replay resync errors exceed threshold.
- [ ] Rollback by disabling canonical capability advertisement and serving legacy-compatible behavior.
- [ ] Keep schema changes additive; patch forward instead of destructive rollback migrations.
