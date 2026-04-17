use std::sync::Arc;

use axum::{
  extract::{Query, State},
  Json,
};
use rusqlite::Connection;

use crate::{
  infrastructure::persistence::{
    estimate_cost_usd, normalize_usage_for_ledger, snapshot_kind_from_str,
  },
  runtime::session_registry::SessionRegistry,
  support::{session_time::parse_unix_z, usage_errors::not_control_plane_endpoint_error},
};

use super::{
  ClaudeUsageResponse, CodexUsageResponse, SessionSummaryRow, UsageLedgerRow, UsageSummaryBucket,
  UsageSummaryModelCost, UsageSummaryQuery, UsageSummarySnapshot,
};
use crate::transport::http::errors::{internal, ApiResult};

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
      internal(
        "usage_summary_failed",
        format!("Usage summary task failed: {err}"),
      )
    })?
    .map_err(|err| internal("usage_summary_failed", err.to_string()))?;

  Ok(Json(summary))
}

pub(super) fn load_usage_summary(
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

pub(super) fn load_legacy_turn_rows_without_ledger(
  conn: &Connection,
) -> anyhow::Result<Vec<UsageLedgerRow>> {
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

pub(super) fn sort_model_costs(bucket: &mut UsageSummaryBucket) {
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
    return Some(format!("GPT-{version}"));
  }
  None
}
