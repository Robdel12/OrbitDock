use std::path::Path;

use codex_protocol::dynamic_tools::DynamicToolCallOutputContentItem;
use codex_protocol::protocol::{
  CodexErrorInfo, HookOutputEntry, HookRunStatus, HookRunSummary, RealtimeHandoffRequested,
  ReviewOutputEvent, ReviewRequest, ReviewTarget, StreamErrorEvent,
};
use serde_json::json;

pub(crate) fn dynamic_tool_output_to_text(
  content_items: &[DynamicToolCallOutputContentItem],
  fallback_error: Option<String>,
) -> Option<String> {
  let mut lines: Vec<String> = Vec::new();

  for item in content_items {
    match item {
      DynamicToolCallOutputContentItem::InputText { text } => {
        if !text.is_empty() {
          lines.push(text.clone());
        }
      }
      DynamicToolCallOutputContentItem::InputImage { image_url } => {
        lines.push(format!("[image] {}", image_url));
      }
    }
  }

  if lines.is_empty() {
    fallback_error
  } else {
    Some(lines.join("\n"))
  }
}

#[allow(dead_code)]
pub(crate) fn tool_input_with_arguments(
  metadata: serde_json::Value,
  arguments: Option<&serde_json::Value>,
) -> Option<String> {
  let mut payload = match metadata {
    serde_json::Value::Object(object) => object,
    _ => serde_json::Map::new(),
  };

  if let Some(args_value) = arguments {
    payload.insert("arguments".to_string(), args_value.clone());

    if let serde_json::Value::Object(args_object) = args_value {
      for (key, value) in args_object {
        if !payload.contains_key(key) {
          payload.insert(key.clone(), value.clone());
        }
      }
    }
  }

  serde_json::to_string(&serde_json::Value::Object(payload)).ok()
}

#[allow(dead_code)]
pub(crate) fn reasoning_trace_metadata_json(
  reasoning_kind: &'static str,
  stream: &'static str,
  item_id: Option<&str>,
  part_index: Option<i64>,
) -> Option<String> {
  let mut metadata = json!({
      "kind": "reasoning_trace",
      "reasoning_kind": reasoning_kind,
      "stream": stream,
  });

  if let Some(object) = metadata.as_object_mut() {
    if let Some(id) = item_id {
      object.insert("item_id".to_string(), json!(id));
    }
    if let Some(index) = part_index {
      object.insert("part_index".to_string(), json!(index));
    }
  }

  serde_json::to_string(&metadata).ok()
}

pub(crate) fn review_request_summary(request: &ReviewRequest) -> String {
  if let Some(hint) = &request.user_facing_hint {
    let trimmed = hint.trim();
    if !trimmed.is_empty() {
      return trimmed.to_string();
    }
  }

  match &request.target {
    ReviewTarget::UncommittedChanges => "Review uncommitted changes".to_string(),
    ReviewTarget::BaseBranch { branch } => format!("Review changes against branch `{branch}`"),
    ReviewTarget::Commit { sha, title } => {
      if let Some(title) = title {
        let trimmed_title = title.trim();
        if !trimmed_title.is_empty() {
          return format!("Review commit `{sha}` - {trimmed_title}");
        }
      }
      format!("Review commit `{sha}`")
    }
    ReviewTarget::Custom { instructions } => {
      if instructions.trim().is_empty() {
        "Run custom review".to_string()
      } else {
        format!(
          "Custom review\n\n{}",
          truncate_for_display(instructions, 600)
        )
      }
    }
  }
}

pub(crate) fn render_review_output(output: &ReviewOutputEvent) -> String {
  let mut lines: Vec<String> = Vec::new();

  if !output.overall_correctness.trim().is_empty() {
    lines.push(format!(
      "Overall correctness: {}",
      output.overall_correctness.trim()
    ));
  }

  if !output.overall_explanation.trim().is_empty() {
    lines.push(String::new());
    lines.push(output.overall_explanation.trim().to_string());
  }

  lines.push(String::new());
  lines.push(format!(
    "Confidence: {:.2}",
    output.overall_confidence_score
  ));

  if !output.findings.is_empty() {
    lines.push(String::new());
    lines.push(format!("Findings ({})", output.findings.len()));
    for finding in &output.findings {
      let path = finding.code_location.absolute_file_path.display();
      let range = &finding.code_location.line_range;
      lines.push(format!(
        "- [P{}] {} ({path}:{}-{}, confidence {:.2})",
        finding.priority,
        finding.title.trim(),
        range.start,
        range.end,
        finding.confidence_score
      ));
      if !finding.body.trim().is_empty() {
        lines.push(format!("  {}", finding.body.trim()));
      }
    }
  }

  lines.join("\n")
}

pub(crate) fn stream_error_should_surface_to_timeline(event: &StreamErrorEvent) -> bool {
  !matches!(
    event.codex_error_info,
    Some(CodexErrorInfo::ResponseStreamDisconnected { .. })
  )
}

pub(crate) fn realtime_text_from_handoff_request(
  handoff: &RealtimeHandoffRequested,
) -> Option<String> {
  let messages = handoff
    .active_transcript
    .iter()
    .map(|message| {
      let role = message.role.trim();
      let text = message.text.trim();
      if role.is_empty() {
        text.to_string()
      } else {
        format!("{role}: {text}")
      }
    })
    .filter(|value| !value.is_empty())
    .collect::<Vec<_>>();

  if !messages.is_empty() {
    return Some(messages.join("\n"));
  }

  let input = handoff.input_transcript.trim();
  if input.is_empty() {
    None
  } else {
    Some(input.to_string())
  }
}

pub(crate) fn hook_started_text(run: &HookRunSummary) -> String {
  format!(
    "Running {} hook via {}",
    hook_event_label(run),
    hook_source_label(run.source_path.as_path())
  )
}

pub(crate) fn hook_completed_text(run: &HookRunSummary) -> String {
  let base = format!(
    "{} hook {} via {}",
    hook_event_label(run),
    hook_status_label(run.status),
    hook_source_label(run.source_path.as_path())
  );
  match non_empty_trimmed(run.status_message.as_deref()) {
    Some(message) => format!("{base}: {message}"),
    None => base,
  }
}

pub(crate) fn hook_output_text(run: &HookRunSummary) -> Option<String> {
  let mut parts: Vec<String> = run.entries.iter().filter_map(hook_entry_text).collect();
  if let Some(message) = non_empty_trimmed(run.status_message.as_deref()) {
    if !parts.iter().any(|part| part == message) {
      parts.insert(0, message.to_string());
    }
  }
  if parts.is_empty() {
    None
  } else {
    Some(parts.join("\n"))
  }
}

pub(crate) fn hook_run_is_error(status: HookRunStatus) -> bool {
  matches!(
    status,
    HookRunStatus::Failed | HookRunStatus::Blocked | HookRunStatus::Stopped
  )
}

fn non_empty_trimmed(value: Option<&str>) -> Option<&str> {
  value.map(str::trim).filter(|text| !text.is_empty())
}

fn hook_entry_text(entry: &HookOutputEntry) -> Option<String> {
  non_empty_trimmed(Some(entry.text.as_str())).map(ToString::to_string)
}

fn hook_event_label(run: &HookRunSummary) -> &'static str {
  match run.event_name {
    codex_protocol::protocol::HookEventName::PreToolUse => "pre_tool_use",
    codex_protocol::protocol::HookEventName::PostToolUse => "post_tool_use",
    codex_protocol::protocol::HookEventName::SessionStart => "session start",
    codex_protocol::protocol::HookEventName::UserPromptSubmit => "prompt submit",
    codex_protocol::protocol::HookEventName::Stop => "stop",
  }
}

fn hook_source_label(path: &Path) -> String {
  path
    .file_name()
    .and_then(|name| name.to_str())
    .map(ToString::to_string)
    .unwrap_or_else(|| path.display().to_string())
}

fn hook_status_label(status: HookRunStatus) -> &'static str {
  match status {
    HookRunStatus::Running => "running",
    HookRunStatus::Completed => "completed",
    HookRunStatus::Failed => "failed",
    HookRunStatus::Blocked => "blocked",
    HookRunStatus::Stopped => "stopped",
  }
}

fn truncate_for_display(value: &str, max_chars: usize) -> String {
  let trimmed = value.trim();
  if trimmed.chars().count() <= max_chars {
    trimmed.to_string()
  } else {
    format!("{}...", trimmed.chars().take(max_chars).collect::<String>())
  }
}
