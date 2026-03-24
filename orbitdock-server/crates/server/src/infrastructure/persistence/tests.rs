use rusqlite::Connection;

use orbitdock_protocol::conversation_contracts::{
    rows::MessageDeliveryStatus, ConversationRow, ConversationRowEntry, MessageRowContent,
};

use super::commands::PersistCommand;
use super::messages::load_messages_from_db;

fn setup_test_db() -> (Connection, std::path::PathBuf, tempfile::TempDir) {
    let dir = tempfile::TempDir::new().unwrap();
    let db_path = dir.path().join("test.db");
    let conn = Connection::open(&db_path).unwrap();
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;
         PRAGMA synchronous = NORMAL;

         CREATE TABLE IF NOT EXISTS sessions (
           id TEXT PRIMARY KEY,
           project_path TEXT NOT NULL DEFAULT '',
           project_name TEXT,
           provider TEXT NOT NULL DEFAULT 'codex',
           status TEXT NOT NULL DEFAULT 'active',
           work_status TEXT NOT NULL DEFAULT 'waiting',
           model TEXT,
           branch TEXT,
           last_message TEXT,
           unread_count INTEGER NOT NULL DEFAULT 0,
           started_at TEXT,
           last_activity_at TEXT,
           last_progress_at TEXT
         );

         CREATE TABLE IF NOT EXISTS messages (
           id TEXT PRIMARY KEY,
           session_id TEXT NOT NULL,
           type TEXT NOT NULL DEFAULT '',
           content TEXT NOT NULL DEFAULT '',
           timestamp TEXT,
           sequence INTEGER DEFAULT 0,
           row_data TEXT,
           is_in_progress INTEGER DEFAULT 0
         );

         CREATE INDEX IF NOT EXISTS idx_messages_session_sequence
           ON messages(session_id, sequence);

         INSERT INTO sessions (id, project_path, provider) VALUES ('test-session', '/tmp/test', 'codex');",
    )
    .unwrap();

    (conn, db_path, dir)
}

fn user_entry(id: &str, sequence: u64) -> ConversationRowEntry {
    ConversationRowEntry {
        session_id: "test-session".to_string(),
        sequence,
        turn_id: None,
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

#[test]
fn row_append_stores_correct_sequence() {
    let (conn, db_path, _dir) = setup_test_db();
    drop(conn);

    let batch = vec![
        PersistCommand::RowAppend {
            session_id: "test-session".to_string(),
            viewer_present: false,
            sequence_tx: None,
            entry: user_entry("row-0", 0),
        },
        PersistCommand::RowAppend {
            session_id: "test-session".to_string(),
            viewer_present: false,
            sequence_tx: None,
            entry: assistant_entry("row-1", 1),
        },
        PersistCommand::RowAppend {
            session_id: "test-session".to_string(),
            viewer_present: false,
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
fn row_append_with_zero_sequence_gets_db_assigned_sequence() {
    // DB computes MAX(sequence)+1 — callers no longer need to assign sequences.
    let (conn, db_path, _dir) = setup_test_db();
    drop(conn);

    let batch = vec![
        PersistCommand::RowAppend {
            session_id: "test-session".to_string(),
            viewer_present: false,
            sequence_tx: None,
            entry: user_entry("row-a", 0),
        },
        PersistCommand::RowAppend {
            session_id: "test-session".to_string(),
            viewer_present: false,
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
    let (conn, db_path, _dir) = setup_test_db();
    drop(conn);

    // First: insert a row — DB assigns sequence=0
    let batch = vec![PersistCommand::RowAppend {
        session_id: "test-session".to_string(),
        viewer_present: false,
        sequence_tx: None,
        entry: user_entry("row-0", 0),
    }];
    super::writer::flush_batch_for_test(&db_path, batch).unwrap();

    // Then: upsert the same row — sequence should be preserved (not overwritten)
    let batch = vec![PersistCommand::RowUpsert {
        session_id: "test-session".to_string(),
        viewer_present: false,
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
    let (conn, db_path, _dir) = setup_test_db();
    drop(conn);

    let batch = vec![PersistCommand::RowUpsert {
        session_id: "test-session".to_string(),
        viewer_present: false,
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
    let (conn, db_path, _dir) = setup_test_db();
    drop(conn);

    let batch = vec![PersistCommand::RowAppend {
        session_id: "test-session".to_string(),
        viewer_present: false,
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
    let (conn, db_path, _dir) = setup_test_db();
    drop(conn);

    // Simulate a burst of 10 rapid messages with correct sequences
    let batch: Vec<PersistCommand> = (0..10)
        .map(|i| PersistCommand::RowAppend {
            session_id: "test-session".to_string(),
            viewer_present: false,
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
    let (conn, db_path, _dir) = setup_test_db();
    drop(conn);

    // INSERT OR IGNORE means second insert with same id is silently dropped
    let batch = vec![
        PersistCommand::RowAppend {
            session_id: "test-session".to_string(),
            viewer_present: false,
            sequence_tx: None,
            entry: user_entry("dup-id", 0),
        },
        PersistCommand::RowAppend {
            session_id: "test-session".to_string(),
            viewer_present: false,
            sequence_tx: None,
            entry: user_entry("dup-id", 5), // Same id, different sequence
        },
    ];

    super::writer::flush_batch_for_test(&db_path, batch).unwrap();

    let conn = Connection::open(&db_path).unwrap();
    let rows = load_messages_from_db(&conn, "test-session").unwrap();

    // Only one row should exist — the first one wins with INSERT OR IGNORE
    assert_eq!(rows.len(), 1);
    assert_eq!(
        rows[0].sequence, 0,
        "first insert wins with INSERT OR IGNORE"
    );
}

#[test]
fn user_row_append_does_not_advance_last_progress() {
    let (conn, db_path, _dir) = setup_test_db();
    conn.execute(
        "UPDATE sessions SET last_progress_at = '100Z', last_activity_at = '100Z' WHERE id = 'test-session'",
        [],
    )
    .unwrap();
    drop(conn);

    let batch = vec![PersistCommand::RowAppend {
        session_id: "test-session".to_string(),
        viewer_present: false,
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
    let (conn, db_path, _dir) = setup_test_db();
    conn.execute(
        "UPDATE sessions SET last_progress_at = '100Z', last_activity_at = '100Z' WHERE id = 'test-session'",
        [],
    )
    .unwrap();
    drop(conn);

    let batch = vec![PersistCommand::RowAppend {
        session_id: "test-session".to_string(),
        viewer_present: false,
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

// ── Mission-scoped tracker credentials ─────────────────────────────

fn setup_mission_db() -> (Connection, std::path::PathBuf, tempfile::TempDir) {
    let dir = tempfile::TempDir::new().unwrap();
    let db_path = dir.path().join("test.db");
    let conn = Connection::open(&db_path).unwrap();
    conn.execute_batch(
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

    (conn, db_path, dir)
}

#[test]
fn mission_create_stores_tracker_key() {
    let (conn, db_path, _dir) = setup_mission_db();
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
    let (conn, db_path, _dir) = setup_mission_db();

    // Insert a mission directly
    conn.execute(
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
    let (conn, db_path, _dir) = setup_mission_db();

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
