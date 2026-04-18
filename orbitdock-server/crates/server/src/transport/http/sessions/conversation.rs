use std::{collections::BTreeMap, sync::Arc};

use axum::{
  extract::{Path, Query, State},
  http::StatusCode,
  Json,
};
use orbitdock_protocol::{
  conversation_contracts::{ConversationRow, RowEntrySummary, RowPageSummary},
  domain_events::ToolStatus,
  ConversationSnapshotPage,
};

use crate::{
  runtime::{
    session_queries::{
      load_conversation_bootstrap, load_conversation_page, load_full_session_state,
    },
    session_registry::SessionRegistry,
  },
  transport::http::{ApiErrorResponse, ApiResult},
};

use super::{
  common::{clamp_conversation_limit, duration_ms, map_session_load_error, row_matches_search},
  ConversationPageQuery, ConversationSearchQuery, MarkReadResponse, SessionStatsResponse,
};

pub async fn get_conversation_snapshot(
  Path(session_id): Path<String>,
  Query(query): Query<ConversationPageQuery>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<ConversationSnapshotPage> {
  let limit = clamp_conversation_limit(query.limit);
  match load_conversation_bootstrap(&state, &session_id, limit).await {
    Ok(bootstrap) => {
      let rows = bootstrap
        .session
        .rows
        .iter()
        .map(|entry| entry.to_transport_summary())
        .collect();
      Ok(Json(ConversationSnapshotPage {
        revision: bootstrap.session.revision.unwrap_or_default(),
        replay_cursor: bootstrap.session.revision.unwrap_or_default(),
        session_id,
        rows,
        total_row_count: bootstrap.total_row_count,
        has_more_before: bootstrap.has_more_before,
        forked_from_session_id: bootstrap.session.forked_from_session_id,
        oldest_sequence: bootstrap.oldest_sequence,
        newest_sequence: bootstrap.newest_sequence,
      }))
    }
    Err(error) => Err(map_session_load_error(&session_id, error)),
  }
}

pub async fn get_conversation_history(
  Path(session_id): Path<String>,
  Query(query): Query<ConversationPageQuery>,
  State(_state): State<Arc<SessionRegistry>>,
) -> ApiResult<RowPageSummary> {
  let limit = clamp_conversation_limit(query.limit);
  match load_conversation_page(&session_id, query.before_sequence, limit).await {
    Ok(page) => Ok(Json(page.into_row_page_summary())),
    Err(error) => Err(map_session_load_error(&session_id, error)),
  }
}

pub async fn mark_session_read(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<MarkReadResponse> {
  let actor = match state.get_session(&session_id) {
    Some(actor) => actor,
    None => {
      return Err((
        StatusCode::NOT_FOUND,
        Json(ApiErrorResponse {
          code: "session_not_found",
          error: format!("Session {} not found", session_id),
        }),
      ));
    }
  };

  let unread_count = actor.mark_read().await.unwrap_or(0);

  Ok(Json(MarkReadResponse {
    session_id,
    unread_count,
  }))
}

pub async fn search_conversation_rows(
  Path(session_id): Path<String>,
  Query(query): Query<ConversationSearchQuery>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<RowPageSummary> {
  let rows = load_full_session_state(&state, &session_id, true, false)
    .await
    .map_err(|error| map_session_load_error(&session_id, error))?
    .rows;

  let rows: Vec<_> = rows
    .into_iter()
    .filter(|entry| row_matches_search(entry, &query))
    .collect();

  let summary_rows: Vec<RowEntrySummary> = rows
    .iter()
    .map(|entry| entry.to_transport_summary())
    .collect();

  Ok(Json(RowPageSummary {
    total_row_count: summary_rows.len() as u64,
    has_more_before: false,
    oldest_sequence: summary_rows.first().map(|entry| entry.sequence),
    newest_sequence: summary_rows.last().map(|entry| entry.sequence),
    rows: summary_rows,
  }))
}

pub async fn get_session_stats(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<SessionStatsResponse> {
  let session = load_full_session_state(&state, &session_id, true, false)
    .await
    .map_err(|error| map_session_load_error(&session_id, error))?;
  let rows = session.rows.clone();

  let mut tool_count = 0_u64;
  let mut failed_tool_count = 0_u64;
  let mut total_tool_duration_ms = 0_u64;
  let mut timed_tool_count = 0_u64;
  let mut tool_count_by_family = BTreeMap::new();

  for entry in &rows {
    if let ConversationRow::Tool(tool) = &entry.row {
      tool_count += 1;
      *tool_count_by_family
        .entry(
          serde_json::to_value(tool.family)
            .ok()
            .and_then(|value| value.as_str().map(ToString::to_string))
            .unwrap_or_else(|| "generic".to_string()),
        )
        .or_insert(0) += 1;
      if tool.status == ToolStatus::Failed {
        failed_tool_count += 1;
      }
      if let Some(duration_ms) = tool.duration_ms {
        total_tool_duration_ms += duration_ms;
        timed_tool_count += 1;
      }
    }
  }

  Ok(Json(SessionStatsResponse {
    session_id,
    total_rows: rows.len() as u64,
    tool_count,
    tool_count_by_family,
    failed_tool_count,
    average_tool_duration_ms: total_tool_duration_ms
      .checked_div(timed_tool_count)
      .unwrap_or_default(),
    turn_count: session.turn_count,
    total_tokens: session.token_usage,
    worker_count: session
      .subagents
      .iter()
      .filter(|worker| worker.ended_at.is_none())
      .count() as u32,
    duration_ms: duration_ms(
      session.started_at.as_deref(),
      session.last_activity_at.as_deref(),
    ),
  }))
}
