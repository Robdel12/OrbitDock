use std::{path::Path as StdPath, sync::Arc};

use axum::{
  extract::{Path, State},
  http::StatusCode,
  Json,
};
use orbitdock_protocol::conversation_contracts::{
  compute_diff_display, compute_expanded_output, compute_input_display, detect_language,
  extract_start_line, ConversationRow, ShellExecutionPayload, ToolRow,
};
use orbitdock_protocol::{domain_events::ToolKind, ImageInput};

use crate::{
  infrastructure::{images::materialize_artifact_path, persistence::load_row_by_id_async},
  runtime::session_registry::SessionRegistry,
  transport::http::{ApiErrorResponse, ApiResult},
};

use super::RowContentResponse;

fn shell_execution_row_content(
  row_id: String,
  shell: &ShellExecutionPayload,
) -> RowContentResponse {
  RowContentResponse {
    row_id,
    input_display: Some(shell.command.clone()),
    output_display: shell.output_text(),
    images: Vec::new(),
    diff_display: None,
    language: None,
    start_line: None,
  }
}

fn image_inputs_for_tool(session_id: &str, tool: &ToolRow) -> Vec<ImageInput> {
  if !matches!(tool.kind, ToolKind::ViewImage | ToolKind::ImageGeneration) {
    return Vec::new();
  }

  let mut paths = Vec::new();
  for value in std::iter::once(&tool.invocation).chain(tool.result.iter()) {
    collect_image_paths(value, &mut paths);
  }

  paths
    .into_iter()
    .enumerate()
    .filter_map(|(index, path)| image_input_from_path(session_id, path, index))
    .collect()
}

fn tool_invocation_input(tool: &ToolRow) -> Option<&serde_json::Value> {
  tool
    .invocation
    .get("raw_input")
    .filter(|raw_input| raw_input.is_object())
    .or(Some(&tool.invocation))
}

fn tool_result_output(tool: &ToolRow) -> Option<&str> {
  tool.result.as_ref().and_then(|result| {
    result
      .get("output")
      .and_then(|value| value.as_str())
      .or_else(|| result.get("raw_output").and_then(|value| value.as_str()))
  })
}

fn collect_image_paths(value: &serde_json::Value, paths: &mut Vec<String>) {
  for key in ["file_path", "saved_path"] {
    if let Some(path) = value.get(key).and_then(serde_json::Value::as_str) {
      push_unique_path(paths, path);
    }
  }

  if let Some(values) = value
    .get("image_paths")
    .and_then(serde_json::Value::as_array)
  {
    for path in values.iter().filter_map(serde_json::Value::as_str) {
      push_unique_path(paths, path);
    }
  }
}

fn push_unique_path(paths: &mut Vec<String>, path: &str) {
  if !path.is_empty() && !paths.iter().any(|existing| existing == path) {
    paths.push(path.to_string());
  }
}

fn image_input_from_path(session_id: &str, path: String, index: usize) -> Option<ImageInput> {
  match materialize_artifact_path(session_id, StdPath::new(&path)) {
    Ok(mut image) => {
      if image.display_name.is_none() {
        image.display_name = Some(format!("generated-image-{}", index + 1));
      }
      Some(image)
    }
    Err(error) => {
      tracing::warn!(
        event = "api.get_row_content.image_artifact_unavailable",
        session_id = %session_id,
        path = %path,
        error = %error,
        "Failed to expose image artifact as a managed attachment"
      );
      None
    }
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
      if let Some(shell) = &tool.shell_execution {
        return Ok(Json(shell_execution_row_content(row_id, shell)));
      }

      let invocation_input = tool_invocation_input(tool);
      let result_output = tool_result_output(tool);

      Ok(Json(RowContentResponse {
        row_id,
        input_display: compute_input_display(tool.kind, invocation_input),
        output_display: compute_expanded_output(tool.kind, result_output),
        images: image_inputs_for_tool(&session_id, tool),
        diff_display: compute_diff_display(tool.kind, invocation_input),
        language: detect_language(tool.kind, invocation_input),
        start_line: extract_start_line(tool.kind, result_output),
      }))
    }
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
  use super::image_inputs_for_tool;
  use crate::support::test_support::ensure_server_test_data_dir;
  use orbitdock_protocol::conversation_contracts::{RenderHints, ToolRow};
  use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
  use orbitdock_protocol::Provider;
  use serde_json::json;
  use serde_json::Value;
  use std::fs;

  #[test]
  fn image_generation_row_content_exposes_saved_path_as_attachment_ref() {
    ensure_server_test_data_dir();
    let temp = tempfile::tempdir().expect("tempdir");
    let image_path = temp.path().join("ig-1.png");
    fs::write(&image_path, b"image-bytes").expect("write test image");
    let image_path = image_path.to_string_lossy().to_string();

    let tool = image_generation_tool(
      json!({
          "revised_prompt": "A tiny dashboard",
          "image_paths": [image_path.clone()],
      }),
      Some(json!({
          "output": "Saved generated image",
          "image_paths": [image_path],
      })),
    );

    let images = image_inputs_for_tool("session-1", &tool);

    assert_eq!(images.len(), 1);
    assert_eq!(images[0].input_type, "attachment");
    assert!(images[0].value.starts_with("orbitdock-image-"));
    assert_eq!(images[0].mime_type.as_deref(), Some("image/png"));
    assert_eq!(images[0].byte_count, Some(11));
    assert_eq!(images[0].display_name.as_deref(), Some("ig-1.png"));
  }

  #[test]
  fn image_generation_row_content_skips_unreadable_saved_path() {
    ensure_server_test_data_dir();
    let temp = tempfile::tempdir().expect("tempdir");
    let image_path = temp
      .path()
      .join("missing.png")
      .to_string_lossy()
      .to_string();
    let tool = image_generation_tool(
      json!({
          "image_paths": [image_path],
      }),
      None,
    );

    let images = image_inputs_for_tool("session-1", &tool);

    assert!(images.is_empty());
  }

  fn image_generation_tool(invocation: Value, result: Option<Value>) -> ToolRow {
    ToolRow {
      id: "ig-1".to_string(),
      provider: Provider::Codex,
      family: ToolFamily::Image,
      kind: ToolKind::ImageGeneration,
      status: ToolStatus::Completed,
      title: "Image generation".to_string(),
      subtitle: None,
      summary: None,
      preview: None,
      started_at: None,
      ended_at: None,
      duration_ms: None,
      grouping_key: None,
      invocation,
      result,
      render_hints: RenderHints::default(),
      tool_display: None,
      shell_execution: None,
    }
  }
}
