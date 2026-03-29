use std::sync::Arc;

use axum::{
  extract::{Query, State},
  http::StatusCode,
  Json,
};
use orbitdock_connector_codex::{discover_models, discover_models_for_context};
use orbitdock_protocol::{
  ClaudeModelOption, ClaudeUsageSnapshot, CodexModelOption, CodexUsageSnapshot, UsageErrorInfo,
};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};

use crate::runtime::session_registry::SessionRegistry;
use crate::support::usage_errors::not_control_plane_endpoint_error;
use crate::{
  infrastructure::persistence::{
    estimate_cost_usd, normalize_usage_for_ledger, snapshot_kind_from_str,
  },
  support::session_time::parse_unix_z,
};

use super::errors::{ApiErrorResponse, ApiResult};

#[derive(Debug, Serialize)]
pub struct CodexUsageResponse {
  pub usage: Option<CodexUsageSnapshot>,
  pub error_info: Option<UsageErrorInfo>,
}

#[derive(Debug, Serialize)]
pub struct ClaudeUsageResponse {
  pub usage: Option<ClaudeUsageSnapshot>,
  pub error_info: Option<UsageErrorInfo>,
}

#[derive(Debug, Serialize)]
pub struct CodexModelsResponse {
  pub models: Vec<CodexModelOption>,
}

#[derive(Debug, Serialize)]
pub struct ClaudeModelsResponse {
  pub models: Vec<ClaudeModelOption>,
}

#[derive(Debug, Deserialize, Default)]
pub struct CodexModelsQuery {
  #[serde(default)]
  pub cwd: Option<String>,
  #[serde(default)]
  pub model_provider: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct UsageSummaryQuery {
  #[serde(default)]
  pub today_start_unix: Option<u64>,
}

#[derive(Debug, Default, Serialize)]
pub struct UsageSummarySnapshot {
  pub today: UsageSummaryBucket,
  pub all_time: UsageSummaryBucket,
}

#[derive(Debug, Default, Serialize)]
pub struct UsageSummaryBucket {
  pub session_count: u64,
  pub total_tokens: u64,
  pub input_tokens: u64,
  pub output_tokens: u64,
  pub cached_tokens: u64,
  pub total_cost_usd: f64,
  pub cost_by_model: Vec<UsageSummaryModelCost>,
}

#[derive(Debug, Serialize)]
pub struct UsageSummaryModelCost {
  pub model: String,
  pub cost_usd: f64,
}

pub async fn fetch_codex_usage(
  State(state): State<Arc<SessionRegistry>>,
) -> Json<CodexUsageResponse> {
  if !state.is_primary() {
    return Json(CodexUsageResponse {
      usage: None,
      error_info: Some(not_control_plane_endpoint_error()),
    });
  }

  let (usage, error_info) = match crate::infrastructure::usage_probe::fetch_codex_usage().await {
    Ok(usage) => (Some(usage), None),
    Err(err) => (None, Some(err.to_info())),
  };

  Json(CodexUsageResponse { usage, error_info })
}

pub async fn fetch_claude_usage(
  State(state): State<Arc<SessionRegistry>>,
) -> Json<ClaudeUsageResponse> {
  if !state.is_primary() {
    return Json(ClaudeUsageResponse {
      usage: None,
      error_info: Some(not_control_plane_endpoint_error()),
    });
  }

  let (usage, error_info) = match crate::infrastructure::usage_probe::fetch_claude_usage().await {
    Ok(usage) => (Some(usage), None),
    Err(err) => (None, Some(err.to_info())),
  };

  Json(ClaudeUsageResponse { usage, error_info })
}

pub async fn fetch_usage_summary(
  Query(query): Query<UsageSummaryQuery>,
) -> ApiResult<UsageSummarySnapshot> {
  let db_path = crate::infrastructure::paths::db_path();
  let today_start_unix = query.today_start_unix;
  let summary = tokio::task::spawn_blocking(move || load_usage_summary(&db_path, today_start_unix))
    .await
    .map_err(|err| {
      super::errors::internal(
        "usage_summary_failed",
        format!("Usage summary task failed: {err}"),
      )
    })?
    .map_err(|err| super::errors::internal("usage_summary_failed", err.to_string()))?;

  Ok(Json(summary))
}

pub async fn list_codex_models(
  Query(query): Query<CodexModelsQuery>,
) -> ApiResult<CodexModelsResponse> {
  let result = if query.cwd.is_some() || query.model_provider.is_some() {
    discover_models_for_context(query.cwd.as_deref(), query.model_provider.as_deref()).await
  } else {
    discover_models().await
  };

  match result {
    Ok(models) => Ok(Json(CodexModelsResponse { models })),
    Err(err) => Err((
      StatusCode::INTERNAL_SERVER_ERROR,
      Json(ApiErrorResponse {
        code: "model_list_failed",
        error: format!("Failed to list models: {err}"),
      }),
    )),
  }
}

pub async fn list_claude_models() -> Json<ClaudeModelsResponse> {
  Json(ClaudeModelsResponse {
    models: ClaudeModelOption::defaults(),
  })
}

#[derive(Debug, Clone)]
struct SessionSummaryRow {
  id: String,
  started_at_unix: Option<u64>,
}

#[derive(Debug, Clone)]
struct UsageLedgerRow {
  session_id: String,
  model: Option<String>,
  observed_at_unix: Option<u64>,
  input_tokens: u64,
  output_tokens: u64,
  cached_tokens: u64,
  cost_usd: f64,
}

fn load_usage_summary(
  db_path: &std::path::Path,
  today_start_unix: Option<u64>,
) -> anyhow::Result<UsageSummarySnapshot> {
  if !db_path.exists() {
    return Ok(UsageSummarySnapshot::default());
  }

  let conn = Connection::open(db_path)?;
  conn.execute_batch(
    "PRAGMA journal_mode = WAL;
     PRAGMA busy_timeout = 5000;",
  )?;

  let sessions: Vec<SessionSummaryRow> = conn
    .prepare("SELECT id, started_at FROM sessions")?
    .query_map([], |row| {
      let session_id: String = row.get(0)?;
      let started_at: Option<String> = row.get(1)?;
      Ok(SessionSummaryRow {
        id: session_id,
        started_at_unix: parse_timestamp_to_unix(started_at.as_deref()),
      })
    })?
    .collect::<Result<Vec<_>, _>>()?;

  let ledger_rows = load_usage_ledger_rows(&conn)?;
  let mut today = UsageSummaryBucket::default();
  let mut all_time = UsageSummaryBucket::default();
  let mut today_session_ids = std::collections::HashSet::new();

  all_time.session_count = sessions.len() as u64;

  for aggregate in ledger_rows {
    apply_usage_aggregate(&mut all_time, &aggregate);
    if aggregate
      .observed_at_unix
      .zip(today_start_unix)
      .is_some_and(|(observed, boundary)| observed >= boundary)
    {
      apply_usage_aggregate(&mut today, &aggregate);
      today_session_ids.insert(aggregate.session_id.clone());
    }
  }

  if let Some(boundary) = today_start_unix {
    for session in &sessions {
      if session
        .started_at_unix
        .is_some_and(|started| started >= boundary)
      {
        today_session_ids.insert(session.id.clone());
      }
    }
  }

  today.session_count = today_session_ids.len() as u64;

  sort_model_costs(&mut today);
  sort_model_costs(&mut all_time);

  Ok(UsageSummarySnapshot { today, all_time })
}

fn load_usage_ledger_rows(conn: &Connection) -> anyhow::Result<Vec<UsageLedgerRow>> {
  let mut rows: Vec<UsageLedgerRow> = conn
    .prepare(
      "SELECT session_id, model, observed_at, billable_input_tokens, billable_output_tokens, cache_read_tokens, estimated_cost_usd
       FROM usage_ledger_entries",
    )?
    .query_map([], |row| {
      let session_id: String = row.get(0)?;
      let observed_at: Option<String> = row.get(2)?;
      Ok(UsageLedgerRow {
        session_id,
        model: row.get(1)?,
        observed_at_unix: parse_timestamp_to_unix(observed_at.as_deref()),
        input_tokens: row.get::<_, i64>(3)?.max(0) as u64,
        output_tokens: row.get::<_, i64>(4)?.max(0) as u64,
        cached_tokens: row.get::<_, i64>(5)?.max(0) as u64,
        cost_usd: row.get::<_, f64>(6)?,
      })
    })?
    .collect::<Result<Vec<_>, _>>()?;

  rows.extend(load_legacy_turn_rows_without_ledger(conn)?);
  Ok(rows)
}

fn parse_timestamp_to_unix(value: Option<&str>) -> Option<u64> {
  let raw = value?;
  if let Some(unix) = parse_unix_z(Some(raw)) {
    return Some(unix);
  }
  chrono::DateTime::parse_from_rfc3339(raw)
    .ok()
    .map(|parsed| parsed.timestamp().max(0) as u64)
}

fn load_legacy_turn_rows_without_ledger(conn: &Connection) -> anyhow::Result<Vec<UsageLedgerRow>> {
  type LegacyTurnRow = (
    String,
    String,
    String,
    Option<String>,
    Option<String>,
    u64,
    u64,
    u64,
    u64,
    bool,
  );

  let rows: Vec<LegacyTurnRow> = conn
    .prepare(
      "SELECT
          ut.session_id,
          COALESCE(s.provider, 'claude'),
          COALESCE(ut.snapshot_kind, 'unknown'),
          s.model,
          ut.created_at,
          ut.input_tokens,
          ut.output_tokens,
          ut.cached_tokens,
          ut.context_window,
          ule.turn_id IS NOT NULL
       FROM usage_turns ut
       JOIN sessions s
         ON s.id = ut.session_id
       LEFT JOIN usage_ledger_entries ule
         ON ule.session_id = ut.session_id AND ule.turn_id = ut.turn_id
       ORDER BY ut.session_id ASC, ut.turn_seq ASC, ut.rowid ASC",
    )?
    .query_map([], |row| {
      Ok((
        row.get(0)?,
        row.get(1)?,
        row.get(2)?,
        row.get(3)?,
        row.get(4)?,
        row.get::<_, i64>(5)?.max(0) as u64,
        row.get::<_, i64>(6)?.max(0) as u64,
        row.get::<_, i64>(7)?.max(0) as u64,
        row.get::<_, i64>(8)?.max(0) as u64,
        row.get(9)?,
      ))
    })?
    .collect::<Result<Vec<_>, _>>()?;

  let mut previous_by_session: std::collections::HashMap<String, orbitdock_protocol::TokenUsage> =
    std::collections::HashMap::new();
  let mut normalized_rows = Vec::with_capacity(rows.len());

  for (
    session_id,
    provider,
    snapshot_kind,
    model,
    created_at,
    input_tokens,
    output_tokens,
    cached_tokens,
    context_window,
    has_ledger_entry,
  ) in rows
  {
    let current = orbitdock_protocol::TokenUsage {
      input_tokens,
      output_tokens,
      cached_tokens,
      context_window,
    };
    let snapshot_kind = snapshot_kind_from_str(Some(snapshot_kind.as_str()));
    let previous = previous_by_session.get(&session_id);
    let normalized = normalize_usage_for_ledger(previous, &current, snapshot_kind);
    let cost_usd = estimate_cost_usd(
      provider.as_str(),
      model.as_deref(),
      normalized.billable_input_tokens,
      normalized.billable_output_tokens,
      normalized.cache_read_tokens,
      normalized.cache_write_tokens,
    );

    if !has_ledger_entry {
      normalized_rows.push(UsageLedgerRow {
        session_id: session_id.clone(),
        model,
        observed_at_unix: parse_timestamp_to_unix(created_at.as_deref()),
        input_tokens: normalized.billable_input_tokens,
        output_tokens: normalized.billable_output_tokens,
        cached_tokens: normalized.cache_read_tokens,
        cost_usd,
      });
    }

    previous_by_session.insert(session_id, current);
  }

  Ok(normalized_rows)
}

fn apply_usage_aggregate(bucket: &mut UsageSummaryBucket, aggregate: &UsageLedgerRow) {
  bucket.input_tokens = bucket.input_tokens.saturating_add(aggregate.input_tokens);
  bucket.output_tokens = bucket.output_tokens.saturating_add(aggregate.output_tokens);
  bucket.cached_tokens = bucket.cached_tokens.saturating_add(aggregate.cached_tokens);
  bucket.total_tokens = bucket.input_tokens.saturating_add(bucket.output_tokens);
  bucket.total_cost_usd += aggregate.cost_usd;

  if let Some(model) = normalize_model_name(aggregate.model.as_deref()) {
    if let Some(existing) = bucket
      .cost_by_model
      .iter_mut()
      .find(|entry| entry.model == model)
    {
      existing.cost_usd += aggregate.cost_usd;
    } else {
      bucket.cost_by_model.push(UsageSummaryModelCost {
        model,
        cost_usd: aggregate.cost_usd,
      });
    }
  }
}

fn sort_model_costs(bucket: &mut UsageSummaryBucket) {
  bucket
    .cost_by_model
    .sort_by(|lhs, rhs| rhs.cost_usd.total_cmp(&lhs.cost_usd));
}

fn normalize_model_name(model: Option<&str>) -> Option<String> {
  let model = model?.trim().to_ascii_lowercase();
  if model.is_empty() {
    return None;
  }
  if model.contains("opus") {
    return Some("Opus".to_string());
  }
  if model.contains("sonnet") {
    return Some("Sonnet".to_string());
  }
  if model.contains("haiku") {
    return Some("Haiku".to_string());
  }
  if let Some(rest) = model.strip_prefix("gpt-") {
    let version = rest.split('-').next().unwrap_or(rest);
    return Some(format!("GPT-{}", version));
  }
  None
}

#[cfg(test)]
mod tests {
  use super::*;
  use axum::{extract::State, Json};

  use crate::transport::http::test_support::new_test_state;

  #[tokio::test]
  async fn usage_endpoints_return_control_plane_error_when_secondary() {
    let state = new_test_state(false);

    let Json(codex) = fetch_codex_usage(State(state.clone())).await;
    assert!(codex.usage.is_none());
    assert_eq!(
      codex.error_info.as_ref().map(|info| info.code.as_str()),
      Some("not_control_plane_endpoint")
    );

    let Json(claude) = fetch_claude_usage(State(state)).await;
    assert!(claude.usage.is_none());
    assert_eq!(
      claude.error_info.as_ref().map(|info| info.code.as_str()),
      Some("not_control_plane_endpoint")
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
       );
       CREATE TABLE usage_turns (
         session_id TEXT NOT NULL,
         turn_id TEXT NOT NULL,
         turn_seq INTEGER NOT NULL DEFAULT 0,
         created_at TEXT NOT NULL,
         snapshot_kind TEXT,
         input_tokens INTEGER NOT NULL DEFAULT 0,
         output_tokens INTEGER NOT NULL DEFAULT 0,
         cached_tokens INTEGER NOT NULL DEFAULT 0,
         context_window INTEGER NOT NULL DEFAULT 0
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
        "INSERT INTO usage_turns (
         session_id,
         turn_id,
         turn_seq,
         created_at,
         snapshot_kind,
         input_tokens,
         output_tokens,
         cached_tokens,
         context_window
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        rusqlite::params![
          "session-1",
          "turn-2",
          2_i64,
          "2026-03-29T00:10:00Z",
          "delta",
          200_i64,
          80_i64,
          0_i64,
          0_i64,
        ],
      )
      .expect("insert legacy turn");
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
    assert_eq!(
      summary.today.total_cost_usd,
      estimate_cost_usd("codex", Some("gpt-5.4"), 200, 80, 0, 0)
    );
    assert_eq!(summary.all_time.input_tokens, 320);
    assert_eq!(summary.all_time.output_tokens, 110);

    drop(conn);
    let _ = std::fs::remove_file(db_path);
  }

  #[test]
  fn legacy_rows_after_ledger_entries_use_prior_session_usage_for_normalization() {
    let conn = Connection::open_in_memory().expect("open sqlite db");

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
       );
       CREATE TABLE usage_turns (
         session_id TEXT NOT NULL,
         turn_id TEXT NOT NULL,
         turn_seq INTEGER NOT NULL DEFAULT 0,
         created_at TEXT NOT NULL,
         snapshot_kind TEXT,
         input_tokens INTEGER NOT NULL DEFAULT 0,
         output_tokens INTEGER NOT NULL DEFAULT 0,
         cached_tokens INTEGER NOT NULL DEFAULT 0,
         context_window INTEGER NOT NULL DEFAULT 0
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
        "INSERT INTO usage_turns (
         session_id,
         turn_id,
         turn_seq,
         created_at,
         snapshot_kind,
         input_tokens,
         output_tokens,
         cached_tokens,
         context_window
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        rusqlite::params![
          "session-1",
          "turn-1",
          1_i64,
          "2026-03-28T23:58:00Z",
          "lifetime_totals",
          120_i64,
          30_i64,
          0_i64,
          0_i64,
        ],
      )
      .expect("insert first turn");
    conn
      .execute(
        "INSERT INTO usage_turns (
         session_id,
         turn_id,
         turn_seq,
         created_at,
         snapshot_kind,
         input_tokens,
         output_tokens,
         cached_tokens,
         context_window
       ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        rusqlite::params![
          "session-1",
          "turn-2",
          2_i64,
          "2026-03-29T00:10:00Z",
          "lifetime_totals",
          200_i64,
          50_i64,
          0_i64,
          0_i64,
        ],
      )
      .expect("insert second turn");
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

    let rows = load_legacy_turn_rows_without_ledger(&conn).expect("load legacy rows");

    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].session_id, "session-1");
    assert_eq!(rows[0].input_tokens, 80);
    assert_eq!(rows[0].output_tokens, 20);
    assert_eq!(rows[0].cached_tokens, 0);
  }
}
