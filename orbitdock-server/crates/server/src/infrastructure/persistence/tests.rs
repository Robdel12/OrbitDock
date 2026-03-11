#![allow(clippy::await_holding_lock)]

use super::*;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

static TEST_ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

struct DataDirGuard;

impl Drop for DataDirGuard {
    fn drop(&mut self) {
        crate::infrastructure::paths::reset_data_dir();
    }
}

fn env_lock() -> &'static Mutex<()> {
    TEST_ENV_LOCK.get_or_init(|| Mutex::new(()))
}

fn set_test_data_dir(home: &Path) -> DataDirGuard {
    crate::infrastructure::paths::init_data_dir(Some(&home.join(".orbitdock")));
    DataDirGuard
}

fn iso_minutes_ago(minutes: u64) -> String {
    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let secs = now_secs.saturating_sub(minutes * 60);
    time_to_iso8601(secs)
}

fn find_migrations_dir() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    for ancestor in manifest_dir.ancestors() {
        let candidate = ancestor.join("migrations");
        if candidate.is_dir() {
            return candidate;
        }
    }
    panic!(
        "Could not locate migrations directory from {:?}",
        manifest_dir
    );
}

fn create_test_home() -> PathBuf {
    let home = std::env::temp_dir().join(format!("orbitdock-server-test-{}", Uuid::new_v4()));
    fs::create_dir_all(home.join(".orbitdock")).expect("create .orbitdock");
    home
}

fn run_all_migrations(db_path: &Path) {
    let conn = Connection::open(db_path).expect("open db");
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
    )
    .expect("set pragmas");

    let migrations_dir = find_migrations_dir();
    let mut files: Vec<PathBuf> = fs::read_dir(&migrations_dir)
        .expect("read migrations")
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|path| path.extension().and_then(|ext| ext.to_str()) == Some("sql"))
        .collect();
    files.sort();

    for file in files {
        let sql = fs::read_to_string(&file).expect("read migration");
        conn.execute_batch(&sql).unwrap_or_else(|err| {
            panic!("migration failed for {}: {}", file.display(), err);
        });
    }
}

#[test]
fn test_time_to_iso8601() {
    // 2024-01-15 12:30:45 UTC
    let result = time_to_iso8601(1705322445);
    assert!(result.starts_with("2024-01-15"));
}

#[test]
fn message_update_sets_last_message_from_completed_conversation_messages_only() {
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![PersistCommand::SessionCreate {
            id: "message-update-last-message".into(),
            provider: Provider::Codex,
            project_path: "/tmp/message-update-last-message".into(),
            project_name: Some("message-update-last-message".into()),
            branch: Some("main".into()),
            model: Some("gpt-5".into()),
            approval_policy: None,
            sandbox_mode: None,
            permission_mode: None,
            forked_from_session_id: None,
        }],
    )
    .expect("seed session");

    flush_batch(
        &db_path,
        vec![PersistCommand::MessageAppend {
            session_id: "message-update-last-message".into(),
            message: Message {
                id: "assistant-stream".into(),
                session_id: "message-update-last-message".into(),
                sequence: None,
                message_type: MessageType::Assistant,
                content: "I".into(),
                tool_name: None,
                tool_input: None,
                tool_output: None,
                is_error: false,
                is_in_progress: true,
                timestamp: "2026-02-28T00:00:00Z".into(),
                duration_ms: None,
                images: vec![],
            },
        }],
    )
    .expect("append in-progress assistant message");

    let conn = Connection::open(&db_path).expect("open db");
    let initial_last_message: Option<String> = conn
        .query_row(
            "SELECT last_message FROM sessions WHERE id = ?1",
            params!["message-update-last-message"],
            |row| row.get(0),
        )
        .expect("query initial last_message");
    assert!(initial_last_message.is_none());

    flush_batch(
        &db_path,
        vec![PersistCommand::MessageUpdate {
            session_id: "message-update-last-message".into(),
            message_id: "assistant-stream".into(),
            content: Some("Implemented both parts of the dashboard update".into()),
            tool_output: None,
            duration_ms: None,
            is_error: None,
            is_in_progress: Some(false),
        }],
    )
    .expect("finalize assistant message");

    let updated_last_message: Option<String> = conn
        .query_row(
            "SELECT last_message FROM sessions WHERE id = ?1",
            params!["message-update-last-message"],
            |row| row.get(0),
        )
        .expect("query updated last_message");
    assert_eq!(
        updated_last_message.as_deref(),
        Some("Implemented both parts of the dashboard update")
    );

    flush_batch(
        &db_path,
        vec![
            PersistCommand::MessageAppend {
                session_id: "message-update-last-message".into(),
                message: Message {
                    id: "tool-msg".into(),
                    session_id: "message-update-last-message".into(),
                    sequence: None,
                    message_type: MessageType::Tool,
                    content: "echo hello".into(),
                    tool_name: Some("Bash".into()),
                    tool_input: Some("{\"command\":\"echo hello\"}".into()),
                    tool_output: None,
                    is_error: false,
                    is_in_progress: false,
                    timestamp: "2026-02-28T00:00:01Z".into(),
                    duration_ms: None,
                    images: vec![],
                },
            },
            PersistCommand::MessageUpdate {
                session_id: "message-update-last-message".into(),
                message_id: "tool-msg".into(),
                content: Some("echo hello && pwd".into()),
                tool_output: None,
                duration_ms: None,
                is_error: None,
                is_in_progress: Some(false),
            },
        ],
    )
    .expect("append and update tool message");

    let after_tool_last_message: Option<String> = conn
        .query_row(
            "SELECT last_message FROM sessions WHERE id = ?1",
            params!["message-update-last-message"],
            |row| row.get(0),
        )
        .expect("query last_message after tool update");
    assert_eq!(
        after_tool_last_message.as_deref(),
        Some("Implemented both parts of the dashboard update")
    );
}

#[test]
fn approval_requested_upserts_existing_unresolved_row_for_same_request_id() {
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![PersistCommand::SessionCreate {
            id: "approval-upsert-session".into(),
            provider: Provider::Codex,
            project_path: "/tmp/approval-upsert".into(),
            project_name: Some("approval-upsert".into()),
            branch: Some("main".into()),
            model: Some("gpt-5".into()),
            approval_policy: None,
            sandbox_mode: None,
            permission_mode: None,
            forked_from_session_id: None,
        }],
    )
    .expect("seed approval upsert session");

    flush_batch(
        &db_path,
        vec![
            PersistCommand::ApprovalRequested {
                session_id: "approval-upsert-session".into(),
                request_id: "req-1".into(),
                approval_type: ApprovalType::Exec,
                tool_name: Some("Bash".into()),
                tool_input: Some(r#"{"command":"echo first"}"#.into()),
                command: Some("echo first".into()),
                file_path: None,
                diff: None,
                question: None,
                question_prompts: vec![],
                preview: None,
                cwd: Some("/tmp/approval-upsert".into()),
                proposed_amendment: None,
                permission_suggestions: None,
            },
            PersistCommand::ApprovalRequested {
                session_id: "approval-upsert-session".into(),
                request_id: "req-1".into(),
                approval_type: ApprovalType::Exec,
                tool_name: Some("Bash".into()),
                tool_input: Some(r#"{"command":"echo updated"}"#.into()),
                command: Some("echo updated".into()),
                file_path: None,
                diff: None,
                question: None,
                question_prompts: vec![],
                preview: None,
                cwd: Some("/tmp/approval-upsert".into()),
                proposed_amendment: None,
                permission_suggestions: None,
            },
        ],
    )
    .expect("persist approval requests");

    let conn = Connection::open(&db_path).expect("open db");
    let rows: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM approval_history WHERE session_id = ?1 AND request_id = ?2",
            params!["approval-upsert-session", "req-1"],
            |row| row.get(0),
        )
        .expect("count approval history rows");
    assert_eq!(rows, 1);

    let command: Option<String> = conn
        .query_row(
            "SELECT command FROM approval_history WHERE session_id = ?1 AND request_id = ?2",
            params!["approval-upsert-session", "req-1"],
            |row| row.get(0),
        )
        .expect("load updated command");
    assert_eq!(command.as_deref(), Some("echo updated"));
}

#[tokio::test]
async fn approval_requested_persists_rich_payload_and_list_approvals_decodes_it() {
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![PersistCommand::SessionCreate {
            id: "approval-rich-session".into(),
            provider: Provider::Claude,
            project_path: "/tmp/approval-rich".into(),
            project_name: Some("approval-rich".into()),
            branch: Some("main".into()),
            model: Some("claude-opus".into()),
            approval_policy: None,
            sandbox_mode: None,
            permission_mode: Some("plan".into()),
            forked_from_session_id: None,
        }],
    )
    .expect("seed approval rich session");

    flush_batch(
            &db_path,
            vec![PersistCommand::ApprovalRequested {
                session_id: "approval-rich-session".into(),
                request_id: "req-rich-1".into(),
                approval_type: ApprovalType::Exec,
                tool_name: Some("ExitPlanMode".into()),
                tool_input: Some(
                    r##"{"plan":"# Plan\n1. Simplify toolbar ordering UX","allowedPrompts":[{"tool":"Bash","prompt":"run tests"}]}"##
                        .into(),
                ),
                command: None,
                file_path: None,
                diff: None,
                question: None,
                question_prompts: vec![],
                preview: Some(ApprovalPreview {
                    preview_type: orbitdock_protocol::ApprovalPreviewType::Prompt,
                    value: "# Plan\n1. Simplify toolbar ordering UX".into(),
                    shell_segments: vec![],
                    compact: Some("Plan".into()),
                    decision_scope: Some("approve/deny applies to this full tool action.".into()),
                    risk_level: Some(orbitdock_protocol::ApprovalRiskLevel::Normal),
                    risk_findings: vec![],
                    manifest: Some("manifest".into()),
                }),
                cwd: Some("/tmp/approval-rich".into()),
                proposed_amendment: Some(vec!["run tests".into()]),
                permission_suggestions: Some(serde_json::json!([
                    {
                        "type": "addRules",
                        "behavior": "allow",
                        "destination": "session"
                    }
                ])),
            }],
        )
        .expect("persist approval request");

    let approvals = list_approvals(Some("approval-rich-session".into()), Some(10))
        .await
        .expect("list approvals");
    assert_eq!(approvals.len(), 1);

    let approval = &approvals[0];
    assert_eq!(approval.request_id, "req-rich-1");
    assert_eq!(approval.tool_name.as_deref(), Some("ExitPlanMode"));
    assert_eq!(
        approval.tool_input.as_deref(),
        Some(
            r##"{"plan":"# Plan\n1. Simplify toolbar ordering UX","allowedPrompts":[{"tool":"Bash","prompt":"run tests"}]}"##
        )
    );
    assert_eq!(
        approval
            .preview
            .as_ref()
            .map(|preview| preview.value.as_str()),
        Some("# Plan\n1. Simplify toolbar ordering UX")
    );
    assert_eq!(
        approval.proposed_amendment.as_ref(),
        Some(&vec!["run tests".to_string()])
    );
    assert!(approval.permission_suggestions.is_some());
}

#[test]
fn approval_decision_resolves_all_unresolved_duplicates_for_request_id() {
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![PersistCommand::SessionCreate {
            id: "approval-resolution-session".into(),
            provider: Provider::Codex,
            project_path: "/tmp/approval-resolution".into(),
            project_name: Some("approval-resolution".into()),
            branch: Some("main".into()),
            model: Some("gpt-5".into()),
            approval_policy: None,
            sandbox_mode: None,
            permission_mode: None,
            forked_from_session_id: None,
        }],
    )
    .expect("seed approval resolution session");

    let conn = Connection::open(&db_path).expect("open db");
    let created_at = "2026-02-25T00:00:00Z";
    conn.execute(
            "INSERT INTO approval_history (
                session_id, request_id, approval_type, tool_name, command, file_path, cwd, proposed_amendment, created_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, NULL, ?6, NULL, ?7)",
            params![
                "approval-resolution-session",
                "req-1",
                "exec",
                "Bash",
                "echo one",
                "/tmp/approval-resolution",
                created_at
            ],
        )
        .expect("insert first duplicate unresolved approval");
    conn.execute(
            "INSERT INTO approval_history (
                session_id, request_id, approval_type, tool_name, command, file_path, cwd, proposed_amendment, created_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, NULL, ?6, NULL, ?7)",
            params![
                "approval-resolution-session",
                "req-1",
                "exec",
                "Bash",
                "echo two",
                "/tmp/approval-resolution",
                created_at
            ],
        )
        .expect("insert second duplicate unresolved approval");
    conn.execute(
            "INSERT INTO approval_history (
                session_id, request_id, approval_type, tool_name, command, file_path, cwd, proposed_amendment, created_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, NULL, ?6, NULL, ?7)",
            params![
                "approval-resolution-session",
                "req-2",
                "exec",
                "Bash",
                "echo next",
                "/tmp/approval-resolution",
                created_at
            ],
        )
        .expect("insert next unresolved approval");
    conn.execute(
        "UPDATE sessions SET pending_approval_id = ?1 WHERE id = ?2",
        params!["req-1", "approval-resolution-session"],
    )
    .expect("seed stale queue head");

    flush_batch(
        &db_path,
        vec![PersistCommand::ApprovalDecision {
            session_id: "approval-resolution-session".into(),
            request_id: "req-1".into(),
            decision: "approved".into(),
        }],
    )
    .expect("persist approval decision");

    let unresolved_for_req_1: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM approval_history
                 WHERE session_id = ?1 AND request_id = ?2 AND decision IS NULL",
            params!["approval-resolution-session", "req-1"],
            |row| row.get(0),
        )
        .expect("count unresolved duplicates");
    assert_eq!(unresolved_for_req_1, 0);

    let pending_approval_id: Option<String> = conn
        .query_row(
            "SELECT pending_approval_id FROM sessions WHERE id = ?1",
            params!["approval-resolution-session"],
            |row| row.get(0),
        )
        .expect("load pending approval id");
    assert_eq!(pending_approval_id.as_deref(), Some("req-2"));
}

#[test]
fn tokens_update_writes_usage_tables() {
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![
            PersistCommand::SessionCreate {
                id: "usage-session".into(),
                provider: Provider::Codex,
                project_path: "/tmp/usage-session".into(),
                project_name: Some("usage-session".into()),
                branch: Some("main".into()),
                model: Some("gpt-5".into()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                forked_from_session_id: None,
            },
            PersistCommand::TokensUpdate {
                session_id: "usage-session".into(),
                usage: TokenUsage {
                    input_tokens: 1200,
                    output_tokens: 300,
                    cached_tokens: 100,
                    context_window: 200_000,
                },
                snapshot_kind: TokenUsageSnapshotKind::ContextTurn,
            },
            PersistCommand::TurnDiffInsert {
                session_id: "usage-session".into(),
                turn_id: "turn-1".into(),
                turn_seq: 1,
                diff: "--- a/file\n+++ b/file\n@@\n-old\n+new".into(),
                input_tokens: 1200,
                output_tokens: 300,
                cached_tokens: 100,
                context_window: 200_000,
                snapshot_kind: TokenUsageSnapshotKind::ContextTurn,
            },
        ],
    )
    .expect("flush usage writes");

    let conn = Connection::open(&db_path).expect("open db");

    let event_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM usage_events WHERE session_id = ?1",
            params!["usage-session"],
            |row| row.get(0),
        )
        .expect("count usage events");
    assert_eq!(event_count, 1);

    let (snapshot_kind, context_input, context_window): (String, i64, i64) = conn
        .query_row(
            "SELECT snapshot_kind, context_input_tokens, context_window
                 FROM usage_session_state
                 WHERE session_id = ?1",
            params!["usage-session"],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("load usage state");
    assert_eq!(snapshot_kind, "context_turn");
    assert_eq!(context_input, 1200);
    assert_eq!(context_window, 200_000);

    let (turn_seq, input_delta, turn_kind): (i64, i64, String) = conn
        .query_row(
            "SELECT turn_seq, input_delta_tokens, snapshot_kind
                 FROM usage_turns
                 WHERE session_id = ?1 AND turn_id = ?2",
            params!["usage-session", "turn-1"],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("load usage turn");
    assert_eq!(turn_seq, 1);
    assert_eq!(input_delta, 1200);
    assert_eq!(turn_kind, "context_turn");
}

#[tokio::test]
async fn startup_restore_prefers_usage_session_state_snapshot_values() {
    let _guard = env_lock()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![
            PersistCommand::SessionCreate {
                id: "usage-restore".into(),
                provider: Provider::Codex,
                project_path: "/tmp/usage-restore".into(),
                project_name: Some("usage-restore".into()),
                branch: Some("main".into()),
                model: Some("gpt-5".into()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                forked_from_session_id: None,
            },
            PersistCommand::TokensUpdate {
                session_id: "usage-restore".into(),
                usage: TokenUsage {
                    input_tokens: 123,
                    output_tokens: 77,
                    cached_tokens: 19,
                    context_window: 200_000,
                },
                snapshot_kind: TokenUsageSnapshotKind::ContextTurn,
            },
        ],
    )
    .expect("seed usage restore session");

    let conn = Connection::open(&db_path).expect("open db");
    conn.execute(
        "UPDATE sessions
             SET input_tokens = 1,
                 output_tokens = 2,
                 cached_tokens = 3,
                 context_window = 4
             WHERE id = ?1",
        params!["usage-restore"],
    )
    .expect("mutate legacy token columns");

    let restored = load_sessions_for_startup()
        .await
        .expect("load sessions for startup");
    let session = restored
        .iter()
        .find(|s| s.id == "usage-restore")
        .expect("restored usage session");

    assert_eq!(session.input_tokens, 123);
    assert_eq!(session.output_tokens, 77);
    assert_eq!(session.cached_tokens, 19);
    assert_eq!(session.context_window, 200_000);
    assert_eq!(
        session.token_usage_snapshot_kind,
        TokenUsageSnapshotKind::ContextTurn
    );
}

#[tokio::test]
async fn load_session_by_id_prefers_usage_turns_and_turn_seq_order() {
    let _guard = env_lock()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![
            PersistCommand::SessionCreate {
                id: "usage-turn-restore".into(),
                provider: Provider::Codex,
                project_path: "/tmp/usage-turn-restore".into(),
                project_name: Some("usage-turn-restore".into()),
                branch: Some("main".into()),
                model: Some("gpt-5".into()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                forked_from_session_id: None,
            },
            PersistCommand::TokensUpdate {
                session_id: "usage-turn-restore".into(),
                usage: TokenUsage {
                    input_tokens: 1_000,
                    output_tokens: 200,
                    cached_tokens: 50,
                    context_window: 200_000,
                },
                snapshot_kind: TokenUsageSnapshotKind::LifetimeTotals,
            },
            PersistCommand::TurnDiffInsert {
                session_id: "usage-turn-restore".into(),
                turn_id: "turn-2".into(),
                turn_seq: 2,
                diff: "two".into(),
                input_tokens: 700,
                output_tokens: 140,
                cached_tokens: 30,
                context_window: 200_000,
                snapshot_kind: TokenUsageSnapshotKind::ContextTurn,
            },
            PersistCommand::TurnDiffInsert {
                session_id: "usage-turn-restore".into(),
                turn_id: "turn-1".into(),
                turn_seq: 1,
                diff: "one".into(),
                input_tokens: 400,
                output_tokens: 80,
                cached_tokens: 20,
                context_window: 200_000,
                snapshot_kind: TokenUsageSnapshotKind::ContextTurn,
            },
        ],
    )
    .expect("seed turn restore session");

    let conn = Connection::open(&db_path).expect("open db");
    conn.execute(
        "UPDATE turn_diffs
             SET input_tokens = 9,
                 output_tokens = 9,
                 cached_tokens = 9,
                 context_window = 9
             WHERE session_id = ?1",
        params!["usage-turn-restore"],
    )
    .expect("mutate legacy turn token columns");

    let restored = load_session_by_id("usage-turn-restore")
        .await
        .expect("load session by id")
        .expect("session restored");

    assert_eq!(
        restored.token_usage_snapshot_kind,
        TokenUsageSnapshotKind::LifetimeTotals
    );
    assert_eq!(restored.turn_diffs.len(), 2);
    assert_eq!(restored.turn_diffs[0].0, "turn-1");
    assert_eq!(restored.turn_diffs[1].0, "turn-2");
    assert_eq!(restored.turn_diffs[0].2, 400);
    assert_eq!(restored.turn_diffs[1].2, 700);
    assert_eq!(
        restored.turn_diffs[0].6,
        TokenUsageSnapshotKind::ContextTurn
    );
    assert_eq!(
        restored.turn_diffs[1].6,
        TokenUsageSnapshotKind::ContextTurn
    );
}

#[tokio::test]
async fn load_session_permission_mode_returns_persisted_value() {
    let _guard = env_lock()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![PersistCommand::SessionCreate {
            id: "claude-permission".into(),
            provider: Provider::Claude,
            project_path: "/tmp/claude-permission".into(),
            project_name: Some("claude-permission".into()),
            branch: Some("main".into()),
            model: Some("claude-opus-4-6".into()),
            approval_policy: None,
            sandbox_mode: None,
            permission_mode: Some("bypassPermissions".into()),
            forked_from_session_id: None,
        }],
    )
    .expect("seed session");

    let mode = load_session_permission_mode("claude-permission")
        .await
        .expect("load permission mode");
    assert_eq!(mode.as_deref(), Some("bypassPermissions"));

    let missing = load_session_permission_mode("missing-session")
        .await
        .expect("load missing permission mode");
    assert!(missing.is_none());
}

#[tokio::test]
async fn startup_restore_includes_active_and_ended_sessions() {
    let _guard = env_lock()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![
            PersistCommand::SessionCreate {
                id: "direct-active".into(),
                provider: Provider::Codex,
                project_path: "/tmp/direct-active".into(),
                project_name: Some("direct-active".into()),
                branch: Some("main".into()),
                model: Some("gpt-5".into()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                forked_from_session_id: None,
            },
            PersistCommand::RolloutSessionUpsert {
                id: "passive-active".into(),
                thread_id: "passive-active".into(),
                project_path: "/tmp/passive-active".into(),
                project_name: Some("passive-active".into()),
                branch: Some("main".into()),
                model: Some("gpt-5".into()),
                context_label: Some("codex_cli_rs".into()),
                transcript_path: "/tmp/passive-active.jsonl".into(),
                started_at: "2026-02-08T00:00:00Z".into(),
            },
            PersistCommand::SessionCreate {
                id: "direct-ended".into(),
                provider: Provider::Codex,
                project_path: "/tmp/direct-ended".into(),
                project_name: Some("direct-ended".into()),
                branch: Some("main".into()),
                model: Some("gpt-5".into()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                forked_from_session_id: None,
            },
            PersistCommand::SessionEnd {
                id: "direct-ended".into(),
                reason: "test".into(),
            },
            PersistCommand::RolloutSessionUpsert {
                id: "passive-ended".into(),
                thread_id: "passive-ended".into(),
                project_path: "/tmp/passive-ended".into(),
                project_name: Some("passive-ended".into()),
                branch: Some("main".into()),
                model: Some("gpt-5".into()),
                context_label: Some("codex_cli_rs".into()),
                transcript_path: "/tmp/passive-ended.jsonl".into(),
                started_at: "2026-02-08T00:00:00Z".into(),
            },
            PersistCommand::RolloutSessionUpdate {
                id: "passive-ended".into(),
                project_path: None,
                model: None,
                status: Some(SessionStatus::Ended),
                work_status: Some(WorkStatus::Ended),
                attention_reason: None,
                pending_tool_name: None,
                pending_tool_input: None,
                pending_question: None,
                total_tokens: None,
                last_tool: None,
                last_tool_at: None,
                custom_name: None,
            },
        ],
    )
    .expect("flush batch");

    let restored = load_sessions_for_startup().await.expect("load sessions");
    let restored_ids: Vec<String> = restored.iter().map(|s| s.id.clone()).collect();

    assert!(restored_ids.iter().any(|id| id == "direct-active"));
    assert!(restored_ids.iter().any(|id| id == "passive-active"));
    assert!(restored_ids.iter().any(|id| id == "direct-ended"));
    assert!(restored_ids.iter().any(|id| id == "passive-ended"));
    assert!(restored.iter().any(|s| s.status == "active"));
    assert!(restored.iter().any(|s| s.status == "ended"));
}

#[tokio::test]
async fn startup_restore_prefers_messages_table_for_last_message_over_stale_session_column() {
    let _guard = env_lock()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![
            PersistCommand::SessionCreate {
                id: "stale-last-message".into(),
                provider: Provider::Codex,
                project_path: "/tmp/stale-last-message".into(),
                project_name: Some("stale-last-message".into()),
                branch: Some("main".into()),
                model: Some("gpt-5".into()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                forked_from_session_id: None,
            },
            PersistCommand::MessageAppend {
                session_id: "stale-last-message".into(),
                message: Message {
                    id: "assistant-final".into(),
                    session_id: "stale-last-message".into(),
                    sequence: None,
                    message_type: MessageType::Assistant,
                    content: "Implemented both parts of the dashboard update".into(),
                    tool_name: None,
                    tool_input: None,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: false,
                    timestamp: "2026-02-28T00:00:00Z".into(),
                    duration_ms: None,
                    images: vec![],
                },
            },
        ],
    )
    .expect("seed stale-last-message session");

    let conn = Connection::open(&db_path).expect("open db");
    conn.execute(
        "UPDATE sessions SET last_message = ?1 WHERE id = ?2",
        params!["Yes", "stale-last-message"],
    )
    .expect("force stale session.last_message");
    drop(conn);

    let restored = load_sessions_for_startup().await.expect("load sessions");
    let startup_last_message = restored
        .iter()
        .find(|session| session.id == "stale-last-message")
        .and_then(|session| session.last_message.clone());
    assert_eq!(
        startup_last_message.as_deref(),
        Some("Implemented both parts of the dashboard update")
    );

    let by_id = load_session_by_id("stale-last-message")
        .await
        .expect("load session by id")
        .expect("expected restored session");
    assert_eq!(
        by_id.last_message.as_deref(),
        Some("Implemented both parts of the dashboard update")
    );
}

#[tokio::test]
async fn startup_restore_keeps_recent_passive_active_and_ends_stale_passive() {
    let _guard = env_lock()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![
            PersistCommand::RolloutSessionUpsert {
                id: "passive-recent".into(),
                thread_id: "passive-recent".into(),
                project_path: "/tmp/passive-recent".into(),
                project_name: Some("passive-recent".into()),
                branch: Some("main".into()),
                model: Some("gpt-5".into()),
                context_label: Some("codex_cli_rs".into()),
                transcript_path: "/tmp/passive-recent.jsonl".into(),
                started_at: iso_minutes_ago(2),
            },
            PersistCommand::RolloutSessionUpsert {
                id: "passive-stale".into(),
                thread_id: "passive-stale".into(),
                project_path: "/tmp/passive-stale".into(),
                project_name: Some("passive-stale".into()),
                branch: Some("main".into()),
                model: Some("gpt-5".into()),
                context_label: Some("codex_cli_rs".into()),
                transcript_path: "/tmp/passive-stale.jsonl".into(),
                started_at: iso_minutes_ago(30),
            },
            PersistCommand::SessionUpdate {
                id: "passive-recent".into(),
                status: Some(SessionStatus::Active),
                work_status: Some(WorkStatus::Waiting),
                last_activity_at: Some(iso_minutes_ago(2)),
            },
            PersistCommand::SessionUpdate {
                id: "passive-stale".into(),
                status: Some(SessionStatus::Active),
                work_status: Some(WorkStatus::Waiting),
                last_activity_at: Some(iso_minutes_ago(30)),
            },
        ],
    )
    .expect("flush startup sessions");

    let restored = load_sessions_for_startup().await.expect("load sessions");
    let recent = restored
        .iter()
        .find(|s| s.id == "passive-recent")
        .expect("recent passive session should be restored");
    let stale = restored
        .iter()
        .find(|s| s.id == "passive-stale")
        .expect("stale passive session should be restored");

    assert_eq!(recent.status, "active");
    assert_eq!(recent.work_status, "waiting");
    assert_eq!(stale.status, "ended");
    assert_eq!(stale.work_status, "ended");

    let conn = Connection::open(&db_path).expect("open db");
    let stale_reason: Option<String> = conn
        .query_row(
            "SELECT end_reason FROM sessions WHERE id = ?1",
            params!["passive-stale"],
            |row| row.get(0),
        )
        .expect("query stale end_reason");
    assert_eq!(stale_reason.as_deref(), Some("startup_stale_passive"));
}

#[tokio::test]
async fn stale_passive_ends_on_startup_then_reactivates_on_live_activity_across_restarts() {
    let _guard = env_lock()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![
            PersistCommand::RolloutSessionUpsert {
                id: "passive-restart-live".into(),
                thread_id: "passive-restart-live".into(),
                project_path: "/tmp/passive-restart-live".into(),
                project_name: Some("passive-restart-live".into()),
                branch: Some("main".into()),
                model: Some("gpt-5".into()),
                context_label: Some("codex_cli_rs".into()),
                transcript_path: "/tmp/passive-restart-live.jsonl".into(),
                started_at: iso_minutes_ago(30),
            },
            PersistCommand::SessionUpdate {
                id: "passive-restart-live".into(),
                status: Some(SessionStatus::Active),
                work_status: Some(WorkStatus::Waiting),
                last_activity_at: Some(iso_minutes_ago(30)),
            },
        ],
    )
    .expect("seed stale passive session");

    let first_restore = load_sessions_for_startup()
        .await
        .expect("first startup restore");
    let first = first_restore
        .iter()
        .find(|s| s.id == "passive-restart-live")
        .expect("stale session should exist after first restore");
    assert_eq!(first.status, "ended");
    assert_eq!(first.work_status, "ended");

    flush_batch(
        &db_path,
        vec![PersistCommand::RolloutSessionUpdate {
            id: "passive-restart-live".into(),
            project_path: None,
            model: None,
            status: Some(SessionStatus::Active),
            work_status: Some(WorkStatus::Waiting),
            attention_reason: Some(Some("awaitingReply".into())),
            pending_tool_name: Some(None),
            pending_tool_input: Some(None),
            pending_question: Some(None),
            total_tokens: None,
            last_tool: None,
            last_tool_at: None,
            custom_name: None,
        }],
    )
    .expect("apply live rollout activity");

    let second_restore = load_sessions_for_startup()
        .await
        .expect("second startup restore");
    let second = second_restore
        .iter()
        .find(|s| s.id == "passive-restart-live")
        .expect("reactivated session should exist after second restore");
    assert_eq!(second.status, "active");
    assert_eq!(second.work_status, "waiting");

    let conn = Connection::open(&db_path).expect("open db");
    let (status, work_status, end_reason): (String, String, Option<String>) = conn
        .query_row(
            "SELECT status, work_status, end_reason FROM sessions WHERE id = ?1",
            params!["passive-restart-live"],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("query reactivated row");
    assert_eq!(status, "active");
    assert_eq!(work_status, "waiting");
    assert!(
        end_reason.is_none(),
        "end_reason should be cleared after live reactivation"
    );
}

#[tokio::test]
async fn startup_ends_empty_active_claude_shell_sessions() {
    let _guard = env_lock()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![
            // Ghost shell: start event only, no prompt/tool/message activity.
            PersistCommand::ClaudeSessionUpsert {
                id: "claude-shell".into(),
                project_path: "/tmp/claude-shell".into(),
                project_name: Some("claude-shell".into()),
                branch: Some("main".into()),
                model: Some("claude-opus-4-1".into()),
                context_label: None,
                transcript_path: Some("/tmp/claude-shell.jsonl".into()),
                source: Some("startup".into()),
                agent_type: None,
                permission_mode: None,
                terminal_session_id: None,
                terminal_app: None,
                forked_from_session_id: None,
                repository_root: None,
                is_worktree: false,
                git_sha: None,
            },
            // Real session: has first prompt and should remain active.
            PersistCommand::ClaudeSessionUpsert {
                id: "claude-real".into(),
                project_path: "/tmp/claude-real".into(),
                project_name: Some("claude-real".into()),
                branch: Some("main".into()),
                model: Some("claude-opus-4-1".into()),
                context_label: None,
                transcript_path: Some("/tmp/claude-real.jsonl".into()),
                source: Some("startup".into()),
                agent_type: None,
                permission_mode: None,
                terminal_session_id: None,
                terminal_app: None,
                forked_from_session_id: None,
                repository_root: None,
                is_worktree: false,
                git_sha: None,
            },
            PersistCommand::ClaudePromptIncrement {
                id: "claude-real".into(),
                first_prompt: Some("Ship the fix".into()),
            },
        ],
    )
    .expect("flush batch");

    let _ = load_sessions_for_startup().await.expect("load sessions");

    let conn = Connection::open(&db_path).expect("open db");
    let shell_status: (String, String, Option<String>) = conn
        .query_row(
            "SELECT status, work_status, end_reason FROM sessions WHERE id = ?1",
            params!["claude-shell"],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("query shell row");
    assert_eq!(shell_status.0, "ended");
    assert_eq!(shell_status.1, "ended");
    assert_eq!(shell_status.2.as_deref(), Some("startup_empty_shell"));

    let real_status: String = conn
        .query_row(
            "SELECT status FROM sessions WHERE id = ?1",
            params!["claude-real"],
            |row| row.get(0),
        )
        .expect("query real row");
    assert_eq!(real_status, "active");
}

#[tokio::test]
async fn rollout_upsert_does_not_convert_direct_session_to_passive() {
    let _guard = env_lock()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![
            PersistCommand::SessionCreate {
                id: "shared-thread".into(),
                provider: Provider::Codex,
                project_path: "/tmp/direct".into(),
                project_name: Some("direct".into()),
                branch: Some("main".into()),
                model: Some("gpt-5".into()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                forked_from_session_id: None,
            },
            PersistCommand::SetThreadId {
                session_id: "shared-thread".into(),
                thread_id: "shared-thread".into(),
            },
            PersistCommand::RolloutSessionUpsert {
                id: "shared-thread".into(),
                thread_id: "shared-thread".into(),
                project_path: "/tmp/passive".into(),
                project_name: Some("passive".into()),
                branch: Some("main".into()),
                model: Some("gpt-5".into()),
                context_label: Some("codex_cli_rs".into()),
                transcript_path: "/tmp/passive.jsonl".into(),
                started_at: "2026-02-08T00:00:00Z".into(),
            },
        ],
    )
    .expect("flush batch");

    let conn = Connection::open(&db_path).expect("open db");
    let (provider, mode, project_path): (String, Option<String>, String) = conn
        .query_row(
            "SELECT provider, codex_integration_mode, project_path FROM sessions WHERE id = ?1",
            params!["shared-thread"],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("query session");

    assert_eq!(provider, "codex");
    assert_eq!(mode.as_deref(), Some("direct"));
    assert_eq!(project_path, "/tmp/direct");

    let restored = load_sessions_for_startup().await.expect("load sessions");
    let direct = restored
        .iter()
        .find(|s| s.id == "shared-thread")
        .expect("direct session restored");
    assert_eq!(direct.codex_integration_mode.as_deref(), Some("direct"));
}

#[tokio::test]
async fn rollout_activity_reactivates_timed_out_passive_session() {
    let _guard = env_lock()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    // Create a passive rollout-backed session and mark it ended (timeout path).
    flush_batch(
        &db_path,
        vec![
            PersistCommand::RolloutSessionUpsert {
                id: "passive-timeout".into(),
                thread_id: "passive-timeout".into(),
                project_path: "/tmp/passive-timeout".into(),
                project_name: Some("passive-timeout".into()),
                branch: Some("main".into()),
                model: Some("gpt-5".into()),
                context_label: Some("codex_cli_rs".into()),
                transcript_path: "/tmp/passive-timeout.jsonl".into(),
                started_at: "2026-02-08T00:00:00Z".into(),
            },
            PersistCommand::SessionEnd {
                id: "passive-timeout".into(),
                reason: "timeout".into(),
            },
        ],
    )
    .expect("flush ended session");

    // A new rollout event should reactivate the session and clear ended markers.
    flush_batch(
        &db_path,
        vec![PersistCommand::RolloutSessionUpdate {
            id: "passive-timeout".into(),
            project_path: None,
            model: None,
            status: Some(SessionStatus::Active),
            work_status: Some(WorkStatus::Waiting),
            attention_reason: Some(Some("awaitingReply".into())),
            pending_tool_name: Some(None),
            pending_tool_input: Some(None),
            pending_question: Some(None),
            total_tokens: None,
            last_tool: None,
            last_tool_at: None,
            custom_name: None,
        }],
    )
    .expect("flush reactivation");

    let conn = Connection::open(&db_path).expect("open db");
    let (status, work_status, ended_at, end_reason): (
        String,
        String,
        Option<String>,
        Option<String>,
    ) = conn
        .query_row(
            "SELECT status, work_status, ended_at, end_reason
                 FROM sessions
                 WHERE id = ?1",
            params!["passive-timeout"],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .expect("query session");

    assert_eq!(status, "active");
    assert_eq!(work_status, "waiting");
    assert!(
        ended_at.is_none(),
        "ended_at should be cleared on reactivation"
    );
    assert!(
        end_reason.is_none(),
        "end_reason should be cleared on reactivation"
    );
}

#[tokio::test]
async fn startup_restores_first_prompt_for_claude_and_codex() {
    let _guard = env_lock()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![
            PersistCommand::ClaudeSessionUpsert {
                id: "claude-1".into(),
                project_path: "/tmp/claude".into(),
                project_name: Some("claude".into()),
                branch: Some("main".into()),
                model: Some("claude-opus-4-1".into()),
                context_label: None,
                transcript_path: Some("/tmp/claude-1.jsonl".into()),
                source: Some("startup".into()),
                agent_type: None,
                permission_mode: None,
                terminal_session_id: None,
                terminal_app: None,
                forked_from_session_id: None,
                repository_root: None,
                is_worktree: false,
                git_sha: None,
            },
            PersistCommand::ClaudePromptIncrement {
                id: "claude-1".into(),
                first_prompt: Some("Investigate flaky CI and propose fixes".into()),
            },
            PersistCommand::SessionCreate {
                id: "codex-1".into(),
                provider: Provider::Codex,
                project_path: "/tmp/codex".into(),
                project_name: Some("codex".into()),
                branch: Some("main".into()),
                model: Some("gpt-5-codex".into()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                forked_from_session_id: None,
            },
            PersistCommand::CodexPromptIncrement {
                id: "codex-1".into(),
                first_prompt: Some("Refactor flaky test setup".into()),
            },
        ],
    )
    .expect("flush batch");

    let restored = load_sessions_for_startup().await.expect("load sessions");
    let session = restored
        .iter()
        .find(|s| s.id == "claude-1")
        .expect("claude session restored");
    assert_eq!(
        session.first_prompt.as_deref(),
        Some("Investigate flaky CI and propose fixes")
    );

    let codex_session = restored
        .iter()
        .find(|s| s.id == "codex-1")
        .expect("codex session restored");
    assert_eq!(
        codex_session.first_prompt.as_deref(),
        Some("Refactor flaky test setup")
    );
}

#[tokio::test]
async fn startup_restore_hydrates_claude_messages_from_transcript_when_db_messages_missing() {
    let _guard = env_lock()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    let transcript_path = home.join("claude-hydrate.jsonl");
    fs::write(
            &transcript_path,
            r#"{"type":"user","timestamp":"2026-02-10T01:00:00Z","message":{"role":"user","content":[{"type":"text","text":"Hello from transcript"}]}}
{"type":"assistant","timestamp":"2026-02-10T01:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"Server hydration works"}]}}
"#,
        )
        .expect("write transcript");

    flush_batch(
        &db_path,
        vec![
            PersistCommand::ClaudeSessionUpsert {
                id: "claude-hydrate".into(),
                project_path: "/tmp/claude-hydrate".into(),
                project_name: Some("claude-hydrate".into()),
                branch: Some("main".into()),
                model: Some("claude-opus-4-1".into()),
                context_label: None,
                transcript_path: Some(transcript_path.to_string_lossy().to_string()),
                source: Some("startup".into()),
                agent_type: None,
                permission_mode: None,
                terminal_session_id: None,
                terminal_app: None,
                forked_from_session_id: None,
                repository_root: None,
                is_worktree: false,
                git_sha: None,
            },
            PersistCommand::ClaudePromptIncrement {
                id: "claude-hydrate".into(),
                first_prompt: Some("Hello from transcript".into()),
            },
        ],
    )
    .expect("flush claude seed");

    let restored = load_sessions_for_startup().await.expect("load sessions");
    let session = restored
        .iter()
        .find(|s| s.id == "claude-hydrate")
        .expect("claude session restored");

    assert!(
        !session.messages.is_empty(),
        "expected transcript-backed message hydration"
    );
    assert!(session
        .messages
        .iter()
        .any(|m| m.content.contains("Hello from transcript")));
}

#[tokio::test]
async fn startup_restore_hydrates_codex_messages_from_input_text_transcript_items() {
    let _guard = env_lock()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    let transcript_path = home.join("codex-input-text.jsonl");
    fs::write(
            &transcript_path,
            r#"{"type":"response_item","timestamp":"2026-02-10T01:00:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"User says hello"}]}}
{"type":"response_item","timestamp":"2026-02-10T01:00:01Z","payload":{"type":"message","role":"assistant","content":[{"type":"input_text","text":"Assistant replies"}]}}
"#,
        )
        .expect("write codex transcript");

    flush_batch(
        &db_path,
        vec![PersistCommand::RolloutSessionUpsert {
            id: "codex-input-text".into(),
            thread_id: "codex-input-text".into(),
            project_path: "/tmp/codex-input-text".into(),
            project_name: Some("codex-input-text".into()),
            branch: Some("main".into()),
            model: Some("gpt-5-codex".into()),
            context_label: Some("codex_cli_rs".into()),
            transcript_path: transcript_path.to_string_lossy().to_string(),
            started_at: iso_minutes_ago(1),
        }],
    )
    .expect("seed codex passive session");

    let restored = load_sessions_for_startup().await.expect("load sessions");
    let session = restored
        .iter()
        .find(|s| s.id == "codex-input-text")
        .expect("codex session restored");

    assert!(session
        .messages
        .iter()
        .any(|m| m.content.contains("User says hello")));
    assert!(session
        .messages
        .iter()
        .any(|m| m.content.contains("Assistant replies")));
}

#[tokio::test]
async fn transcript_usage_parses_claude_message_usage() {
    let tmp_dir = std::env::temp_dir().join(format!("orbitdock-usage-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&tmp_dir).expect("create temp dir");
    let transcript_path = tmp_dir.join("claude-usage.jsonl");

    std::fs::write(
            &transcript_path,
            r#"{"type":"assistant","timestamp":"2026-02-10T01:00:00Z","message":{"role":"assistant","usage":{"input_tokens":100,"output_tokens":40,"cache_read_input_tokens":10,"cache_creation_input_tokens":5},"content":[{"type":"text","text":"first"}]}}
{"type":"assistant","timestamp":"2026-02-10T01:00:02Z","message":{"role":"assistant","usage":{"input_tokens":50,"output_tokens":20,"cache_read_input_tokens":4,"cache_creation_input_tokens":1},"content":[{"type":"text","text":"second"}]}}
"#,
        )
        .expect("write transcript");

    let usage = load_token_usage_from_transcript_path(transcript_path.to_string_lossy().as_ref())
        .await
        .expect("parse usage")
        .expect("usage present");

    // input_tokens and cached_tokens use the LAST message (current context fill)
    assert_eq!(usage.input_tokens, 50);
    assert_eq!(usage.output_tokens, 60);
    assert_eq!(usage.cached_tokens, 5); // 4 + 1 from last message
    assert_eq!(usage.context_window, 0);
}

#[tokio::test]
async fn transcript_usage_parses_codex_token_count_total_usage() {
    let tmp_dir = std::env::temp_dir().join(format!("orbitdock-usage-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&tmp_dir).expect("create temp dir");
    let transcript_path = tmp_dir.join("codex-usage.jsonl");

    std::fs::write(
            &transcript_path,
            r#"{"type":"event_msg","timestamp":"2026-02-10T01:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":321,"output_tokens":123,"cached_input_tokens":55},"last_token_usage":{"input_tokens":9,"output_tokens":4,"cached_input_tokens":1},"model_context_window":200000}}}
"#,
        )
        .expect("write transcript");

    let usage = load_token_usage_from_transcript_path(transcript_path.to_string_lossy().as_ref())
        .await
        .expect("parse usage")
        .expect("usage present");

    // Prefers last_token_usage (current context fill) over total
    assert_eq!(usage.input_tokens, 9);
    assert_eq!(usage.output_tokens, 4);
    assert_eq!(usage.cached_tokens, 1);
    assert_eq!(usage.context_window, 200_000);
}

#[tokio::test]
async fn transcript_turn_context_settings_extract_latest_model_and_effort() {
    let tmp_dir = std::env::temp_dir().join(format!("orbitdock-turn-context-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&tmp_dir).expect("create temp dir");
    let transcript_path = tmp_dir.join("codex-turn-context.jsonl");

    std::fs::write(
        &transcript_path,
        r#"{"type":"session_meta","payload":{"id":"s","cwd":"/tmp/repo","model_provider":"openai"}}
{"type":"turn_context","payload":{"model":"gpt-5.3-codex","effort":"xhigh"}}
{"type":"turn_context","payload":{"model":"gpt-5.4-codex","effort":"high"}}
"#,
    )
    .expect("write transcript");

    let (model, effort) = load_latest_codex_turn_context_settings_from_transcript_path(
        transcript_path.to_string_lossy().as_ref(),
    )
    .await
    .expect("load settings");

    assert_eq!(model.as_deref(), Some("gpt-5.4-codex"));
    assert_eq!(effort.as_deref(), Some("high"));
}

#[tokio::test]
async fn transcript_turn_context_settings_falls_back_to_reasoning_effort() {
    let tmp_dir = std::env::temp_dir().join(format!("orbitdock-turn-context-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&tmp_dir).expect("create temp dir");
    let transcript_path = tmp_dir.join("codex-turn-context-collab.jsonl");

    std::fs::write(
            &transcript_path,
            r#"{"type":"turn_context","payload":{"model":"gpt-5.3-codex","collaboration_mode":{"settings":{"reasoning_effort":"xhigh"}}}}
"#,
        )
        .expect("write transcript");

    let (model, effort) = load_latest_codex_turn_context_settings_from_transcript_path(
        transcript_path.to_string_lossy().as_ref(),
    )
    .await
    .expect("load settings");

    assert_eq!(model.as_deref(), Some("gpt-5.3-codex"));
    assert_eq!(effort.as_deref(), Some("xhigh"));
}

#[tokio::test]
async fn startup_ends_ghost_direct_claude_sessions() {
    let _guard = env_lock()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![
            // Ghost: direct Claude session that never initialized (no SDK ID, no prompt, no messages)
            PersistCommand::SessionCreate {
                id: "claude-ghost".into(),
                provider: Provider::Claude,
                project_path: "/tmp/ghost".into(),
                project_name: Some("ghost".into()),
                branch: Some("main".into()),
                model: Some("claude-opus-4-6".into()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                forked_from_session_id: None,
            },
            // Initialized: direct Claude session with SDK ID — should survive
            PersistCommand::SessionCreate {
                id: "claude-alive".into(),
                provider: Provider::Claude,
                project_path: "/tmp/alive".into(),
                project_name: Some("alive".into()),
                branch: Some("main".into()),
                model: Some("claude-opus-4-6".into()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                forked_from_session_id: None,
            },
            PersistCommand::SetClaudeSdkSessionId {
                session_id: "claude-alive".into(),
                claude_sdk_session_id: "sdk-abc-123".into(),
            },
            // Has messages but no SDK ID — should survive (messages prove it was real)
            PersistCommand::SessionCreate {
                id: "claude-has-msgs".into(),
                provider: Provider::Claude,
                project_path: "/tmp/has-msgs".into(),
                project_name: Some("has-msgs".into()),
                branch: Some("main".into()),
                model: Some("claude-opus-4-6".into()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                forked_from_session_id: None,
            },
            PersistCommand::MessageAppend {
                session_id: "claude-has-msgs".into(),
                message: Message {
                    id: "msg-1".into(),
                    session_id: "claude-has-msgs".into(),
                    sequence: None,
                    message_type: MessageType::User,
                    content: "hello".into(),
                    tool_name: None,
                    tool_input: None,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: false,
                    timestamp: "2026-02-22T00:00:00Z".into(),
                    duration_ms: None,
                    images: vec![],
                },
            },
        ],
    )
    .expect("flush batch");

    let _ = load_sessions_for_startup().await.expect("load sessions");

    let conn = Connection::open(&db_path).expect("open db");

    // Ghost should be ended
    let ghost: (String, String, Option<String>) = conn
        .query_row(
            "SELECT status, work_status, end_reason FROM sessions WHERE id = ?1",
            params!["claude-ghost"],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("query ghost");
    assert_eq!(ghost.0, "ended");
    assert_eq!(ghost.1, "ended");
    assert_eq!(ghost.2.as_deref(), Some("startup_ghost_direct"));

    // Initialized session should remain active
    let alive: String = conn
        .query_row(
            "SELECT status FROM sessions WHERE id = ?1",
            params!["claude-alive"],
            |row| row.get(0),
        )
        .expect("query alive");
    assert_eq!(alive, "active");

    // Session with messages should remain active
    let has_msgs: String = conn
        .query_row(
            "SELECT status FROM sessions WHERE id = ?1",
            params!["claude-has-msgs"],
            |row| row.get(0),
        )
        .expect("query has-msgs");
    assert_eq!(has_msgs, "active");
}

#[tokio::test]
async fn startup_ends_ghost_direct_codex_sessions() {
    let _guard = env_lock()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![
            // Ghost: direct Codex session with no thread_id
            PersistCommand::SessionCreate {
                id: "codex-ghost".into(),
                provider: Provider::Codex,
                project_path: "/tmp/codex-ghost".into(),
                project_name: Some("codex-ghost".into()),
                branch: Some("main".into()),
                model: Some("gpt-5".into()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                forked_from_session_id: None,
            },
            // Initialized: direct Codex session with thread_id — should survive
            PersistCommand::SessionCreate {
                id: "codex-alive".into(),
                provider: Provider::Codex,
                project_path: "/tmp/codex-alive".into(),
                project_name: Some("codex-alive".into()),
                branch: Some("main".into()),
                model: Some("gpt-5".into()),
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                forked_from_session_id: None,
            },
            PersistCommand::SetThreadId {
                session_id: "codex-alive".into(),
                thread_id: "thread-abc-123".into(),
            },
        ],
    )
    .expect("flush batch");

    let _ = load_sessions_for_startup().await.expect("load sessions");

    let conn = Connection::open(&db_path).expect("open db");

    // Ghost should be ended
    let ghost: (String, String, Option<String>) = conn
        .query_row(
            "SELECT status, work_status, end_reason FROM sessions WHERE id = ?1",
            params!["codex-ghost"],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("query ghost");
    assert_eq!(ghost.0, "ended");
    assert_eq!(ghost.1, "ended");
    assert_eq!(ghost.2.as_deref(), Some("startup_ghost_direct"));

    // Initialized session should remain active
    let alive: String = conn
        .query_row(
            "SELECT status FROM sessions WHERE id = ?1",
            params!["codex-alive"],
            |row| row.get(0),
        )
        .expect("query alive");
    assert_eq!(alive, "active");
}

#[tokio::test]
async fn cleanup_stale_permission_state_repairs_orphaned_permission_sessions() {
    let _guard = env_lock()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![PersistCommand::SessionCreate {
            id: "orphaned-permission".into(),
            provider: Provider::Claude,
            project_path: "/tmp/orphaned".into(),
            project_name: Some("orphaned".into()),
            branch: Some("main".into()),
            model: Some("claude-sonnet-4-6".into()),
            approval_policy: None,
            sandbox_mode: None,
            permission_mode: None,
            forked_from_session_id: None,
        }],
    )
    .expect("seed orphaned session");

    let conn = Connection::open(&db_path).expect("open db");
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;",
    )
    .expect("set pragmas");
    conn.execute(
        "UPDATE sessions
             SET work_status = 'permission',
                 attention_reason = 'awaitingPermission',
                 pending_tool_name = NULL,
                 pending_tool_input = NULL,
                 pending_question = NULL,
                 pending_approval_id = NULL
             WHERE id = ?1",
        params!["orphaned-permission"],
    )
    .expect("mark orphaned permission state");
    conn.execute(
        "INSERT INTO approval_history (
                 session_id, request_id, approval_type, tool_name, command, file_path, cwd,
                 decision, proposed_amendment, created_at, decided_at
             ) VALUES (?1, ?2, 'exec', 'Bash', 'echo hello', NULL, '/tmp', NULL, NULL, ?3, NULL)",
        params![
            "orphaned-permission",
            "orphaned-request-1",
            "2026-02-28T00:00:00Z"
        ],
    )
    .expect("seed unresolved approval row");
    drop(conn);

    let fixed = cleanup_stale_permission_state().await.expect("run cleanup");
    assert_eq!(fixed, 1, "expected one orphaned session to be repaired");

    let conn = Connection::open(&db_path).expect("reopen db");
    let repaired: (String, String, Option<String>, Option<String>) = conn
        .query_row(
            "SELECT work_status, attention_reason, pending_approval_id, pending_tool_name
                 FROM sessions WHERE id = ?1",
            params!["orphaned-permission"],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .expect("query repaired session");
    assert_eq!(repaired.0, "waiting");
    assert_eq!(repaired.1, "awaitingReply");
    assert!(repaired.2.is_none());
    assert!(repaired.3.is_none());

    let decision: Option<String> = conn
        .query_row(
            "SELECT decision FROM approval_history
                 WHERE session_id = ?1 AND request_id = ?2",
            params!["orphaned-permission", "orphaned-request-1"],
            |row| row.get(0),
        )
        .expect("query repaired approval decision");
    assert_eq!(decision.as_deref(), Some("abort"));
}

#[test]
fn display_name_new_style() {
    assert_eq!(
        display_name_from_model_string("claude-opus-4-6"),
        "Opus 4.6"
    );
    assert_eq!(
        display_name_from_model_string("claude-sonnet-4-5"),
        "Sonnet 4.5"
    );
    assert_eq!(
        display_name_from_model_string("claude-haiku-3-5"),
        "Haiku 3.5"
    );
    assert_eq!(
        display_name_from_model_string("claude-sonnet-4-6"),
        "Sonnet 4.6"
    );
}

#[test]
fn display_name_with_date_suffix() {
    assert_eq!(
        display_name_from_model_string("claude-sonnet-4-5-20250514"),
        "Sonnet 4.5"
    );
    assert_eq!(
        display_name_from_model_string("claude-opus-4-6-20260101"),
        "Opus 4.6"
    );
}

#[test]
fn display_name_legacy_format() {
    assert_eq!(
        display_name_from_model_string("claude-3-opus-20240229"),
        "Opus 3"
    );
    assert_eq!(
        display_name_from_model_string("claude-3-5-sonnet-20241022"),
        "Sonnet 3.5"
    );
    assert_eq!(
        display_name_from_model_string("claude-3-5-haiku-20241022"),
        "Haiku 3.5"
    );
}

#[test]
fn display_name_unknown_format() {
    assert_eq!(
        display_name_from_model_string("custom-model"),
        "custom-model"
    );
    assert_eq!(display_name_from_model_string("claude-unknown"), "unknown");
    assert_eq!(display_name_from_model_string("gpt-4o"), "gpt-4o");
}

#[test]
fn display_name_family_only() {
    assert_eq!(display_name_from_model_string("claude-opus"), "Opus");
    assert_eq!(display_name_from_model_string("claude-sonnet"), "Sonnet");
    assert_eq!(display_name_from_model_string("claude-haiku"), "Haiku");
}

#[tokio::test]
async fn subagent_metadata_round_trips_from_persistence() {
    let _guard = env_lock().lock().expect("lock test env");
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![PersistCommand::SessionCreate {
            id: "subagent-metadata-session".into(),
            provider: Provider::Claude,
            project_path: "/tmp/subagent-metadata-session".into(),
            project_name: Some("subagent-metadata-session".into()),
            branch: Some("main".into()),
            model: Some("claude-sonnet".into()),
            approval_policy: None,
            sandbox_mode: None,
            permission_mode: None,
            forked_from_session_id: None,
        }],
    )
    .expect("seed session");

    flush_batch(
        &db_path,
        vec![PersistCommand::ClaudeSubagentStart {
            id: "subagent-1".into(),
            session_id: "subagent-metadata-session".into(),
            agent_type: "plan".into(),
        }],
    )
    .expect("start subagent");

    {
        let conn = Connection::open(&db_path).expect("open db");
        conn.execute(
            "UPDATE subagents
             SET task_summary = ?1,
                 result_summary = ?2,
                 error_summary = ?3,
                 parent_subagent_id = ?4,
                 model = ?5
             WHERE id = ?6",
            params![
                "Explore the repository structure",
                "Found the primary modules",
                Option::<String>::None,
                "parent-1",
                "gpt-5",
                "subagent-1"
            ],
        )
        .expect("enrich subagent row");
    }

    flush_batch(
        &db_path,
        vec![PersistCommand::ClaudeSubagentEnd {
            id: "subagent-1".into(),
            transcript_path: Some("/tmp/subagent.jsonl".into()),
        }],
    )
    .expect("end subagent");

    let subagents = load_subagents_for_session("subagent-metadata-session")
        .await
        .expect("load subagents");
    let subagent = subagents.first().expect("expected subagent");

    assert_eq!(subagent.provider, Some(Provider::Claude));
    assert_eq!(subagent.label.as_deref(), Some("plan"));
    assert_eq!(
        subagent.status,
        orbitdock_protocol::SubagentStatus::Completed
    );
    assert_eq!(
        subagent.task_summary.as_deref(),
        Some("Explore the repository structure")
    );
    assert_eq!(
        subagent.result_summary.as_deref(),
        Some("Found the primary modules")
    );
    assert_eq!(subagent.parent_subagent_id.as_deref(), Some("parent-1"));
    assert_eq!(subagent.model.as_deref(), Some("gpt-5"));
    assert!(subagent.last_activity_at.is_some());
    assert!(subagent.ended_at.is_some());
}

#[tokio::test]
async fn upsert_subagent_preserves_completed_result_over_later_shutdown_update() {
    let _guard = env_lock().lock().expect("lock test env");
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![PersistCommand::SessionCreate {
            id: "subagent-precedence-session".into(),
            provider: Provider::Codex,
            project_path: "/tmp/subagent-precedence-session".into(),
            project_name: Some("subagent-precedence-session".into()),
            branch: Some("main".into()),
            model: Some("gpt-5.4".into()),
            approval_policy: None,
            sandbox_mode: None,
            permission_mode: None,
            forked_from_session_id: None,
        }],
    )
    .expect("seed session");

    flush_batch(
        &db_path,
        vec![PersistCommand::UpsertSubagent {
            session_id: "subagent-precedence-session".into(),
            info: orbitdock_protocol::SubagentInfo {
                id: "worker-1".into(),
                agent_type: "worker".into(),
                started_at: "2026-03-11T05:00:00Z".into(),
                ended_at: Some("2026-03-11T05:01:00Z".into()),
                provider: Some(Provider::Codex),
                label: Some("Mill".into()),
                status: orbitdock_protocol::SubagentStatus::Completed,
                task_summary: Some("Read AGENTS.md".into()),
                result_summary: Some("Reported the repository guidelines cleanly.".into()),
                error_summary: None,
                parent_subagent_id: Some("parent-1".into()),
                model: Some("gpt-5.4".into()),
                last_activity_at: Some("2026-03-11T05:01:00Z".into()),
            },
        }],
    )
    .expect("write completed worker state");

    flush_batch(
        &db_path,
        vec![PersistCommand::UpsertSubagent {
            session_id: "subagent-precedence-session".into(),
            info: orbitdock_protocol::SubagentInfo {
                id: "worker-1".into(),
                agent_type: "worker".into(),
                started_at: "2026-03-11T05:00:00Z".into(),
                ended_at: Some("2026-03-11T05:03:00Z".into()),
                provider: Some(Provider::Codex),
                label: Some("Mill".into()),
                status: orbitdock_protocol::SubagentStatus::Shutdown,
                task_summary: None,
                result_summary: None,
                error_summary: None,
                parent_subagent_id: Some("parent-1".into()),
                model: Some("gpt-5.4".into()),
                last_activity_at: Some("2026-03-11T05:02:00Z".into()),
            },
        }],
    )
    .expect("write later shutdown worker state");

    let subagents = load_subagents_for_session("subagent-precedence-session")
        .await
        .expect("load subagents");
    let subagent = subagents.first().expect("expected subagent");

    assert_eq!(
        subagent.status,
        orbitdock_protocol::SubagentStatus::Completed
    );
    assert_eq!(
        subagent.result_summary.as_deref(),
        Some("Reported the repository guidelines cleanly.")
    );
    assert_eq!(subagent.ended_at.as_deref(), Some("2026-03-11T05:01:00Z"));
    assert_eq!(subagent.last_activity_at.as_deref(), Some("2026-03-11T05:02:00Z"));
}

#[tokio::test]
async fn upsert_subagent_preserves_completed_result_over_later_not_found_update() {
    let _guard = env_lock().lock().expect("lock test env");
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![PersistCommand::SessionCreate {
            id: "subagent-not-found-session".into(),
            provider: Provider::Codex,
            project_path: "/tmp/subagent-not-found-session".into(),
            project_name: Some("subagent-not-found-session".into()),
            branch: Some("main".into()),
            model: Some("gpt-5.4".into()),
            approval_policy: None,
            sandbox_mode: None,
            permission_mode: None,
            forked_from_session_id: None,
        }],
    )
    .expect("seed session");

    flush_batch(
        &db_path,
        vec![PersistCommand::UpsertSubagent {
            session_id: "subagent-not-found-session".into(),
            info: orbitdock_protocol::SubagentInfo {
                id: "worker-2".into(),
                agent_type: "worker".into(),
                started_at: "2026-03-11T05:10:00Z".into(),
                ended_at: Some("2026-03-11T05:11:00Z".into()),
                provider: Some(Provider::Codex),
                label: Some("Gauss".into()),
                status: orbitdock_protocol::SubagentStatus::Completed,
                task_summary: Some("Read one file".into()),
                result_summary: Some("Finished with a clean answer.".into()),
                error_summary: None,
                parent_subagent_id: Some("parent-2".into()),
                model: Some("gpt-5.4".into()),
                last_activity_at: Some("2026-03-11T05:11:00Z".into()),
            },
        }],
    )
    .expect("write completed worker state");

    flush_batch(
        &db_path,
        vec![PersistCommand::UpsertSubagent {
            session_id: "subagent-not-found-session".into(),
            info: orbitdock_protocol::SubagentInfo {
                id: "worker-2".into(),
                agent_type: "worker".into(),
                started_at: "2026-03-11T05:10:00Z".into(),
                ended_at: Some("2026-03-11T05:12:00Z".into()),
                provider: Some(Provider::Codex),
                label: Some("Gauss".into()),
                status: orbitdock_protocol::SubagentStatus::NotFound,
                task_summary: None,
                result_summary: None,
                error_summary: Some("Worker disappeared after completion.".into()),
                parent_subagent_id: Some("parent-2".into()),
                model: Some("gpt-5.4".into()),
                last_activity_at: Some("2026-03-11T05:12:00Z".into()),
            },
        }],
    )
    .expect("write later not-found worker state");

    let subagents = load_subagents_for_session("subagent-not-found-session")
        .await
        .expect("load subagents");
    let subagent = subagents.first().expect("expected subagent");

    assert_eq!(
        subagent.status,
        orbitdock_protocol::SubagentStatus::Completed
    );
    assert_eq!(
        subagent.result_summary.as_deref(),
        Some("Finished with a clean answer.")
    );
    assert_eq!(subagent.error_summary, None);
    assert_eq!(subagent.ended_at.as_deref(), Some("2026-03-11T05:11:00Z"));
    assert_eq!(subagent.last_activity_at.as_deref(), Some("2026-03-11T05:12:00Z"));
}

#[tokio::test]
async fn upsert_subagent_preserves_completed_result_over_later_failed_update() {
    let _guard = env_lock().lock().expect("lock test env");
    let home = create_test_home();
    let _dd_guard = set_test_data_dir(&home);
    let db_path = home.join(".orbitdock/orbitdock.db");
    run_all_migrations(&db_path);

    flush_batch(
        &db_path,
        vec![PersistCommand::SessionCreate {
            id: "subagent-failed-session".into(),
            provider: Provider::Codex,
            project_path: "/tmp/subagent-failed-session".into(),
            project_name: Some("subagent-failed-session".into()),
            branch: Some("main".into()),
            model: Some("gpt-5.4".into()),
            approval_policy: None,
            sandbox_mode: None,
            permission_mode: None,
            forked_from_session_id: None,
        }],
    )
    .expect("seed session");

    flush_batch(
        &db_path,
        vec![PersistCommand::UpsertSubagent {
            session_id: "subagent-failed-session".into(),
            info: orbitdock_protocol::SubagentInfo {
                id: "worker-3".into(),
                agent_type: "worker".into(),
                started_at: "2026-03-11T05:20:00Z".into(),
                ended_at: Some("2026-03-11T05:21:00Z".into()),
                provider: Some(Provider::Codex),
                label: Some("Wegener".into()),
                status: orbitdock_protocol::SubagentStatus::Completed,
                task_summary: Some("Inspect a Swift file".into()),
                result_summary: Some("Picked the right file and explained it.".into()),
                error_summary: None,
                parent_subagent_id: Some("parent-3".into()),
                model: Some("gpt-5.4".into()),
                last_activity_at: Some("2026-03-11T05:21:00Z".into()),
            },
        }],
    )
    .expect("write completed worker state");

    flush_batch(
        &db_path,
        vec![PersistCommand::UpsertSubagent {
            session_id: "subagent-failed-session".into(),
            info: orbitdock_protocol::SubagentInfo {
                id: "worker-3".into(),
                agent_type: "worker".into(),
                started_at: "2026-03-11T05:20:00Z".into(),
                ended_at: Some("2026-03-11T05:22:00Z".into()),
                provider: Some(Provider::Codex),
                label: Some("Wegener".into()),
                status: orbitdock_protocol::SubagentStatus::Failed,
                task_summary: None,
                result_summary: None,
                error_summary: Some("Late failure after completion.".into()),
                parent_subagent_id: Some("parent-3".into()),
                model: Some("gpt-5.4".into()),
                last_activity_at: Some("2026-03-11T05:22:00Z".into()),
            },
        }],
    )
    .expect("write later failed worker state");

    let subagents = load_subagents_for_session("subagent-failed-session")
        .await
        .expect("load subagents");
    let subagent = subagents.first().expect("expected subagent");

    assert_eq!(
        subagent.status,
        orbitdock_protocol::SubagentStatus::Completed
    );
    assert_eq!(
        subagent.result_summary.as_deref(),
        Some("Picked the right file and explained it.")
    );
    assert_eq!(subagent.error_summary, None);
    assert_eq!(subagent.ended_at.as_deref(), Some("2026-03-11T05:21:00Z"));
    assert_eq!(subagent.last_activity_at.as_deref(), Some("2026-03-11T05:22:00Z"));
}
