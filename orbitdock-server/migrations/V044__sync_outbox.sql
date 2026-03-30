CREATE TABLE sync_outbox (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    workspace_id TEXT NOT NULL REFERENCES workspaces(id),
    sequence INTEGER NOT NULL,
    command_json TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(workspace_id, sequence)
);

CREATE INDEX idx_sync_outbox_workspace_sequence ON sync_outbox(workspace_id, sequence);
