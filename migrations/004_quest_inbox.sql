-- Quest + Inbox System
-- Replaces workstreams with flexible, user-defined work containers

-- Quests: flexible work containers (not branch-centric)
CREATE TABLE IF NOT EXISTS quests (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  status TEXT DEFAULT 'active',  -- 'active', 'paused', 'completed'
  color TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  completed_at TEXT
);

-- Inbox items: global quick capture
CREATE TABLE IF NOT EXISTS inbox_items (
  id TEXT PRIMARY KEY,
  content TEXT NOT NULL,
  source TEXT DEFAULT 'manual',  -- 'manual', 'cli', 'quickswitcher'
  session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL,
  quest_id TEXT REFERENCES quests(id) ON DELETE SET NULL,
  created_at TEXT DEFAULT (datetime('now')),
  attached_at TEXT
);

-- Quest links: high-confidence external links only
CREATE TABLE IF NOT EXISTS quest_links (
  id TEXT PRIMARY KEY,
  quest_id TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  source TEXT NOT NULL,  -- 'github_pr', 'github_issue', 'linear', 'plan_file'
  url TEXT NOT NULL,
  title TEXT,
  external_id TEXT,  -- e.g., "VIZ-123" or "#456"
  detected_from TEXT,  -- 'cli_output', 'manual'
  created_at TEXT DEFAULT (datetime('now')),
  UNIQUE(quest_id, url)
);

-- Quest-session relationships: many-to-many
CREATE TABLE IF NOT EXISTS quest_sessions (
  quest_id TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  linked_at TEXT DEFAULT (datetime('now')),
  PRIMARY KEY (quest_id, session_id)
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_quest_status ON quests(status);
CREATE INDEX IF NOT EXISTS idx_inbox_quest ON inbox_items(quest_id);
CREATE INDEX IF NOT EXISTS idx_inbox_unattached ON inbox_items(quest_id) WHERE quest_id IS NULL;
CREATE INDEX IF NOT EXISTS idx_quest_links_quest ON quest_links(quest_id);
CREATE INDEX IF NOT EXISTS idx_quest_sessions_quest ON quest_sessions(quest_id);
CREATE INDEX IF NOT EXISTS idx_quest_sessions_session ON quest_sessions(session_id);
