use super::*;
use crate::infrastructure::persistence::load_row_by_id_async;
use crate::support::session_time::parse_unix_z;
use orbitdock_protocol::conversation_contracts::{
  compute_diff_display, compute_expanded_output, compute_input_display, detect_language,
  extract_row_content_str, extract_start_line, CommandExecutionRow, ConversationRow, DiffLine,
  RowEntrySummary, RowPageSummary,
};
use orbitdock_protocol::domain_events::ToolStatus;
use orbitdock_protocol::{
  ConversationSnapshotPage, DashboardSnapshot, SessionComposerSnapshot, SessionDetailSnapshot,
};
use std::collections::BTreeMap;

const DEFAULT_CONVERSATION_PAGE_SIZE: usize = 50;
const MAX_CONVERSATION_PAGE_SIZE: usize = 200;

#[derive(Debug, Deserialize, Default)]
pub struct ConversationPageQuery {
  #[serde(default)]
  pub limit: Option<usize>,
  #[serde(default)]
  pub before_sequence: Option<u64>,
}

#[derive(Debug, Deserialize, Default)]
pub struct SessionSnapshotQuery {
  #[serde(default)]
  pub include_messages: bool,
}

#[derive(Debug, Serialize)]
pub struct MarkReadResponse {
  pub session_id: String,
  pub unread_count: u64,
}

#[derive(Debug, Deserialize, Default)]
pub struct ConversationSearchQuery {
  #[serde(default)]
  pub q: Option<String>,
  #[serde(default)]
  pub family: Option<String>,
  #[serde(default)]
  pub status: Option<String>,
  #[serde(default)]
  pub kind: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct SessionStatsResponse {
  pub session_id: String,
  pub total_rows: u64,
  pub tool_count: u64,
  pub tool_count_by_family: BTreeMap<String, u64>,
  pub failed_tool_count: u64,
  pub average_tool_duration_ms: u64,
  pub turn_count: u64,
  pub total_tokens: orbitdock_protocol::TokenUsage,
  pub worker_count: u32,
  pub duration_ms: u64,
}

fn clamp_conversation_limit(limit: Option<usize>) -> usize {
  limit
    .unwrap_or(DEFAULT_CONVERSATION_PAGE_SIZE)
    .clamp(1, MAX_CONVERSATION_PAGE_SIZE)
}

fn enum_wire_name<T: serde::Serialize>(value: T) -> Option<String> {
  serde_json::to_value(value)
    .ok()?
    .as_str()
    .map(ToString::to_string)
}

fn row_matches_search(
  entry: &orbitdock_protocol::conversation_contracts::ConversationRowEntry,
  query: &ConversationSearchQuery,
) -> bool {
  let text_matches = query.q.as_ref().is_none_or(|needle| {
    extract_row_content_str(&entry.row)
      .to_lowercase()
      .contains(&needle.to_lowercase())
  });
  if !text_matches {
    return false;
  }

  match &entry.row {
    ConversationRow::Tool(tool) => {
      let family_matches = query
        .family
        .as_ref()
        .is_none_or(|family| enum_wire_name(tool.family) == Some(family.clone()));
      let status_matches = query
        .status
        .as_ref()
        .is_none_or(|status| enum_wire_name(tool.status) == Some(status.clone()));
      let kind_matches = query
        .kind
        .as_ref()
        .is_none_or(|kind| enum_wire_name(tool.kind) == Some(kind.clone()));
      family_matches && status_matches && kind_matches
    }
    _ => query.family.is_none() && query.status.is_none() && query.kind.is_none(),
  }
}

fn duration_ms(started_at: Option<&str>, last_activity_at: Option<&str>) -> u64 {
  let Some(start) = parse_unix_z(started_at) else {
    return 0;
  };
  let Some(end) = parse_unix_z(last_activity_at) else {
    return 0;
  };
  end.saturating_sub(start).saturating_mul(1000)
}

pub async fn get_dashboard_snapshot(
  State(state): State<Arc<SessionRegistry>>,
) -> Json<DashboardSnapshot> {
  Json(state.current_dashboard_snapshot())
}

pub async fn get_session_detail(
  Path(session_id): Path<String>,
  Query(query): Query<SessionSnapshotQuery>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<SessionDetailSnapshot> {
  match load_full_session_state(&state, &session_id, query.include_messages).await {
    Ok(session) => Ok(Json(SessionDetailSnapshot {
      revision: session.revision.unwrap_or_default(),
      session,
    })),
    Err(SessionLoadError::NotFound) => Err((
      StatusCode::NOT_FOUND,
      Json(ApiErrorResponse {
        code: "not_found",
        error: format!("Session {} not found", session_id),
      }),
    )),
    Err(SessionLoadError::Db(err)) => {
      error!(
          component = "api",
          event = "api.get_session.db_error",
          session_id = %session_id,
          error = %err,
          "Failed to load session from database"
      );
      Err((
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(ApiErrorResponse {
          code: "db_error",
          error: err,
        }),
      ))
    }
    Err(SessionLoadError::Runtime(err)) => {
      error!(
          component = "api",
          event = "api.get_session.runtime_error",
          session_id = %session_id,
          error = %err,
          "Failed to load runtime session state"
      );
      Err((
        StatusCode::SERVICE_UNAVAILABLE,
        Json(ApiErrorResponse {
          code: "runtime_error",
          error: err,
        }),
      ))
    }
  }
}

pub async fn get_session_composer(
  Path(session_id): Path<String>,
  Query(query): Query<SessionSnapshotQuery>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<SessionComposerSnapshot> {
  match load_full_session_state(&state, &session_id, query.include_messages).await {
    Ok(session) => Ok(Json(SessionComposerSnapshot {
      revision: session.revision.unwrap_or_default(),
      session,
    })),
    Err(SessionLoadError::NotFound) => Err((
      StatusCode::NOT_FOUND,
      Json(ApiErrorResponse {
        code: "not_found",
        error: format!("Session {} not found", session_id),
      }),
    )),
    Err(SessionLoadError::Db(err)) => Err((
      StatusCode::INTERNAL_SERVER_ERROR,
      Json(ApiErrorResponse {
        code: "db_error",
        error: err,
      }),
    )),
    Err(SessionLoadError::Runtime(err)) => Err((
      StatusCode::SERVICE_UNAVAILABLE,
      Json(ApiErrorResponse {
        code: "runtime_error",
        error: err,
      }),
    )),
  }
}

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
        .map(|entry| entry.to_summary())
        .collect();
      Ok(Json(ConversationSnapshotPage {
        revision: bootstrap.session.revision.unwrap_or_default(),
        session_id,
        session: bootstrap.session,
        rows,
        total_row_count: bootstrap.total_row_count,
        has_more_before: bootstrap.has_more_before,
        oldest_sequence: bootstrap.oldest_sequence,
        newest_sequence: bootstrap.newest_sequence,
      }))
    }
    Err(SessionLoadError::NotFound) => Err((
      StatusCode::NOT_FOUND,
      Json(ApiErrorResponse {
        code: "not_found",
        error: format!("Session {} not found", session_id),
      }),
    )),
    Err(SessionLoadError::Db(err)) => Err((
      StatusCode::INTERNAL_SERVER_ERROR,
      Json(ApiErrorResponse {
        code: "db_error",
        error: err,
      }),
    )),
    Err(SessionLoadError::Runtime(err)) => Err((
      StatusCode::SERVICE_UNAVAILABLE,
      Json(ApiErrorResponse {
        code: "runtime_error",
        error: err,
      }),
    )),
  }
}

pub async fn get_conversation_history(
  Path(session_id): Path<String>,
  Query(query): Query<ConversationPageQuery>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<RowPageSummary> {
  let limit = clamp_conversation_limit(query.limit);
  match load_conversation_page(&state, &session_id, query.before_sequence, limit).await {
    Ok(page) => Ok(Json(page.into_row_page_summary())),
    Err(SessionLoadError::NotFound) => Err((
      StatusCode::NOT_FOUND,
      Json(ApiErrorResponse {
        code: "not_found",
        error: format!("Session {} not found", session_id),
      }),
    )),
    Err(SessionLoadError::Db(err)) => Err((
      StatusCode::INTERNAL_SERVER_ERROR,
      Json(ApiErrorResponse {
        code: "db_error",
        error: err,
      }),
    )),
    Err(SessionLoadError::Runtime(err)) => Err((
      StatusCode::SERVICE_UNAVAILABLE,
      Json(ApiErrorResponse {
        code: "runtime_error",
        error: err,
      }),
    )),
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
  let rows = load_full_session_state(&state, &session_id, true)
    .await
    .map_err(|error| match error {
      SessionLoadError::NotFound => (
        StatusCode::NOT_FOUND,
        Json(ApiErrorResponse {
          code: "not_found",
          error: format!("Session {} not found", session_id),
        }),
      ),
      SessionLoadError::Db(err) => (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(ApiErrorResponse {
          code: "db_error",
          error: err,
        }),
      ),
      SessionLoadError::Runtime(err) => (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(ApiErrorResponse {
          code: "runtime_error",
          error: err,
        }),
      ),
    })?
    .rows;

  let rows: Vec<_> = rows
    .into_iter()
    .filter(|entry| row_matches_search(entry, &query))
    .collect();

  let summary_rows: Vec<RowEntrySummary> = rows.iter().map(|e| e.to_summary()).collect();

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
  let session = load_full_session_state(&state, &session_id, true)
    .await
    .map_err(|error| match error {
      SessionLoadError::NotFound => (
        StatusCode::NOT_FOUND,
        Json(ApiErrorResponse {
          code: "not_found",
          error: format!("Session {} not found", session_id),
        }),
      ),
      SessionLoadError::Db(err) => (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(ApiErrorResponse {
          code: "db_error",
          error: err,
        }),
      ),
      SessionLoadError::Runtime(err) => (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(ApiErrorResponse {
          code: "runtime_error",
          error: err,
        }),
      ),
    })?;
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
        .entry(enum_wire_name(tool.family).unwrap_or_else(|| "generic".to_string()))
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
    average_tool_duration_ms: if timed_tool_count == 0 {
      0
    } else {
      total_tool_duration_ms / timed_tool_count
    },
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

#[derive(Debug, Serialize)]
pub struct RowContentResponse {
  pub row_id: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub input_display: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub output_display: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub diff_display: Option<Vec<DiffLine>>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub language: Option<String>,
  /// Starting line number for Read tool output (extracted from cat -n format).
  #[serde(skip_serializing_if = "Option::is_none")]
  pub start_line: Option<u32>,
}

fn command_execution_row_content(row_id: String, row: &CommandExecutionRow) -> RowContentResponse {
  let output_display = row
    .aggregated_output
    .clone()
    .or_else(|| row.live_output_preview.clone())
    .filter(|value| !value.trim().is_empty());

  RowContentResponse {
    row_id,
    input_display: Some(row.command.clone()),
    output_display,
    diff_display: None,
    language: None,
    start_line: None,
  }
}

pub async fn get_row_content(
  Path((session_id, row_id)): Path<(String, String)>,
  State(_state): State<Arc<SessionRegistry>>,
) -> ApiResult<RowContentResponse> {
  let entry = load_row_by_id_async(&session_id, &row_id)
    .await
    .map_err(|err| {
      error!(
          component = "api",
          event = "api.get_row_content.db_error",
          session_id = %session_id,
          row_id = %row_id,
          error = %err,
          "Failed to load row from database"
      );
      (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(ApiErrorResponse {
          code: "db_error",
          error: err.to_string(),
        }),
      )
    })?;

  let entry = entry.ok_or_else(|| {
    (
      StatusCode::NOT_FOUND,
      Json(ApiErrorResponse {
        code: "not_found",
        error: format!("Row {} not found in session {}", row_id, session_id),
      }),
    )
  })?;

  match &entry.row {
    ConversationRow::Tool(tool) => {
      // Unwrap raw_input wrapper, same logic as compute_tool_display
      let unwrapped = tool
        .invocation
        .get("raw_input")
        .filter(|ri| ri.is_object())
        .or(Some(&tool.invocation));

      let result_output = tool.result.as_ref().and_then(|r| {
        r.get("output")
          .and_then(|o| o.as_str())
          .or_else(|| r.get("raw_output").and_then(|o| o.as_str()))
      });

      let start_line = extract_start_line(tool.kind, result_output);
      let input_display = compute_input_display(tool.kind, unwrapped);
      let output_display = compute_expanded_output(tool.kind, result_output);
      let diff_display = compute_diff_display(tool.kind, unwrapped);
      let language = detect_language(tool.kind, unwrapped);

      Ok(Json(RowContentResponse {
        row_id,
        input_display,
        output_display,
        diff_display,
        language,
        start_line,
      }))
    }
    ConversationRow::CommandExecution(row) => Ok(Json(command_execution_row_content(row_id, row))),
    _ => Err((
      StatusCode::UNPROCESSABLE_ENTITY,
      Json(ApiErrorResponse {
        code: "not_expandable_row",
        error: format!("Row {} does not expose expandable content", row_id),
      }),
    )),
  }
}

#[cfg(test)]
mod tests {
  use super::*;
  use axum::extract::{Path, Query, State};
  use orbitdock_protocol::conversation_contracts::render_hints::RenderHints;
  use orbitdock_protocol::conversation_contracts::{
    CommandExecutionAction, CommandExecutionRow, CommandExecutionStatus, ConversationRow,
    ConversationRowEntry, ToolRow,
  };
  use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
  use orbitdock_protocol::Provider;

  use crate::domain::sessions::session::SessionHandle;
  use crate::runtime::session_commands::SessionCommand;
  use crate::transport::http::test_support::new_test_state;

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
      }),
    }
  }

  fn test_command_execution_row(
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
      row: ConversationRow::CommandExecution(CommandExecutionRow {
        id: id.to_string(),
        status: CommandExecutionStatus::Completed,
        command: "sed -n '1,40p' docs/design-system.md".to_string(),
        cwd: "/tmp/orbitdock-command-execution".to_string(),
        process_id: Some("pty-42".to_string()),
        command_actions: vec![CommandExecutionAction::Read {
          command: "sed -n '1,40p' docs/design-system.md".to_string(),
          name: "design-system.md".to_string(),
          path: "docs/design-system.md".to_string(),
        }],
        live_output_preview: None,
        aggregated_output: output.map(ToString::to_string),
        preview: None,
        exit_code: Some(0),
        duration_ms: Some(18),
        render_hints: RenderHints::default(),
      }),
    }
  }

  #[tokio::test]
  async fn search_conversation_rows_filters_by_query_and_tool_metadata() {
    let state = new_test_state(true);
    let session_id = orbitdock_protocol::new_session_id();
    state.add_session(SessionHandle::new(
      session_id.clone(),
      Provider::Codex,
      "/tmp/orbitdock-search-test".to_string(),
    ));
    let actor = state
      .get_session(&session_id)
      .expect("session should exist for search test");

    actor
      .send(SessionCommand::ProcessEvent {
        event: crate::domain::sessions::transition::Input::RowCreated(test_tool_row(
          &session_id,
          "tool-1",
          1,
          "Deploy preview build",
          ToolStatus::Completed,
          Some(1200),
        )),
      })
      .await;
    tokio::task::yield_now().await;
    tokio::task::yield_now().await;

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
    let state = new_test_state(true);
    let session_id = orbitdock_protocol::new_session_id();
    let handle = SessionHandle::new(
      session_id.clone(),
      Provider::Codex,
      "/tmp/orbitdock-stats-test".to_string(),
    );
    state.add_session(handle);
    let actor = state
      .get_session(&session_id)
      .expect("session should exist for stats test");

    for entry in [
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
    ] {
      actor
        .send(SessionCommand::ProcessEvent {
          event: crate::domain::sessions::transition::Input::RowCreated(entry),
        })
        .await;
    }
    tokio::task::yield_now().await;
    tokio::task::yield_now().await;

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
  async fn command_execution_row_content_returns_full_output() {
    let entry =
      test_command_execution_row("session-1", "cmd-1", 1, Some("22pt Bold\n18pt Semibold"));
    let ConversationRow::CommandExecution(row) = &entry.row else {
      panic!("expected command execution row");
    };

    let response = command_execution_row_content("cmd-1".to_string(), row);

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
}
