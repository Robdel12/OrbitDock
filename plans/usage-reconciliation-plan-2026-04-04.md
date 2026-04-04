# OrbitDock Usage Reconciliation Plan

Date: 2026-04-04
Owner: OrbitDock Server Team
Status: Draft

## 1. Why This Change
- Problem:
  - OrbitDock usage summary is materially lower than Codex history (`npx @ccusage/codex`) and drifts after restarts.
  - Current summary pipeline does not include most sessions with usage activity.
- Why now:
  - Usage totals drive trust and billing visibility; incorrect values undermine product confidence.
- User/business impact:
  - Users see numbers that do not match provider-side usage, especially for Codex-heavy workflows.
- Cost of not changing:
  - Persistent mismatch, restart-related drift, and inability to audit usage reliably.

## 2. Goals And Non-Goals
### Goals
- [ ] Make usage accounting durable and restart-stable.
- [ ] Ensure summary aggregation includes all completed turns, not only turns with diffs.
- [ ] Reconcile historical totals against `ccusage` with explicit gap reporting.
- [ ] Add automated checks so regressions are caught in CI.

### Non-Goals
- [ ] Real-time token-by-token billing precision for streaming updates.
- [ ] Rebuilding provider billing engines from scratch.
- [ ] Rewriting UI design for usage surfaces.

## 3. Current State
- Architecture/data flow summary:
  - `PersistCommand::TokensUpdate` writes `sessions` snapshot tokens, `usage_events`, and `usage_session_state`.
  - `usage_turns` and `usage_ledger_entries` are written only via `PersistCommand::TurnDiffInsert`.
  - `TurnDiffInsert` is emitted on `TurnCompleted` only when `current_diff` exists.
  - `/api/usage/summary` aggregates ledger rows + legacy `usage_turns` fallback.
- Pain points:
  - Sessions with token activity but no diffs are excluded from ledger-based summary.
  - `usage_turns` / `usage_ledger_entries` upserts rewrite timestamps (`created_at` / `observed_at`), causing day attribution drift.
  - Restore path seeds `turn_count` from `turn_diffs.len()`, not authoritative turn sequence, risking turn-id reuse after restart.
  - Multi-runtime summary merge currently sums session counts/totals without dedupe by session identity.
- Constraints:
  - Preserve server-authoritative persistence model.
  - Keep additive DB migration strategy.
  - Support mixed snapshot semantics (`context_turn`, `lifetime_totals`, `mixed_legacy`).

## 4. Proposed Architecture
- System boundaries:
  - Keep `usage_events` as raw append-only telemetry.
  - Make `usage_ledger_entries` authoritative for summary math.
  - Decouple usage turn ledgering from diff persistence.
- Data model / API changes:
  - Add a new persist op for completed-turn usage (`TurnUsageFinalize`) that always fires on `TurnCompleted` when `current_turn_id` exists, regardless of diff availability.
  - Add immutable first-seen timestamps and mutable last-seen timestamps on turn/ledger rows:
    - `first_observed_at`, `last_observed_at` (or equivalent) in `usage_ledger_entries`.
    - `first_created_at`, `last_created_at` (or equivalent) in `usage_turns`.
  - Use first-seen timestamp for daily bucketing to prevent restart drift.
  - Extend restore metadata to carry authoritative last turn sequence (derive from `usage_turns.max(turn_seq)` fallback), and initialize `turn_count` from that value.
- Control flow:
  - Connector token update path remains unchanged for live session snapshots.
  - Turn completion always emits usage finalize effect.
  - Diff archiving remains optional and independent.
  - Summary endpoint reads authoritative ledger rows and no longer depends on sparse diff-derived coverage.
- Migration strategy:
  - Add additive migration for timestamp and sequence support.
  - Backfill ledger from existing `usage_turns` where ledger missing.
  - Produce a reconciliation report versus `ccusage`; do not silently mutate historical totals without an explicit import step.

## 5. Alternatives Considered
1. Use `usage_events` directly for summary
- Pros:
  - Full coverage of token updates.
- Cons:
  - Event stream contains repeated snapshots and mixed semantics; aggregation is error-prone.
- Why rejected:
  - Too high risk without robust semantic event compaction.

2. Keep current turn-diff-triggered ledger writes
- Pros:
  - Minimal code change.
- Cons:
  - Systematically misses sessions/turns with no diff.
- Why rejected:
  - Root mismatch remains unresolved.

3. Replace OrbitDock history with `ccusage` values only
- Pros:
  - Closer to provider totals quickly.
- Cons:
  - External dependency, no internal audit trail by turn/session.
- Why rejected:
  - Useful for reconciliation/audit, not as sole source of truth.

## 6. Risks And Mitigations
| Risk | Impact | Mitigation | Owner |
|---|---|---|---|
| Snapshot semantics differ by provider/version | high | Keep normalization per `snapshot_kind`; add fixtures/tests per connector | Server |
| Historical data remains partially unrecoverable | med | Provide explicit reconciliation gap report and optional import baseline | Server |
| Restart turn-id collisions persist | high | Restore `turn_count` from authoritative max turn sequence | Server |
| Daily totals drift due row rewrites | high | Use immutable first-seen timestamps for day bucketing | Server |
| UI doubles counts across runtimes | med | Deduplicate merged sessions by id/provider before summing counts | Native |

## 7. Phased Execution Plan

### Phase 1: Correct Turn-Ledger Coverage
Objective: Ensure every completed turn contributes a usage ledger row independent of diffs.
Dependencies: none
Exit Criteria:
- [ ] `TurnCompleted` emits usage finalize persist effect whenever a turn id exists.
- [ ] New turns without diffs appear in `usage_turns` and `usage_ledger_entries`.
- [ ] Unit tests cover diffless turn completion.
Tasks:
- [ ] Add new persist command and handling in [transition.rs](/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/connector-core/src/transition.rs), [session.rs](/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/domain/sessions/transition.rs), and [mod.rs](/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/infrastructure/persistence/mod.rs).
- [ ] Reuse/update usage upsert helpers in [usage.rs](/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/infrastructure/persistence/usage.rs) so ledger writes do not depend on `TurnDiffInsert`.
- [ ] Add tests in [sync_tests.rs](/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/infrastructure/persistence/sync_tests.rs) and connector-core transition tests.

### Phase 2: Stabilize Restart Semantics And Timestamps
Objective: Remove restart-driven attribution drift and turn-sequence reuse.
Dependencies: Phase 1 outputs
Exit Criteria:
- [ ] Day attribution is based on immutable first-seen turn timestamp.
- [ ] Restored sessions continue turn ids monotonically after restart.
Tasks:
- [ ] Add migration for immutable/mutable timestamp columns in `usage_turns` and `usage_ledger_entries` under [migrations/](/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/migrations).
- [ ] Update upsert logic in [usage.rs](/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/infrastructure/persistence/usage.rs) to preserve first-seen timestamps.
- [ ] Extend restore read path in [session_reads.rs](/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/infrastructure/persistence/session_reads.rs) and apply in [session.rs](/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/domain/sessions/session.rs) to initialize turn counter from authoritative sequence.

### Phase 3: Reconciliation And Summary Accuracy
Objective: Reconcile current DB totals and ship reliable summary output.
Dependencies: Phase 1 and Phase 2 outputs
Exit Criteria:
- [ ] `/api/usage/summary` uses authoritative ledger coverage and passes regression tests.
- [ ] Reconciliation report compares OrbitDock daily totals against `ccusage` and flags residual gap.
- [ ] Native summary merge avoids cross-runtime session-count inflation.
Tasks:
- [ ] Refactor summary loader in [server_meta.rs](/Users/robertdeluca/Developer/OrbitDock/orbitdock-server/crates/server/src/transport/http/server_meta.rs) to read authoritative ledger timestamp fields.
- [ ] Add admin/doctor reconciliation command in server CLI (`ccusage` JSON ingest as input) and document workflow in [docs/debugging.md](/Users/robertdeluca/Developer/OrbitDock/docs/debugging.md).
- [ ] Deduplicate merged runtime session counts in [UsageServiceRegistry.swift](/Users/robertdeluca/Developer/OrbitDock/OrbitDockNative/OrbitDock/Services/UsageServiceRegistry.swift).

## 8. Parallel Worker Lanes
| Lane | Owner | Scope | Can Start After | Integration Point |
|---|---|---|---|---|
| Worker A | Server | Turn-complete usage finalize path and persistence wiring | now | Phase 1 PR |
| Worker B | Server | Migration + timestamp immutability + restore turn-seq continuity | schema finalized | Phase 2 PR |
| Worker C | Native | Runtime-merge dedupe in usage registry | now | Phase 3 integration |
| Worker D | Server | Reconciliation command + docs + validation harness | Phase 1 data shape stable | Phase 3 PR |

### Coordination Notes
- Shared contracts:
  - `usage_ledger_entries` schema fields and summary SQL.
  - Persist command enum additions across connector-core and server.
- Merge order:
  - A -> B -> D, with C mergeable in parallel but validated after A/B.
- Conflict risks:
  - `usage.rs`, `persistence/mod.rs`, and `server_meta.rs` touched by multiple lanes.

## 9. Validation Plan
- Unit/integration/e2e strategy:
  - Unit test normalization + turn finalize behavior.
  - Integration test restart scenario verifying no turn id reuse and stable day attribution.
  - Reconciliation check against `ccusage` daily output.
- Commands:
  - `cargo test -p orbitdock-server`
  - `cargo test -p orbitdock-server usage_summary`
  - `sqlite3 ~/.orbitdock/orbitdock.db "<reconciliation SQL>"`
  - `npx @ccusage/codex daily --json --offline --since <date>`
- [ ] Add a test fixture where turns complete without diffs and still appear in ledger.
- [ ] Add a restart regression test proving turn sequence monotonicity.
- [ ] Add reconciliation assertion: OrbitDock daily totals within agreed tolerance against `ccusage` for sampled dates.

## 10. Rollout And Rollback
- Rollout sequence:
  - Ship Phase 1 + 2 behind a feature flag for ledger source switching.
  - Run one-time backfill/reconciliation in staging copy of production DB.
  - Enable new summary source in production.
- Monitoring/alerts:
  - Track daily delta between OrbitDock summary and `ccusage` sample.
  - Track percentage of active sessions with ledger coverage.
- Rollback trigger:
  - Summary divergence worsens or ingestion errors spike.
- Rollback steps:
  - Toggle summary source back to legacy path.
  - Disable new turn finalize persist op.
  - Keep additive schema (no destructive rollback).

## 11. Decision Log
| Date | Decision | Context | Owner | Status |
|---|---|---|---|---|
| 2026-04-04 | Decouple usage ledger writes from turn diffs | Majority of codex sessions have usage but no turn diffs | Server | resolved |
| 2026-04-04 | Preserve immutable first-seen timestamps for day bucketing | Upsert rewrites caused attribution drift | Server | resolved |
| 2026-04-04 | Use `ccusage` as reconciliation source, not sole truth | Need internal durable ledger and external audit check | Server | resolved |
| 2026-04-04 | Decide tolerance threshold for OrbitDock vs `ccusage` | Required for automated gate | Product + Server | open |

## 12. Immediate Next Actions
- [ ] Implement Phase 1 persist-command split and tests — Owner: Server — Due: 2026-04-05
- [ ] Draft migration for immutable timestamps + restore turn-seq continuity — Owner: Server — Due: 2026-04-05
- [ ] Define reconciliation tolerance policy (daily and monthly) — Owner: Product/Server — Due: 2026-04-06
- [ ] Add `ccusage` reconciliation runbook to docs — Owner: Server — Due: 2026-04-06
