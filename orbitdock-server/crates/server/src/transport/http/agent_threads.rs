use std::sync::Arc;

use axum::{
  extract::{Path, Query, State},
  http::StatusCode,
  Json,
};
use serde::Deserialize;

use orbitdock_protocol::{
  AgentThreadConversationPage, AgentThreadListResponse, AgentThreadTranscriptFreshness,
};

use super::{messaging_dispatch_error_response, session_load_error, ApiErrorResponse, ApiResult};
use crate::{
  domain::agent_threads::{
    parent_mediated_message, summarize_agent_thread, AgentThreadTranscriptState,
  },
  infrastructure::persistence::PersistCommand,
  runtime::{
    message_dispatch, session_queries::load_light_session_state, session_registry::SessionRegistry,
  },
};

const DEFAULT_AGENT_THREAD_PAGE_SIZE: usize = 50;
const MAX_AGENT_THREAD_PAGE_SIZE: usize = 200;

#[derive(Debug, Deserialize, Default)]
pub struct AgentThreadConversationQuery {
  #[serde(default)]
  pub before_sequence: Option<u64>,
  #[serde(default)]
  pub limit: Option<usize>,
}

#[derive(Debug, Deserialize)]
pub struct AgentThreadMessageRequest {
  pub content: String,
}

#[derive(Debug, serde::Serialize)]
pub struct AgentThreadMessageResponse {
  pub accepted: bool,
  pub thread_id: String,
  pub interjection_mode: orbitdock_protocol::AgentThreadInterjectionMode,
  pub row: orbitdock_protocol::conversation_contracts::RowEntrySummary,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub session_detail_snapshot: Option<orbitdock_protocol::SessionDetailSnapshot>,
}

pub async fn list_agent_threads(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<AgentThreadListResponse> {
  let session = load_light_session_state(&state, &session_id)
    .await
    .map_err(|error| session_load_error(&session_id, error))?;

  let mut threads = Vec::with_capacity(session.subagents.len());
  for thread in &session.subagents {
    let has_transcript = super::files::resolve_subagent_transcript_path(&thread.id)
      .await
      .is_some();
    threads.push(summarize_agent_thread(
      &session,
      thread,
      AgentThreadTranscriptState {
        has_transcript,
        total_row_count: None,
        oldest_sequence: None,
        newest_sequence: None,
      },
    ));
  }

  Ok(Json(AgentThreadListResponse {
    session_id,
    revision: session.revision.unwrap_or_default(),
    threads,
  }))
}

pub async fn get_agent_thread_conversation(
  Path((session_id, thread_id)): Path<(String, String)>,
  Query(query): Query<AgentThreadConversationQuery>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<AgentThreadConversationPage> {
  let session = load_light_session_state(&state, &session_id)
    .await
    .map_err(|error| session_load_error(&session_id, error))?;
  let thread = session
    .subagents
    .iter()
    .find(|thread| thread.id == thread_id)
    .ok_or_else(|| thread_not_found(&thread_id))?;

  let transcript_path = super::files::resolve_subagent_transcript_path(&thread_id).await;
  let Some(_) = transcript_path else {
    return Ok(Json(AgentThreadConversationPage {
      session_id,
      thread_id,
      rows: vec![],
      total_row_count: 0,
      has_more_before: false,
      oldest_sequence: None,
      newest_sequence: None,
      freshness: AgentThreadTranscriptFreshness::Unavailable,
    }));
  };

  let mut rows = super::files::load_subagent_rows(&thread_id).await;
  for row in &mut rows {
    row.session_id = session_id.clone();
  }
  let page = page_rows(rows, query.before_sequence, clamp_limit(query.limit));
  let summary = summarize_agent_thread(
    &session,
    thread,
    AgentThreadTranscriptState {
      has_transcript: true,
      total_row_count: Some(page.total_row_count),
      oldest_sequence: page.oldest_sequence,
      newest_sequence: page.newest_sequence,
    },
  );

  Ok(Json(AgentThreadConversationPage {
    session_id,
    thread_id,
    rows: page.rows,
    total_row_count: page.total_row_count,
    has_more_before: page.has_more_before,
    oldest_sequence: page.oldest_sequence,
    newest_sequence: page.newest_sequence,
    freshness: summary.conversation.freshness,
  }))
}

pub async fn post_agent_thread_message(
  Path((session_id, thread_id)): Path<(String, String)>,
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<AgentThreadMessageRequest>,
) -> Result<(StatusCode, Json<AgentThreadMessageResponse>), (StatusCode, Json<ApiErrorResponse>)> {
  let content = body.content.trim();
  if content.is_empty() {
    return Err((
      StatusCode::BAD_REQUEST,
      Json(ApiErrorResponse {
        code: "invalid_request",
        error: "Provide content to interject into an agent thread".to_string(),
      }),
    ));
  }

  let session = load_light_session_state(&state, &session_id)
    .await
    .map_err(|error| session_load_error(&session_id, error))?;
  let thread = session
    .subagents
    .iter()
    .find(|thread| thread.id == thread_id)
    .ok_or_else(|| thread_not_found(&thread_id))?;
  let summary = summarize_agent_thread(
    &session,
    thread,
    AgentThreadTranscriptState {
      has_transcript: super::files::resolve_subagent_transcript_path(&thread_id)
        .await
        .is_some(),
      total_row_count: None,
      oldest_sequence: None,
      newest_sequence: None,
    },
  );

  if !summary.capabilities.accepts_user_input {
    return Err((
      StatusCode::CONFLICT,
      Json(ApiErrorResponse {
        code: "agent_thread_observe_only",
        error: summary
          .limitations
          .first()
          .cloned()
          .unwrap_or_else(|| "This agent thread is observe-only right now.".to_string()),
      }),
    ));
  }

  let row = message_dispatch::dispatch_steer_turn(
    &state,
    session_id.clone(),
    parent_mediated_message(&summary, content),
    vec![],
    vec![],
    format!("agent-thread-steer-{}", orbitdock_protocol::new_id()),
  )
  .await
  .map_err(|error| messaging_dispatch_error_response(error, &session_id))?;

  flush_persistence(&state).await;
  let session_detail_snapshot =
    crate::runtime::session_queries::load_full_session_state(&state, &session_id, false, false)
      .await
      .map(|session| orbitdock_protocol::SessionDetailSnapshot {
        revision: session.revision.unwrap_or_default(),
        session,
      })
      .map_err(|error| session_load_error(&session_id, error))?;

  Ok((
    StatusCode::ACCEPTED,
    Json(AgentThreadMessageResponse {
      accepted: true,
      thread_id,
      interjection_mode: summary.capabilities.interjection_mode,
      row: row.to_transport_summary(),
      session_detail_snapshot: Some(session_detail_snapshot),
    }),
  ))
}

async fn flush_persistence(state: &Arc<SessionRegistry>) {
  let (ack_tx, ack_rx) = tokio::sync::oneshot::channel();
  if state
    .persist()
    .send(PersistCommand::Flush { ack: ack_tx })
    .await
    .is_ok()
  {
    let _ = ack_rx.await;
  }
}

fn clamp_limit(limit: Option<usize>) -> usize {
  limit
    .unwrap_or(DEFAULT_AGENT_THREAD_PAGE_SIZE)
    .clamp(1, MAX_AGENT_THREAD_PAGE_SIZE)
}

fn page_rows(
  rows: Vec<orbitdock_protocol::conversation_contracts::ConversationRowEntry>,
  before_sequence: Option<u64>,
  limit: usize,
) -> orbitdock_protocol::conversation_contracts::RowPageSummary {
  let total_row_count = rows.len() as u64;
  let mut candidates: Vec<_> = rows
    .into_iter()
    .filter(|row| {
      before_sequence
        .map(|before| row.sequence < before)
        .unwrap_or(true)
    })
    .collect();
  let has_more_before = candidates.len() > limit;
  let start = candidates.len().saturating_sub(limit);
  if start > 0 {
    candidates.drain(0..start);
  }

  let rows = candidates
    .iter()
    .map(|entry| entry.to_transport_summary())
    .collect::<Vec<_>>();

  orbitdock_protocol::conversation_contracts::RowPageSummary {
    total_row_count,
    has_more_before,
    oldest_sequence: rows.first().map(|entry| entry.sequence),
    newest_sequence: rows.last().map(|entry| entry.sequence),
    rows,
  }
}

fn thread_not_found(thread_id: &str) -> (StatusCode, Json<ApiErrorResponse>) {
  (
    StatusCode::NOT_FOUND,
    Json(ApiErrorResponse {
      code: "agent_thread_not_found",
      error: format!("Agent thread {thread_id} not found"),
    }),
  )
}

#[cfg(test)]
mod tests {
  use super::*;
  use orbitdock_protocol::conversation_contracts::{
    ConversationRow, ConversationRowEntry, MessageRowContent, TurnStatus,
  };

  #[test]
  fn page_rows_returns_bounded_latest_rows_with_total_count() {
    let page = page_rows((0..5).map(row).collect(), None, 2);

    assert_eq!(page.total_row_count, 5);
    assert!(page.has_more_before);
    assert_eq!(page.oldest_sequence, Some(3));
    assert_eq!(page.newest_sequence, Some(4));
    assert_eq!(
      page
        .rows
        .iter()
        .map(|entry| entry.sequence)
        .collect::<Vec<_>>(),
      vec![3, 4]
    );
  }

  #[test]
  fn page_rows_honors_before_sequence() {
    let page = page_rows((0..5).map(row).collect(), Some(4), 2);

    assert_eq!(page.total_row_count, 5);
    assert!(page.has_more_before);
    assert_eq!(
      page
        .rows
        .iter()
        .map(|entry| entry.sequence)
        .collect::<Vec<_>>(),
      vec![2, 3]
    );
  }

  #[test]
  fn clamp_limit_keeps_agent_thread_pages_in_bounds() {
    assert_eq!(clamp_limit(None), DEFAULT_AGENT_THREAD_PAGE_SIZE);
    assert_eq!(clamp_limit(Some(0)), 1);
    assert_eq!(clamp_limit(Some(500)), MAX_AGENT_THREAD_PAGE_SIZE);
  }

  fn row(sequence: u64) -> ConversationRowEntry {
    ConversationRowEntry {
      session_id: "child-thread".to_string(),
      sequence,
      turn_id: None,
      turn_status: TurnStatus::Active,
      row: ConversationRow::Assistant(MessageRowContent {
        id: format!("row-{sequence}"),
        content: format!("message {sequence}"),
        turn_id: None,
        timestamp: None,
        is_streaming: false,
        images: vec![],
        memory_citation: None,
        delivery_status: None,
      }),
    }
  }
}
