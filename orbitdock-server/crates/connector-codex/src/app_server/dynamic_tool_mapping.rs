use orbitdock_connector_core::ConnectorOutput;
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind};
use serde_json::Value;

use super::tool_row_mapping::{duration_millis, map_tool_row};

pub(crate) struct DynamicToolCallArgs {
  pub(crate) id: String,
  pub(crate) namespace: Option<String>,
  pub(crate) tool: String,
  pub(crate) arguments: Value,
  pub(crate) content_items:
    Option<Vec<codex_app_server_protocol::DynamicToolCallOutputContentItem>>,
  pub(crate) success: bool,
  pub(crate) duration_ms: Option<i64>,
  pub(crate) started: bool,
}

pub(crate) fn map_dynamic_tool(args: DynamicToolCallArgs) -> Vec<ConnectorOutput> {
  let DynamicToolCallArgs {
    id,
    namespace,
    tool,
    arguments,
    content_items,
    success,
    duration_ms,
    started,
  } = args;
  if started {
    let (family, kind, title) = dynamic_tool_identity_from_name(&tool).unwrap_or((
      ToolFamily::Generic,
      ToolKind::DynamicToolCall,
      tool.as_str(),
    ));
    return map_tool_row(super::tool_row_mapping::ToolRowArgs {
      id,
      family,
      kind,
      title: title.to_string(),
      summary: None,
      invocation: dynamic_tool_invocation(namespace.clone(), tool, arguments),
      result: None,
      started,
      success,
      duration_ms: duration_millis(duration_ms),
    });
  }

  let output = dynamic_tool_output_to_text(content_items.as_deref());
  let identity_from_name = dynamic_tool_identity_from_name(&tool);
  let resolved_identity = if tool == "plan_write" {
    identity_from_name
  } else {
    dynamic_tool_identity_from_output(output.as_ref()).or(identity_from_name)
  };
  let (family, kind, title) = resolved_identity.unwrap_or((
    ToolFamily::Generic,
    ToolKind::DynamicToolCall,
    tool.as_str(),
  ));
  let (summary, result) =
    dynamic_tool_result_payload(tool.as_str(), kind, &arguments, output.as_ref());

  map_tool_row(super::tool_row_mapping::ToolRowArgs {
    id,
    family,
    kind,
    title: title.to_string(),
    summary,
    invocation: dynamic_tool_invocation(namespace, tool, arguments),
    result: Some(result),
    started,
    success,
    duration_ms: duration_millis(duration_ms),
  })
}

fn dynamic_tool_invocation(
  namespace: Option<String>,
  tool_name: String,
  arguments: Value,
) -> Value {
  serde_json::json!({
    "namespace": namespace,
    "tool_name": tool_name,
    "raw_input": arguments,
  })
}

fn dynamic_tool_output_to_text(
  content_items: Option<&[codex_app_server_protocol::DynamicToolCallOutputContentItem]>,
) -> Option<String> {
  let mut lines = Vec::new();
  for item in content_items.unwrap_or_default() {
    match item {
      codex_app_server_protocol::DynamicToolCallOutputContentItem::InputText { text }
        if !text.is_empty() =>
      {
        lines.push(text.clone());
      }
      codex_app_server_protocol::DynamicToolCallOutputContentItem::InputImage { image_url } => {
        lines.push(format!("[image] {image_url}"));
      }
      codex_app_server_protocol::DynamicToolCallOutputContentItem::InputText { .. } => {}
    }
  }
  (!lines.is_empty()).then(|| lines.join("\n"))
}

fn dynamic_tool_identity_from_name(
  tool_name: &str,
) -> Option<(ToolFamily, ToolKind, &'static str)> {
  match tool_name {
    "file_read" => Some((ToolFamily::FileRead, ToolKind::Read, "Read")),
    "file_write" => Some((ToolFamily::FileChange, ToolKind::Write, "Write")),
    "file_edit" => Some((ToolFamily::FileChange, ToolKind::Edit, "Edit")),
    "plan_write" => Some((ToolFamily::Plan, ToolKind::Write, "Plan")),
    _ => None,
  }
}

fn dynamic_tool_identity_from_output(
  output: Option<&String>,
) -> Option<(ToolFamily, ToolKind, &'static str)> {
  let object = dynamic_tool_raw_output_value(output)?;
  let object = object.as_object()?;
  if object.contains_key("bytes_written") {
    return Some((ToolFamily::FileChange, ToolKind::Write, "Write"));
  }
  if object.contains_key("replacements") {
    return Some((ToolFamily::FileChange, ToolKind::Edit, "Edit"));
  }
  if object.contains_key("content") && object.contains_key("truncated") {
    return Some((ToolFamily::FileRead, ToolKind::Read, "Read"));
  }
  None
}

fn dynamic_tool_raw_output_value(output: Option<&String>) -> Option<Value> {
  let output = output?;
  match serde_json::from_str::<Value>(output).ok() {
    Some(Value::String(inner)) => serde_json::from_str::<Value>(&inner)
      .ok()
      .or(Some(Value::String(inner))),
    Some(parsed) => Some(parsed),
    None => Some(Value::String(output.clone())),
  }
}

fn dynamic_tool_result_payload(
  tool_name: &str,
  kind: ToolKind,
  arguments: &Value,
  output: Option<&String>,
) -> (Option<String>, Value) {
  let raw_output = dynamic_tool_raw_output_value(output);
  let object = raw_output.as_ref().and_then(Value::as_object);
  let path = object
    .and_then(|map| map.get("path"))
    .and_then(Value::as_str)
    .map(ToOwned::to_owned);
  let replacements = object
    .and_then(|map| map.get("replacements"))
    .and_then(Value::as_u64);
  let bytes_written = object
    .and_then(|map| map.get("bytes_written"))
    .and_then(Value::as_u64);
  let read_content = object
    .and_then(|map| map.get("content"))
    .and_then(Value::as_str)
    .map(ToOwned::to_owned);
  let read_truncated = object
    .and_then(|map| map.get("truncated"))
    .and_then(Value::as_bool);

  let output_text = match kind {
    ToolKind::Read => read_content.clone(),
    ToolKind::Write => bytes_written
      .map(|count| {
        if tool_name == "plan_write" {
          path
            .as_deref()
            .map(|value| format!("Saved plan ({count} bytes) to {value}"))
            .unwrap_or_else(|| format!("Saved plan ({count} bytes)"))
        } else {
          path
            .as_deref()
            .map(|value| format!("Wrote {count} bytes to {value}"))
            .unwrap_or_else(|| format!("Wrote {count} bytes"))
        }
      })
      .or_else(|| output.cloned()),
    ToolKind::Edit => replacements
      .map(|count| {
        path
          .as_deref()
          .map(|value| format!("Applied {count} replacement(s) in {value}"))
          .unwrap_or_else(|| format!("Applied {count} replacement(s)"))
      })
      .or_else(|| output.cloned()),
    _ => output.cloned(),
  };

  let summary = match kind {
    ToolKind::Read => path
      .as_deref()
      .map(|value| format!("Read {value}"))
      .or_else(|| Some("Read file".to_string())),
    ToolKind::Write | ToolKind::Edit => output_text.clone().or_else(|| output.cloned()),
    _ => output.cloned(),
  };

  let mut result = serde_json::Map::new();
  result.insert("tool_name".to_string(), serde_json::json!(tool_name));
  result.insert(
    "raw_input".to_string(),
    serde_json::json!(arguments.clone()),
  );
  if let Some(raw_output) = raw_output {
    result.insert("raw_output".to_string(), raw_output);
  }
  if let Some(summary_text) = summary.as_ref() {
    result.insert("summary".to_string(), serde_json::json!(summary_text));
  }
  if let Some(output_text) = output_text.as_ref() {
    result.insert("output".to_string(), serde_json::json!(output_text));
  }
  if let Some(path) = path.as_ref() {
    result.insert("path".to_string(), serde_json::json!(path));
  }
  if let Some(bytes_written) = bytes_written {
    result.insert(
      "bytes_written".to_string(),
      serde_json::json!(bytes_written),
    );
  }
  if let Some(replacements) = replacements {
    result.insert("replacements".to_string(), serde_json::json!(replacements));
  }
  if let Some(truncated) = read_truncated {
    result.insert("truncated".to_string(), serde_json::json!(truncated));
  }

  (summary, Value::Object(result))
}
