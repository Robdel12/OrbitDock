use std::path::PathBuf;

use axum::{
  extract::{Path, Query, State},
  Json,
};
use orbitdock_protocol::conversation_contracts::{render_hints::RenderHints, MessageRowContent};
use orbitdock_protocol::conversation_contracts::{ConversationRow, ConversationRowEntry, ToolRow};
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
use orbitdock_protocol::{
  Provider, ReviewCommentStatus, ReviewCommentTag, SessionControlMode, WorkStatus,
};
use rusqlite::Connection;

use crate::{
  domain::sessions::session::SessionHandle,
  infrastructure::persistence::{flush_batch_for_test, PersistCommand, SessionCreateParams},
  transport::http::test_support::{flush_next_persist_command, new_persist_test_state},
};

use super::{
  common::clamp_library_limit,
  conversation::{
    get_conversation_history, get_conversation_snapshot, get_session_stats, mark_session_read,
    search_conversation_rows,
  },
  detail::get_session_detail,
  get_session_review, get_session_usage_turns, get_sessions_summary,
  summary::{get_active_sessions_snapshot, get_archived_sessions_snapshot},
  ConversationPageQuery, ConversationSearchQuery, LibrarySnapshotQuery, SessionSnapshotQuery,
  SessionUsageTurnsQuery,
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

fn update_session_timestamps(
  db_path: &PathBuf,
  session_id: &str,
  started_at: Option<&str>,
  last_activity_at: Option<&str>,
  last_progress_at: Option<&str>,
  ended_at: Option<&str>,
) {
  let conn = Connection::open(db_path).expect("open sqlite");
  conn
    .execute(
      "UPDATE sessions
         SET started_at = ?1,
             last_activity_at = ?2,
             last_progress_at = ?3,
             ended_at = ?4
       WHERE id = ?5",
      rusqlite::params![
        started_at,
        last_activity_at,
        last_progress_at,
        ended_at,
        session_id,
      ],
    )
    .expect("update session timestamps");
}

fn update_session_diff_fixture(
  db_path: &PathBuf,
  session_id: &str,
  current_diff: &str,
  turn_id: &str,
  turn_diff: &str,
) {
  let conn = Connection::open(db_path).expect("open sqlite");
  conn
    .execute(
      "UPDATE sessions SET current_diff = ?1 WHERE id = ?2",
      rusqlite::params![current_diff, session_id],
    )
    .expect("update session current diff");
  conn
    .execute(
      "INSERT OR REPLACE INTO turn_diffs (
         session_id, turn_id, diff, input_tokens, output_tokens, cached_tokens, context_window
       ) VALUES (?1, ?2, ?3, 0, 0, 0, 0)",
      rusqlite::params![session_id, turn_id, turn_diff],
    )
    .expect("insert turn diff");
}

fn insert_review_comment_fixture(
  db_path: &PathBuf,
  session_id: &str,
  comment_id: &str,
  turn_id: Option<&str>,
  body: &str,
  tag: Option<ReviewCommentTag>,
  status: ReviewCommentStatus,
) {
  let conn = Connection::open(db_path).expect("open sqlite");
  let tag = tag.map(|value| match value {
    ReviewCommentTag::Clarity => "clarity",
    ReviewCommentTag::Scope => "scope",
    ReviewCommentTag::Risk => "risk",
    ReviewCommentTag::Nit => "nit",
  });
  let status = match status {
    ReviewCommentStatus::Open => "open",
    ReviewCommentStatus::Resolved => "resolved",
  };

  conn
    .execute(
      "INSERT INTO review_comments (
         id, session_id, turn_id, file_path, line_start, line_end, body, tag, status, created_at
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
      rusqlite::params![
        comment_id,
        session_id,
        turn_id,
        "src/main.rs",
        12_i64,
        Some(14_i64),
        body,
        tag,
        status,
        "2026-04-26T10:10:00Z",
      ],
    )
    .expect("insert review comment");
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

fn test_user_row(session_id: &str, id: &str, sequence: u64, content: &str) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: session_id.to_string(),
    sequence,
    turn_id: Some(id.to_string()),
    turn_status: Default::default(),
    row: ConversationRow::User(MessageRowContent {
      id: id.to_string(),
      content: content.to_string(),
      turn_id: Some(id.to_string()),
      timestamp: None,
      is_streaming: false,
      images: Vec::new(),
      memory_citation: None,
      delivery_status: None,
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
async fn session_detail_trims_messages_and_diffs_by_default_then_returns_full_payloads_when_requested(
) {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let session_id = orbitdock_protocol::new_session_id();
  persist_session_fixture(
    &db_path,
    &session_id,
    "/tmp/orbitdock-detail-test",
    vec![test_tool_row(
      &session_id,
      "tool-1",
      1,
      "Inspect deployment logs",
      ToolStatus::Completed,
      Some(42),
    )],
  );
  update_session_diff_fixture(
    &db_path,
    &session_id,
    "diff --git a/src/main.rs b/src/main.rs",
    "turn-1",
    "diff --git a/src/main.rs b/src/main.rs",
  );

  let mut live = SessionHandle::new(
    session_id.clone(),
    Provider::Codex,
    "/tmp/orbitdock-detail-runtime".to_string(),
  );
  live.set_work_status(WorkStatus::Working);
  live.refresh_snapshot();
  state.add_session(live);

  let Json(default_detail) = get_session_detail(
    Path(session_id.clone()),
    Query(SessionSnapshotQuery::default()),
    State(state.clone()),
  )
  .await
  .expect("default detail snapshot should succeed");

  assert_eq!(default_detail.session.work_status, WorkStatus::Working);
  assert!(default_detail.session.rows.is_empty());
  assert!(default_detail.session.current_diff.is_none());
  assert!(default_detail.session.turn_diffs.is_empty());

  let Json(expanded_detail) = get_session_detail(
    Path(session_id),
    Query(SessionSnapshotQuery {
      include_messages: true,
      include_diffs: true,
    }),
    State(state),
  )
  .await
  .expect("expanded detail snapshot should succeed");

  assert_eq!(expanded_detail.session.work_status, WorkStatus::Working);
  assert_eq!(expanded_detail.session.rows.len(), 1);
  assert_eq!(expanded_detail.session.rows[0].id(), "tool-1");
  assert_eq!(
    expanded_detail.session.current_diff.as_deref(),
    Some("diff --git a/src/main.rs b/src/main.rs")
  );
  assert_eq!(expanded_detail.session.turn_diffs.len(), 1);
  assert_eq!(expanded_detail.session.turn_diffs[0].turn_id, "turn-1");
}

#[tokio::test]
async fn conversation_history_returns_rows_in_sequence_order_with_pagination() {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let session_id = orbitdock_protocol::new_session_id();
  persist_session_fixture(
    &db_path,
    &session_id,
    "/tmp/orbitdock-history-test",
    vec![
      test_user_row(&session_id, "user-1", 1, "Prepare release"),
      test_user_row(&session_id, "user-2", 2, "Ship release"),
      test_user_row(&session_id, "user-3", 3, "Verify release"),
      test_user_row(&session_id, "user-4", 4, "Tag release"),
      test_user_row(&session_id, "user-5", 5, "Announce release"),
    ],
  );

  let Json(first_page) = get_conversation_history(
    Path(session_id.clone()),
    Query(ConversationPageQuery {
      limit: Some(4),
      before_sequence: None,
    }),
    State(state.clone()),
  )
  .await
  .expect("first history page should succeed");

  assert_eq!(first_page.total_row_count, 5);
  assert_eq!(first_page.rows.len(), 4);
  assert_eq!(
    first_page
      .rows
      .iter()
      .map(|entry| entry.id())
      .collect::<Vec<_>>(),
    vec!["user-2", "user-3", "user-4", "user-5"]
  );

  let Json(second_page) = get_conversation_history(
    Path(session_id),
    Query(ConversationPageQuery {
      limit: Some(1),
      before_sequence: first_page.oldest_sequence,
    }),
    State(state),
  )
  .await
  .expect("second history page should succeed");

  assert_eq!(second_page.total_row_count, 5);
  assert_eq!(second_page.rows.len(), 1);
  assert_eq!(second_page.rows[0].id(), "user-1");
}

#[tokio::test]
async fn session_review_returns_persisted_diffs_and_comments() {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let session_id = orbitdock_protocol::new_session_id();
  persist_session_fixture(&db_path, &session_id, "/tmp/orbitdock-review-test", vec![]);
  update_session_diff_fixture(
    &db_path,
    &session_id,
    "diff --git a/src/lib.rs b/src/lib.rs",
    "turn-1",
    "diff --git a/src/lib.rs b/src/lib.rs",
  );
  insert_review_comment_fixture(
    &db_path,
    &session_id,
    "comment-1",
    Some("turn-1"),
    "Please keep this API-level test.",
    Some(ReviewCommentTag::Risk),
    ReviewCommentStatus::Open,
  );

  let Json(review) = get_session_review(Path(session_id), State(state))
    .await
    .expect("review snapshot should succeed");

  assert_eq!(
    review.current_diff.as_deref(),
    Some("diff --git a/src/lib.rs b/src/lib.rs")
  );
  assert_eq!(review.turn_diffs.len(), 1);
  assert_eq!(review.turn_diffs[0].turn_id, "turn-1");
  assert_eq!(review.comments.len(), 1);
  assert_eq!(review.comments[0].body, "Please keep this API-level test.");
  assert_eq!(review.comments[0].tag, Some(ReviewCommentTag::Risk));
  assert_eq!(review.comments[0].status, ReviewCommentStatus::Open);
}

#[tokio::test]
async fn sessions_summary_counts_active_sessions_and_recent_archive() {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let archived_session_id = orbitdock_protocol::new_session_id();
  persist_session_fixture(
    &db_path,
    &archived_session_id,
    "/tmp/orbitdock-summary-archive",
    vec![],
  );

  let active_session_id = orbitdock_protocol::new_session_id();
  let mut active_session = SessionHandle::new(
    active_session_id.clone(),
    Provider::Codex,
    "/tmp/orbitdock-summary-active".to_string(),
  );
  active_session.set_work_status(WorkStatus::Reply);
  active_session.refresh_snapshot();
  state.add_session(active_session);

  let Json(summary) = get_sessions_summary(State(state))
    .await
    .expect("sessions summary should succeed");

  assert_eq!(summary.counts.total, 1);
  assert_eq!(summary.counts.active, 1);
  assert_eq!(summary.counts.ready, 1);
  assert_eq!(summary.active_sessions.len(), 1);
  assert_eq!(summary.active_sessions[0].id, active_session_id);
  assert_eq!(summary.recent_sessions.len(), 1);
  assert_eq!(summary.recent_sessions[0].id, archived_session_id);
}

#[tokio::test]
async fn mark_session_read_returns_reset_unread_count_and_persists_reset() {
  let (state, mut persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let session_id = orbitdock_protocol::new_session_id();
  let unread_row = test_tool_row(
    &session_id,
    "tool-1",
    1,
    "Inspect release notes",
    ToolStatus::Completed,
    Some(15),
  );
  persist_session_fixture(
    &db_path,
    &session_id,
    "/tmp/orbitdock-mark-read-test",
    vec![unread_row.clone()],
  );

  let mut session = SessionHandle::new(
    session_id.clone(),
    Provider::Codex,
    "/tmp/orbitdock-mark-read-runtime".to_string(),
  );
  session.set_work_status(WorkStatus::Reply);
  session.add_row(unread_row);
  assert_eq!(session.unread_count(), 1);
  state.add_session(session);

  let Json(response) = mark_session_read(Path(session_id.clone()), State(state.clone()))
    .await
    .expect("mark read should succeed");

  assert_eq!(response.session_id, session_id);
  assert_eq!(response.unread_count, 0);

  let actor = state
    .get_session(&response.session_id)
    .expect("live session should still exist");
  let retained = actor.retained_state().await.expect("retained state");
  assert_eq!(retained.unread_count, 0);
  assert_eq!(retained.work_status, WorkStatus::Waiting);

  flush_next_persist_command(&mut persist_rx, &db_path).await;
  flush_next_persist_command(&mut persist_rx, &db_path).await;

  let conn = Connection::open(&db_path).expect("open sqlite");
  let (db_unread_count, db_last_read_sequence): (i64, i64) = conn
    .query_row(
      "SELECT unread_count, last_read_sequence FROM sessions WHERE id = ?1",
      rusqlite::params![response.session_id],
      |row| Ok((row.get(0)?, row.get(1)?)),
    )
    .expect("query marked session");
  assert_eq!(db_unread_count, 0);
  assert_eq!(db_last_read_sequence, 1);
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
      q: None,
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
      q: None,
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
async fn library_snapshot_sorts_mixed_timestamp_formats_by_activity() {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let older_session_id = orbitdock_protocol::new_session_id();
  let newer_session_id = orbitdock_protocol::new_session_id();
  persist_session_fixture(
    &db_path,
    &older_session_id,
    "/tmp/orbitdock-library-sort-older",
    vec![],
  );
  persist_session_fixture(
    &db_path,
    &newer_session_id,
    "/tmp/orbitdock-library-sort-newer",
    vec![],
  );

  update_session_timestamps(
    &db_path,
    &older_session_id,
    Some("2026-04-26T08:00:00Z"),
    Some("2026-04-26T09:00:00Z"),
    Some("2026-04-26T09:00:00Z"),
    Some("2026-04-26T09:00:00Z"),
  );
  update_session_timestamps(
    &db_path,
    &newer_session_id,
    Some("2026-04-26T10:00:00Z"),
    Some("1777328742Z"),
    Some("1777328728Z"),
    Some("2026-04-27T22:25:42Z"),
  );

  let Json(snapshot) =
    get_archived_sessions_snapshot(Query(LibrarySnapshotQuery::default()), State(state))
      .await
      .expect("library snapshot should succeed");

  let returned_ids: Vec<&str> = snapshot
    .sessions
    .iter()
    .map(|session| session.id.as_str())
    .collect();
  assert_eq!(
    returned_ids,
    vec![newer_session_id.as_str(), older_session_id.as_str()]
  );
}

#[tokio::test]
async fn library_snapshot_filters_by_session_id_query() {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let matched_session_id = orbitdock_protocol::new_session_id();
  let other_session_id = orbitdock_protocol::new_session_id();
  persist_session_fixture(
    &db_path,
    &matched_session_id,
    "/tmp/orbitdock-library-filter-match",
    vec![],
  );
  persist_session_fixture(
    &db_path,
    &other_session_id,
    "/tmp/orbitdock-library-filter-other",
    vec![],
  );

  let Json(snapshot) = get_archived_sessions_snapshot(
    Query(LibrarySnapshotQuery {
      q: Some(matched_session_id.clone()),
      ..LibrarySnapshotQuery::default()
    }),
    State(state),
  )
  .await
  .expect("library snapshot search should succeed");

  assert_eq!(snapshot.total_count, 1);
  assert_eq!(snapshot.sessions.len(), 1);
  assert_eq!(snapshot.sessions[0].id, matched_session_id);
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
      q: None,
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
