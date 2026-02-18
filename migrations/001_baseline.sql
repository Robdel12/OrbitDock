-- OrbitDock baseline schema
-- 7 tables: schema_versions, sessions, messages, subagents,
--           turn_diffs, approval_history, review_comments

-- Migration tracking
CREATE TABLE IF NOT EXISTS schema_versions (
    version INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- Core session tracking (Claude, Codex, etc.)
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    provider TEXT NOT NULL DEFAULT 'claude',
    status TEXT NOT NULL DEFAULT 'active',
    work_status TEXT NOT NULL DEFAULT 'waiting',

    -- Project
    project_path TEXT NOT NULL,
    project_name TEXT,
    branch TEXT,
    model TEXT,
    context_label TEXT,
    transcript_path TEXT,

    -- Naming hierarchy: custom_name > summary > first_prompt > project_name
    custom_name TEXT,
    summary TEXT,
    first_prompt TEXT,
    last_message TEXT,

    -- Attention state
    attention_reason TEXT,
    pending_tool_name TEXT,
    pending_tool_input TEXT,
    pending_question TEXT,

    -- Timestamps
    started_at TEXT,
    ended_at TEXT,
    end_reason TEXT,
    last_activity_at TEXT,
    last_tool TEXT,
    last_tool_at TEXT,

    -- Stats
    total_tokens INTEGER DEFAULT 0,
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,
    cached_tokens INTEGER DEFAULT 0,
    context_window INTEGER DEFAULT 0,
    prompt_count INTEGER DEFAULT 0,
    tool_count INTEGER DEFAULT 0,
    compact_count INTEGER DEFAULT 0,
    effort TEXT,

    -- Hook metadata
    source TEXT,
    agent_type TEXT,
    permission_mode TEXT,

    -- Codex integration
    codex_integration_mode TEXT,
    codex_thread_id TEXT,

    -- Claude integration
    claude_integration_mode TEXT,
    claude_sdk_session_id TEXT,

    -- Autonomy config
    approval_policy TEXT,
    sandbox_mode TEXT,

    -- Fork tracking
    forked_from_session_id TEXT,

    -- Turn state snapshots
    current_diff TEXT,
    current_plan TEXT,

    -- Environment
    current_cwd TEXT,
    git_branch TEXT,
    git_sha TEXT,

    -- Terminal
    terminal_session_id TEXT,
    terminal_app TEXT,

    -- Subagent tracking
    active_subagent_id TEXT,
    active_subagent_type TEXT
);

CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);
CREATE INDEX IF NOT EXISTS idx_sessions_project_path ON sessions(project_path);
CREATE INDEX IF NOT EXISTS idx_sessions_codex_thread_id ON sessions(codex_thread_id);
CREATE INDEX IF NOT EXISTS idx_sessions_claude_sdk_session_id ON sessions(claude_sdk_session_id);

-- Session messages
CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES sessions(id),
    type TEXT NOT NULL,
    content TEXT,
    timestamp TEXT NOT NULL,
    sequence INTEGER NOT NULL DEFAULT 0,
    tool_name TEXT,
    tool_input TEXT,
    tool_output TEXT,
    tool_duration REAL,
    is_in_progress INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id);
CREATE INDEX IF NOT EXISTS idx_messages_session_seq ON messages(session_id, sequence);

-- Spawned subagents (Explore, Plan, etc.)
CREATE TABLE IF NOT EXISTS subagents (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES sessions(id),
    agent_type TEXT NOT NULL,
    transcript_path TEXT,
    started_at TEXT NOT NULL,
    ended_at TEXT,
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_subagents_session ON subagents(session_id);

-- Per-turn diff snapshots + token usage
CREATE TABLE IF NOT EXISTS turn_diffs (
    session_id TEXT NOT NULL REFERENCES sessions(id),
    turn_id TEXT NOT NULL,
    diff TEXT NOT NULL,
    input_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    cached_tokens INTEGER NOT NULL DEFAULT 0,
    context_window INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    PRIMARY KEY (session_id, turn_id)
);

CREATE INDEX IF NOT EXISTS idx_turn_diffs_session ON turn_diffs(session_id);

-- Tool approval audit log
CREATE TABLE IF NOT EXISTS approval_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL REFERENCES sessions(id),
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

CREATE INDEX IF NOT EXISTS idx_approval_history_session ON approval_history(session_id, id DESC);
CREATE INDEX IF NOT EXISTS idx_approval_history_created_at ON approval_history(created_at DESC);

-- Code review annotations
CREATE TABLE IF NOT EXISTS review_comments (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES sessions(id),
    turn_id TEXT,
    file_path TEXT NOT NULL,
    line_start INTEGER NOT NULL,
    line_end INTEGER,
    body TEXT NOT NULL,
    tag TEXT,
    status TEXT NOT NULL DEFAULT 'open',
    created_at TEXT NOT NULL,
    updated_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_review_comments_session ON review_comments(session_id);
CREATE INDEX IF NOT EXISTS idx_review_comments_session_turn ON review_comments(session_id, turn_id);

-- Codex shadow write guards (prevent passive watcher from overwriting direct sessions)
CREATE TRIGGER IF NOT EXISTS trg_sessions_block_direct_thread_shadow_insert
BEFORE INSERT ON sessions
WHEN EXISTS (
    SELECT 1 FROM sessions direct
    WHERE direct.codex_integration_mode = 'direct'
      AND direct.codex_thread_id = NEW.id
) AND COALESCE(NEW.provider, 'claude') != 'codex'
BEGIN
    SELECT RAISE(IGNORE);
END;

CREATE TRIGGER IF NOT EXISTS trg_sessions_block_direct_thread_shadow_update
BEFORE UPDATE ON sessions
WHEN EXISTS (
    SELECT 1 FROM sessions direct
    WHERE direct.codex_integration_mode = 'direct'
      AND direct.codex_thread_id = NEW.id
) AND COALESCE(NEW.provider, 'claude') != 'codex'
BEGIN
    SELECT RAISE(IGNORE);
END;

CREATE TRIGGER IF NOT EXISTS trg_sessions_normalize_codex_cli_rs_insert
AFTER INSERT ON sessions
WHEN NEW.context_label = 'codex_cli_rs'
BEGIN
    UPDATE sessions
    SET provider = 'codex',
        codex_integration_mode = COALESCE(codex_integration_mode, 'passive'),
        codex_thread_id = COALESCE(codex_thread_id, id)
    WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_sessions_normalize_codex_cli_rs_update
AFTER UPDATE ON sessions
WHEN NEW.context_label = 'codex_cli_rs'
BEGIN
    UPDATE sessions
    SET provider = 'codex',
        codex_integration_mode = COALESCE(codex_integration_mode, 'passive'),
        codex_thread_id = COALESCE(codex_thread_id, id)
    WHERE id = NEW.id;
END;
