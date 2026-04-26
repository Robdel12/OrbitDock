use std::sync::Arc;

use axum::{
  extract::{Path, Query, State},
  Json,
};
use orbitdock_protocol::{
  Provider, SessionUsageTurnEntry, SessionUsageTurnsPage, TokenUsage, UsagePricingSnapshotPayload,
  UsageSummaryBucket, UsageSummaryModelCost,
};
use rusqlite::{params, Connection};

use crate::{
  runtime::session_registry::SessionRegistry,
  transport::http::{errors::not_found, ApiResult},
};

use super::SessionUsageTurnsQuery;

const DEFAULT_USAGE_TURN_LIMIT: usize = 100;
const MAX_USAGE_TURN_LIMIT: usize = 500;

pub async fn get_session_usage_turns(
  Path(session_id): Path<String>,
  Query(query): Query<SessionUsageTurnsQuery>,
  State(_state): State<Arc<SessionRegistry>>,
) -> ApiResult<SessionUsageTurnsPage> {
  let db_path = crate::infrastructure::paths::db_path();
  let limit = clamp_usage_turn_limit(query.limit);
  let before_turn_seq = query.before_turn_seq;
  let session_id_for_task = session_id.clone();

  let page = tokio::task::spawn_blocking(move || {
    load_session_usage_turns(&db_path, &session_id_for_task, before_turn_seq, limit)
  })
  .await
  .map_err(|err| {
    crate::transport::http::errors::internal(
      "session_usage_turns_failed",
      format!("Session usage turns task failed: {err}"),
    )
  })?
  .map_err(|err| {
    crate::transport::http::errors::internal("session_usage_turns_failed", err.to_string())
  })?;

  match page {
    Some(page) => Ok(Json(page)),
    None => Err(not_found(
      "session_not_found",
      format!("Session {session_id} not found"),
    )),
  }
}

fn clamp_usage_turn_limit(limit: Option<usize>) -> usize {
  match limit.unwrap_or(DEFAULT_USAGE_TURN_LIMIT) {
    0 => 1,
    value if value > MAX_USAGE_TURN_LIMIT => MAX_USAGE_TURN_LIMIT,
    value => value,
  }
}

fn load_session_usage_turns(
  db_path: &std::path::Path,
  session_id: &str,
  before_turn_seq: Option<u64>,
  limit: usize,
) -> anyhow::Result<Option<SessionUsageTurnsPage>> {
  if !db_path.exists() {
    return Ok(None);
  }

  let conn = Connection::open(db_path)?;
  conn.execute_batch(
    "PRAGMA journal_mode = WAL;
     PRAGMA busy_timeout = 5000;",
  )?;

  let session_exists: bool = conn.query_row(
    "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ?1)",
    params![session_id],
    |row| row.get::<_, i64>(0).map(|value| value == 1),
  )?;
  if !session_exists {
    return Ok(None);
  }

  let total_turn_count = conn.query_row(
    "SELECT COUNT(*) FROM usage_turns WHERE session_id = ?1",
    params![session_id],
    |row| row.get::<_, i64>(0).map(|value| value.max(0) as u64),
  )?;

  let rows_desc = conn
    .prepare(
      "SELECT
         ut.turn_id,
         ut.turn_seq,
         ut.provider,
         ut.model,
         ule.observed_at,
         ut.snapshot_kind,
         ut.input_tokens,
         ut.output_tokens,
         ut.cached_tokens,
         ut.context_window,
         COALESCE(ule.billable_input_tokens, 0),
         COALESCE(ule.billable_output_tokens, 0),
         COALESCE(ule.cache_read_tokens, 0),
         COALESCE(ule.cache_write_tokens, 0),
         COALESCE(ule.context_input_tokens, 0),
         COALESCE(ule.estimated_cost_usd, 0),
         COALESCE(ule.pricing_source, 'orbitdock_builtin'),
         COALESCE(ule.pricing_version, 'unknown'),
         ule.pricing_model_key,
         COALESCE(ule.input_cost_per_token, 0),
         COALESCE(ule.output_cost_per_token, 0),
         COALESCE(ule.cache_read_cost_per_token, 0),
         COALESCE(ule.cache_write_cost_per_token, 0)
       FROM usage_turns ut
       LEFT JOIN usage_ledger_entries ule
         ON ule.session_id = ut.session_id
        AND ule.turn_id = ut.turn_id
       WHERE ut.session_id = ?1
         AND (?2 IS NULL OR ut.turn_seq < ?2)
       ORDER BY ut.turn_seq DESC, ut.rowid DESC
       LIMIT ?3",
    )?
    .query_map(
      params![
        session_id,
        before_turn_seq.map(|value| value as i64),
        limit as i64,
      ],
      |row| {
        let provider_raw: String = row.get(2)?;
        let provider = provider_raw.parse().unwrap_or(Provider::Claude);
        let snapshot_kind_raw: String = row.get(5)?;
        Ok(SessionUsageTurnEntry {
          turn_id: row.get(0)?,
          turn_seq: row.get::<_, i64>(1)?.max(0) as u64,
          provider,
          model: row.get(3)?,
          observed_at: row.get(4)?,
          snapshot_kind: crate::infrastructure::persistence::snapshot_kind_from_str(Some(
            snapshot_kind_raw.as_str(),
          )),
          raw_usage: TokenUsage {
            input_tokens: row.get::<_, i64>(6)?.max(0) as u64,
            output_tokens: row.get::<_, i64>(7)?.max(0) as u64,
            cached_tokens: row.get::<_, i64>(8)?.max(0) as u64,
            context_window: row.get::<_, i64>(9)?.max(0) as u64,
          },
          billable_input_tokens: row.get::<_, i64>(10)?.max(0) as u64,
          billable_output_tokens: row.get::<_, i64>(11)?.max(0) as u64,
          cache_read_tokens: row.get::<_, i64>(12)?.max(0) as u64,
          cache_write_tokens: row.get::<_, i64>(13)?.max(0) as u64,
          context_input_tokens: row.get::<_, i64>(14)?.max(0) as u64,
          estimated_cost_usd: row.get(15)?,
          pricing: UsagePricingSnapshotPayload {
            source: row.get(16)?,
            version: row.get(17)?,
            model_key: row.get(18)?,
            input_cost_per_token: row.get(19)?,
            output_cost_per_token: row.get(20)?,
            cache_read_cost_per_token: row.get(21)?,
            cache_write_cost_per_token: row.get(22)?,
          },
        })
      },
    )?
    .collect::<Result<Vec<_>, _>>()?;

  let mut rows = rows_desc;
  rows.reverse();

  let oldest_turn_seq = rows.first().map(|entry| entry.turn_seq);
  let newest_turn_seq = rows.last().map(|entry| entry.turn_seq);
  let has_more_before = if let Some(oldest_turn_seq) = oldest_turn_seq {
    conn.query_row(
      "SELECT EXISTS(
         SELECT 1
         FROM usage_turns
         WHERE session_id = ?1
           AND turn_seq < ?2
       )",
      params![session_id, oldest_turn_seq as i64],
      |row| row.get::<_, i64>(0).map(|value| value == 1),
    )?
  } else {
    false
  };

  let summary_rows = conn
    .prepare(
      "SELECT model, billable_input_tokens, billable_output_tokens, cache_read_tokens, estimated_cost_usd
       FROM usage_ledger_entries
       WHERE session_id = ?1
       ORDER BY turn_seq ASC",
    )?
    .query_map(params![session_id], |row| {
      Ok((
        row.get::<_, Option<String>>(0)?,
        row.get::<_, i64>(1)?.max(0) as u64,
        row.get::<_, i64>(2)?.max(0) as u64,
        row.get::<_, i64>(3)?.max(0) as u64,
        row.get::<_, f64>(4)?,
      ))
    })?
    .collect::<Result<Vec<_>, _>>()?;

  let summary = build_session_usage_summary(&summary_rows, total_turn_count);

  Ok(Some(SessionUsageTurnsPage {
    session_id: session_id.to_string(),
    total_turn_count,
    has_more_before,
    oldest_turn_seq,
    newest_turn_seq,
    summary,
    rows,
  }))
}

fn build_session_usage_summary(
  rows: &[(Option<String>, u64, u64, u64, f64)],
  total_turn_count: u64,
) -> UsageSummaryBucket {
  let mut bucket = UsageSummaryBucket {
    session_count: if total_turn_count > 0 { 1 } else { 0 },
    ..UsageSummaryBucket::default()
  };
  let mut by_model: std::collections::BTreeMap<String, f64> = std::collections::BTreeMap::new();

  for (model, input_tokens, output_tokens, cached_tokens, cost_usd) in rows {
    bucket.input_tokens = bucket.input_tokens.saturating_add(*input_tokens);
    bucket.output_tokens = bucket.output_tokens.saturating_add(*output_tokens);
    bucket.cached_tokens = bucket.cached_tokens.saturating_add(*cached_tokens);
    bucket.total_tokens = bucket.input_tokens.saturating_add(bucket.output_tokens);
    bucket.total_cost_usd += *cost_usd;

    if let Some(model_name) = normalize_model_name(model.as_deref()) {
      *by_model.entry(model_name).or_insert(0.0) += *cost_usd;
    }
  }

  bucket.cost_by_model = by_model
    .into_iter()
    .map(|(model, cost_usd)| UsageSummaryModelCost { model, cost_usd })
    .collect();
  bucket
    .cost_by_model
    .sort_by(|lhs, rhs| rhs.cost_usd.total_cmp(&lhs.cost_usd));
  bucket
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
