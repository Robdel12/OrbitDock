use std::sync::Arc;

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
  infrastructure::persistence::load_row_by_id_async,
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

fn image_inputs_for_tool(tool: &ToolRow) -> Vec<ImageInput> {
  if !matches!(tool.kind, ToolKind::ViewImage | ToolKind::ImageGeneration) {
    return Vec::new();
  }

  let mut paths = Vec::new();
  collect_image_paths(&tool.invocation, &mut paths);
  if let Some(result) = &tool.result {
    collect_image_paths(result, &mut paths);
  }

  paths
    .into_iter()
    .enumerate()
    .map(|(index, path)| image_input_from_path(path, index))
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
  if let Some(path) = value
    .get("file_path")
    .and_then(|value| value.as_str())
    .or_else(|| value.get("saved_path").and_then(|value| value.as_str()))
  {
    push_unique_path(paths, path);
  }

  if let Some(values) = value.get("image_paths").and_then(|value| value.as_array()) {
    for path in values.iter().filter_map(|value| value.as_str()) {
      push_unique_path(paths, path);
    }
  }
}

fn push_unique_path(paths: &mut Vec<String>, path: &str) {
  if !path.is_empty() && !paths.iter().any(|existing| existing == path) {
    paths.push(path.to_string());
  }
}

fn image_input_from_path(path: String, index: usize) -> ImageInput {
  let metadata = std::fs::metadata(&path).ok();
  let display_name = std::path::Path::new(&path)
    .file_name()
    .and_then(|name| name.to_str())
    .map(ToOwned::to_owned)
    .unwrap_or_else(|| format!("generated-image-{}", index + 1));

  ImageInput {
    input_type: "path".to_string(),
    mime_type: mime_type_for_path(&path).map(ToOwned::to_owned),
    byte_count: metadata.map(|metadata| metadata.len()),
    display_name: Some(display_name),
    pixel_width: None,
    pixel_height: None,
    detail: None,
    value: path,
  }
}

fn mime_type_for_path(path: &str) -> Option<&'static str> {
  match std::path::Path::new(path)
    .extension()
    .and_then(|ext| ext.to_str())
    .map(str::to_ascii_lowercase)
    .as_deref()
  {
    Some("png") => Some("image/png"),
    Some("jpg" | "jpeg") => Some("image/jpeg"),
    Some("gif") => Some("image/gif"),
    Some("webp") => Some("image/webp"),
    Some("heic") => Some("image/heic"),
    Some("heif") => Some("image/heif"),
    Some("svg") => Some("image/svg+xml"),
    Some("bmp") => Some("image/bmp"),
    Some("tif" | "tiff") => Some("image/tiff"),
    _ => None,
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
        images: image_inputs_for_tool(tool),
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
pub(super) fn test_shell_execution_row_content(
  row_id: String,
  shell: &ShellExecutionPayload,
) -> RowContentResponse {
  shell_execution_row_content(row_id, shell)
}

#[cfg(test)]
mod tests {
  use super::image_inputs_for_tool;
  use orbitdock_protocol::conversation_contracts::{RenderHints, ToolRow};
  use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
  use orbitdock_protocol::Provider;
  use serde_json::json;

  #[test]
  fn image_generation_row_content_exposes_saved_path_as_image_ref() {
    let tool = ToolRow {
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
      invocation: json!({
          "revised_prompt": "A tiny dashboard",
          "image_paths": ["/tmp/generated/ig-1.png"],
      }),
      result: Some(json!({
          "output": "Saved generated image to /tmp/generated/ig-1.png",
          "image_paths": ["/tmp/generated/ig-1.png"],
      })),
      render_hints: RenderHints::default(),
      tool_display: None,
      shell_execution: None,
    };

    let images = image_inputs_for_tool(&tool);

    assert_eq!(images.len(), 1);
    assert_eq!(images[0].input_type, "path");
    assert_eq!(images[0].value, "/tmp/generated/ig-1.png");
    assert_eq!(images[0].mime_type.as_deref(), Some("image/png"));
  }
}
