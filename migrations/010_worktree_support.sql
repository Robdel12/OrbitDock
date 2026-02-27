-- Worktree detection fields on sessions
ALTER TABLE sessions ADD COLUMN repository_root TEXT;
ALTER TABLE sessions ADD COLUMN is_worktree INTEGER NOT NULL DEFAULT 0;
ALTER TABLE sessions ADD COLUMN worktree_id TEXT;
CREATE INDEX IF NOT EXISTS idx_sessions_repository_root ON sessions(repository_root);
CREATE INDEX IF NOT EXISTS idx_sessions_worktree_id ON sessions(worktree_id);

-- Worktree lifecycle tracking (independent of sessions)
CREATE TABLE IF NOT EXISTS worktrees (
    id TEXT PRIMARY KEY,
    repo_root TEXT NOT NULL,
    worktree_path TEXT NOT NULL UNIQUE,
    branch TEXT NOT NULL,
    base_branch TEXT,
    base_sha TEXT,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    last_session_ended_at TEXT,
    last_health_check_at TEXT,
    disk_present INTEGER NOT NULL DEFAULT 1,
    auto_prune INTEGER NOT NULL DEFAULT 1,
    custom_name TEXT,
    created_by TEXT
);
CREATE INDEX IF NOT EXISTS idx_worktrees_repo_root ON worktrees(repo_root);
CREATE INDEX IF NOT EXISTS idx_worktrees_status ON worktrees(status);
