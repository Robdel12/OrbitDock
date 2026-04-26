use std::path::Path;

#[cfg(test)]
use codex_protocol::protocol::{CodexErrorInfo, StreamErrorEvent};
use codex_protocol::protocol::{
  HookOutputEntry, HookRunStatus, HookRunSummary, RealtimeHandoffRequested,
};

pub(crate) fn is_thread_start_skills_trimmed_warning(message: &str) -> bool {
  message.starts_with("Some enabled skills were not included in the model-visible skills list")
    || message.starts_with("Warning: Exceeded skills context budget")
}

#[cfg(test)]
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
    codex_protocol::protocol::HookEventName::PermissionRequest => "permission request",
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
