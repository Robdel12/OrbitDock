# Token + Context Tracking Architecture

This is the usage tracking model OrbitDock now treats as canonical at the storage layer.

## Problem We Needed to Fix

Different providers and integration modes emit token snapshots with different semantics:

- Some snapshots represent **lifetime totals**.
- Some represent **current turn/context occupancy**.
- Some are **mixed legacy snapshots** (for example context-oriented input with cumulative output).

A single `input/output/cached/context_window` tuple is not enough unless semantics are explicit.

## Core Model

Every token snapshot is persisted with an explicit `snapshot_kind`:

- `context_turn`
- `lifetime_totals`
- `mixed_legacy`
- `compaction_reset`
- `unknown`

The runtime still emits legacy `tokens_updated` messages for UI compatibility, but persistence now records semantic intent.

## Database Design

Migration: `migrations/007_usage_tracking.sql`

### `usage_events`
Append-only raw snapshots.

- One row per observed token update.
- Includes `snapshot_kind` and raw values.
- Used for auditability, replay, and future offline recomputation.

### `usage_session_state`
Normalized per-session usage rollup.

- Stores the latest raw snapshot.
- Stores derived `lifetime_*` and `context_*` fields.
- Upserted on every token update.

### `usage_turns`
Per-turn usage snapshots.

- Written at turn completion (`TurnDiffInsert`).
- Stores `turn_seq`, `snapshot_kind`, and an `input_delta_tokens` convenience field.

## Semantics Mapping (Current)

- Codex direct token updates: `context_turn`
- Codex rollout watcher total usage: `lifetime_totals`
- Claude direct stream/result usage: `mixed_legacy`
- Context compaction reset: `compaction_reset`
- Transcript backfill usage: provider-based best effort (`codex => context_turn`, `claude => mixed_legacy`)

## Invariants

- Raw events are never overwritten (`usage_events` append-only).
- Session state is deterministic from latest update + semantic kind.
- Turn snapshots are persisted independently from session snapshots.
- Legacy `sessions.{input_tokens,output_tokens,...}` fields continue to be maintained for existing UI paths.

## Current Read Path

Startup/session restore now reads usage from normalized tables first:

- `usage_session_state.snapshot_*` + `snapshot_kind` are authoritative for `RestoredSession` token fields.
- `usage_turns` is authoritative for per-turn token snapshots and ordering (`turn_seq`), with `turn_diffs` as diff-text source.
- Legacy `sessions` and `turn_diffs` token columns remain as fallback when normalized rows are missing.

## Next Step

Move Swift client usage displays from provider-specific token math to explicit snapshot semantics (use `snapshot_kind` + normalized usage fields).
