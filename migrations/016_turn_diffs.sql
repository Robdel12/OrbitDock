-- Persist per-turn diff snapshots so they survive server restarts.
CREATE TABLE IF NOT EXISTS turn_diffs (
    session_id TEXT NOT NULL,
    turn_id TEXT NOT NULL,
    diff TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    PRIMARY KEY (session_id, turn_id),
    FOREIGN KEY (session_id) REFERENCES sessions(id)
);

CREATE INDEX IF NOT EXISTS idx_turn_diffs_session ON turn_diffs(session_id);
