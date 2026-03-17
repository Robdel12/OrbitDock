use rusqlite::Connection;

use orbitdock_protocol::conversation_contracts::{
    ConversationRow, ConversationRowEntry, MessageRowContent,
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
           last_activity_at TEXT
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
            entry: user_entry("row-0", 0),
        },
        PersistCommand::RowAppend {
            session_id: "test-session".to_string(),
            entry: assistant_entry("row-1", 1),
        },
        PersistCommand::RowAppend {
            session_id: "test-session".to_string(),
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
fn row_append_with_zero_sequence_stores_zero() {
    // This test documents that RowAppend is a dumb write — it persists
    // whatever sequence it receives. The caller (AddRowAndBroadcast handler)
    // is responsible for assigning the correct sequence BEFORE sending.
    let (conn, db_path, _dir) = setup_test_db();
    drop(conn);

    let batch = vec![
        PersistCommand::RowAppend {
            session_id: "test-session".to_string(),
            entry: user_entry("row-a", 0),
        },
        PersistCommand::RowAppend {
            session_id: "test-session".to_string(),
            entry: user_entry("row-b", 0), // Bad: duplicate sequence=0
        },
    ];

    super::writer::flush_batch_for_test(&db_path, batch).unwrap();

    let conn = Connection::open(&db_path).unwrap();
    let rows = load_messages_from_db(&conn, "test-session").unwrap();

    // Both rows are stored, both with sequence=0 — this is why callers
    // MUST go through the actor (AddRowAndBroadcast) to get correct sequences.
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].sequence, 0);
    assert_eq!(rows[1].sequence, 0);
}

#[test]
fn row_upsert_updates_sequence_on_conflict() {
    let (conn, db_path, _dir) = setup_test_db();
    drop(conn);

    // First: insert a row with sequence=0 (the old buggy behavior)
    let batch = vec![PersistCommand::RowAppend {
        session_id: "test-session".to_string(),
        entry: user_entry("row-0", 0),
    }];
    super::writer::flush_batch_for_test(&db_path, batch).unwrap();

    // Then: upsert the same row with the correct sequence=5
    let batch = vec![PersistCommand::RowUpsert {
        session_id: "test-session".to_string(),
        entry: user_entry("row-0", 5),
    }];
    super::writer::flush_batch_for_test(&db_path, batch).unwrap();

    let conn = Connection::open(&db_path).unwrap();
    let rows = load_messages_from_db(&conn, "test-session").unwrap();

    assert_eq!(rows.len(), 1);
    // The sequence should be corrected from 0 to 5
    assert_eq!(
        rows[0].sequence, 5,
        "RowUpsert must update the sequence column"
    );
}

#[test]
fn row_upsert_inserts_when_not_existing() {
    let (conn, db_path, _dir) = setup_test_db();
    drop(conn);

    let batch = vec![PersistCommand::RowUpsert {
        session_id: "test-session".to_string(),
        entry: user_entry("new-row", 3),
    }];
    super::writer::flush_batch_for_test(&db_path, batch).unwrap();

    let conn = Connection::open(&db_path).unwrap();
    let rows = load_messages_from_db(&conn, "test-session").unwrap();

    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].id(), "new-row");
    assert_eq!(rows[0].sequence, 3);
}

#[test]
fn batch_of_appends_preserves_insertion_order() {
    let (conn, db_path, _dir) = setup_test_db();
    drop(conn);

    // Simulate a burst of 10 rapid messages with correct sequences
    let batch: Vec<PersistCommand> = (0..10)
        .map(|i| PersistCommand::RowAppend {
            session_id: "test-session".to_string(),
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
            entry: user_entry("dup-id", 0),
        },
        PersistCommand::RowAppend {
            session_id: "test-session".to_string(),
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
