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
  ConversationSnapshotPage, DashboardSnapshot, LibrarySnapshot, SessionComposerSnapshot,
  SessionDetailSnapshot, TurnDiff,
};
use std::collections::BTreeMap;

const DEFAULT_CONVERSATION_PAGE_SIZE: usize = 50;
const MAX_CONVERSATION_PAGE_SIZE: usize = 200;
const DEFAULT_LIBRARY_PAGE_SIZE: usize = 200;
const MAX_LIBRARY_PAGE_SIZE: usize = 500;

#[derive(Debug, Deserialize, Default)]
pub struct ConversationPageQuery {
  #[serde(default)]
  pub limit: Option<usize>,
  #[serde(default)]
  pub before_sequence: Option<u64>,
  #[serde(default)]
  pub include_diffs: bool,
}

#[derive(Debug, Deserialize, Default)]
pub struct SessionSnapshotQuery {
  #[serde(default)]
  pub include_messages: bool,
  #[serde(default)]
  pub include_diffs: bool,
}

#[derive(Debug, Deserialize, Default)]
pub struct LibrarySnapshotQuery {
  #[serde(default)]
  pub limit: Option<usize>,
  #[serde(default)]
  pub offset: Option<usize>,
}

#[derive(Debug, Serialize)]
pub struct SessionDiffsResponse {
  pub session_id: String,
  pub revision: u64,
  pub current_diff: Option<String>,
  pub cumulative_diff: Option<String>,
  pub turn_diffs: Vec<TurnDiff>,
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

fn clamp_library_limit(limit: Option<usize>) -> usize {
  limit
    .unwrap_or(DEFAULT_LIBRARY_PAGE_SIZE)
    .clamp(1, MAX_LIBRARY_PAGE_SIZE)
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
) -> ApiResult<DashboardSnapshot> {
  match load_dashboard_snapshot(&state).await {
    Ok(snapshot) => Ok(Json(snapshot)),
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
    Err(SessionLoadError::NotFound) => Ok(Json(DashboardSnapshot {
      revision: state.current_dashboard_revision(),
      sessions: Vec::new(),
      conversations: Vec::new(),
      counts: orbitdock_protocol::DashboardCounts {
        attention: 0,
        running: 0,
        ready: 0,
        direct: 0,
      },
    })),
  }
}

pub async fn get_library_snapshot(
  Query(query): Query<LibrarySnapshotQuery>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<LibrarySnapshot> {
  let limit = clamp_library_limit(query.limit);
  let offset = query.offset.unwrap_or(0);

  match load_library_snapshot(&state, limit, offset).await {
    Ok(snapshot) => Ok(Json(snapshot)),
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
    Err(SessionLoadError::NotFound) => Ok(Json(LibrarySnapshot {
      revision: state.current_dashboard_revision(),
      sessions: Vec::new(),
      next_offset: None,
      total_count: 0,
    })),
  }
}

pub async fn get_session_detail(
  Path(session_id): Path<String>,
  Query(query): Query<SessionSnapshotQuery>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<SessionDetailSnapshot> {
  match load_full_session_state(
    &state,
    &session_id,
    query.include_messages,
    query.include_diffs,
  )
  .await
  {
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
  match load_full_session_state(
    &state,
    &session_id,
    query.include_messages,
    query.include_diffs,
  )
  .await
  {
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
  match load_conversation_bootstrap(&state, &session_id, limit, query.include_diffs).await {
    Ok(bootstrap) => {
      let rows = bootstrap
        .session
        .rows
        .iter()
        .map(|entry| entry.to_transport_summary())
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
  State(_state): State<Arc<SessionRegistry>>,
) -> ApiResult<RowPageSummary> {
  let limit = clamp_conversation_limit(query.limit);
  match load_conversation_page(&session_id, query.before_sequence, limit).await {
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

pub async fn get_session_diffs(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<SessionDiffsResponse> {
  match load_full_session_state(&state, &session_id, false, true).await {
    Ok(session) => Ok(Json(SessionDiffsResponse {
      session_id,
      revision: session.revision.unwrap_or_default(),
      current_diff: session.current_diff,
      cumulative_diff: session.cumulative_diff,
      turn_diffs: session.turn_diffs,
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
  use orbitdock_protocol::{Provider, SessionControlMode};
  use std::path::PathBuf;

  use crate::infrastructure::persistence::{
    flush_batch_for_test, PersistCommand, SessionCreateParams,
  };
  use crate::transport::http::test_support::new_persist_test_state;

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
        terminal_snapshot: None,
        preview: None,
        exit_code: Some(0),
        duration_ms: Some(18),
        render_hints: RenderHints::default(),
      }),
    }
  }

  #[test]
  fn library_snapshot_limit_clamps_to_safe_bounds() {
    assert_eq!(
      clamp_library_limit(None),
      DEFAULT_LIBRARY_PAGE_SIZE,
      "missing limit should use default page size"
    );
    assert_eq!(
      clamp_library_limit(Some(0)),
      1,
      "zero limit should clamp to minimum page size"
    );
    assert_eq!(
      clamp_library_limit(Some(MAX_LIBRARY_PAGE_SIZE + 1)),
      MAX_LIBRARY_PAGE_SIZE,
      "oversized limit should clamp to max page size"
    );
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
  async fn dashboard_snapshot_reads_persisted_sessions() {
    let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
    let session_id = orbitdock_protocol::new_session_id();
    persist_session_fixture(
      &db_path,
      &session_id,
      "/tmp/orbitdock-dashboard-test",
      vec![],
    );

    let Json(snapshot) = get_dashboard_snapshot(State(state))
      .await
      .expect("dashboard snapshot should succeed");

    assert_eq!(snapshot.sessions.len(), 1);
    assert_eq!(snapshot.conversations.len(), 1);
    assert_eq!(snapshot.counts.attention, 0);
    assert_eq!(snapshot.counts.running, 0);
    assert_eq!(snapshot.counts.ready, 1);
    assert_eq!(snapshot.counts.direct, 0);
  }

  #[tokio::test]
  async fn library_snapshot_reads_persisted_sessions() {
    let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
    let session_id = orbitdock_protocol::new_session_id();
    persist_session_fixture(&db_path, &session_id, "/tmp/orbitdock-library-test", vec![]);

    let Json(snapshot) = get_library_snapshot(Query(LibrarySnapshotQuery::default()), State(state))
      .await
      .expect("library snapshot should succeed");

    assert_eq!(snapshot.sessions.len(), 1);
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

    let Json(first_page) = get_library_snapshot(
      Query(LibrarySnapshotQuery {
        limit: Some(1),
        offset: Some(0),
      }),
      State(state.clone()),
    )
    .await
    .expect("first library page should succeed");

    assert_eq!(first_page.sessions.len(), 1);
    assert_eq!(first_page.total_count, 2);
    assert_eq!(first_page.next_offset, Some(1));

    let Json(second_page) = get_library_snapshot(
      Query(LibrarySnapshotQuery {
        limit: Some(1),
        offset: Some(1),
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
  async fn library_snapshot_offset_past_end_returns_empty_page() {
    let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
    let session_id = orbitdock_protocol::new_session_id();
    persist_session_fixture(
      &db_path,
      &session_id,
      "/tmp/orbitdock-library-pagination-offset",
      vec![],
    );

    let Json(page) = get_library_snapshot(
      Query(LibrarySnapshotQuery {
        limit: Some(50),
        offset: Some(5),
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
      Query(ConversationSearchQuery::default()),
      State(state.clone()),
    )
    .await
    .expect_err("runtime-only session should not satisfy DB-backed search");

    assert_eq!(search_status, StatusCode::NOT_FOUND);
    assert_eq!(search_error.code, "not_found");

    let (stats_status, Json(stats_error)) = get_session_stats(Path(session_id), State(state))
      .await
      .expect_err("runtime-only session should not satisfy DB-backed stats");

    assert_eq!(stats_status, StatusCode::NOT_FOUND);
    assert_eq!(stats_error.code, "not_found");
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
