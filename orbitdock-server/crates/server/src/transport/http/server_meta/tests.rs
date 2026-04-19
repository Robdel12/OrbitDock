use axum::{extract::State, Json};
use rusqlite::Connection;

use crate::transport::http::test_support::new_test_state;

use super::{
  fetch_claude_usage, fetch_codex_usage, list_claude_models,
  usage::{load_usage_summary, sort_model_costs},
  UsageSummaryBucket, UsageSummaryModelCost,
};

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

#[test]
fn today_usage_uses_observed_at_for_sessions_spanning_midnight() {
  let db_path = std::env::temp_dir().join(format!(
    "orbitdock-usage-summary-{}-{}.db",
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
         model TEXT,
         started_at TEXT
       );
       CREATE TABLE usage_ledger_entries (
         session_id TEXT NOT NULL,
         turn_id TEXT NOT NULL,
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
      "INSERT INTO sessions (id, provider, model, started_at) VALUES (?1, ?2, ?3, ?4)",
      rusqlite::params!["session-1", "codex", "gpt-5.4", "2026-03-28T23:55:00Z"],
    )
    .expect("insert session");
  conn
    .execute(
      "INSERT INTO usage_ledger_entries (
         session_id,
         turn_id,
         model,
         session_started_at,
         observed_at,
         billable_input_tokens,
         billable_output_tokens,
         cache_read_tokens,
         estimated_cost_usd
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
      rusqlite::params![
        "session-1",
        "turn-1",
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
         model,
         session_started_at,
         observed_at,
         billable_input_tokens,
         billable_output_tokens,
         cache_read_tokens,
         estimated_cost_usd
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
      rusqlite::params![
        "session-1",
        "turn-2",
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
  assert_eq!(summary.today.input_tokens, 200);
  assert_eq!(summary.today.output_tokens, 80);
  assert_eq!(summary.today.total_tokens, 280);
  assert_eq!(summary.today.total_cost_usd, 1.0_f64);
  assert_eq!(summary.all_time.input_tokens, 320);
  assert_eq!(summary.all_time.output_tokens, 110);

  drop(conn);
  let _ = std::fs::remove_file(db_path);
}
