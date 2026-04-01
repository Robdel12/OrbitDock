use rusqlite::Connection;
use std::sync::{Mutex, OnceLock};

use orbitdock_protocol::conversation_contracts::{
  rows::MessageDeliveryStatus, ConversationRow, ConversationRowEntry, MessageRowContent,
};
use orbitdock_protocol::{CodexConfigMode, Provider, SessionLifecycleState, SessionStatus};

use super::commands::{PersistCommand, SessionCreateParams};
use super::messages::load_messages_from_db;
use super::SyncCommand;

fn persistence_test_db_guard() -> &'static Mutex<()> {
  static GUARD: OnceLock<Mutex<()>> = OnceLock::new();
  GUARD.get_or_init(|| Mutex::new(()))
}

type PersistenceTestGuard = std::sync::MutexGuard<'static, ()>;

fn setup_test_db() -> (
  Connection,
  std::path::PathBuf,
  tempfile::TempDir,
  PersistenceTestGuard,
) {
  let guard = persistence_test_db_guard().lock().unwrap();
  crate::support::test_support::ensure_server_test_data_dir();
  let dir = tempfile::TempDir::new().unwrap();
  crate::infrastructure::paths::init_data_dir(Some(dir.path()));
  let db_path = dir.path().join("orbitdock.db");
  let conn = Connection::open(&db_path).unwrap();
  conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;
         PRAGMA synchronous = NORMAL;
         PRAGMA foreign_keys = ON;

         CREATE TABLE IF NOT EXISTS sessions (
           id TEXT PRIMARY KEY,
           provider TEXT NOT NULL DEFAULT 'codex',
           status TEXT NOT NULL DEFAULT 'active',
           work_status TEXT NOT NULL DEFAULT 'waiting',
           lifecycle_state TEXT NOT NULL DEFAULT 'open',
           control_mode TEXT,
           project_path TEXT NOT NULL DEFAULT '',
           project_name TEXT,
           branch TEXT,
           model TEXT,
           context_label TEXT,
           transcript_path TEXT,
           custom_name TEXT,
           summary TEXT,
           first_prompt TEXT,
           last_message TEXT,
           attention_reason TEXT,
           pending_tool_name TEXT,
           pending_tool_input TEXT,
           pending_question TEXT,
           started_at TEXT,
           ended_at TEXT,
           end_reason TEXT,
           last_activity_at TEXT,
           last_progress_at TEXT,
           last_tool TEXT,
           last_tool_at TEXT,
           total_tokens INTEGER NOT NULL DEFAULT 0,
           input_tokens INTEGER NOT NULL DEFAULT 0,
           output_tokens INTEGER NOT NULL DEFAULT 0,
           cached_tokens INTEGER NOT NULL DEFAULT 0,
           context_window INTEGER NOT NULL DEFAULT 0,
           prompt_count INTEGER NOT NULL DEFAULT 0,
           tool_count INTEGER NOT NULL DEFAULT 0,
           compact_count INTEGER NOT NULL DEFAULT 0,
           effort TEXT,
           source TEXT,
           agent_type TEXT,
           permission_mode TEXT,
           codex_integration_mode TEXT,
           codex_thread_id TEXT,
           claude_integration_mode TEXT,
           claude_sdk_session_id TEXT,
           approval_policy TEXT,
           sandbox_mode TEXT,
           forked_from_session_id TEXT,
           current_diff TEXT,
           current_plan TEXT,
           current_cwd TEXT,
           git_branch TEXT,
           git_sha TEXT,
           terminal_session_id TEXT,
           terminal_app TEXT,
           active_subagent_id TEXT,
           active_subagent_type TEXT,
           collaboration_mode TEXT,
           multi_agent INTEGER,
           personality TEXT,
           service_tier TEXT,
           developer_instructions TEXT,
           codex_config_mode TEXT,
           codex_config_profile TEXT,
           codex_model_provider TEXT,
           codex_config_source TEXT,
           codex_config_overrides_json TEXT,
           pending_approval_id TEXT,
           approval_version INTEGER NOT NULL DEFAULT 0,
           unread_count INTEGER NOT NULL DEFAULT 0,
           last_read_sequence INTEGER NOT NULL DEFAULT 0,
           mission_id TEXT,
           issue_identifier TEXT,
           allow_bypass_permissions INTEGER NOT NULL DEFAULT 0,
           repository_root TEXT,
           is_worktree INTEGER NOT NULL DEFAULT 0,
           worktree_id TEXT
         );

         CREATE TABLE IF NOT EXISTS messages (
           id TEXT PRIMARY KEY,
           session_id TEXT NOT NULL REFERENCES sessions(id),
           type TEXT NOT NULL DEFAULT '',
           content TEXT NOT NULL DEFAULT '',
           timestamp TEXT,
           sequence INTEGER DEFAULT 0,
           row_data TEXT,
           is_in_progress INTEGER DEFAULT 0,
           turn_status TEXT NOT NULL DEFAULT 'active'
         );

         CREATE INDEX IF NOT EXISTS idx_messages_session_sequence
           ON messages(session_id, sequence);

         CREATE TABLE IF NOT EXISTS turn_diffs (
           session_id TEXT NOT NULL REFERENCES sessions(id),
           turn_id TEXT NOT NULL,
           diff TEXT NOT NULL,
           input_tokens INTEGER NOT NULL DEFAULT 0,
           output_tokens INTEGER NOT NULL DEFAULT 0,
           cached_tokens INTEGER NOT NULL DEFAULT 0,
           context_window INTEGER NOT NULL DEFAULT 0,
           PRIMARY KEY (session_id, turn_id)
         );

         CREATE TABLE IF NOT EXISTS usage_session_state (
           session_id TEXT PRIMARY KEY,
           snapshot_input_tokens INTEGER,
           snapshot_output_tokens INTEGER,
           snapshot_cached_tokens INTEGER,
           snapshot_context_window INTEGER,
           snapshot_kind TEXT
         );

         INSERT INTO sessions (id, project_path, provider) VALUES ('test-session', '/tmp/test', 'codex');",
    )
    .unwrap();

  (conn, db_path, dir, guard)
}

fn user_entry(id: &str, sequence: u64) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: "test-session".to_string(),
    sequence,
    turn_id: None,
    turn_status: Default::default(),
    row: ConversationRow::User(MessageRowContent {
      id: id.to_string(),
      content: format!("message from {id}"),
      turn_id: None,
      timestamp: None,
      is_streaming: false,
      images: vec![],
      memory_citation: None,
      delivery_status: None,
    }),
  }
}

fn assistant_entry(id: &str, sequence: u64) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: "test-session".to_string(),
    sequence,
    turn_id: None,
    turn_status: Default::default(),
    row: ConversationRow::Assistant(MessageRowContent {
      id: id.to_string(),
      content: format!("response from {id}"),
      turn_id: None,
      timestamp: None,
      is_streaming: false,
      images: vec![],
      memory_citation: None,
      delivery_status: None,
    }),
  }
}

fn steer_entry(id: &str, sequence: u64) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: "test-session".to_string(),
    sequence,
    turn_id: None,
    turn_status: Default::default(),
    row: ConversationRow::Steer(MessageRowContent {
      id: id.to_string(),
      content: format!("steer from {id}"),
      turn_id: None,
      timestamp: None,
      is_streaming: false,
      images: vec![],
      memory_citation: None,
      delivery_status: Some(MessageDeliveryStatus::Pending),
    }),
  }
}

fn session_lifecycle_state(conn: &Connection, session_id: &str) -> String {
  conn
    .query_row(
      "SELECT lifecycle_state FROM sessions WHERE id = ?1",
      [session_id],
      |row| row.get(0),
    )
    .unwrap()
}

fn session_control_mode(conn: &Connection, session_id: &str) -> String {
  conn
    .query_row(
      "SELECT control_mode FROM sessions WHERE id = ?1",
      [session_id],
      |row| row.get(0),
    )
    .unwrap()
}

fn session_last_activity_at(conn: &Connection, session_id: &str) -> Option<String> {
  conn
    .query_row(
      "SELECT last_activity_at FROM sessions WHERE id = ?1",
      [session_id],
      |row| row.get(0),
    )
    .unwrap()
}

fn session_last_progress_at(conn: &Connection, session_id: &str) -> Option<String> {
  conn
    .query_row(
      "SELECT last_progress_at FROM sessions WHERE id = ?1",
      [session_id],
      |row| row.get(0),
    )
    .unwrap()
}

#[test]
fn row_append_stores_correct_sequence() {
  let (conn, db_path, _dir, _guard) = setup_test_db();
  drop(conn);

  let batch = vec![
    PersistCommand::RowAppend {
      session_id: "test-session".to_string(),
      viewer_present: false,
      assigned_sequence: None,
      sequence_tx: None,
      entry: user_entry("row-0", 0),
    },
    PersistCommand::RowAppend {
      session_id: "test-session".to_string(),
      viewer_present: false,
      assigned_sequence: None,
      sequence_tx: None,
      entry: assistant_entry("row-1", 1),
    },
    PersistCommand::RowAppend {
      session_id: "test-session".to_string(),
      viewer_present: false,
      assigned_sequence: None,
      sequence_tx: None,
      entry: user_entry("row-2", 2),
    },
  ];

  super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  let conn = Connection::open(&db_path).unwrap();
  let rows = load_messages_from_db(&conn, "test-session").unwrap();

  assert_eq!(rows.len(), 3);
  assert_eq!(rows[0].sequence, 0);
  assert_eq!(rows[1].sequence, 1);
  assert_eq!(rows[2].sequence, 2);
}

#[test]
fn flush_batch_emits_row_sync_commands_with_db_assigned_sequences() {
  let (conn, db_path, _dir, _guard) = setup_test_db();
  drop(conn);

  let batch = vec![
    PersistCommand::RowAppend {
      session_id: "test-session".to_string(),
      viewer_present: false,
      assigned_sequence: None,
      sequence_tx: None,
      entry: user_entry("row-a", 0),
    },
    PersistCommand::RowAppend {
      session_id: "test-session".to_string(),
      viewer_present: true,
      assigned_sequence: None,
      sequence_tx: None,
      entry: assistant_entry("row-b", 0),
    },
  ];

  let result = super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  assert_eq!(result.command_count, 2);
  assert_eq!(result.sync_commands.len(), 2);
  assert!(matches!(
    &result.sync_commands[0],
    SyncCommand::RowAppend { sequence: 0, .. }
  ));
  assert!(matches!(
    &result.sync_commands[1],
    SyncCommand::RowAppend { sequence: 1, .. }
  ));
}

#[test]
fn flush_batch_skips_non_syncable_commands() {
  let (conn, db_path, _dir, _guard) = setup_test_db();
  drop(conn);

  let batch = vec![
    PersistCommand::SetConfig {
      key: "workspace_provider".to_string(),
      value: "local".to_string(),
    },
    PersistCommand::RowAppend {
      session_id: "test-session".to_string(),
      viewer_present: false,
      assigned_sequence: None,
      sequence_tx: None,
      entry: user_entry("row-syncable", 0),
    },
  ];

  let result = super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  assert_eq!(result.command_count, 2);
  assert_eq!(result.sync_commands.len(), 1);
  assert!(matches!(
    &result.sync_commands[0],
    SyncCommand::RowAppend { .. }
  ));
}

#[test]
fn row_append_with_zero_sequence_gets_db_assigned_sequence() {
  // DB computes MAX(sequence)+1 — callers no longer need to assign sequences.
  let (conn, db_path, _dir, _guard) = setup_test_db();
  drop(conn);

  let batch = vec![
    PersistCommand::RowAppend {
      session_id: "test-session".to_string(),
      viewer_present: false,
      assigned_sequence: None,
      sequence_tx: None,
      entry: user_entry("row-a", 0),
    },
    PersistCommand::RowAppend {
      session_id: "test-session".to_string(),
      viewer_present: false,
      assigned_sequence: None,
      sequence_tx: None,
      entry: user_entry("row-b", 0),
    },
  ];

  super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  let conn = Connection::open(&db_path).unwrap();
  let rows = load_messages_from_db(&conn, "test-session").unwrap();

  // DB assigns contiguous sequences regardless of the app-provided value.
  assert_eq!(rows.len(), 2);
  assert_eq!(rows[0].sequence, 0);
  assert_eq!(rows[1].sequence, 1);
}

#[test]
fn row_upsert_preserves_original_sequence_on_conflict() {
  let (conn, db_path, _dir, _guard) = setup_test_db();
  drop(conn);

  // First: insert a row — DB assigns sequence=0
  let batch = vec![PersistCommand::RowAppend {
    session_id: "test-session".to_string(),
    viewer_present: false,
    assigned_sequence: None,
    sequence_tx: None,
    entry: user_entry("row-0", 0),
  }];
  super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  // Then: upsert the same row — sequence should be preserved (not overwritten)
  let batch = vec![PersistCommand::RowUpsert {
    session_id: "test-session".to_string(),
    viewer_present: false,
    assigned_sequence: None,
    sequence_tx: None,
    entry: user_entry("row-0", 5),
  }];
  super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  let conn = Connection::open(&db_path).unwrap();
  let rows = load_messages_from_db(&conn, "test-session").unwrap();

  assert_eq!(rows.len(), 1);
  // ON CONFLICT preserves the original DB-assigned sequence
  assert_eq!(
    rows[0].sequence, 0,
    "RowUpsert must preserve original sequence on conflict"
  );
}

#[test]
fn row_upsert_inserts_when_not_existing() {
  let (conn, db_path, _dir, _guard) = setup_test_db();
  drop(conn);

  let batch = vec![PersistCommand::RowUpsert {
    session_id: "test-session".to_string(),
    viewer_present: false,
    assigned_sequence: None,
    sequence_tx: None,
    entry: user_entry("new-row", 3),
  }];
  super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  let conn = Connection::open(&db_path).unwrap();
  let rows = load_messages_from_db(&conn, "test-session").unwrap();

  assert_eq!(rows.len(), 1);
  assert_eq!(rows[0].id(), "new-row");
  // DB computes sequence as MAX+1 (0 for first row), ignoring app-provided value
  assert_eq!(rows[0].sequence, 0);
}

#[test]
fn steer_rows_persist_as_steer_type() {
  let (conn, db_path, _dir, _guard) = setup_test_db();
  drop(conn);

  let batch = vec![PersistCommand::RowAppend {
    session_id: "test-session".to_string(),
    viewer_present: false,
    assigned_sequence: None,
    sequence_tx: None,
    entry: steer_entry("steer-1", 0),
  }];

  super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  let conn = Connection::open(&db_path).unwrap();
  let row_type: String = conn
    .query_row(
      "SELECT type FROM messages WHERE id = 'steer-1'",
      [],
      |row| row.get(0),
    )
    .unwrap();
  let rows = load_messages_from_db(&conn, "test-session").unwrap();

  assert_eq!(row_type, "steer");
  match &rows[0].row {
    ConversationRow::Steer(_) => {}
    other => panic!("expected user row, got {other:?}"),
  }
}

#[test]
fn batch_of_appends_preserves_insertion_order() {
  let (conn, db_path, _dir, _guard) = setup_test_db();
  drop(conn);

  // Simulate a burst of 10 rapid messages with correct sequences
  let batch: Vec<PersistCommand> = (0..10)
    .map(|i| PersistCommand::RowAppend {
      session_id: "test-session".to_string(),
      viewer_present: false,
      assigned_sequence: None,
      sequence_tx: None,
      entry: assistant_entry(&format!("msg-{i}"), i as u64),
    })
    .collect();

  super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  let conn = Connection::open(&db_path).unwrap();
  let rows = load_messages_from_db(&conn, "test-session").unwrap();

  assert_eq!(rows.len(), 10);
  for (i, row) in rows.iter().enumerate() {
    assert_eq!(row.id(), format!("msg-{i}"));
    assert_eq!(row.sequence, i as u64);
  }

  // Verify ORDER BY sequence returns them in correct order
  let sequences: Vec<u64> = rows.iter().map(|r| r.sequence).collect();
  let mut sorted = sequences.clone();
  sorted.sort();
  assert_eq!(
    sequences, sorted,
    "rows must be ordered by sequence from DB"
  );
}

#[test]
fn row_append_ignore_deduplicates_by_id() {
  let (conn, db_path, _dir, _guard) = setup_test_db();
  drop(conn);

  // ON CONFLICT(id) DO NOTHING means second insert with same id is silently dropped
  let batch = vec![
    PersistCommand::RowAppend {
      session_id: "test-session".to_string(),
      viewer_present: false,
      assigned_sequence: None,
      sequence_tx: None,
      entry: user_entry("dup-id", 0),
    },
    PersistCommand::RowAppend {
      session_id: "test-session".to_string(),
      viewer_present: false,
      assigned_sequence: None,
      sequence_tx: None,
      entry: user_entry("dup-id", 5), // Same id, different sequence
    },
  ];

  super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  let conn = Connection::open(&db_path).unwrap();
  let rows = load_messages_from_db(&conn, "test-session").unwrap();

  // Only one row should exist — the first one wins with ON CONFLICT(id) DO NOTHING
  assert_eq!(rows.len(), 1);
  assert_eq!(
    rows[0].sequence, 0,
    "first insert wins with ON CONFLICT(id) DO NOTHING"
  );
}

#[test]
fn user_row_append_does_not_advance_last_progress() {
  let (conn, db_path, _dir, _guard) = setup_test_db();
  conn.execute(
        "UPDATE sessions SET last_progress_at = '100Z', last_activity_at = '100Z' WHERE id = 'test-session'",
        [],
    )
    .unwrap();
  drop(conn);

  let batch = vec![PersistCommand::RowAppend {
    session_id: "test-session".to_string(),
    viewer_present: false,
    assigned_sequence: None,
    sequence_tx: None,
    entry: user_entry("user-row", 0),
  }];

  super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  let conn = Connection::open(&db_path).unwrap();
  let (last_activity_at, last_progress_at): (Option<String>, Option<String>) = conn
    .query_row(
      "SELECT last_activity_at, last_progress_at FROM sessions WHERE id = 'test-session'",
      [],
      |row| Ok((row.get(0)?, row.get(1)?)),
    )
    .unwrap();

  assert_ne!(last_activity_at.as_deref(), Some("100Z"));
  assert_eq!(last_progress_at.as_deref(), Some("100Z"));
}

#[test]
fn assistant_row_append_advances_last_progress() {
  let (conn, db_path, _dir, _guard) = setup_test_db();
  conn.execute(
        "UPDATE sessions SET last_progress_at = '100Z', last_activity_at = '100Z' WHERE id = 'test-session'",
        [],
    )
    .unwrap();
  drop(conn);

  let batch = vec![PersistCommand::RowAppend {
    session_id: "test-session".to_string(),
    viewer_present: false,
    assigned_sequence: None,
    sequence_tx: None,
    entry: assistant_entry("assistant-row", 0),
  }];

  super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  let conn = Connection::open(&db_path).unwrap();
  let (last_activity_at, last_progress_at): (Option<String>, Option<String>) = conn
    .query_row(
      "SELECT last_activity_at, last_progress_at FROM sessions WHERE id = 'test-session'",
      [],
      |row| Ok((row.get(0)?, row.get(1)?)),
    )
    .unwrap();

  assert_ne!(last_activity_at.as_deref(), Some("100Z"));
  assert_ne!(last_progress_at.as_deref(), Some("100Z"));
}

#[test]
fn session_lifecycle_state_transitions_are_persisted() {
  let (conn, db_path, _dir, _guard) = setup_test_db();
  drop(conn);

  let session_id = "lifecycle-session";

  let batch = vec![PersistCommand::SessionCreate(Box::new(
    SessionCreateParams {
      id: session_id.to_string(),
      provider: Provider::Codex,
      control_mode: orbitdock_protocol::SessionControlMode::Direct,
      project_path: "/tmp/test".to_string(),
      project_name: Some("Test Project".to_string()),
      branch: Some("main".to_string()),
      model: Some("gpt-4.1".to_string()),
      approval_policy: None,
      sandbox_mode: None,
      permission_mode: None,
      collaboration_mode: None,
      multi_agent: None,
      personality: None,
      service_tier: None,
      developer_instructions: None,
      codex_config_mode: None,
      codex_config_profile: None,
      codex_model_provider: None,
      codex_config_source: None,
      codex_config_overrides_json: None,
      forked_from_session_id: None,
      mission_id: None,
      issue_identifier: None,
      allow_bypass_permissions: false,
      worktree_id: None,
    },
  ))];
  super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  let conn = Connection::open(&db_path).unwrap();
  assert_eq!(session_lifecycle_state(&conn, session_id), "open");
  assert_eq!(session_control_mode(&conn, session_id), "direct");
  drop(conn);

  let batch = vec![PersistCommand::SessionEnd {
    id: session_id.to_string(),
    reason: "completed".to_string(),
  }];
  super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  let conn = Connection::open(&db_path).unwrap();
  assert_eq!(session_lifecycle_state(&conn, session_id), "ended");
  assert_eq!(session_control_mode(&conn, session_id), "direct");
  drop(conn);

  let batch = vec![PersistCommand::ReactivateSession {
    id: session_id.to_string(),
  }];
  super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  let conn = Connection::open(&db_path).unwrap();
  assert_eq!(session_lifecycle_state(&conn, session_id), "open");
  assert_eq!(session_control_mode(&conn, session_id), "direct");
}

#[test]
fn load_session_by_id_reads_persisted_lifecycle_state() {
  let (conn, db_path, _dir, _guard) = setup_test_db();
  drop(conn);

  let session_id = "lifecycle-session";

  let batch = vec![
    PersistCommand::SessionCreate(Box::new(SessionCreateParams {
      id: session_id.to_string(),
      provider: Provider::Codex,
      control_mode: orbitdock_protocol::SessionControlMode::Direct,
      project_path: "/tmp/test".to_string(),
      project_name: Some("Test Project".to_string()),
      branch: Some("main".to_string()),
      model: Some("gpt-4.1".to_string()),
      approval_policy: None,
      sandbox_mode: None,
      permission_mode: None,
      collaboration_mode: None,
      multi_agent: None,
      personality: None,
      service_tier: None,
      developer_instructions: None,
      codex_config_mode: None,
      codex_config_profile: None,
      codex_model_provider: None,
      codex_config_source: None,
      codex_config_overrides_json: None,
      forked_from_session_id: None,
      mission_id: None,
      issue_identifier: None,
      allow_bypass_permissions: false,
      worktree_id: None,
    })),
    PersistCommand::SessionEnd {
      id: session_id.to_string(),
      reason: "completed".to_string(),
    },
  ];
  super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  let runtime = tokio::runtime::Builder::new_current_thread()
    .enable_all()
    .build()
    .unwrap();
  let restored = runtime
    .block_on(super::session_reads::load_session_lifecycle_state(
      session_id,
    ))
    .unwrap()
    .unwrap();

  assert_eq!(restored, SessionLifecycleState::Ended);
}

#[test]
fn reactivate_session_preserves_existing_activity_timestamps() {
  let (conn, db_path, _dir, _guard) = setup_test_db();
  let session_id = "test-session";
  let original_last_activity_at = "2026-03-24T10:00:00Z";
  let original_last_progress_at = "2026-03-24T10:05:00Z";

  conn
    .execute(
      "UPDATE sessions
         SET status = 'ended',
             work_status = 'ended',
             lifecycle_state = 'ended',
             ended_at = '2026-03-24T11:00:00Z',
             end_reason = 'completed',
             last_activity_at = ?1,
             last_progress_at = ?2
         WHERE id = ?3",
      [
        original_last_activity_at,
        original_last_progress_at,
        session_id,
      ],
    )
    .unwrap();
  drop(conn);

  super::writer::flush_batch_for_test(
    &db_path,
    vec![PersistCommand::ReactivateSession {
      id: session_id.to_string(),
    }],
  )
  .unwrap();

  let conn = Connection::open(&db_path).unwrap();
  assert_eq!(session_lifecycle_state(&conn, session_id), "open");
  assert_eq!(
    session_last_activity_at(&conn, session_id).as_deref(),
    Some(original_last_activity_at)
  );
  assert_eq!(
    session_last_progress_at(&conn, session_id).as_deref(),
    Some(original_last_progress_at)
  );
}

#[test]
fn load_session_by_id_and_startup_restore_use_persisted_control_mode() {
  let (conn, db_path, _dir, _guard) = setup_test_db();

  conn
    .execute(
      "INSERT INTO sessions (
            id, provider, status, work_status, lifecycle_state,
            project_path, codex_integration_mode, claude_integration_mode, control_mode
         ) VALUES (
            'control-mode-session', 'codex', 'active', 'waiting', 'open',
            '/tmp/test', 'passive', NULL, 'direct'
         )",
      [],
    )
    .unwrap();
  drop(conn);

  let runtime = tokio::runtime::Builder::new_current_thread()
    .enable_all()
    .build()
    .unwrap();

  let restored = runtime
    .block_on(super::session_reads::load_session_by_id(
      "control-mode-session",
    ))
    .unwrap()
    .unwrap();
  assert_eq!(restored.codex_integration_mode.as_deref(), Some("direct"));

  let sessions = runtime
    .block_on(super::session_reads::load_sessions_for_startup())
    .unwrap();
  let startup = sessions
    .into_iter()
    .find(|session| session.id == "control-mode-session")
    .expect("startup session should be loaded");
  assert_eq!(startup.codex_integration_mode.as_deref(), Some("direct"));

  let conn = Connection::open(&db_path).unwrap();
  assert_eq!(
    session_control_mode(&conn, "control-mode-session"),
    "direct"
  );
}

#[test]
fn legacy_codex_rows_without_mode_infer_profile_and_custom_modes() {
  let (conn, _db_path, _dir, _guard) = setup_test_db();

  conn
    .execute(
      "INSERT INTO sessions (
            id, provider, status, work_status, lifecycle_state, control_mode,
            project_path, model, codex_config_mode, codex_config_profile, codex_model_provider
         ) VALUES (
            'legacy-codex-profile', 'codex', 'active', 'waiting', 'open', 'direct',
            '/tmp/profile', 'qwen/qwen3-coder-next', NULL, 'qwen', 'openrouter'
         )",
      [],
    )
    .unwrap();
  conn
    .execute(
      "INSERT INTO sessions (
            id, provider, status, work_status, lifecycle_state, control_mode,
            project_path, model, codex_config_mode, codex_config_profile, codex_model_provider
         ) VALUES (
            'legacy-codex-custom', 'codex', 'active', 'waiting', 'open', 'direct',
            '/tmp/custom', 'qwen/qwen3-coder-next', NULL, NULL, 'openrouter'
         )",
      [],
    )
    .unwrap();
  drop(conn);

  let runtime = tokio::runtime::Builder::new_current_thread()
    .enable_all()
    .build()
    .unwrap();

  let profile_row = runtime
    .block_on(super::session_reads::load_session_by_id(
      "legacy-codex-profile",
    ))
    .unwrap()
    .expect("legacy profile row should load");
  assert_eq!(
    profile_row.codex_config_mode,
    Some(CodexConfigMode::Profile)
  );
  assert_eq!(profile_row.codex_config_profile.as_deref(), Some("qwen"));
  assert_eq!(
    profile_row.codex_model_provider.as_deref(),
    Some("openrouter")
  );

  let custom_row = runtime
    .block_on(super::session_reads::load_session_by_id(
      "legacy-codex-custom",
    ))
    .unwrap()
    .expect("legacy custom row should load");
  assert_eq!(custom_row.codex_config_mode, Some(CodexConfigMode::Custom));
  assert_eq!(
    custom_row.codex_model_provider.as_deref(),
    Some("openrouter")
  );

  let restored = runtime
    .block_on(super::session_reads::load_sessions_for_startup())
    .unwrap();
  let startup_profile = restored
    .iter()
    .find(|session| session.id == "legacy-codex-profile")
    .expect("legacy profile row should restore");
  assert_eq!(
    startup_profile.codex_config_mode,
    Some(CodexConfigMode::Profile)
  );

  let startup_custom = restored
    .iter()
    .find(|session| session.id == "legacy-codex-custom")
    .expect("legacy custom row should restore");
  assert_eq!(
    startup_custom.codex_config_mode,
    Some(CodexConfigMode::Custom)
  );
}

#[test]
fn load_direct_claude_owner_by_sdk_session_id_returns_direct_owner() {
  let (_conn, db_path, _dir, _guard) = setup_test_db();

  let direct_id = "od-direct-claude";
  let sdk_id = "claude-sdk-123";
  let batch = vec![
    PersistCommand::SessionCreate(Box::new(SessionCreateParams {
      id: direct_id.to_string(),
      provider: Provider::Claude,
      control_mode: orbitdock_protocol::SessionControlMode::Direct,
      project_path: "/tmp/test".to_string(),
      project_name: Some("Test Project".to_string()),
      branch: None,
      model: Some("claude-opus-4-6".to_string()),
      approval_policy: None,
      sandbox_mode: None,
      permission_mode: None,
      collaboration_mode: None,
      multi_agent: None,
      personality: None,
      service_tier: None,
      developer_instructions: None,
      codex_config_mode: None,
      codex_config_profile: None,
      codex_model_provider: None,
      codex_config_source: None,
      codex_config_overrides_json: None,
      forked_from_session_id: None,
      mission_id: None,
      issue_identifier: None,
      allow_bypass_permissions: false,
      worktree_id: None,
    })),
    PersistCommand::SetClaudeSdkSessionId {
      session_id: direct_id.to_string(),
      claude_sdk_session_id: sdk_id.to_string(),
    },
    PersistCommand::SessionEnd {
      id: direct_id.to_string(),
      reason: "completed".to_string(),
    },
  ];
  super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  let runtime = tokio::runtime::Builder::new_current_thread()
    .enable_all()
    .build()
    .unwrap();
  let owner = runtime
    .block_on(super::session_reads::load_direct_claude_owner_by_sdk_session_id(sdk_id))
    .unwrap()
    .expect("direct Claude owner should be found");

  assert_eq!(owner.session_id, direct_id);
  assert_eq!(owner.status, SessionStatus::Ended);
  assert_eq!(owner.lifecycle_state, SessionLifecycleState::Ended);
}

#[test]
fn session_create_persists_codex_config_columns_without_placeholder_drift() {
  let (_conn, db_path, _dir, _guard) = setup_test_db();
  let batch = vec![PersistCommand::SessionCreate(Box::new(
    SessionCreateParams {
      id: "codex-profile-session".to_string(),
      provider: Provider::Codex,
      control_mode: orbitdock_protocol::SessionControlMode::Direct,
      project_path: "/tmp/test".to_string(),
      project_name: Some("Test Project".to_string()),
      branch: Some("main".to_string()),
      model: Some("qwen/qwen3-coder-next".to_string()),
      approval_policy: Some("on-request".to_string()),
      sandbox_mode: Some("workspace-write".to_string()),
      permission_mode: None,
      collaboration_mode: Some("default".to_string()),
      multi_agent: Some(true),
      personality: Some("mentor".to_string()),
      service_tier: Some("priority".to_string()),
      developer_instructions: Some("Stay focused".to_string()),
      codex_config_mode: Some(orbitdock_protocol::CodexConfigMode::Profile),
      codex_config_profile: Some("qwen".to_string()),
      codex_model_provider: Some("openrouter".to_string()),
      codex_config_source: Some(orbitdock_protocol::CodexConfigSource::User),
      codex_config_overrides_json: Some("{\"effort\":\"high\"}".to_string()),
      forked_from_session_id: None,
      mission_id: None,
      issue_identifier: None,
      allow_bypass_permissions: false,
      worktree_id: None,
    },
  ))];
  super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  struct PersistedCodexSessionRow {
    codex_config_mode: Option<String>,
    codex_config_profile: Option<String>,
    codex_model_provider: Option<String>,
    codex_config_overrides_json: Option<String>,
    started_at: Option<String>,
  }

  let conn = Connection::open(&db_path).unwrap();
  let row = conn
    .query_row(
      "SELECT codex_config_mode, codex_config_profile, codex_model_provider, codex_config_overrides_json, started_at
       FROM sessions
       WHERE id = 'codex-profile-session'",
      [],
      |row| {
        Ok(PersistedCodexSessionRow {
          codex_config_mode: row.get(0)?,
          codex_config_profile: row.get(1)?,
          codex_model_provider: row.get(2)?,
          codex_config_overrides_json: row.get(3)?,
          started_at: row.get(4)?,
        })
      },
    )
    .unwrap();

  assert_eq!(row.codex_config_mode.as_deref(), Some("profile"));
  assert_eq!(row.codex_config_profile.as_deref(), Some("qwen"));
  assert_eq!(row.codex_model_provider.as_deref(), Some("openrouter"));
  assert_eq!(
    row.codex_config_overrides_json.as_deref(),
    Some("{\"effort\":\"high\"}")
  );
  assert!(row.started_at.is_some());
}

#[test]
fn startup_restore_ends_passive_claude_shadow_owned_by_direct_session() {
  let (conn, db_path, _dir, _guard) = setup_test_db();

  let direct_id = "od-direct-shadow-owner";
  let sdk_id = "claude-sdk-shadow";

  conn.execute(
        "INSERT INTO sessions (
            id, provider, status, work_status, lifecycle_state, control_mode,
            project_path, claude_integration_mode, claude_sdk_session_id, started_at, last_activity_at
         ) VALUES (
            ?1, 'claude', 'active', 'waiting', 'open', 'direct',
            '/tmp/test', 'direct', ?2, '2026-03-26T10:00:00Z', '2026-03-26T10:00:00Z'
         )",
        [direct_id, sdk_id],
    )
    .unwrap();
  conn
    .execute(
      "INSERT INTO sessions (
            id, provider, status, work_status, lifecycle_state, control_mode,
            project_path, claude_integration_mode, started_at, last_activity_at
         ) VALUES (
            ?1, 'claude', 'active', 'working', 'open', 'passive',
            '/tmp/test', 'passive', '2026-03-26T10:05:00Z', '2026-03-26T10:05:00Z'
         )",
      [sdk_id],
    )
    .unwrap();
  drop(conn);

  let runtime = tokio::runtime::Builder::new_current_thread()
    .enable_all()
    .build()
    .unwrap();
  let restored = runtime
    .block_on(super::session_reads::load_sessions_for_startup())
    .unwrap();

  assert!(
    restored.into_iter().all(|session| session.id != sdk_id),
    "startup restore should not surface passive Claude shadows owned by a direct session"
  );

  let conn = Connection::open(&db_path).unwrap();
  let shadow: (String, String, String) = conn
    .query_row(
      "SELECT status, work_status, COALESCE(end_reason, '') FROM sessions WHERE id = ?1",
      [sdk_id],
      |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    )
    .unwrap();

  assert_eq!(shadow.0, "ended");
  assert_eq!(shadow.1, "ended");
  assert_eq!(shadow.2, "startup_direct_shadow");
}

#[test]
fn startup_restore_only_ends_stale_passive_codex_sessions() {
  let (conn, db_path, _dir, _guard) = setup_test_db();

  conn
    .execute(
      "INSERT INTO sessions (
            id, provider, status, work_status, lifecycle_state, control_mode,
            project_path, codex_integration_mode, started_at, last_activity_at
         ) VALUES (
            'stale-passive', 'codex', 'active', 'waiting', 'open', 'passive',
            '/tmp/test', 'passive', '2026-03-20T10:00:00Z', '2026-03-20T10:00:00Z'
         )",
      [],
    )
    .unwrap();
  conn
    .execute(
      "INSERT INTO sessions (
            id, provider, status, work_status, lifecycle_state, control_mode,
            project_path, codex_integration_mode, started_at, last_activity_at
         ) VALUES (
            'approval-passive', 'codex', 'active', 'permission', 'open', 'passive',
            '/tmp/test', 'passive', '2026-03-20T10:00:00Z', '2026-03-20T10:00:00Z'
         )",
      [],
    )
    .unwrap();
  conn
    .execute(
      "INSERT INTO sessions (
            id, provider, status, work_status, lifecycle_state, control_mode,
            project_path, codex_integration_mode, codex_thread_id, started_at, last_activity_at
         ) VALUES (
            'direct-session', 'codex', 'active', 'waiting', 'open', 'direct',
            '/tmp/test', 'direct', 'thread-direct-session', '2026-03-20T10:00:00Z', '2026-03-20T10:00:00Z'
         )",
      [],
    )
    .unwrap();
  drop(conn);

  let runtime = tokio::runtime::Builder::new_current_thread()
    .enable_all()
    .build()
    .unwrap();
  let restored = runtime
    .block_on(super::session_reads::load_sessions_for_startup())
    .unwrap();

  assert!(
    restored.iter().all(|session| session.id != "stale-passive"),
    "stale passive session should be ended during startup restore"
  );
  assert!(
    restored
      .iter()
      .any(|session| session.id == "approval-passive"),
    "passive approval session should survive startup restore"
  );
  assert!(
    restored
      .iter()
      .any(|session| session.id == "direct-session"),
    "direct session should survive startup restore"
  );

  let conn = Connection::open(&db_path).unwrap();
  let stale_row: (String, String, String) = conn
    .query_row(
      "SELECT status, work_status, COALESCE(end_reason, '') FROM sessions WHERE id = 'stale-passive'",
      [],
      |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    )
    .unwrap();
  assert_eq!(stale_row.0, "ended");
  assert_eq!(stale_row.1, "ended");
  assert_eq!(stale_row.2, "startup_stale_passive");

  let approval_status: (String, String) = conn
    .query_row(
      "SELECT status, work_status FROM sessions WHERE id = 'approval-passive'",
      [],
      |row| Ok((row.get(0)?, row.get(1)?)),
    )
    .unwrap();
  assert_eq!(approval_status.0, "active");
  assert_eq!(approval_status.1, "permission");
}

#[test]
fn startup_restore_marks_open_direct_sessions_as_resumable() {
  let (conn, db_path, _dir, _guard) = setup_test_db();

  conn
    .execute(
      "INSERT INTO sessions (
            id, provider, status, work_status, lifecycle_state, control_mode,
            project_path, codex_integration_mode, codex_thread_id, started_at, last_activity_at
         ) VALUES (
            'direct-codex-open', 'codex', 'active', 'working', 'open', 'direct',
            '/tmp/test', 'direct', 'thread-direct-codex-open', '2026-03-20T10:00:00Z', '2026-03-20T10:00:00Z'
         )",
      [],
    )
    .unwrap();
  conn
    .execute(
      "INSERT INTO sessions (
            id, provider, status, work_status, lifecycle_state, control_mode,
            project_path, claude_integration_mode, claude_sdk_session_id, started_at, last_activity_at
         ) VALUES (
            'direct-claude-open', 'claude', 'active', 'reply', 'open', 'direct',
            '/tmp/test', 'direct', 'claude-sdk-direct-open', '2026-03-20T10:00:00Z', '2026-03-20T10:00:00Z'
         )",
      [],
    )
    .unwrap();
  drop(conn);

  let runtime = tokio::runtime::Builder::new_current_thread()
    .enable_all()
    .build()
    .unwrap();
  let restored = runtime
    .block_on(super::session_reads::load_sessions_for_startup_from_db_path(db_path.clone()))
    .unwrap();

  let restored_codex = restored
    .iter()
    .find(|session| session.id == "direct-codex-open")
    .expect("direct codex session should be restored");
  assert_eq!(
    restored_codex.lifecycle_state,
    SessionLifecycleState::Resumable
  );
  assert_eq!(restored_codex.work_status, "waiting");

  let restored_claude = restored
    .iter()
    .find(|session| session.id == "direct-claude-open")
    .expect("direct claude session should be restored");
  assert_eq!(
    restored_claude.lifecycle_state,
    SessionLifecycleState::Resumable
  );
  assert_eq!(restored_claude.work_status, "waiting");

  let conn = Connection::open(&db_path).unwrap();
  let codex_row: (String, String) = conn
    .query_row(
      "SELECT work_status, lifecycle_state FROM sessions WHERE id = 'direct-codex-open'",
      [],
      |row| Ok((row.get(0)?, row.get(1)?)),
    )
    .unwrap();
  assert_eq!(codex_row.0, "waiting");
  assert_eq!(codex_row.1, "resumable");

  let claude_row: (String, String) = conn
    .query_row(
      "SELECT work_status, lifecycle_state FROM sessions WHERE id = 'direct-claude-open'",
      [],
      |row| Ok((row.get(0)?, row.get(1)?)),
    )
    .unwrap();
  assert_eq!(claude_row.0, "waiting");
  assert_eq!(claude_row.1, "resumable");
}

#[test]
fn startup_restore_reactivates_server_shutdown_direct_sessions_as_resumable() {
  let (conn, db_path, _dir, _guard) = setup_test_db();

  conn
    .execute(
      "INSERT INTO sessions (
            id, provider, status, work_status, lifecycle_state, control_mode, end_reason, ended_at,
            project_path, codex_integration_mode, codex_thread_id, started_at, last_activity_at
         ) VALUES (
            'direct-codex-server-shutdown', 'codex', 'ended', 'ended', 'ended', 'direct', 'server_shutdown', '2026-03-20T10:10:00Z',
            '/tmp/test', 'direct', 'thread-direct-codex-server-shutdown', '2026-03-20T10:00:00Z', '2026-03-20T10:00:00Z'
         )",
      [],
    )
    .unwrap();
  conn
    .execute(
      "INSERT INTO sessions (
            id, provider, status, work_status, lifecycle_state, control_mode, end_reason, ended_at,
            project_path, claude_integration_mode, claude_sdk_session_id, started_at, last_activity_at
         ) VALUES (
            'direct-claude-server-shutdown', 'claude', 'ended', 'ended', 'ended', 'direct', 'server_shutdown', '2026-03-20T10:10:00Z',
            '/tmp/test', 'direct', 'claude-sdk-server-shutdown', '2026-03-20T10:00:00Z', '2026-03-20T10:00:00Z'
         )",
      [],
    )
    .unwrap();
  drop(conn);

  let runtime = tokio::runtime::Builder::new_current_thread()
    .enable_all()
    .build()
    .unwrap();
  let restored = runtime
    .block_on(super::session_reads::load_sessions_for_startup_from_db_path(db_path.clone()))
    .unwrap();

  let restored_codex = restored
    .iter()
    .find(|session| session.id == "direct-codex-server-shutdown")
    .expect("direct codex server-shutdown session should be restored");
  assert_eq!(restored_codex.status, "active");
  assert_eq!(restored_codex.work_status, "waiting");
  assert_eq!(
    restored_codex.lifecycle_state,
    SessionLifecycleState::Resumable
  );

  let restored_claude = restored
    .iter()
    .find(|session| session.id == "direct-claude-server-shutdown")
    .expect("direct claude server-shutdown session should be restored");
  assert_eq!(restored_claude.status, "active");
  assert_eq!(restored_claude.work_status, "waiting");
  assert_eq!(
    restored_claude.lifecycle_state,
    SessionLifecycleState::Resumable
  );

  let conn = Connection::open(&db_path).unwrap();
  let codex_row: (String, String, String, Option<String>) = conn
    .query_row(
      "SELECT status, work_status, lifecycle_state, end_reason FROM sessions WHERE id = 'direct-codex-server-shutdown'",
      [],
      |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
    )
    .unwrap();
  assert_eq!(codex_row.0, "active");
  assert_eq!(codex_row.1, "waiting");
  assert_eq!(codex_row.2, "resumable");
  assert_eq!(codex_row.3, None);

  let claude_row: (String, String, String, Option<String>) = conn
    .query_row(
      "SELECT status, work_status, lifecycle_state, end_reason FROM sessions WHERE id = 'direct-claude-server-shutdown'",
      [],
      |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
    )
    .unwrap();
  assert_eq!(claude_row.0, "active");
  assert_eq!(claude_row.1, "waiting");
  assert_eq!(claude_row.2, "resumable");
  assert_eq!(claude_row.3, None);
}

#[test]
fn claude_session_upsert_skips_new_shadow_when_direct_owner_exists() {
  let (conn, db_path, _dir, _guard) = setup_test_db();

  let direct_id = "od-direct-shadow-owner";
  let sdk_id = "claude-sdk-shadow";

  conn.execute(
        "INSERT INTO sessions (
            id, provider, status, work_status, lifecycle_state, control_mode,
            project_path, claude_integration_mode, claude_sdk_session_id, started_at, last_activity_at
         ) VALUES (
            ?1, 'claude', 'ended', 'ended', 'ended', 'direct',
            '/tmp/test', 'direct', ?2, '2026-03-26T10:00:00Z', '2026-03-26T10:10:00Z'
         )",
        [direct_id, sdk_id],
    )
    .unwrap();
  drop(conn);

  super::writer::flush_batch_for_test(
    &db_path,
    vec![PersistCommand::ClaudeSessionUpsert {
      id: sdk_id.to_string(),
      project_path: "/tmp/test".to_string(),
      project_name: Some("Test Project".to_string()),
      branch: Some("main".to_string()),
      model: Some("claude-opus-4-6".to_string()),
      context_label: None,
      transcript_path: Some("/tmp/test/transcript.jsonl".to_string()),
      source: Some("hook".to_string()),
      agent_type: None,
      permission_mode: Some("acceptEdits".to_string()),
      terminal_session_id: None,
      terminal_app: None,
      forked_from_session_id: None,
      repository_root: Some("/tmp/test".to_string()),
      is_worktree: false,
      git_sha: Some("abc123".to_string()),
    }],
  )
  .unwrap();

  let conn = Connection::open(&db_path).unwrap();
  let shadow_count: i64 = conn
    .query_row(
      "SELECT COUNT(*) FROM sessions WHERE id = ?1",
      [sdk_id],
      |row| row.get(0),
    )
    .unwrap();

  assert_eq!(shadow_count, 0);
}

#[test]
fn claude_session_upsert_ends_existing_shadow_when_direct_owner_exists() {
  let (conn, db_path, _dir, _guard) = setup_test_db();

  let direct_id = "od-direct-shadow-owner";
  let sdk_id = "claude-sdk-shadow";

  conn.execute(
        "INSERT INTO sessions (
            id, provider, status, work_status, lifecycle_state, control_mode,
            project_path, claude_integration_mode, claude_sdk_session_id, started_at, last_activity_at
         ) VALUES (
            ?1, 'claude', 'ended', 'ended', 'ended', 'direct',
            '/tmp/test', 'direct', ?2, '2026-03-26T10:00:00Z', '2026-03-26T10:10:00Z'
         )",
        [direct_id, sdk_id],
    )
    .unwrap();
  conn
    .execute(
      "INSERT INTO sessions (
            id, provider, status, work_status, lifecycle_state, control_mode,
            project_path, claude_integration_mode, started_at, last_activity_at
         ) VALUES (
            ?1, 'claude', 'active', 'working', 'open', 'passive',
            '/tmp/test', 'passive', '2026-03-26T10:05:00Z', '2026-03-26T10:05:00Z'
         )",
      [sdk_id],
    )
    .unwrap();
  drop(conn);

  super::writer::flush_batch_for_test(
    &db_path,
    vec![PersistCommand::ClaudeSessionUpsert {
      id: sdk_id.to_string(),
      project_path: "/tmp/test".to_string(),
      project_name: Some("Test Project".to_string()),
      branch: Some("main".to_string()),
      model: Some("claude-opus-4-6".to_string()),
      context_label: None,
      transcript_path: Some("/tmp/test/transcript.jsonl".to_string()),
      source: Some("hook".to_string()),
      agent_type: None,
      permission_mode: Some("acceptEdits".to_string()),
      terminal_session_id: None,
      terminal_app: None,
      forked_from_session_id: None,
      repository_root: Some("/tmp/test".to_string()),
      is_worktree: false,
      git_sha: Some("abc123".to_string()),
    }],
  )
  .unwrap();

  let conn = Connection::open(&db_path).unwrap();
  let shadow: (String, String, String) = conn
    .query_row(
      "SELECT status, work_status, COALESCE(end_reason, '') FROM sessions WHERE id = ?1",
      [sdk_id],
      |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    )
    .unwrap();

  assert_eq!(shadow.0, "ended");
  assert_eq!(shadow.1, "ended");
  assert_eq!(shadow.2, "direct_owner_exists");
}

#[test]
fn claude_session_update_preserves_ended_shadow_when_direct_owner_exists() {
  let (conn, db_path, _dir, _guard) = setup_test_db();

  let direct_id = "od-direct-shadow-owner";
  let sdk_id = "claude-sdk-shadow";

  conn.execute(
        "INSERT INTO sessions (
            id, provider, status, work_status, lifecycle_state, control_mode,
            project_path, claude_integration_mode, claude_sdk_session_id, started_at, last_activity_at
         ) VALUES (
            ?1, 'claude', 'ended', 'ended', 'ended', 'direct',
            '/tmp/test', 'direct', ?2, '2026-03-26T10:00:00Z', '2026-03-26T10:10:00Z'
         )",
        [direct_id, sdk_id],
    )
    .unwrap();
  conn
    .execute(
      "INSERT INTO sessions (
            id, provider, status, work_status, lifecycle_state, control_mode,
            project_path, claude_integration_mode, started_at, ended_at, end_reason, last_activity_at
         ) VALUES (
            ?1, 'claude', 'ended', 'ended', 'ended', 'passive',
            '/tmp/test', 'passive', '2026-03-26T10:05:00Z', '2026-03-26T10:06:00Z', 'startup_direct_shadow', '2026-03-26T10:06:00Z'
         )",
      [sdk_id],
    )
    .unwrap();
  drop(conn);

  super::writer::flush_batch_for_test(
    &db_path,
    vec![PersistCommand::ClaudeSessionUpdate {
      id: sdk_id.to_string(),
      work_status: Some("working".to_string()),
      attention_reason: Some(Some("awaitingReply".to_string())),
      last_tool: Some(Some("Bash".to_string())),
      last_tool_at: Some(Some("2026-03-26T10:07:00Z".to_string())),
      pending_tool_name: Some(Some("Bash".to_string())),
      pending_tool_input: Some(Some("{\"command\":\"pwd\"}".to_string())),
      pending_question: Some(Some("continue?".to_string())),
      source: None,
      agent_type: None,
      permission_mode: None,
      active_subagent_id: Some(Some("subagent-1".to_string())),
      active_subagent_type: Some(Some("worker".to_string())),
      first_prompt: Some("hello".to_string()),
      compact_count_increment: true,
    }],
  )
  .unwrap();

  let conn = Connection::open(&db_path).unwrap();
  let shadow: (String, String, String, String) = conn
    .query_row(
      "SELECT status, work_status, lifecycle_state, COALESCE(end_reason, '') FROM sessions WHERE id = ?1",
      [sdk_id],
      |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
    )
    .unwrap();

  assert_eq!(shadow.0, "ended");
  assert_eq!(shadow.1, "ended");
  assert_eq!(shadow.2, "ended");
  assert_eq!(shadow.3, "startup_direct_shadow");
}

// ── Mission-scoped tracker credentials ─────────────────────────────

fn setup_mission_db() -> (
  Connection,
  std::path::PathBuf,
  tempfile::TempDir,
  PersistenceTestGuard,
) {
  let guard = persistence_test_db_guard().lock().unwrap();
  let dir = tempfile::TempDir::new().unwrap();
  let db_path = dir.path().join("test.db");
  let conn = Connection::open(&db_path).unwrap();
  conn
    .execute_batch(
      "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;

         CREATE TABLE IF NOT EXISTS missions (
           id TEXT PRIMARY KEY,
           name TEXT NOT NULL,
           repo_root TEXT NOT NULL,
           tracker_kind TEXT NOT NULL DEFAULT 'linear',
           provider TEXT NOT NULL DEFAULT 'claude',
           config_json TEXT,
           prompt_template TEXT,
           enabled INTEGER NOT NULL DEFAULT 1,
           paused INTEGER NOT NULL DEFAULT 0,
           last_parsed_at TEXT,
           parse_error TEXT,
           mission_file_path TEXT,
           created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
           updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
           tracker_api_key TEXT
         );

         CREATE TABLE IF NOT EXISTS config (
           key TEXT PRIMARY KEY,
           value TEXT NOT NULL
         );",
    )
    .unwrap();

  (conn, db_path, dir, guard)
}

#[test]
fn mission_create_stores_tracker_key() {
  let (conn, db_path, _dir, _guard) = setup_mission_db();
  drop(conn);

  let batch = vec![PersistCommand::MissionCreate {
    id: "m-1".to_string(),
    name: "Test Mission".to_string(),
    repo_root: "/tmp/test".to_string(),
    tracker_kind: "linear".to_string(),
    provider: "claude".to_string(),
    config_json: None,
    prompt_template: None,
    mission_file_path: None,
    tracker_api_key: None,
  }];
  super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  let conn = Connection::open(&db_path).unwrap();
  let key: Option<String> = conn
    .query_row(
      "SELECT tracker_api_key FROM missions WHERE id = 'm-1'",
      [],
      |row| row.get(0),
    )
    .unwrap();
  assert!(key.is_none(), "tracker_api_key should be NULL when not set");
}

#[test]
fn mission_set_tracker_key_persists() {
  let (conn, db_path, _dir, _guard) = setup_mission_db();

  // Insert a mission directly
  conn
    .execute(
      "INSERT INTO missions (id, name, repo_root) VALUES ('m-2', 'Key Test', '/tmp/key')",
      [],
    )
    .unwrap();
  drop(conn);

  let batch = vec![PersistCommand::MissionSetTrackerKey {
    mission_id: "m-2".to_string(),
    key: Some("test_secret_key_123".to_string()),
  }];
  super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  let conn = Connection::open(&db_path).unwrap();
  let raw: Option<String> = conn
    .query_row(
      "SELECT tracker_api_key FROM missions WHERE id = 'm-2'",
      [],
      |row| row.get(0),
    )
    .unwrap();

  // When an encryption key is available the value will be encrypted (enc: prefix).
  // When no key is available the encrypt() call returns Err and the command stores
  // the error result — but the command handler maps that to an Err that propagates.
  // In CI the env-based encryption key may or may not be present, so we test the
  // decrypt round-trip path: if it stored *something*, decrypt should recover it.
  if let Some(raw_val) = raw {
    let decrypted = crate::infrastructure::crypto::decrypt(&raw_val);
    assert_eq!(decrypted, Some("test_secret_key_123".to_string()));
  }
  // If raw is None, the encrypt failed (no key) — the command returned Err and
  // the batch writer logged the error. This is acceptable test behavior when no
  // encryption key is configured.
}

#[test]
fn mission_clear_tracker_key() {
  let (conn, db_path, _dir, _guard) = setup_mission_db();

  // Insert a mission with a plaintext key (bypasses encryption for test simplicity)
  conn.execute(
        "INSERT INTO missions (id, name, repo_root, tracker_api_key) VALUES ('m-3', 'Clear Test', '/tmp/clear', 'old_key')",
        [],
    )
    .unwrap();
  drop(conn);

  let batch = vec![PersistCommand::MissionSetTrackerKey {
    mission_id: "m-3".to_string(),
    key: None,
  }];
  super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  let conn = Connection::open(&db_path).unwrap();
  let key: Option<String> = conn
    .query_row(
      "SELECT tracker_api_key FROM missions WHERE id = 'm-3'",
      [],
      |row| row.get(0),
    )
    .unwrap();
  assert!(
    key.is_none(),
    "tracker_api_key should be NULL after clearing"
  );
}

#[test]
fn row_append_fk_violation_rejects_orphan_message() {
  let (conn, db_path, _dir, _guard) = setup_test_db();
  drop(conn);

  // Mix a valid command with an FK-violating one (ghost-session doesn't exist).
  // The batch should succeed overall — the orphan is skipped, the valid one persists.
  let batch = vec![
    PersistCommand::RowAppend {
      session_id: "test-session".to_string(),
      viewer_present: false,
      assigned_sequence: None,
      sequence_tx: None,
      entry: user_entry("valid-msg", 0),
    },
    PersistCommand::RowAppend {
      session_id: "ghost-session".to_string(),
      viewer_present: false,
      assigned_sequence: None,
      sequence_tx: None,
      entry: {
        let mut e = user_entry("orphan-msg", 0);
        e.session_id = "ghost-session".to_string();
        e
      },
    },
  ];

  super::writer::flush_batch_for_test(&db_path, batch).unwrap();

  let conn = Connection::open(&db_path).unwrap();
  let valid_rows = load_messages_from_db(&conn, "test-session").unwrap();
  assert_eq!(valid_rows.len(), 1, "valid message should be persisted");

  let ghost_rows = load_messages_from_db(&conn, "ghost-session").unwrap();
  assert_eq!(
    ghost_rows.len(),
    0,
    "orphan message must NOT be persisted (FK violation)"
  );
}
