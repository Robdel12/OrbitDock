-- Migration 005: Enhanced hook tracking
-- Captures additional data from Claude Code hooks

-- Add new columns to sessions for richer hook data
ALTER TABLE sessions ADD COLUMN source TEXT;                    -- 'startup', 'resume', 'clear', 'compact'
ALTER TABLE sessions ADD COLUMN agent_type TEXT;                -- If started with --agent flag
ALTER TABLE sessions ADD COLUMN permission_mode TEXT;           -- 'default', 'plan', 'acceptEdits', 'dontAsk', 'bypassPermissions'
ALTER TABLE sessions ADD COLUMN compact_count INTEGER DEFAULT 0; -- Times context was compacted
ALTER TABLE sessions ADD COLUMN active_subagent_id TEXT;        -- Currently running subagent
ALTER TABLE sessions ADD COLUMN active_subagent_type TEXT;      -- Type of running subagent (Explore, Plan, etc.)

-- Subagents table - tracks spawned agents via Task tool
CREATE TABLE IF NOT EXISTS subagents (
  id TEXT PRIMARY KEY,                          -- agent_id from hook
  session_id TEXT NOT NULL REFERENCES sessions(id),
  agent_type TEXT NOT NULL,                     -- 'Bash', 'Explore', 'Plan', custom agent names
  transcript_path TEXT,                         -- agent_transcript_path from SubagentStop
  started_at TEXT NOT NULL,
  ended_at TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);

-- Index for querying subagents by session
CREATE INDEX IF NOT EXISTS idx_subagents_session ON subagents(session_id);

-- Compaction events table - tracks context compactions
CREATE TABLE IF NOT EXISTS compactions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  trigger TEXT NOT NULL,                        -- 'manual' or 'auto'
  custom_instructions TEXT,                     -- User's /compact instructions
  compacted_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_compactions_session ON compactions(session_id);
