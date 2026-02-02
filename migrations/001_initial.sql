-- Migration 001: Initial schema
-- Consolidates the full OrbitDock database schema

-- Repositories (git repos being tracked)
CREATE TABLE IF NOT EXISTS repos (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  path TEXT NOT NULL UNIQUE,
  github_owner TEXT,
  github_name TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);

-- Workstreams (feature branches / work units)
CREATE TABLE IF NOT EXISTS workstreams (
  id TEXT PRIMARY KEY,
  repo_id TEXT NOT NULL REFERENCES repos(id),
  branch TEXT NOT NULL,
  directory TEXT,
  name TEXT,
  description TEXT,

  -- Linear integration
  linear_issue_id TEXT,
  linear_issue_title TEXT,
  linear_issue_state TEXT,
  linear_issue_url TEXT,

  -- GitHub issue integration
  github_issue_number INTEGER,
  github_issue_title TEXT,
  github_issue_state TEXT,

  -- GitHub PR integration
  github_pr_number INTEGER,
  github_pr_title TEXT,
  github_pr_state TEXT,
  github_pr_url TEXT,
  github_pr_additions INTEGER,
  github_pr_deletions INTEGER,

  -- Review state
  review_state TEXT,
  review_approvals INTEGER DEFAULT 0,
  review_comments INTEGER DEFAULT 0,

  -- Stage (legacy single-value) and state flags (new combinable)
  stage TEXT DEFAULT 'working',
  is_working INTEGER DEFAULT 1,
  has_open_pr INTEGER DEFAULT 0,
  in_review INTEGER DEFAULT 0,
  has_approval INTEGER DEFAULT 0,
  is_merged INTEGER DEFAULT 0,
  is_closed INTEGER DEFAULT 0,

  -- Stats
  session_count INTEGER DEFAULT 0,
  total_session_seconds INTEGER DEFAULT 0,
  commit_count INTEGER DEFAULT 0,

  -- Timestamps
  last_activity_at TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),

  UNIQUE(repo_id, branch)
);

-- Workstream tickets (linked issues from Linear, GitHub, etc.)
CREATE TABLE IF NOT EXISTS workstream_tickets (
  id TEXT PRIMARY KEY,
  workstream_id TEXT NOT NULL REFERENCES workstreams(id),
  source TEXT NOT NULL,  -- 'linear', 'github'
  external_id TEXT NOT NULL,
  title TEXT,
  state TEXT,
  url TEXT,
  is_primary INTEGER DEFAULT 0,
  created_at TEXT DEFAULT (datetime('now')),
  UNIQUE(workstream_id, source, external_id)
);

-- Workstream notes (blockers, decisions, context)
CREATE TABLE IF NOT EXISTS workstream_notes (
  id TEXT PRIMARY KEY,
  workstream_id TEXT NOT NULL REFERENCES workstreams(id),
  session_id TEXT,
  type TEXT NOT NULL DEFAULT 'note',  -- 'note', 'blocker', 'decision'
  content TEXT NOT NULL,
  metadata TEXT,  -- JSON for additional data
  created_at TEXT NOT NULL,
  resolved_at TEXT
);

-- Claude Code sessions
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  project_path TEXT NOT NULL,
  project_name TEXT,
  branch TEXT,
  model TEXT,
  provider TEXT DEFAULT 'claude',  -- 'claude', 'codex', 'gemini'

  -- Naming hierarchy: custom_name > summary > first_prompt > project_name
  context_label TEXT,   -- Legacy field
  custom_name TEXT,     -- User-defined name (highest priority)
  summary TEXT,         -- Claude-generated title
  first_prompt TEXT,    -- First user message (fallback)

  transcript_path TEXT,

  -- Status
  status TEXT DEFAULT 'active',      -- 'active', 'idle', 'ended'
  work_status TEXT DEFAULT 'unknown', -- 'working', 'waiting', 'permission', 'unknown'

  -- Attention state (why session needs user attention)
  attention_reason TEXT,      -- 'none', 'awaitingReply', 'awaitingPermission', 'awaitingQuestion'
  pending_tool_name TEXT,     -- Which tool needs permission
  pending_tool_input TEXT,    -- JSON of tool input (for display)
  pending_question TEXT,      -- Question text from AskUserQuestion

  -- Timestamps
  started_at TEXT,
  ended_at TEXT,
  end_reason TEXT,            -- 'clear', 'logout', 'manual', 'stale', etc.
  last_activity_at TEXT,
  last_tool TEXT,
  last_tool_at TEXT,

  -- Stats
  total_tokens INTEGER DEFAULT 0,
  total_cost_usd REAL DEFAULT 0,
  prompt_count INTEGER DEFAULT 0,
  tool_count INTEGER DEFAULT 0,

  -- Terminal tracking
  terminal_session_id TEXT,
  terminal_app TEXT,

  -- Workstream link
  workstream_id TEXT REFERENCES workstreams(id)
);

-- Session activities (tool usage, events)
CREATE TABLE IF NOT EXISTS activities (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  timestamp TEXT NOT NULL,
  event_type TEXT,
  tool_name TEXT,
  file_path TEXT,
  summary TEXT,
  tokens_used INTEGER,
  cost_usd REAL
);

-- Projects (user-defined groupings of workstreams)
CREATE TABLE IF NOT EXISTS projects (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  color TEXT,
  status TEXT DEFAULT 'active',  -- 'active', 'archived'
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Project-Workstream junction table
CREATE TABLE IF NOT EXISTS project_workstreams (
  project_id TEXT NOT NULL REFERENCES projects(id),
  workstream_id TEXT NOT NULL REFERENCES workstreams(id),
  PRIMARY KEY (project_id, workstream_id)
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);
CREATE INDEX IF NOT EXISTS idx_sessions_project_path ON sessions(project_path);
CREATE INDEX IF NOT EXISTS idx_sessions_workstream ON sessions(workstream_id);
CREATE INDEX IF NOT EXISTS idx_sessions_terminal ON sessions(terminal_session_id);
CREATE INDEX IF NOT EXISTS idx_workstreams_repo ON workstreams(repo_id);
CREATE INDEX IF NOT EXISTS idx_workstreams_branch ON workstreams(repo_id, branch);
CREATE INDEX IF NOT EXISTS idx_activities_session ON activities(session_id);
