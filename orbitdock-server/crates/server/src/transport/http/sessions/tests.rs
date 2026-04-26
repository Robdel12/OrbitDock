use std::path::PathBuf;

use axum::{
  extract::{Path, Query, State},
  Json,
};
use orbitdock_protocol::conversation_contracts::render_hints::RenderHints;
use orbitdock_protocol::conversation_contracts::{
  shell_terminal_snapshot, ConversationRow, ConversationRowEntry, ShellAction,
  ShellExecutionPayload, ToolRow,
};
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
use orbitdock_protocol::{Provider, SessionControlMode};
use rusqlite::Connection;

use crate::{
  domain::sessions::session::SessionHandle,
  infrastructure::persistence::{flush_batch_for_test, PersistCommand, SessionCreateParams},
  transport::http::test_support::new_persist_test_state,
};

use super::{
  common::clamp_library_limit,
  conversation::{get_conversation_snapshot, get_session_stats, search_conversation_rows},
  get_session_usage_turns,
  row_content::test_shell_execution_row_content,
  summary::{get_active_sessions_snapshot, get_archived_sessions_snapshot},
  ConversationPageQuery, ConversationSearchQuery, LibrarySnapshotQuery, SessionUsageTurnsQuery,
};

fn persist_session_fixture(
  db_path: &PathBuf,
  session_id: &str,
  project_path: &str,
  rows: Vec<ConversationRowEntry>,
) {
  let mut batch = vec![PersistCommand::SessionCreate(Box::new(
    SessionCreateParams {
      id: session_id.to_string(),
      provider: Provider::Codex,
      control_mode: SessionControlMode::Passive,
      project_path: project_path.to_string(),
      project_name: Some("orbitdock-test".to_string()),
      branch: Some("main".to_string()),
      model: Some("gpt-5".to_string()),
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

  batch.extend(rows.into_iter().map(|entry| PersistCommand::RowAppend {
    session_id: session_id.to_string(),
    entry,
    viewer_present: false,
    assigned_sequence: None,
    sequence_tx: None,
  }));

  flush_batch_for_test(db_path, batch).expect("persist session fixture");
}

fn test_tool_row(
  session_id: &str,
  id: &str,
  sequence: u64,
  title: &str,
  status: ToolStatus,
  duration_ms: Option<u64>,
) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: session_id.to_string(),
    sequence,
    turn_id: Some("turn-1".to_string()),
    turn_status: Default::default(),
    row: ConversationRow::Tool(ToolRow {
      id: id.to_string(),
      provider: Provider::Codex,
      family: ToolFamily::Shell,
      kind: ToolKind::Bash,
      status,
      title: title.to_string(),
      subtitle: None,
      summary: None,
      preview: None,
      started_at: None,
      ended_at: None,
      duration_ms,
      grouping_key: None,
      invocation: serde_json::json!({
          "tool_name": "bash",
          "raw_input": "echo hi",
      }),
      result: Some(serde_json::json!({
          "tool_name": "bash",
          "raw_output": "done",
      })),
      render_hints: RenderHints::default(),
      tool_display: None,
      shell_execution: None,
    }),
  }
}

fn test_shell_tool_row(
  session_id: &str,
  id: &str,
  sequence: u64,
  output: Option<&str>,
) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: session_id.to_string(),
    sequence,
    turn_id: Some("turn-1".to_string()),
    turn_status: Default::default(),
    row: ConversationRow::Tool(ToolRow {
      id: id.to_string(),
      provider: Provider::Codex,
      family: ToolFamily::Shell,
      kind: ToolKind::Bash,
      status: ToolStatus::Completed,
      title: "sed -n '1,40p' docs/design-system.md".to_string(),
      subtitle: Some("/tmp/orbitdock-shell-execution".to_string()),
      summary: None,
      preview: None,
      started_at: None,
      ended_at: None,
      duration_ms: Some(18),
      grouping_key: None,
      invocation: serde_json::json!({
        "command": "sed -n '1,40p' docs/design-system.md",
        "cwd": "/tmp/orbitdock-shell-execution",
      }),
      result: None,
      render_hints: RenderHints::default(),
      tool_display: None,
      shell_execution: Some(ShellExecutionPayload {
        command: "sed -n '1,40p' docs/design-system.md".to_string(),
        cwd: "/tmp/orbitdock-shell-execution".to_string(),
        process_id: Some("pty-42".to_string()),
        actions: vec![ShellAction::Read {
          command: "sed -n '1,40p' docs/design-system.md".to_string(),
          name: "design-system.md".to_string(),
          path: "docs/design-system.md".to_string(),
        }],
        live_output_preview: None,
        aggregated_output: output.map(ToString::to_string),
        terminal_snapshot: None,
        preview: None,
        exit_code: Some(0),
      }),
    }),
  }
}

fn insert_usage_turn_fixture(db_path: &PathBuf, session_id: &str) {
  let conn = Connection::open(db_path).expect("open sqlite");
  conn
    .execute(
      "INSERT INTO usage_turns (
         session_id, turn_id, turn_seq, provider, model, snapshot_kind,
         input_tokens, output_tokens, cached_tokens, context_window, input_delta_tokens, created_at
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
      rusqlite::params![
        session_id,
        "turn-1",
        1_i64,
        "codex",
        "gpt-5.4",
        "lifetime_totals",
        100_i64,
        20_i64,
        0_i64,
        200_000_i64,
        100_i64,
        "2026-04-26T10:00:00Z",
      ],
    )
    .expect("insert usage turn 1");
  conn
    .execute(
      "INSERT INTO usage_turns (
         session_id, turn_id, turn_seq, provider, model, snapshot_kind,
         input_tokens, output_tokens, cached_tokens, context_window, input_delta_tokens, created_at
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
      rusqlite::params![
        session_id,
        "turn-2",
        2_i64,
        "codex",
        "gpt-5.4",
        "lifetime_totals",
        160_i64,
        32_i64,
        0_i64,
        200_000_i64,
        60_i64,
        "2026-04-26T10:05:00Z",
      ],
    )
    .expect("insert usage turn 2");
  conn
    .execute(
      "INSERT INTO usage_ledger_entries (
         session_id, turn_id, turn_seq, provider, model, session_started_at, observed_at,
         snapshot_kind, billable_input_tokens, billable_output_tokens, cache_read_tokens,
         cache_write_tokens, context_input_tokens, context_window, estimated_cost_usd,
         pricing_source, pricing_version, pricing_model_key, input_cost_per_token,
         output_cost_per_token, cache_read_cost_per_token, cache_write_cost_per_token
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22)",
      rusqlite::params![
        session_id,
        "turn-1",
        1_i64,
        "codex",
        "gpt-5.4",
        "2026-04-26T09:58:00Z",
        "2026-04-26T10:00:00Z",
        "lifetime_totals",
        100_i64,
        20_i64,
        0_i64,
        0_i64,
        100_i64,
        200_000_i64,
        0.0004_f64,
        "orbitdock_builtin",
        "2026-04-backbone-v1",
        "gpt-5",
        2.0 / 1_000_000.0,
        10.0 / 1_000_000.0,
        0.0_f64,
        0.0_f64,
      ],
    )
    .expect("insert usage ledger 1");
  conn
    .execute(
      "INSERT INTO usage_ledger_entries (
         session_id, turn_id, turn_seq, provider, model, session_started_at, observed_at,
         snapshot_kind, billable_input_tokens, billable_output_tokens, cache_read_tokens,
         cache_write_tokens, context_input_tokens, context_window, estimated_cost_usd,
         pricing_source, pricing_version, pricing_model_key, input_cost_per_token,
         output_cost_per_token, cache_read_cost_per_token, cache_write_cost_per_token
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22)",
      rusqlite::params![
        session_id,
        "turn-2",
        2_i64,
        "codex",
        "gpt-5.4",
        "2026-04-26T09:58:00Z",
        "2026-04-26T10:05:00Z",
        "lifetime_totals",
        60_i64,
        12_i64,
        0_i64,
        0_i64,
        160_i64,
        200_000_i64,
        0.00024_f64,
        "orbitdock_builtin",
        "2026-04-backbone-v1",
        "gpt-5",
        2.0 / 1_000_000.0,
        10.0 / 1_000_000.0,
        0.0_f64,
        0.0_f64,
      ],
    )
    .expect("insert usage ledger 2");
}

#[test]
fn library_snapshot_limit_clamps_to_safe_bounds() {
  assert_eq!(clamp_library_limit(None), 200);
  assert_eq!(clamp_library_limit(Some(0)), 1);
  assert_eq!(clamp_library_limit(Some(501)), 500);
}

#[tokio::test]
async fn search_conversation_rows_filters_by_query_and_tool_metadata() {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let session_id = orbitdock_protocol::new_session_id();
  persist_session_fixture(
    &db_path,
    &session_id,
    "/tmp/orbitdock-search-test",
    vec![test_tool_row(
      &session_id,
      "tool-1",
      1,
      "Deploy preview build",
      ToolStatus::Completed,
      Some(1200),
    )],
  );

  let response = search_conversation_rows(
    Path(session_id.clone()),
    Query(ConversationSearchQuery {
      q: Some("deploy".to_string()),
      family: Some("shell".to_string()),
      status: Some("completed".to_string()),
      kind: Some("bash".to_string()),
    }),
    State(state),
  )
  .await
  .expect("search endpoint should succeed");

  assert_eq!(response.0.total_row_count, 1);
  assert_eq!(
    response.0.rows.first().map(|entry| entry.id()),
    Some("tool-1")
  );
}

#[tokio::test]
async fn session_stats_reports_tool_rollups() {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let session_id = orbitdock_protocol::new_session_id();
  persist_session_fixture(
    &db_path,
    &session_id,
    "/tmp/orbitdock-stats-test",
    vec![
      test_tool_row(
        &session_id,
        "tool-1",
        1,
        "Run build",
        ToolStatus::Completed,
        Some(1000),
      ),
      test_tool_row(
        &session_id,
        "tool-2",
        2,
        "Run deploy",
        ToolStatus::Failed,
        Some(3000),
      ),
    ],
  );

  let response = get_session_stats(Path(session_id), State(state))
    .await
    .expect("stats endpoint should succeed");

  assert_eq!(response.0.total_rows, 2);
  assert_eq!(response.0.tool_count, 2);
  assert_eq!(response.0.failed_tool_count, 1);
  assert_eq!(response.0.average_tool_duration_ms, 2000);
  assert_eq!(response.0.tool_count_by_family.get("shell"), Some(&2));
}

#[tokio::test]
async fn session_usage_turns_returns_paginated_turn_rows_with_summary() {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let session_id = orbitdock_protocol::new_session_id();
  persist_session_fixture(&db_path, &session_id, "/tmp/orbitdock-usage-turns", vec![]);
  insert_usage_turn_fixture(&db_path, &session_id);

  let response = get_session_usage_turns(
    Path(session_id.clone()),
    Query(SessionUsageTurnsQuery {
      limit: Some(1),
      before_turn_seq: None,
    }),
    State(state.clone()),
  )
  .await
  .expect("session usage turns should succeed");

  assert_eq!(response.0.session_id, session_id);
  assert_eq!(response.0.total_turn_count, 2);
  assert!(response.0.has_more_before);
  assert_eq!(response.0.rows.len(), 1);
  assert_eq!(response.0.rows[0].turn_id, "turn-2");
  assert_eq!(response.0.rows[0].billable_input_tokens, 60);
  assert_eq!(
    response.0.rows[0].pricing.model_key.as_deref(),
    Some("gpt-5")
  );
  assert_eq!(response.0.summary.input_tokens, 160);
  assert_eq!(response.0.summary.output_tokens, 32);
  assert_eq!(response.0.summary.total_tokens, 192);

  let next_page = get_session_usage_turns(
    Path(session_id),
    Query(SessionUsageTurnsQuery {
      limit: Some(1),
      before_turn_seq: response.0.oldest_turn_seq,
    }),
    State(state),
  )
  .await
  .expect("session usage turns pagination should succeed");

  assert!(!next_page.0.has_more_before);
  assert_eq!(next_page.0.rows.len(), 1);
  assert_eq!(next_page.0.rows[0].turn_id, "turn-1");
}

#[tokio::test]
async fn dashboard_snapshot_reads_in_memory_sessions() {
  let (state, _persist_rx, _db_path, _guard) = new_persist_test_state(true).await;

  let mut session = crate::domain::sessions::session::SessionHandle::new(
    orbitdock_protocol::new_session_id(),
    orbitdock_protocol::Provider::Codex,
    "/tmp/orbitdock-dashboard-test".to_string(),
  );
  session.set_work_status(orbitdock_protocol::WorkStatus::Reply);
  session.refresh_snapshot();
  state.add_session(session);

  let Json(snapshot) = get_active_sessions_snapshot(State(state))
    .await
    .expect("dashboard snapshot should succeed");

  assert_eq!(snapshot.conversations.len(), 1);
  assert_eq!(snapshot.counts.attention, 0);
  assert_eq!(snapshot.counts.running, 0);
  assert_eq!(snapshot.counts.ready, 1);
  assert_eq!(snapshot.counts.direct, 0);
}

#[tokio::test]
async fn conversation_snapshot_prefers_live_runtime_rows_when_persistence_lags() {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let session_id = orbitdock_protocol::new_session_id();

  persist_session_fixture(
    &db_path,
    &session_id,
    "/tmp/orbitdock-conversation-db-lag",
    vec![test_tool_row(
      &session_id,
      "tool-db-1",
      0,
      "Persisted row",
      ToolStatus::Completed,
      Some(20),
    )],
  );

  let mut live = SessionHandle::new(
    session_id.clone(),
    Provider::Codex,
    "/tmp/orbitdock-conversation-runtime".to_string(),
  );
  live.replace_rows(vec![
    test_tool_row(
      &session_id,
      "tool-db-1",
      0,
      "Persisted row",
      ToolStatus::Completed,
      Some(20),
    ),
    test_tool_row(
      &session_id,
      "tool-live-2",
      1,
      "Live row",
      ToolStatus::Completed,
      Some(30),
    ),
  ]);
  state.add_session(live);

  let Json(snapshot) = get_conversation_snapshot(
    Path(session_id),
    Query(ConversationPageQuery::default()),
    State(state),
  )
  .await
  .expect("conversation snapshot should succeed");

  let ids: Vec<String> = snapshot
    .rows
    .iter()
    .map(|entry| entry.id().to_string())
    .collect();
  assert_eq!(snapshot.total_row_count, 2);
  assert_eq!(
    ids,
    vec!["tool-db-1".to_string(), "tool-live-2".to_string()]
  );
}

#[tokio::test]
async fn library_snapshot_reads_persisted_sessions() {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let session_id = orbitdock_protocol::new_session_id();
  persist_session_fixture(&db_path, &session_id, "/tmp/orbitdock-library-test", vec![]);

  let Json(snapshot) =
    get_archived_sessions_snapshot(Query(LibrarySnapshotQuery::default()), State(state))
      .await
      .expect("library snapshot should succeed");

  assert_eq!(snapshot.sessions.len(), 1);
}

#[tokio::test]
async fn library_snapshot_uses_library_revision() {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let session_id = orbitdock_protocol::new_session_id();
  persist_session_fixture(
    &db_path,
    &session_id,
    "/tmp/orbitdock-library-revision",
    vec![],
  );
  state.publish_library_invalidation();

  let Json(snapshot) =
    get_archived_sessions_snapshot(Query(LibrarySnapshotQuery::default()), State(state))
      .await
      .expect("library snapshot should succeed");

  assert_eq!(snapshot.revision, 1);
}

#[tokio::test]
async fn library_snapshot_paginates_with_offset_and_next_offset() {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let session_id_one = orbitdock_protocol::new_session_id();
  let session_id_two = orbitdock_protocol::new_session_id();
  persist_session_fixture(
    &db_path,
    &session_id_one,
    "/tmp/orbitdock-library-pagination-one",
    vec![],
  );
  persist_session_fixture(
    &db_path,
    &session_id_two,
    "/tmp/orbitdock-library-pagination-two",
    vec![],
  );

  let Json(first_page) = get_archived_sessions_snapshot(
    Query(LibrarySnapshotQuery {
      limit: Some(1),
      offset: Some(0),
    }),
    State(state.clone()),
  )
  .await
  .expect("first library page should succeed");

  assert_eq!(first_page.sessions.len(), 1);
  assert_eq!(first_page.total_count, 2);
  assert_eq!(first_page.next_offset, Some(1));

  let Json(second_page) = get_archived_sessions_snapshot(
    Query(LibrarySnapshotQuery {
      limit: Some(1),
      offset: Some(1),
    }),
    State(state),
  )
  .await
  .expect("second library page should succeed");

  assert_eq!(second_page.sessions.len(), 1);
  assert_eq!(second_page.total_count, 2);
  assert_eq!(second_page.next_offset, None);
}

#[tokio::test]
async fn library_snapshot_offset_past_end_returns_empty_page() {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let session_id = orbitdock_protocol::new_session_id();
  persist_session_fixture(
    &db_path,
    &session_id,
    "/tmp/orbitdock-library-pagination-offset",
    vec![],
  );

  let Json(page) = get_archived_sessions_snapshot(
    Query(LibrarySnapshotQuery {
      limit: Some(50),
      offset: Some(5),
    }),
    State(state),
  )
  .await
  .expect("library snapshot with offset past end should succeed");

  assert!(page.sessions.is_empty());
  assert_eq!(page.total_count, 1);
  assert_eq!(page.next_offset, None);
}

#[tokio::test]
async fn search_and_stats_return_not_found_for_runtime_only_sessions() {
  let (state, _persist_rx, _db_path, _guard) = new_persist_test_state(true).await;
  let session_id = orbitdock_protocol::new_session_id();
  state.add_session(crate::domain::sessions::session::SessionHandle::new(
    session_id.clone(),
    Provider::Codex,
    "/tmp/orbitdock-runtime-only".to_string(),
  ));

  let (search_status, Json(search_error)) = search_conversation_rows(
    Path(session_id.clone()),
    Query(super::ConversationSearchQuery::default()),
    State(state.clone()),
  )
  .await
  .expect_err("runtime-only session should not satisfy DB-backed search");

  assert_eq!(search_status, axum::http::StatusCode::NOT_FOUND);
  assert_eq!(search_error.code, "not_found");

  let (stats_status, Json(stats_error)) = get_session_stats(Path(session_id), State(state))
    .await
    .expect_err("runtime-only session should not satisfy DB-backed stats");

  assert_eq!(stats_status, axum::http::StatusCode::NOT_FOUND);
  assert_eq!(stats_error.code, "not_found");
}

#[tokio::test]
async fn shell_execution_row_content_returns_full_output() {
  let entry = test_shell_tool_row("session-1", "cmd-1", 1, Some("22pt Bold\n18pt Semibold"));
  let ConversationRow::Tool(row) = &entry.row else {
    panic!("expected tool row");
  };
  let shell = row.shell_execution.as_ref().expect("shell_execution");

  let response = test_shell_execution_row_content("cmd-1".to_string(), shell);

  assert_eq!(response.row_id, "cmd-1");
  assert_eq!(
    response.input_display.as_deref(),
    Some("sed -n '1,40p' docs/design-system.md")
  );
  assert_eq!(
    response.output_display.as_deref(),
    Some("22pt Bold\n18pt Semibold")
  );
  assert!(response.diff_display.is_none());
}

#[tokio::test]
async fn shell_execution_row_content_falls_back_to_terminal_snapshot_output() {
  let entry = test_shell_tool_row("session-1", "cmd-1", 1, None);
  let ConversationRow::Tool(row) = &entry.row else {
    panic!("expected tool row");
  };
  let mut shell = row.shell_execution.clone().expect("shell_execution");
  shell.terminal_snapshot = shell_terminal_snapshot(
    "sed -n '1,40p' docs/design-system.md",
    "/tmp/orbitdock-shell-execution",
    Some("snapshot only\n"),
  );

  let response = test_shell_execution_row_content("cmd-1".to_string(), &shell);

  assert_eq!(response.output_display.as_deref(), Some("snapshot only\n"));
}
