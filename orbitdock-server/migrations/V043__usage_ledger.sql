-- Normalized usage ledger for authoritative historical accounting.
-- One row per completed turn with provider-normalized billable facts.

CREATE TABLE IF NOT EXISTS usage_ledger_entries (
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    turn_id TEXT NOT NULL,
    turn_seq INTEGER NOT NULL DEFAULT 0,
    provider TEXT NOT NULL,
    model TEXT,
    session_started_at TEXT,
    observed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    snapshot_kind TEXT NOT NULL DEFAULT 'unknown',
    billable_input_tokens INTEGER NOT NULL DEFAULT 0,
    billable_output_tokens INTEGER NOT NULL DEFAULT 0,
    cache_read_tokens INTEGER NOT NULL DEFAULT 0,
    cache_write_tokens INTEGER NOT NULL DEFAULT 0,
    context_input_tokens INTEGER NOT NULL DEFAULT 0,
    context_window INTEGER NOT NULL DEFAULT 0,
    estimated_cost_usd REAL NOT NULL DEFAULT 0,
    PRIMARY KEY (session_id, turn_id)
);

CREATE INDEX IF NOT EXISTS idx_usage_ledger_started_at
    ON usage_ledger_entries(session_started_at DESC);
CREATE INDEX IF NOT EXISTS idx_usage_ledger_provider_started_at
    ON usage_ledger_entries(provider, session_started_at DESC);
