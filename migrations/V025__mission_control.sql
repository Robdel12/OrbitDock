-- Mission Control: autonomous issue-driven orchestration

CREATE TABLE missions (
    id TEXT PRIMARY KEY,
    repo_root TEXT NOT NULL,
    tracker_kind TEXT NOT NULL DEFAULT 'linear',
    provider TEXT NOT NULL DEFAULT 'claude',
    config_json TEXT,
    prompt_template TEXT,
    enabled INTEGER NOT NULL DEFAULT 1,
    paused INTEGER NOT NULL DEFAULT 0,
    last_parsed_at TEXT,
    parse_error TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE mission_issues (
    id TEXT PRIMARY KEY,
    mission_id TEXT NOT NULL REFERENCES missions(id),
    issue_id TEXT NOT NULL,
    issue_identifier TEXT NOT NULL,
    issue_title TEXT,
    issue_state TEXT,
    orchestration_state TEXT NOT NULL DEFAULT 'queued',
    session_id TEXT,
    provider TEXT,
    attempt INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    retry_due_at TEXT,
    started_at TEXT,
    completed_at TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(mission_id, issue_id)
);

-- Link sessions to missions
ALTER TABLE sessions ADD COLUMN mission_id TEXT;
ALTER TABLE sessions ADD COLUMN issue_id TEXT;
ALTER TABLE sessions ADD COLUMN issue_identifier TEXT;
