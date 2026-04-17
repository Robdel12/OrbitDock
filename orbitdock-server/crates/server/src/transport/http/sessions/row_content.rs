use std::sync::Arc;

use axum::{
  extract::{Path, State},
  http::StatusCode,
  Json,
};
use orbitdock_protocol::conversation_contracts::{
  compute_diff_display, compute_expanded_output, compute_input_display, detect_language,
  extract_start_line, CommandExecutionRow, ConversationRow,
};

use crate::{
  infrastructure::persistence::load_row_by_id_async,
  runtime::session_registry::SessionRegistry,
  transport::http::{ApiErrorResponse, ApiResult},
};

use super::RowContentResponse;

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
      tracing::error!(
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

      Ok(Json(RowContentResponse {
        row_id,
        input_display: compute_input_display(tool.kind, unwrapped),
        output_display: compute_expanded_output(tool.kind, result_output),
        diff_display: compute_diff_display(tool.kind, unwrapped),
        language: detect_language(tool.kind, unwrapped),
        start_line: extract_start_line(tool.kind, result_output),
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
pub(super) fn test_command_execution_row_content(
  row_id: String,
  row: &CommandExecutionRow,
) -> RowContentResponse {
  command_execution_row_content(row_id, row)
}
