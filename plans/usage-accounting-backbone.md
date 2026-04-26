# Usage Accounting Backbone

## Goal

Make OrbitDock usage tracking server-authoritative, historically stable, and durable enough to power future UI without client-side inference.

## Invariants

- Every completed direct-session turn produces one durable `usage_turns` row.
- `usage_ledger_entries` is the normalized accounting layer derived from `usage_turns`.
- Historical cost rows must not drift when pricing tables change.
- Summary APIs aggregate ledger rows only.
- Client UI should never reconstruct historical usage from session snapshots.

## Current Findings

- New write path after `2026-04-22` is healthy: new `usage_turns` and ledger rows match.
- Historical data was incomplete: older `usage_turns` existed without matching ledger rows.
- Legacy snapshot kinds still existed in older rows (`mixed_legacy` in `usage_turns`).
- Server-side cost estimation depended on a hardcoded table at write time and only stored `estimated_cost_usd`, not the underlying pricing basis.

## Phase 1

- [completed] Canonicalize legacy snapshot kinds on the server/migration path.
- [completed] Add pricing metadata columns to `usage_ledger_entries`.
- [completed] Add a server-side ledger repair/backfill pass during migration/startup.
- [completed] Add tests for historical repair and pricing snapshot persistence.

## Phase 2

- [completed] Expose per-session/per-turn usage HTTP surfaces.
- [completed] Add grouped breakdown APIs by provider/model/day/session.
- [completed] Remove remaining server reads that treat session token snapshot columns as historical truth.
- [completed] Replace the ad hoc pricing logic with a canonical server-owned pricing source/versioning strategy.
- [completed] Gate startup repair so healthy databases do not rebuild usage accounting on every boot.

## Client Authority Cleanup

- [completed] Remove dashboard/session-detail client-side usage and cost calculation fallbacks.
- [completed] Remove native pricing service and protocol-level cost estimation helpers that guessed session cost outside the server-owned pricing path.

## Ready For UI

- API usage truth is now ledger-backed for historical accounting and turn-backed for detail drill-down.
- Turn-level provider/model snapshots prevent future recompute drift when a session changes models.
- Startup repair now rebuilds both ledger rows and persisted live usage session state from canonical usage tables only when repair is actually needed.
- Client usage surfaces now render API summary/detail data directly instead of synthesizing token or cost totals locally.
