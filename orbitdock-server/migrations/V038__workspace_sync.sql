CREATE TABLE workspaces (
    id TEXT PRIMARY KEY,
    mission_issue_id TEXT REFERENCES mission_issues(id),
    session_id TEXT,
    provider TEXT NOT NULL DEFAULT 'local',
    external_id TEXT,
    repo_url TEXT,
    branch TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'creating',
    connection_info TEXT,
    sync_token TEXT,
    sync_acked_through INTEGER NOT NULL DEFAULT 0,
    last_heartbeat_at TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    ready_at TEXT,
    destroyed_at TEXT
);

CREATE INDEX idx_workspaces_mission_issue_id ON workspaces(mission_issue_id);
CREATE UNIQUE INDEX idx_workspaces_sync_token ON workspaces(sync_token) WHERE sync_token IS NOT NULL;

ALTER TABLE mission_issues ADD COLUMN workspace_id TEXT REFERENCES workspaces(id);

CREATE TABLE sync_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    workspace_id TEXT NOT NULL REFERENCES workspaces(id),
    sequence INTEGER NOT NULL,
    command_json TEXT NOT NULL,
    received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(workspace_id, sequence)
);

CREATE INDEX idx_sync_log_workspace_sequence ON sync_log(workspace_id, sequence);
