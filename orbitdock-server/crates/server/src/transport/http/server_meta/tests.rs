use axum::{
  extract::{Query, State},
  Json,
};
use rusqlite::Connection;

use crate::transport::http::test_support::{new_persist_test_state, new_test_state};

use super::{
  fetch_claude_usage, fetch_codex_usage, fetch_usage_sessions, fetch_usage_summary,
  list_claude_models,
  usage::{load_usage_breakdown, load_usage_overview, load_usage_summary, sort_model_costs},
  UsageSessionsQuery, UsageSummaryQuery,
};
use orbitdock_protocol::{UsageBreakdownGroupBy, UsageSummaryBucket, UsageSummaryModelCost};

#[tokio::test]
async fn usage_endpoints_return_primary_endpoint_error_when_secondary() {
  let state = new_test_state(false);

  let Json(codex) = fetch_codex_usage(State(state.clone())).await;
  assert!(codex.usage.is_none());
  assert_eq!(
    codex.error_info.as_ref().map(|info| info.code.as_str()),
    Some("not_primary_usage_endpoint")
  );

  let Json(claude) = fetch_claude_usage(State(state)).await;
  assert!(claude.usage.is_none());
  assert_eq!(
    claude.error_info.as_ref().map(|info| info.code.as_str()),
    Some("not_primary_usage_endpoint")
  );
}

#[tokio::test]
async fn claude_models_endpoint_returns_cached_shape() {
  crate::support::test_support::ensure_server_test_data_dir();
  let Json(response) = list_claude_models().await;
  assert!(response
    .models
    .iter()
    .all(|model| !model.value.trim().is_empty()));
}

#[test]
fn usage_summary_costs_sort_descending() {
  let mut bucket = UsageSummaryBucket {
    cost_by_model: vec![
      UsageSummaryModelCost {
        model: "Sonnet".to_string(),
        cost_usd: 1.0,
      },
      UsageSummaryModelCost {
        model: "Opus".to_string(),
        cost_usd: 3.0,
      },
    ],
    ..UsageSummaryBucket::default()
  };

  sort_model_costs(&mut bucket);

  assert_eq!(bucket.cost_by_model[0].model, "Opus");
  assert_eq!(bucket.cost_by_model[1].model, "Sonnet");
}

#[tokio::test]
async fn usage_summary_endpoint_uses_observed_at_for_sessions_spanning_midnight() {
  let (_state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let conn = Connection::open(&db_path).expect("open sqlite db");

  conn
    .execute_batch(
      "DELETE FROM usage_ledger_entries;
       DELETE FROM sessions;",
    )
    .expect("clear usage fixtures");

  conn
    .execute(
      "INSERT INTO sessions (
         id,
         provider,
         project_path,
         model,
         started_at,
         control_mode,
         codex_integration_mode
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
      rusqlite::params![
        "session-1",
        "codex",
        "/tmp/orbitdock-usage-summary",
        "gpt-5.4",
        "2026-03-28T23:55:00Z",
        "direct",
        "direct",
      ],
    )
    .expect("insert session");
  conn
    .execute(
      "INSERT INTO usage_ledger_entries (
         session_id,
         turn_id,
         provider,
         model,
         session_started_at,
         observed_at,
         billable_input_tokens,
         billable_output_tokens,
         cache_read_tokens,
         estimated_cost_usd
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
      rusqlite::params![
        "session-1",
        "turn-1",
        "codex",
        "gpt-5.4",
        "2026-03-28T23:55:00Z",
        "2026-03-28T23:58:00Z",
        120_i64,
        30_i64,
        0_i64,
        0.5_f64,
      ],
    )
    .expect("insert ledger entry");
  conn
    .execute(
      "INSERT INTO usage_ledger_entries (
         session_id,
         turn_id,
         provider,
         model,
         session_started_at,
         observed_at,
         billable_input_tokens,
         billable_output_tokens,
         cache_read_tokens,
         estimated_cost_usd
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
      rusqlite::params![
        "session-1",
        "turn-2",
        "codex",
        "gpt-5.4",
        "2026-03-28T23:55:00Z",
        "2026-03-29T00:10:00Z",
        200_i64,
        80_i64,
        0_i64,
        1.0_f64,
      ],
    )
    .expect("insert next-day ledger entry");

  drop(conn);

  let Json(summary) = fetch_usage_summary(Query(UsageSummaryQuery {
    today_start_unix: Some(
      chrono::DateTime::parse_from_rfc3339("2026-03-29T00:00:00Z")
        .expect("parse boundary")
        .timestamp() as u64,
    ),
  }))
  .await
  .expect("fetch usage summary");

  assert_eq!(summary.today.session_count, 1);
  assert_eq!(summary.today.input_tokens, 200);
  assert_eq!(summary.today.output_tokens, 80);
  assert_eq!(summary.today.total_tokens, 280);
  assert_eq!(summary.today.total_cost_usd, 1.0_f64);
  assert_eq!(summary.all_time.input_tokens, 320);
  assert_eq!(summary.all_time.output_tokens, 110);

  let _ = std::fs::remove_file(db_path);
}

#[test]
fn usage_summary_only_counts_direct_sessions() {
  let db_path = std::env::temp_dir().join(format!(
    "orbitdock-direct-usage-summary-{}-{}.db",
    std::process::id(),
    std::time::SystemTime::now()
      .duration_since(std::time::UNIX_EPOCH)
      .expect("unix epoch")
      .as_nanos()
  ));
  let conn = Connection::open(&db_path).expect("open sqlite db");

  conn
    .execute_batch(
      "CREATE TABLE sessions (
         id TEXT PRIMARY KEY,
         provider TEXT,
         project_path TEXT,
         project_name TEXT,
         model TEXT,
         custom_name TEXT,
         summary TEXT,
         first_prompt TEXT,
         last_message TEXT,
         started_at TEXT,
         last_activity_at TEXT,
         control_mode TEXT,
         codex_integration_mode TEXT,
         claude_integration_mode TEXT
       );
       CREATE TABLE usage_ledger_entries (
         session_id TEXT NOT NULL,
         turn_id TEXT NOT NULL,
         provider TEXT NOT NULL,
         model TEXT,
         session_started_at TEXT,
         observed_at TEXT NOT NULL,
         billable_input_tokens INTEGER NOT NULL DEFAULT 0,
         billable_output_tokens INTEGER NOT NULL DEFAULT 0,
         cache_read_tokens INTEGER NOT NULL DEFAULT 0,
         estimated_cost_usd REAL NOT NULL DEFAULT 0,
         PRIMARY KEY (session_id, turn_id)
       );",
    )
    .expect("create schema");

  conn
    .execute(
      "INSERT INTO sessions (
         id,
         provider,
         model,
         started_at,
         control_mode,
         codex_integration_mode
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      rusqlite::params![
        "direct-session",
        "codex",
        "gpt-5.4",
        "2026-03-29T00:01:00Z",
        "direct",
        "direct",
      ],
    )
    .expect("insert direct session");
  conn
    .execute(
      "INSERT INTO sessions (
         id,
         provider,
         model,
         started_at,
         control_mode,
         codex_integration_mode
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      rusqlite::params![
        "passive-session",
        "codex",
        "gpt-5.4",
        "2026-03-29T00:02:00Z",
        "passive",
        "passive",
      ],
    )
    .expect("insert passive session");

  conn
    .execute(
      "INSERT INTO usage_ledger_entries (
         session_id,
         turn_id,
         provider,
         model,
         session_started_at,
         observed_at,
         billable_input_tokens,
         billable_output_tokens,
         cache_read_tokens,
         estimated_cost_usd
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
      rusqlite::params![
        "direct-session",
        "turn-1",
        "codex",
        "gpt-5.4",
        "2026-03-29T00:01:00Z",
        "2026-03-29T00:03:00Z",
        10_i64,
        5_i64,
        3_i64,
        0.25_f64,
      ],
    )
    .expect("insert direct ledger entry");
  conn
    .execute(
      "INSERT INTO usage_ledger_entries (
         session_id,
         turn_id,
         provider,
         model,
         session_started_at,
         observed_at,
         billable_input_tokens,
         billable_output_tokens,
         cache_read_tokens,
         estimated_cost_usd
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
      rusqlite::params![
        "passive-session",
        "turn-1",
        "codex",
        "gpt-5.4",
        "2026-03-29T00:02:00Z",
        "2026-03-29T00:04:00Z",
        999_i64,
        999_i64,
        999_i64,
        99.0_f64,
      ],
    )
    .expect("insert passive ledger entry");

  let summary = load_usage_summary(
    &db_path,
    Some(
      chrono::DateTime::parse_from_rfc3339("2026-03-29T00:00:00Z")
        .expect("parse boundary")
        .timestamp() as u64,
    ),
  )
  .expect("load usage summary");

  assert_eq!(summary.today.session_count, 1);
  assert_eq!(summary.today.input_tokens, 10);
  assert_eq!(summary.today.output_tokens, 5);
  assert_eq!(summary.today.cached_tokens, 3);
  assert_eq!(summary.today.total_tokens, 15);
  assert_eq!(summary.today.total_cost_usd, 0.25_f64);
  assert_eq!(summary.all_time.session_count, 1);
  assert_eq!(summary.all_time.input_tokens, 10);
  assert_eq!(summary.all_time.output_tokens, 5);
  assert_eq!(summary.all_time.cached_tokens, 3);
  assert_eq!(summary.all_time.total_cost_usd, 0.25_f64);

  drop(conn);
  let _ = std::fs::remove_file(db_path);
}

#[tokio::test]
async fn usage_breakdown_groups_direct_usage_by_provider() {
  let (_state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let conn = Connection::open(&db_path).expect("open sqlite db");

  conn
    .execute_batch(
      "DELETE FROM usage_ledger_entries;
       DELETE FROM sessions;",
    )
    .expect("clear usage fixtures");

  conn
    .execute(
      "INSERT INTO sessions (
         id, provider, project_path, model, started_at, control_mode, codex_integration_mode
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
      rusqlite::params![
        "codex-session",
        "codex",
        "/tmp/orbitdock-usage-codex",
        "gpt-5.4",
        "2026-04-26T10:00:00Z",
        "direct",
        "direct",
      ],
    )
    .expect("insert codex session");
  conn
    .execute(
      "INSERT INTO sessions (
         id, provider, project_path, model, started_at, control_mode, claude_integration_mode
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
      rusqlite::params![
        "claude-session",
        "claude",
        "/tmp/orbitdock-usage-claude",
        "claude-sonnet-4",
        "2026-04-26T10:00:00Z",
        "direct",
        "direct",
      ],
    )
    .expect("insert claude session");

  conn
    .execute(
      "INSERT INTO usage_ledger_entries (
         session_id, turn_id, turn_seq, provider, model, session_started_at, observed_at,
         snapshot_kind, billable_input_tokens, billable_output_tokens, cache_read_tokens,
         cache_write_tokens, context_input_tokens, context_window, estimated_cost_usd
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
      rusqlite::params![
        "codex-session",
        "turn-1",
        1_i64,
        "codex",
        "gpt-5.4",
        "2026-04-26T10:00:00Z",
        "2026-04-26T10:05:00Z",
        "lifetime_totals",
        100_i64,
        20_i64,
        0_i64,
        0_i64,
        100_i64,
        200_000_i64,
        0.5_f64,
      ],
    )
    .expect("insert codex ledger");
  conn
    .execute(
      "INSERT INTO usage_ledger_entries (
         session_id, turn_id, turn_seq, provider, model, session_started_at, observed_at,
         snapshot_kind, billable_input_tokens, billable_output_tokens, cache_read_tokens,
         cache_write_tokens, context_input_tokens, context_window, estimated_cost_usd
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
      rusqlite::params![
        "claude-session",
        "turn-1",
        1_i64,
        "claude",
        "claude-sonnet-4",
        "2026-04-26T10:00:00Z",
        "2026-04-26T10:10:00Z",
        "context_turn",
        50_i64,
        10_i64,
        5_i64,
        0_i64,
        55_i64,
        200_000_i64,
        1.25_f64,
      ],
    )
    .expect("insert claude ledger");

  let breakdown = load_usage_breakdown(&db_path, UsageBreakdownGroupBy::Provider, None, None)
    .expect("load usage breakdown");

  assert_eq!(breakdown.totals.session_count, 2);
  assert_eq!(breakdown.totals.input_tokens, 150);
  assert_eq!(breakdown.totals.output_tokens, 30);
  assert_eq!(breakdown.groups.len(), 2);
  assert_eq!(breakdown.groups[0].group_key, "claude");
  assert_eq!(breakdown.groups[0].total_cost_usd, 1.25_f64);
  assert_eq!(breakdown.groups[1].group_key, "codex");
  assert_eq!(breakdown.groups[1].total_cost_usd, 0.5_f64);

  drop(conn);
  let _ = std::fs::remove_file(db_path);
}

#[test]
fn usage_breakdown_groups_by_day_with_time_range() {
  let db_path = std::env::temp_dir().join(format!(
    "orbitdock-usage-breakdown-day-{}-{}.db",
    std::process::id(),
    std::time::SystemTime::now()
      .duration_since(std::time::UNIX_EPOCH)
      .expect("unix epoch")
      .as_nanos()
  ));
  let conn = Connection::open(&db_path).expect("open sqlite db");

  conn
    .execute_batch(
      "CREATE TABLE sessions (
         id TEXT PRIMARY KEY,
         provider TEXT,
         project_path TEXT,
         project_name TEXT,
         model TEXT,
         custom_name TEXT,
         summary TEXT,
         first_prompt TEXT,
         last_message TEXT,
         started_at TEXT,
         last_activity_at TEXT,
         control_mode TEXT,
         codex_integration_mode TEXT,
         claude_integration_mode TEXT
       );
       CREATE TABLE usage_ledger_entries (
         session_id TEXT NOT NULL,
         turn_id TEXT NOT NULL,
         turn_seq INTEGER NOT NULL DEFAULT 0,
         provider TEXT NOT NULL,
         model TEXT,
         session_started_at TEXT,
         observed_at TEXT NOT NULL,
         snapshot_kind TEXT NOT NULL DEFAULT 'unknown',
         billable_input_tokens INTEGER NOT NULL DEFAULT 0,
         billable_output_tokens INTEGER NOT NULL DEFAULT 0,
         cache_read_tokens INTEGER NOT NULL DEFAULT 0,
         cache_write_tokens INTEGER NOT NULL DEFAULT 0,
         context_input_tokens INTEGER NOT NULL DEFAULT 0,
         context_window INTEGER NOT NULL DEFAULT 0,
         estimated_cost_usd REAL NOT NULL DEFAULT 0,
         PRIMARY KEY (session_id, turn_id)
       );",
    )
    .expect("create schema");

  conn
    .execute(
      "INSERT INTO sessions (id, provider, model, started_at, control_mode, codex_integration_mode)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      rusqlite::params![
        "codex-session",
        "codex",
        "gpt-5.4",
        "2026-04-25T23:50:00Z",
        "direct",
        "direct",
      ],
    )
    .expect("insert session");

  conn
    .execute(
      "INSERT INTO usage_ledger_entries (
         session_id, turn_id, turn_seq, provider, model, session_started_at, observed_at,
         snapshot_kind, billable_input_tokens, billable_output_tokens, cache_read_tokens,
         cache_write_tokens, context_input_tokens, context_window, estimated_cost_usd
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
      rusqlite::params![
        "codex-session",
        "turn-1",
        1_i64,
        "codex",
        "gpt-5.4",
        "2026-04-25T23:50:00Z",
        "2026-04-25T23:58:00Z",
        "lifetime_totals",
        80_i64,
        20_i64,
        0_i64,
        0_i64,
        80_i64,
        200_000_i64,
        0.4_f64,
      ],
    )
    .expect("insert prior-day ledger");
  conn
    .execute(
      "INSERT INTO usage_ledger_entries (
         session_id, turn_id, turn_seq, provider, model, session_started_at, observed_at,
         snapshot_kind, billable_input_tokens, billable_output_tokens, cache_read_tokens,
         cache_write_tokens, context_input_tokens, context_window, estimated_cost_usd
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
      rusqlite::params![
        "codex-session",
        "turn-2",
        2_i64,
        "codex",
        "gpt-5.4",
        "2026-04-25T23:50:00Z",
        "2026-04-26T00:05:00Z",
        "lifetime_totals",
        120_i64,
        30_i64,
        10_i64,
        0_i64,
        120_i64,
        200_000_i64,
        0.8_f64,
      ],
    )
    .expect("insert current-day ledger");

  let start_unix = chrono::DateTime::parse_from_rfc3339("2026-04-26T00:00:00Z")
    .expect("parse start")
    .timestamp() as u64;
  let end_unix = chrono::DateTime::parse_from_rfc3339("2026-04-27T00:00:00Z")
    .expect("parse end")
    .timestamp() as u64;

  let breakdown = load_usage_breakdown(
    &db_path,
    UsageBreakdownGroupBy::Day,
    Some(start_unix),
    Some(end_unix),
  )
  .expect("load usage breakdown");

  assert_eq!(breakdown.totals.session_count, 1);
  assert_eq!(breakdown.totals.input_tokens, 120);
  assert_eq!(breakdown.totals.output_tokens, 30);
  assert_eq!(breakdown.groups.len(), 1);
  assert_eq!(breakdown.groups[0].day_start_unix, Some(start_unix));
  assert_eq!(breakdown.groups[0].turn_count, 1);
  assert_eq!(breakdown.groups[0].total_cost_usd, 0.8_f64);

  drop(conn);
  let _ = std::fs::remove_file(db_path);
}

#[test]
fn usage_overview_returns_scoped_breakdowns() {
  let db_path = std::env::temp_dir().join(format!(
    "orbitdock-usage-overview-{}-{}.db",
    std::process::id(),
    std::time::SystemTime::now()
      .duration_since(std::time::UNIX_EPOCH)
      .expect("unix epoch")
      .as_nanos()
  ));
  let conn = Connection::open(&db_path).expect("open sqlite db");

  conn
    .execute_batch(
      "CREATE TABLE sessions (
         id TEXT PRIMARY KEY,
         provider TEXT,
         project_path TEXT,
         project_name TEXT,
         model TEXT,
         custom_name TEXT,
         summary TEXT,
         first_prompt TEXT,
         last_message TEXT,
         started_at TEXT,
         last_activity_at TEXT,
         control_mode TEXT,
         codex_integration_mode TEXT,
         claude_integration_mode TEXT
       );
       CREATE TABLE usage_ledger_entries (
         session_id TEXT NOT NULL,
         turn_id TEXT NOT NULL,
         turn_seq INTEGER NOT NULL DEFAULT 0,
         provider TEXT NOT NULL,
         model TEXT,
         session_started_at TEXT,
         observed_at TEXT NOT NULL,
         snapshot_kind TEXT NOT NULL DEFAULT 'unknown',
         billable_input_tokens INTEGER NOT NULL DEFAULT 0,
         billable_output_tokens INTEGER NOT NULL DEFAULT 0,
         cache_read_tokens INTEGER NOT NULL DEFAULT 0,
         cache_write_tokens INTEGER NOT NULL DEFAULT 0,
         context_input_tokens INTEGER NOT NULL DEFAULT 0,
         context_window INTEGER NOT NULL DEFAULT 0,
         estimated_cost_usd REAL NOT NULL DEFAULT 0,
         PRIMARY KEY (session_id, turn_id)
       );",
    )
    .expect("create schema");

  conn
    .execute(
      "INSERT INTO sessions (
         id, provider, project_path, project_name, model, custom_name, summary, first_prompt,
         last_message, started_at, last_activity_at, control_mode, codex_integration_mode
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
      rusqlite::params![
        "session-1",
        "codex",
        "/tmp/orbitdock",
        "OrbitDock",
        "gpt-5.4",
        "Usage cleanup",
        "Usage cleanup",
        "Clean up the usage dashboard",
        "Implement overview endpoint",
        "2026-04-26T09:00:00Z",
        "2026-04-26T09:20:00Z",
        "direct",
        "direct",
      ],
    )
    .expect("insert session");
  conn
    .execute(
      "INSERT INTO usage_ledger_entries (
         session_id, turn_id, turn_seq, provider, model, session_started_at, observed_at,
         snapshot_kind, billable_input_tokens, billable_output_tokens, cache_read_tokens,
         cache_write_tokens, context_input_tokens, context_window, estimated_cost_usd
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
      rusqlite::params![
        "session-1",
        "turn-1",
        1_i64,
        "codex",
        "gpt-5.4",
        "2026-04-26T09:00:00Z",
        "2026-04-26T09:10:00Z",
        "lifetime_totals",
        120_i64,
        30_i64,
        10_i64,
        0_i64,
        120_i64,
        200_000_i64,
        0.75_f64,
      ],
    )
    .expect("insert ledger row");

  let today_start_unix = chrono::DateTime::parse_from_rfc3339("2026-04-26T00:00:00Z")
    .expect("parse today start")
    .timestamp() as u64;
  let overview = load_usage_overview(
    &db_path,
    Some(today_start_unix),
    Some(today_start_unix),
    None,
  )
  .expect("load overview");

  assert_eq!(overview.summary.today.distinct_session_count, 1);
  assert_eq!(overview.today_provider_breakdown.groups.len(), 1);
  assert_eq!(
    overview.today_provider_breakdown.groups[0].group_key,
    "codex"
  );
  assert_eq!(
    overview.today_model_breakdown.groups[0].group_key,
    "gpt-5.4"
  );
  assert_eq!(
    overview.day_breakdown.groups[0].day_start_unix,
    Some(today_start_unix)
  );

  drop(conn);
  let _ = std::fs::remove_file(db_path);
}

#[tokio::test]
async fn usage_sessions_endpoint_returns_display_metadata() {
  let (_state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let conn = Connection::open(&db_path).expect("open sqlite db");

  conn
    .execute_batch(
      "DELETE FROM usage_ledger_entries;
       DELETE FROM sessions;",
    )
    .expect("clear usage fixtures");

  conn
    .execute(
      "INSERT INTO sessions (
         id, provider, project_path, project_name, model, custom_name, summary, first_prompt,
         last_message, started_at, last_activity_at, control_mode, codex_integration_mode
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
      rusqlite::params![
        "session-1",
        "codex",
        "/tmp/orbitdock",
        "OrbitDock",
        "gpt-5.4",
        "API cleanup",
        "API cleanup",
        "Clean up the usage dashboard",
        "Implement usage sessions endpoint",
        "2026-04-26T09:00:00Z",
        "2026-04-26T09:30:00Z",
        "direct",
        "direct",
      ],
    )
    .expect("insert session");
  conn
    .execute(
      "INSERT INTO usage_ledger_entries (
         session_id, turn_id, turn_seq, provider, model, session_started_at, observed_at,
         snapshot_kind, billable_input_tokens, billable_output_tokens, cache_read_tokens,
         cache_write_tokens, context_input_tokens, context_window, estimated_cost_usd
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
      rusqlite::params![
        "session-1",
        "turn-1",
        1_i64,
        "codex",
        "gpt-5.4",
        "2026-04-26T09:00:00Z",
        "2026-04-26T09:10:00Z",
        "lifetime_totals",
        100_i64,
        25_i64,
        10_i64,
        0_i64,
        100_i64,
        200_000_i64,
        0.5_f64,
      ],
    )
    .expect("insert ledger row");

  drop(conn);

  let today_start_unix = chrono::DateTime::parse_from_rfc3339("2026-04-26T00:00:00Z")
    .expect("parse today start")
    .timestamp() as u64;
  let Json(sessions) = fetch_usage_sessions(Query(UsageSessionsQuery {
    start_unix: Some(today_start_unix),
    end_unix: None,
    limit: 10,
    offset: 0,
  }))
  .await
  .expect("fetch usage sessions");

  assert_eq!(sessions.total_count, 1);
  assert_eq!(sessions.sessions[0].display_name, "API cleanup");
  assert_eq!(
    sessions.sessions[0].project_name.as_deref(),
    Some("OrbitDock")
  );
  assert_eq!(
    sessions.sessions[0].context_line.as_deref(),
    Some("Implement usage sessions endpoint")
  );
  assert_eq!(sessions.sessions[0].turn_count, 1);

  let _ = std::fs::remove_file(db_path);
}
