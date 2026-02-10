-- Migration 012: Approval history tracking for Codex control plane
-- Stores approval requests + decisions so UI can inspect/revoke history.

CREATE TABLE IF NOT EXISTS approval_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  request_id TEXT NOT NULL,
  approval_type TEXT NOT NULL,
  tool_name TEXT,
  command TEXT,
  file_path TEXT,
  cwd TEXT,
  decision TEXT,
  proposed_amendment TEXT,
  created_at TEXT NOT NULL,
  decided_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_approval_history_session_id
  ON approval_history(session_id, id DESC);

CREATE INDEX IF NOT EXISTS idx_approval_history_created_at
  ON approval_history(created_at DESC);
