use std::sync::Arc;

use axum::{
  extract::{Query, State},
  Json,
};
use orbitdock_protocol::{
  Provider, UsageBreakdownEntry, UsageBreakdownGroupBy, UsageBreakdownSnapshot, UsageSummaryBucket,
  UsageSummaryModelCost, UsageSummarySnapshot,
};
use rusqlite::Connection;

use crate::{
  runtime::session_registry::SessionRegistry,
  support::{session_time::parse_unix_z, usage_errors::not_primary_usage_endpoint_error},
};

use super::{
  ClaudeUsageResponse, CodexUsageResponse, SessionSummaryRow, UsageBreakdownQuery, UsageLedgerRow,
  UsageSummaryQuery,
};
use crate::transport::http::errors::{internal, ApiResult};

const DIRECT_SESSION_PREDICATE: &str = "
COALESCE(s.control_mode, CASE
  WHEN s.provider = 'claude' AND s.claude_integration_mode = 'direct' THEN 'direct'
  WHEN s.provider = 'codex' AND s.codex_integration_mode = 'direct' THEN 'direct'
  ELSE 'passive'
END) = 'direct'";

pub async fn fetch_codex_usage(
  State(state): State<Arc<SessionRegistry>>,
) -> Json<CodexUsageResponse> {
  if !state.is_primary() {
    return Json(CodexUsageResponse {
      usage: None,
      error_info: Some(not_primary_usage_endpoint_error()),
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
      error_info: Some(not_primary_usage_endpoint_error()),
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

pub async fn fetch_usage_breakdown(
  Query(query): Query<UsageBreakdownQuery>,
) -> ApiResult<UsageBreakdownSnapshot> {
  let db_path = crate::infrastructure::paths::db_path();
  let breakdown = tokio::task::spawn_blocking(move || {
    load_usage_breakdown(&db_path, query.group_by, query.start_unix, query.end_unix)
  })
  .await
  .map_err(|err| {
    internal(
      "usage_breakdown_failed",
      format!("Usage breakdown task failed: {err}"),
    )
  })?
  .map_err(|err| internal("usage_breakdown_failed", err.to_string()))?;

  Ok(Json(breakdown))
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

  let sessions = load_direct_sessions(&conn)?;

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

pub(super) fn load_usage_breakdown(
  db_path: &std::path::Path,
  group_by: UsageBreakdownGroupBy,
  start_unix: Option<u64>,
  end_unix: Option<u64>,
) -> anyhow::Result<UsageBreakdownSnapshot> {
  if !db_path.exists() {
    return Ok(UsageBreakdownSnapshot {
      group_by,
      start_unix,
      end_unix,
      ..UsageBreakdownSnapshot::default()
    });
  }

  let conn = Connection::open(db_path)?;
  conn.execute_batch(
    "PRAGMA journal_mode = WAL;
     PRAGMA busy_timeout = 5000;",
  )?;

  let filtered_rows: Vec<UsageLedgerRow> = load_usage_ledger_rows(&conn)?
    .into_iter()
    .filter(|row| row_in_range(row, start_unix, end_unix))
    .collect();

  let totals = build_totals_bucket(&filtered_rows);
  let groups = build_breakdown_groups(&filtered_rows, group_by);

  Ok(UsageBreakdownSnapshot {
    group_by,
    start_unix,
    end_unix,
    totals,
    groups,
  })
}

fn load_direct_sessions(conn: &Connection) -> anyhow::Result<Vec<SessionSummaryRow>> {
  conn
    .prepare(&format!(
      "SELECT s.id, s.started_at FROM sessions s WHERE {DIRECT_SESSION_PREDICATE}"
    ))?
    .query_map([], |row| {
      let session_id: String = row.get(0)?;
      let started_at: Option<String> = row.get(1)?;
      Ok(SessionSummaryRow {
        id: session_id,
        started_at_unix: parse_timestamp_to_unix(started_at.as_deref()),
      })
    })?
    .collect::<Result<Vec<_>, _>>()
    .map_err(Into::into)
}

fn load_usage_ledger_rows(conn: &Connection) -> anyhow::Result<Vec<UsageLedgerRow>> {
  conn
    .prepare(&format!(
      "SELECT
         ule.session_id,
         ule.provider,
         ule.model,
         ule.observed_at,
         ule.billable_input_tokens,
         ule.billable_output_tokens,
         ule.cache_read_tokens,
         ule.estimated_cost_usd
       FROM usage_ledger_entries ule
       JOIN sessions s ON s.id = ule.session_id
       WHERE {DIRECT_SESSION_PREDICATE}"
    ))?
    .query_map([], |row| {
      let session_id: String = row.get(0)?;
      let provider_raw: String = row.get(1)?;
      let observed_at: Option<String> = row.get(3)?;
      Ok(UsageLedgerRow {
        session_id,
        provider: provider_raw.parse().unwrap_or(Provider::Claude),
        model: row.get(2)?,
        observed_at_unix: parse_timestamp_to_unix(observed_at.as_deref()),
        input_tokens: row.get::<_, i64>(4)?.max(0) as u64,
        output_tokens: row.get::<_, i64>(5)?.max(0) as u64,
        cached_tokens: row.get::<_, i64>(6)?.max(0) as u64,
        cost_usd: row.get::<_, f64>(7)?,
      })
    })?
    .collect::<Result<Vec<_>, _>>()
    .map_err(Into::into)
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

fn row_in_range(row: &UsageLedgerRow, start_unix: Option<u64>, end_unix: Option<u64>) -> bool {
  let observed = row.observed_at_unix;
  if let Some(start_unix) = start_unix {
    if observed.is_none_or(|value| value < start_unix) {
      return false;
    }
  }
  if let Some(end_unix) = end_unix {
    if observed.is_none_or(|value| value >= end_unix) {
      return false;
    }
  }
  true
}

fn build_totals_bucket(rows: &[UsageLedgerRow]) -> UsageSummaryBucket {
  let mut bucket = UsageSummaryBucket::default();
  let mut session_ids = std::collections::HashSet::new();

  for row in rows {
    session_ids.insert(row.session_id.clone());
    apply_usage_aggregate(&mut bucket, row);
  }

  bucket.session_count = session_ids.len() as u64;
  sort_model_costs(&mut bucket);
  bucket
}

fn build_breakdown_groups(
  rows: &[UsageLedgerRow],
  group_by: UsageBreakdownGroupBy,
) -> Vec<UsageBreakdownEntry> {
  #[derive(Default)]
  struct GroupAccumulator {
    provider: Option<Provider>,
    model: Option<String>,
    session_id: Option<String>,
    day_start_unix: Option<u64>,
    session_ids: std::collections::HashSet<String>,
    turn_count: u64,
    input_tokens: u64,
    output_tokens: u64,
    cached_tokens: u64,
    total_cost_usd: f64,
  }

  let mut groups: std::collections::BTreeMap<String, GroupAccumulator> =
    std::collections::BTreeMap::new();

  for row in rows {
    let (group_key, provider, model, session_id, day_start_unix) = match group_by {
      UsageBreakdownGroupBy::Provider => (
        provider_key(row.provider),
        Some(row.provider),
        None,
        None,
        None,
      ),
      UsageBreakdownGroupBy::Model => (
        row.model.clone().unwrap_or_else(|| "unknown".to_string()),
        None,
        row.model.clone(),
        None,
        None,
      ),
      UsageBreakdownGroupBy::Session => (
        row.session_id.clone(),
        None,
        None,
        Some(row.session_id.clone()),
        None,
      ),
      UsageBreakdownGroupBy::Day => {
        let day_start = row.observed_at_unix.map(|value| value - (value % 86_400));
        (
          day_start
            .map(|value| value.to_string())
            .unwrap_or_else(|| "unknown".to_string()),
          None,
          None,
          None,
          day_start,
        )
      }
    };

    let group = groups.entry(group_key).or_default();
    group.provider = provider.or(group.provider);
    if group.model.is_none() {
      group.model = model;
    }
    if group.session_id.is_none() {
      group.session_id = session_id;
    }
    if group.day_start_unix.is_none() {
      group.day_start_unix = day_start_unix;
    }
    group.session_ids.insert(row.session_id.clone());
    group.turn_count = group.turn_count.saturating_add(1);
    group.input_tokens = group.input_tokens.saturating_add(row.input_tokens);
    group.output_tokens = group.output_tokens.saturating_add(row.output_tokens);
    group.cached_tokens = group.cached_tokens.saturating_add(row.cached_tokens);
    group.total_cost_usd += row.cost_usd;
  }

  let mut entries: Vec<UsageBreakdownEntry> = groups
    .into_iter()
    .map(|(group_key, accumulator)| UsageBreakdownEntry {
      group_key,
      provider: accumulator.provider,
      model: accumulator.model,
      session_id: accumulator.session_id,
      day_start_unix: accumulator.day_start_unix,
      turn_count: accumulator.turn_count,
      session_count: accumulator.session_ids.len() as u64,
      input_tokens: accumulator.input_tokens,
      output_tokens: accumulator.output_tokens,
      cached_tokens: accumulator.cached_tokens,
      total_tokens: accumulator
        .input_tokens
        .saturating_add(accumulator.output_tokens),
      total_cost_usd: accumulator.total_cost_usd,
    })
    .collect();

  match group_by {
    UsageBreakdownGroupBy::Day => entries.sort_by_key(|entry| entry.day_start_unix.unwrap_or(0)),
    _ => entries.sort_by(|lhs, rhs| rhs.total_cost_usd.total_cmp(&lhs.total_cost_usd)),
  }

  entries
}

fn provider_key(provider: Provider) -> String {
  match provider {
    Provider::Claude => "claude".to_string(),
    Provider::Codex => "codex".to_string(),
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
