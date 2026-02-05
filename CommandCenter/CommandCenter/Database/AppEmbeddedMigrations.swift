//
//  AppEmbeddedMigrations.swift
//  OrbitDock
//
//  Embedded database migrations for the app.
//  Keep in sync with OrbitDockCore/Database/EmbeddedMigrations.swift
//

import Foundation

/// Embedded database migrations for the app
/// Note: This mirrors OrbitDockCore/EmbeddedMigrations for the CLI
/// When adding new migrations, update BOTH files
enum AppEmbeddedMigrations: Sendable {
  struct Migration: Sendable {
    let version: Int
    let name: String
    let sql: String
  }

  nonisolated(unsafe) static let all: [Migration] = [
    migration001,
    migration002,
    migration003,
    migration004,
    migration005,
    migration006,
    migration007,
    migration008,
    migration009,
    migration010,
  ]

  // MARK: - Migration 001: Initial schema

  static let migration001 = Migration(
    version: 1,
    name: "initial",
    sql: """
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
        linear_issue_id TEXT,
        linear_issue_title TEXT,
        linear_issue_state TEXT,
        linear_issue_url TEXT,
        github_issue_number INTEGER,
        github_issue_title TEXT,
        github_issue_state TEXT,
        github_pr_number INTEGER,
        github_pr_title TEXT,
        github_pr_state TEXT,
        github_pr_url TEXT,
        github_pr_additions INTEGER,
        github_pr_deletions INTEGER,
        review_state TEXT,
        review_approvals INTEGER DEFAULT 0,
        review_comments INTEGER DEFAULT 0,
        stage TEXT DEFAULT 'working',
        is_working INTEGER DEFAULT 1,
        has_open_pr INTEGER DEFAULT 0,
        in_review INTEGER DEFAULT 0,
        has_approval INTEGER DEFAULT 0,
        is_merged INTEGER DEFAULT 0,
        is_closed INTEGER DEFAULT 0,
        session_count INTEGER DEFAULT 0,
        total_session_seconds INTEGER DEFAULT 0,
        commit_count INTEGER DEFAULT 0,
        last_activity_at TEXT,
        created_at TEXT DEFAULT (datetime('now')),
        updated_at TEXT DEFAULT (datetime('now')),
        UNIQUE(repo_id, branch)
      );

      -- Workstream tickets
      CREATE TABLE IF NOT EXISTS workstream_tickets (
        id TEXT PRIMARY KEY,
        workstream_id TEXT NOT NULL REFERENCES workstreams(id),
        source TEXT NOT NULL,
        external_id TEXT NOT NULL,
        title TEXT,
        state TEXT,
        url TEXT,
        is_primary INTEGER DEFAULT 0,
        created_at TEXT DEFAULT (datetime('now')),
        UNIQUE(workstream_id, source, external_id)
      );

      -- Workstream notes
      CREATE TABLE IF NOT EXISTS workstream_notes (
        id TEXT PRIMARY KEY,
        workstream_id TEXT NOT NULL REFERENCES workstreams(id),
        session_id TEXT,
        type TEXT NOT NULL DEFAULT 'note',
        content TEXT NOT NULL,
        metadata TEXT,
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
        provider TEXT DEFAULT 'claude',
        context_label TEXT,
        custom_name TEXT,
        summary TEXT,
        first_prompt TEXT,
        transcript_path TEXT,
        status TEXT DEFAULT 'active',
        work_status TEXT DEFAULT 'unknown',
        attention_reason TEXT,
        pending_tool_name TEXT,
        pending_tool_input TEXT,
        pending_question TEXT,
        started_at TEXT,
        ended_at TEXT,
        end_reason TEXT,
        last_activity_at TEXT,
        last_tool TEXT,
        last_tool_at TEXT,
        total_tokens INTEGER DEFAULT 0,
        total_cost_usd REAL DEFAULT 0,
        prompt_count INTEGER DEFAULT 0,
        tool_count INTEGER DEFAULT 0,
        terminal_session_id TEXT,
        terminal_app TEXT,
        workstream_id TEXT REFERENCES workstreams(id)
      );

      -- Session activities
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

      -- Projects
      CREATE TABLE IF NOT EXISTS projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT,
        color TEXT,
        status TEXT DEFAULT 'active',
        created_at TEXT DEFAULT (datetime('now')),
        updated_at TEXT DEFAULT (datetime('now'))
      );

      -- Project-Workstream junction
      CREATE TABLE IF NOT EXISTS project_workstreams (
        project_id TEXT NOT NULL REFERENCES projects(id),
        workstream_id TEXT NOT NULL REFERENCES workstreams(id),
        PRIMARY KEY (project_id, workstream_id)
      );

      -- Indexes
      CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);
      CREATE INDEX IF NOT EXISTS idx_sessions_project_path ON sessions(project_path);
      CREATE INDEX IF NOT EXISTS idx_sessions_workstream ON sessions(workstream_id);
      CREATE INDEX IF NOT EXISTS idx_sessions_terminal ON sessions(terminal_session_id);
      CREATE INDEX IF NOT EXISTS idx_workstreams_repo ON workstreams(repo_id);
      CREATE INDEX IF NOT EXISTS idx_workstreams_branch ON workstreams(repo_id, branch);
      CREATE INDEX IF NOT EXISTS idx_activities_session ON activities(session_id);
      """
  )

  // MARK: - Migration 002: Codex sessions

  static let migration002 = Migration(
    version: 2,
    name: "add_codex_sessions",
    sql: """
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
      """
  )

  // MARK: - Migration 003: Workstream archived

  static let migration003 = Migration(
    version: 3,
    name: "add_workstream_archived",
    sql: """
      ALTER TABLE workstreams ADD COLUMN is_archived INTEGER DEFAULT 0;
      CREATE INDEX IF NOT EXISTS idx_workstreams_archived ON workstreams(is_archived);
      """
  )

  // MARK: - Migration 004: Quest + Inbox

  static let migration004 = Migration(
    version: 4,
    name: "quest_inbox",
    sql: """
      CREATE TABLE IF NOT EXISTS quests (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT,
        status TEXT DEFAULT 'active',
        color TEXT,
        created_at TEXT DEFAULT (datetime('now')),
        updated_at TEXT DEFAULT (datetime('now')),
        completed_at TEXT
      );

      CREATE TABLE IF NOT EXISTS inbox_items (
        id TEXT PRIMARY KEY,
        content TEXT NOT NULL,
        source TEXT DEFAULT 'manual',
        session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL,
        quest_id TEXT REFERENCES quests(id) ON DELETE SET NULL,
        created_at TEXT DEFAULT (datetime('now')),
        attached_at TEXT
      );

      CREATE TABLE IF NOT EXISTS quest_links (
        id TEXT PRIMARY KEY,
        quest_id TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
        source TEXT NOT NULL,
        url TEXT NOT NULL,
        title TEXT,
        external_id TEXT,
        detected_from TEXT,
        created_at TEXT DEFAULT (datetime('now')),
        UNIQUE(quest_id, url)
      );

      CREATE TABLE IF NOT EXISTS quest_sessions (
        quest_id TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        linked_at TEXT DEFAULT (datetime('now')),
        PRIMARY KEY (quest_id, session_id)
      );

      CREATE INDEX IF NOT EXISTS idx_quest_status ON quests(status);
      CREATE INDEX IF NOT EXISTS idx_inbox_quest ON inbox_items(quest_id);
      CREATE INDEX IF NOT EXISTS idx_inbox_unattached ON inbox_items(quest_id) WHERE quest_id IS NULL;
      CREATE INDEX IF NOT EXISTS idx_quest_links_quest ON quest_links(quest_id);
      CREATE INDEX IF NOT EXISTS idx_quest_sessions_quest ON quest_sessions(quest_id);
      CREATE INDEX IF NOT EXISTS idx_quest_sessions_session ON quest_sessions(session_id);
      """
  )

  // MARK: - Migration 005: Enhanced hook tracking

  static let migration005 = Migration(
    version: 5,
    name: "enhanced_hook_tracking",
    sql: """
      ALTER TABLE sessions ADD COLUMN source TEXT;
      ALTER TABLE sessions ADD COLUMN agent_type TEXT;
      ALTER TABLE sessions ADD COLUMN permission_mode TEXT;
      ALTER TABLE sessions ADD COLUMN compact_count INTEGER DEFAULT 0;
      ALTER TABLE sessions ADD COLUMN active_subagent_id TEXT;
      ALTER TABLE sessions ADD COLUMN active_subagent_type TEXT;

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

      CREATE TABLE IF NOT EXISTS compactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL REFERENCES sessions(id),
        trigger TEXT NOT NULL,
        custom_instructions TEXT,
        compacted_at TEXT NOT NULL
      );

      CREATE INDEX IF NOT EXISTS idx_compactions_session ON compactions(session_id);
      """
  )

  // MARK: - Migration 006: Inbox status

  static let migration006 = Migration(
    version: 6,
    name: "inbox_status",
    sql: """
      ALTER TABLE inbox_items ADD COLUMN status TEXT DEFAULT 'pending';
      ALTER TABLE inbox_items ADD COLUMN linear_issue_id TEXT;
      ALTER TABLE inbox_items ADD COLUMN linear_issue_url TEXT;
      ALTER TABLE inbox_items ADD COLUMN completed_at TEXT;
      CREATE INDEX IF NOT EXISTS idx_inbox_status ON inbox_items(status);
      """
  )

  // MARK: - Migration 007: Quest notes

  static let migration007 = Migration(
    version: 7,
    name: "quest_notes",
    sql: """
      CREATE TABLE IF NOT EXISTS quest_notes (
        id TEXT PRIMARY KEY,
        quest_id TEXT NOT NULL REFERENCES quests(id) ON DELETE CASCADE,
        title TEXT,
        content TEXT NOT NULL,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
      );

      CREATE INDEX IF NOT EXISTS idx_quest_notes_quest_id ON quest_notes(quest_id);
      """
  )

  // MARK: - Migration 008: Codex direct integration

  static let migration008 = Migration(
    version: 8,
    name: "codex_direct_integration",
    sql: """
      ALTER TABLE sessions ADD COLUMN codex_integration_mode TEXT;
      ALTER TABLE sessions ADD COLUMN codex_thread_id TEXT;
      ALTER TABLE sessions ADD COLUMN pending_approval_id TEXT;
      CREATE INDEX IF NOT EXISTS idx_sessions_codex_thread_id ON sessions(codex_thread_id);
      """
  )

  // MARK: - Migration 009: Codex token usage tracking

  static let migration009 = Migration(
    version: 9,
    name: "codex_token_usage",
    sql: """
      ALTER TABLE sessions ADD COLUMN codex_input_tokens INTEGER;
      ALTER TABLE sessions ADD COLUMN codex_output_tokens INTEGER;
      ALTER TABLE sessions ADD COLUMN codex_cached_tokens INTEGER;
      ALTER TABLE sessions ADD COLUMN codex_context_window INTEGER;
      """
  )

  // MARK: - Migration 010: Codex turn state (diff/plan)

  static let migration010 = Migration(
    version: 10,
    name: "codex_turn_state",
    sql: """
      ALTER TABLE sessions ADD COLUMN current_diff TEXT;
      ALTER TABLE sessions ADD COLUMN current_plan TEXT;
      """
  )
}
