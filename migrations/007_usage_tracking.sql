-- Usage tracking v2 (normalized and append-only)
-- Keeps raw snapshots, session rollup state, and per-turn token snapshots.

CREATE TABLE IF NOT EXISTS usage_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    observed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    snapshot_kind TEXT NOT NULL DEFAULT 'unknown',
    input_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    cached_tokens INTEGER NOT NULL DEFAULT 0,
    context_window INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_usage_events_session_id ON usage_events(session_id, id DESC);
CREATE INDEX IF NOT EXISTS idx_usage_events_observed_at ON usage_events(observed_at DESC);

CREATE TABLE IF NOT EXISTS usage_session_state (
    session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    codex_integration_mode TEXT,
    claude_integration_mode TEXT,

    -- Last observed raw snapshot
    snapshot_kind TEXT NOT NULL DEFAULT 'unknown',
    snapshot_input_tokens INTEGER NOT NULL DEFAULT 0,
    snapshot_output_tokens INTEGER NOT NULL DEFAULT 0,
    snapshot_cached_tokens INTEGER NOT NULL DEFAULT 0,
    snapshot_context_window INTEGER NOT NULL DEFAULT 0,

    -- Normalized rollups (best-effort based on snapshot_kind)
    lifetime_input_tokens INTEGER NOT NULL DEFAULT 0,
    lifetime_output_tokens INTEGER NOT NULL DEFAULT 0,
    lifetime_cached_tokens INTEGER NOT NULL DEFAULT 0,
    context_input_tokens INTEGER NOT NULL DEFAULT 0,
    context_cached_tokens INTEGER NOT NULL DEFAULT 0,
    context_window INTEGER NOT NULL DEFAULT 0,

    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_usage_session_state_provider ON usage_session_state(provider);
CREATE INDEX IF NOT EXISTS idx_usage_session_state_updated_at ON usage_session_state(updated_at DESC);

CREATE TABLE IF NOT EXISTS usage_turns (
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    turn_id TEXT NOT NULL,
    turn_seq INTEGER NOT NULL DEFAULT 0,
    snapshot_kind TEXT NOT NULL DEFAULT 'unknown',
    input_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    cached_tokens INTEGER NOT NULL DEFAULT 0,
    context_window INTEGER NOT NULL DEFAULT 0,
    input_delta_tokens INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    PRIMARY KEY (session_id, turn_id)
);

CREATE INDEX IF NOT EXISTS idx_usage_turns_session_seq ON usage_turns(session_id, turn_seq DESC);
CREATE INDEX IF NOT EXISTS idx_usage_turns_created_at ON usage_turns(created_at DESC);
