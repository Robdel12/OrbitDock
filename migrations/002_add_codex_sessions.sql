-- Migration 002: Add Codex sessions table
-- Tracks OpenAI Codex CLI sessions separately

CREATE TABLE IF NOT EXISTS codex_sessions (
  id TEXT PRIMARY KEY,
  project_path TEXT NOT NULL,
  project_name TEXT,
  model TEXT,
  status TEXT DEFAULT 'active',
  started_at TEXT,
  ended_at TEXT,
  last_activity_at TEXT,
  total_tokens INTEGER DEFAULT 0,
  total_cost_usd REAL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_codex_sessions_status ON codex_sessions(status);
CREATE INDEX IF NOT EXISTS idx_codex_sessions_project ON codex_sessions(project_path);
