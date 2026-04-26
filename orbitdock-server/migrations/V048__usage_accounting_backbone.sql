ALTER TABLE usage_ledger_entries
    ADD COLUMN pricing_source TEXT NOT NULL DEFAULT 'orbitdock_builtin';

ALTER TABLE usage_ledger_entries
    ADD COLUMN pricing_version TEXT NOT NULL DEFAULT '2026-04-backbone-v1';

ALTER TABLE usage_ledger_entries
    ADD COLUMN pricing_model_key TEXT;

ALTER TABLE usage_ledger_entries
    ADD COLUMN input_cost_per_token REAL NOT NULL DEFAULT 0;

ALTER TABLE usage_ledger_entries
    ADD COLUMN output_cost_per_token REAL NOT NULL DEFAULT 0;

ALTER TABLE usage_ledger_entries
    ADD COLUMN cache_read_cost_per_token REAL NOT NULL DEFAULT 0;

ALTER TABLE usage_ledger_entries
    ADD COLUMN cache_write_cost_per_token REAL NOT NULL DEFAULT 0;

UPDATE usage_turns
   SET snapshot_kind = 'mixed'
 WHERE snapshot_kind = 'mixed_legacy';

UPDATE usage_ledger_entries
   SET snapshot_kind = 'mixed'
 WHERE snapshot_kind = 'mixed_legacy';
