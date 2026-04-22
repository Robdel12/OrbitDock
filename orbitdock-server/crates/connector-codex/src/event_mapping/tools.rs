use super::{
  row_created_output, row_updated_output, runtime_output, shell_execution_payload, state_output,
  tool_row_entry, transport_output, ConnectorOutputs, SharedEnvironmentTracker,
  SharedOutputBuffers, SharedPatchContexts,
};
use crate::timeline::dynamic_tool_output_to_text;
use crate::workers::iso_now;
use codex_protocol::dynamic_tools::DynamicToolCallRequest;
use codex_protocol::parse_command::ParsedCommand;
use codex_protocol::protocol::DynamicToolCallResponseEvent;
use codex_protocol::protocol::{
  ExecCommandBeginEvent, ExecCommandEndEvent, ExecCommandOutputDeltaEvent, FileChange,
  ImageGenerationBeginEvent, ImageGenerationEndEvent, McpToolCallBeginEvent, McpToolCallEndEvent,
  PatchApplyBeginEvent, PatchApplyEndEvent, PatchApplyUpdatedEvent, TerminalInteractionEvent,
  ViewImageToolCallEvent, WebSearchBeginEvent, WebSearchEndEvent,
};
use orbitdock_connector_core::{
  ConnectorRuntimeDirective, ConnectorStateEvent, ConnectorTransportEffect,
};
use orbitdock_protocol::conversation_contracts::render_hints::RenderHints;
use orbitdock_protocol::conversation_contracts::{ShellAction, ToolRow};
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
use orbitdock_protocol::Provider;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Instant;

const OUTPUT_STREAM_THROTTLE_MS: u128 = 120;

fn combined_exec_stdio(stdout: &str, stderr: &str) -> Option<String> {
  let stdout = stdout.trim();
  let stderr = stderr.trim();

  match (stdout.is_empty(), stderr.is_empty()) {
    (true, true) => None,
    (false, true) => Some(format!("{}\n", stdout)),
    (true, false) => Some(format!("{}\n", stderr)),
    (false, false) => Some(format!("stdout:\n{}\n\nstderr:\n{}\n", stdout, stderr)),
  }
}

fn terminal_exec_output(event: &ExecCommandEndEvent, streamed_output: String) -> Option<String> {
  let preferred = [
    (!event.aggregated_output.trim().is_empty()).then(|| event.aggregated_output.clone()),
    (!event.formatted_output.trim().is_empty()).then(|| event.formatted_output.clone()),
    combined_exec_stdio(&event.stdout, &event.stderr),
  ]
  .into_iter()
  .flatten()
  .next();

  let streamed = (!streamed_output.trim().is_empty()).then_some(streamed_output);
  match (preferred, streamed) {
    (None, None) => None,
    (Some(preferred), None) => Some(preferred),
    (None, Some(streamed)) => Some(streamed),
    (Some(preferred), Some(streamed)) => {
      // Some runtimes send a compact aggregated payload even when the live
      // stream captured significantly richer output. Prefer the richer stream
      // when it is materially larger to avoid clipped expanded cards.
      let materially_larger = streamed.len() > preferred.len().saturating_add(256)
        || streamed.len() > preferred.len().saturating_mul(2);
      if materially_larger {
        Some(streamed)
      } else {
        Some(preferred)
      }
    }
  }
}

fn tool_status_from_exec_end(event: &ExecCommandEndEvent) -> ToolStatus {
  match event.status {
    codex_protocol::protocol::ExecCommandStatus::Declined => ToolStatus::Cancelled,
    codex_protocol::protocol::ExecCommandStatus::Failed => ToolStatus::Failed,
    codex_protocol::protocol::ExecCommandStatus::Completed => {
      if event.exit_code == 0 {
        ToolStatus::Completed
      } else {
        ToolStatus::Failed
      }
    }
  }
}

fn expandable_command_render_hints() -> RenderHints {
  RenderHints {
    can_expand: true,
    default_expanded: false,
    emphasized: false,
    monospace_summary: false,
    accent_tone: None,
  }
}

fn expandable_image_render_hints() -> RenderHints {
  RenderHints {
    can_expand: true,
    default_expanded: false,
    emphasized: false,
    monospace_summary: false,
    accent_tone: Some("accent".to_string()),
  }
}

fn image_generation_status(status: &str) -> ToolStatus {
  match status {
    "completed" | "succeeded" | "success" => ToolStatus::Completed,
    "failed" | "error" => ToolStatus::Failed,
    "cancelled" | "canceled" => ToolStatus::Cancelled,
    "queued" | "pending" => ToolStatus::Pending,
    _ => ToolStatus::Running,
  }
}

fn image_generation_saved_path(event: &ImageGenerationEndEvent) -> Option<String> {
  event
    .saved_path
    .as_ref()
    .map(|path| path.to_string_lossy().to_string())
    .filter(|path| !path.is_empty())
}

fn image_generation_summary(status: ToolStatus, saved_path: Option<&str>) -> String {
  match (status, saved_path) {
    (ToolStatus::Completed, Some(_)) => "Generated image".to_string(),
    (ToolStatus::Completed, None) => "Generated image metadata".to_string(),
    (ToolStatus::Failed, _) => "Image generation failed".to_string(),
    (ToolStatus::Cancelled, _) => "Image generation cancelled".to_string(),
    _ => "Generating image".to_string(),
  }
}

fn image_generation_output(status: ToolStatus, saved_path: Option<&str>) -> String {
  match (status, saved_path) {
    (ToolStatus::Completed, Some(path)) => format!("Saved generated image to {path}"),
    (ToolStatus::Completed, None) => {
      "Image generation completed, but Codex did not provide a saved image path.".to_string()
    }
    (ToolStatus::Failed, _) => "Image generation failed.".to_string(),
    (ToolStatus::Cancelled, _) => "Image generation was cancelled.".to_string(),
    _ => "Image generation is still running.".to_string(),
  }
}

fn image_generation_revised_prompt(event: &ImageGenerationEndEvent) -> Option<&str> {
  event
    .revised_prompt
    .as_deref()
    .filter(|value| !value.is_empty())
}

fn shell_actions_from_parsed(parsed_cmd: &[ParsedCommand]) -> Vec<ShellAction> {
  parsed_cmd
    .iter()
    .map(|command| match command {
      ParsedCommand::Read { cmd, name, path } => ShellAction::Read {
        command: cmd.clone(),
        name: name.clone(),
        path: path.display().to_string(),
      },
      ParsedCommand::ListFiles { cmd, path } => ShellAction::ListFiles {
        command: cmd.clone(),
        path: path.clone(),
      },
      ParsedCommand::Search { cmd, query, path } => ShellAction::Search {
        command: cmd.clone(),
        query: query.clone(),
        path: path.clone(),
      },
      ParsedCommand::Unknown { cmd } => ShellAction::Unknown {
        command: cmd.clone(),
      },
    })
    .collect()
}

fn command_token_basename(token: &str) -> String {
  std::path::Path::new(token)
    .file_name()
    .map(|name| name.to_string_lossy().to_string())
    .unwrap_or_else(|| token.to_string())
    .to_ascii_lowercase()
}

fn strip_env_wrapper_tokens(command: &[String]) -> &[String] {
  let Some(first) = command.first() else {
    return command;
  };
  if command_token_basename(first.as_str()) != "env" {
    return command;
  }

  let mut index = 1;
  while index < command.len() {
    let token = command[index].as_str();
    if token == "-u" {
      index += if index + 1 < command.len() { 2 } else { 1 };
      continue;
    }
    if token.starts_with('-') {
      index += 1;
      continue;
    }
    if token.contains('=') {
      index += 1;
      continue;
    }
    break;
  }

  command.get(index..).unwrap_or_default()
}

fn shell_payload_index(command: &[String]) -> Option<usize> {
  let first = command.first()?;
  let shell = command_token_basename(first.as_str());

  if matches!(
    shell.as_str(),
    "sh" | "bash" | "zsh" | "dash" | "ksh" | "mksh" | "ash" | "fish" | "csh" | "tcsh"
  ) {
    for (index, token) in command.iter().enumerate().skip(1) {
      if token == "--" {
        continue;
      }
      if let Some(flags) = token.strip_prefix('-') {
        if token.starts_with("--") || flags.is_empty() {
          continue;
        }
        if flags.chars().all(|ch| ch.is_ascii_alphabetic()) && flags.contains('c') {
          return (index + 1 < command.len()).then_some(index + 1);
        }
        continue;
      }
      break;
    }
  }

  if matches!(
    shell.as_str(),
    "pwsh" | "pwsh.exe" | "powershell" | "powershell.exe"
  ) {
    for (index, token) in command.iter().enumerate().skip(1) {
      let lower = token.to_ascii_lowercase();
      if lower == "-command" || lower == "-c" {
        return (index + 1 < command.len()).then_some(index + 1);
      }
    }
  }

  if matches!(shell.as_str(), "cmd" | "cmd.exe") {
    for (index, token) in command.iter().enumerate().skip(1) {
      let lower = token.to_ascii_lowercase();
      if lower == "/c" || lower == "/k" {
        return (index + 1 < command.len()).then_some(index + 1);
      }
    }
  }

  None
}

fn display_command_from_exec_tokens(command: &[String]) -> String {
  let stripped = strip_env_wrapper_tokens(command);
  if let Some(index) = shell_payload_index(stripped) {
    let inner = stripped[index..].join(" ").trim().to_string();
    if !inner.is_empty() {
      return inner;
    }
  }
  command.join(" ")
}

fn summarize_shell_output(output: &str) -> String {
  const MAX_SUMMARY_CHARS: usize = 100;
  if output.chars().count() <= MAX_SUMMARY_CHARS {
    return output.to_string();
  }

  let truncated: String = output.chars().take(MAX_SUMMARY_CHARS).collect();
  format!("{truncated}...")
}

fn patch_apply_context_from_changes(
  changes: &std::collections::HashMap<std::path::PathBuf, FileChange>,
) -> (Vec<String>, Value) {
  let mut changes = changes.iter().collect::<Vec<_>>();
  changes.sort_by(|(left, _), (right, _)| left.cmp(right));

  let files = changes
    .iter()
    .map(|(path, _)| path.display().to_string())
    .collect::<Vec<_>>();
  let unified_diff = changes
    .iter()
    .map(|(path, change)| file_change_unified_diff(path, change))
    .collect::<Vec<_>>()
    .join("\n\n");

  let first_file = files.first().cloned().unwrap_or_default();
  (
    files,
    json!({
      "path": first_file,
      "diff": unified_diff,
    }),
  )
}

fn file_change_unified_diff(path: &std::path::Path, change: &FileChange) -> String {
  match change {
    FileChange::Add { content } => {
      format!(
        "--- /dev/null\n+++ {}\n{}",
        path.display(),
        content
          .lines()
          .map(|line| format!("+{}", line))
          .collect::<Vec<_>>()
          .join("\n")
      )
    }
    FileChange::Delete { content } => {
      format!(
        "--- {}\n+++ /dev/null\n{}",
        path.display(),
        content
          .lines()
          .map(|line| format!("-{}", line))
          .collect::<Vec<_>>()
          .join("\n")
      )
    }
    FileChange::Update { unified_diff, .. } => {
      format!(
        "--- {}\n+++ {}\n{}",
        path.display(),
        path.display(),
        unified_diff
      )
    }
  }
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
  let parsed = dynamic_tool_raw_output_value(output)?;
  let object = parsed.as_object()?;
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
  result.insert("tool_name".to_string(), json!(tool_name));
  result.insert("raw_input".to_string(), arguments.clone());
  if let Some(raw_output) = raw_output {
    result.insert("raw_output".to_string(), raw_output);
  }
  if let Some(summary_text) = summary.as_ref() {
    result.insert("summary".to_string(), json!(summary_text));
  }
  if let Some(output_text) = output_text.as_ref() {
    result.insert("output".to_string(), json!(output_text));
  }
  if let Some(path) = path.as_ref() {
    result.insert("path".to_string(), json!(path));
  }
  if let Some(bytes_written) = bytes_written {
    result.insert("bytes_written".to_string(), json!(bytes_written));
  }
  if let Some(replacements) = replacements {
    result.insert("replacements".to_string(), json!(replacements));
  }
  if let Some(truncated) = read_truncated {
    result.insert("truncated".to_string(), json!(truncated));
  }

  (summary, Value::Object(result))
}

pub(crate) async fn handle_exec_command_begin(
  event: ExecCommandBeginEvent,
  output_buffers: &SharedOutputBuffers,
  env_tracker: &SharedEnvironmentTracker,
  current_cwd: &Arc<tokio::sync::Mutex<String>>,
) -> ConnectorOutputs {
  let command_str = display_command_from_exec_tokens(&event.command);
  let cwd = event.cwd.display().to_string();
  let shell_actions = shell_actions_from_parsed(&event.parsed_cmd);

  {
    let mut buffers = output_buffers.lock().await;
    buffers.insert(
      event.call_id.clone(),
      super::OutputBufferState {
        command: command_str.clone(),
        cwd: cwd.clone(),
        process_id: event.process_id.clone(),
        command_actions: shell_actions.clone(),
        ..Default::default()
      },
    );
  }

  let new_cwd = event.cwd.to_string_lossy().to_string();
  {
    let mut cwd = current_cwd.lock().await;
    *cwd = new_cwd.clone();
  }
  let git_info = codex_git_utils::collect_git_info(&event.cwd).await;
  let (new_branch, new_sha) = match git_info {
    Some(info) => (info.branch, info.commit_hash.map(|s| s.0)),
    None => (None, None),
  };

  let mut connector_events: ConnectorOutputs = Vec::new();
  {
    let mut tracker = env_tracker.lock().await;
    let cwd_changed = tracker.cwd.as_deref() != Some(&new_cwd);
    let branch_changed = tracker.branch != new_branch;
    let sha_changed = tracker.sha != new_sha;
    if cwd_changed || branch_changed || sha_changed {
      tracker.cwd = Some(new_cwd.clone());
      tracker.branch = new_branch.clone();
      tracker.sha = new_sha.clone();
      connector_events.push(state_output(ConnectorStateEvent::EnvironmentChanged {
        cwd: Some(new_cwd.clone()),
        git_branch: new_branch,
        git_sha: new_sha,
      }));
    }
  }

  // Emit ToolPtyCreated so the UI can attach live PTY streaming immediately.
  connector_events.push(transport_output(ConnectorTransportEffect::ToolPtyCreated {
    tool_id: event.call_id.clone(),
  }));

  connector_events.push(row_created_output(tool_row_entry(ToolRow {
    id: event.call_id.clone(),
    provider: Provider::Codex,
    family: ToolFamily::Shell,
    kind: ToolKind::Bash,
    status: ToolStatus::Running,
    title: command_str.clone(),
    subtitle: Some(cwd.clone()),
    summary: None,
    preview: None,
    started_at: Some(iso_now()),
    ended_at: None,
    duration_ms: None,
    grouping_key: None,
    invocation: json!({
      "command": command_str.clone(),
      "cwd": cwd.clone(),
    }),
    result: None,
    render_hints: expandable_command_render_hints(),
    tool_display: None,
    shell_execution: Some(shell_execution_payload(
      command_str,
      cwd,
      event.process_id,
      shell_actions,
      None,
      None,
      None,
    )),
  })));

  connector_events
}

pub(crate) async fn handle_exec_command_output_delta(
  event: ExecCommandOutputDeltaEvent,
  output_buffers: &SharedOutputBuffers,
) -> ConnectorOutputs {
  let mut events: ConnectorOutputs = Vec::new();

  // Always emit raw bytes for live PTY streaming (no throttle)
  if !event.chunk.is_empty() {
    events.push(transport_output(ConnectorTransportEffect::ToolPtyOutput {
      tool_id: event.call_id.clone(),
      bytes: event.chunk.clone(),
    }));
  }

  // Text-based row updates are throttled for UI performance
  let chunk_str = String::from_utf8_lossy(&event.chunk).to_string();
  let (should_broadcast, shell_payload) = {
    let mut buffers = output_buffers.lock().await;
    if let Some(buffer) = buffers.get_mut(&event.call_id) {
      buffer.append(&chunk_str);
      let now = Instant::now();
      if now.duration_since(buffer.last_broadcast).as_millis() < OUTPUT_STREAM_THROTTLE_MS {
        return events;
      }
      buffer.last_broadcast = now;
      let live_preview = buffer.preview();
      let has_preview = live_preview.is_some();
      (
        has_preview,
        shell_execution_payload(
          buffer.command.clone(),
          buffer.cwd.clone(),
          buffer.process_id.clone(),
          buffer.command_actions.clone(),
          live_preview.clone(),
          None,
          None,
        ),
      )
    } else {
      return events;
    }
  };

  if should_broadcast {
    let entry = tool_row_entry(ToolRow {
      id: event.call_id.clone(),
      provider: Provider::Codex,
      family: ToolFamily::Shell,
      kind: ToolKind::Bash,
      status: ToolStatus::Running,
      title: shell_payload.command.clone(),
      subtitle: Some(shell_payload.cwd.clone()),
      summary: None,
      preview: None,
      started_at: None,
      ended_at: None,
      duration_ms: None,
      grouping_key: None,
      invocation: json!({
        "command": shell_payload.command.clone(),
        "cwd": shell_payload.cwd.clone(),
      }),
      result: None,
      render_hints: expandable_command_render_hints(),
      tool_display: None,
      shell_execution: Some(shell_payload),
    });
    events.push(row_updated_output(event.call_id, entry));
  }

  events
}

pub(crate) async fn handle_exec_command_end(
  event: ExecCommandEndEvent,
  output_buffers: &SharedOutputBuffers,
) -> ConnectorOutputs {
  let streamed_output = {
    let mut buffers = output_buffers.lock().await;
    buffers
      .remove(&event.call_id)
      .map(|state| state.full_output)
      .unwrap_or_default()
  };

  let duration_ms = Some(event.duration.as_millis() as u64);
  let status = tool_status_from_exec_end(&event);
  let shell_actions = shell_actions_from_parsed(&event.parsed_cmd);
  let command = display_command_from_exec_tokens(&event.command);
  let cwd = event.cwd.display().to_string();
  let aggregated_output = terminal_exec_output(&event, streamed_output);

  let entry = tool_row_entry(ToolRow {
    id: event.call_id.clone(),
    provider: Provider::Codex,
    family: ToolFamily::Shell,
    kind: ToolKind::Bash,
    status,
    title: command.clone(),
    subtitle: Some(cwd.clone()),
    summary: aggregated_output
      .as_ref()
      .map(|output| summarize_shell_output(output)),
    preview: None,
    started_at: None,
    ended_at: Some(iso_now()),
    duration_ms,
    grouping_key: None,
    invocation: json!({
      "command": command.clone(),
      "cwd": cwd.clone(),
    }),
    result: aggregated_output.as_ref().map(|output| {
      json!({
        "tool_name": "Bash",
        "output": output,
        "exit_code": event.exit_code,
      })
    }),
    render_hints: expandable_command_render_hints(),
    tool_display: None,
    shell_execution: Some(shell_execution_payload(
      command,
      cwd,
      event.process_id,
      shell_actions,
      None,
      aggregated_output,
      Some(event.exit_code),
    )),
  });

  vec![
    transport_output(ConnectorTransportEffect::ToolPtyExited {
      tool_id: event.call_id.clone(),
      exit_code: Some(event.exit_code),
    }),
    row_updated_output(event.call_id, entry),
  ]
}

pub(crate) async fn handle_patch_apply_begin(
  event: PatchApplyBeginEvent,
  patch_contexts: &SharedPatchContexts,
) -> ConnectorOutputs {
  let (files, invocation) = patch_apply_context_from_changes(&event.changes);
  let first_file = files.first().cloned().unwrap_or_default();

  {
    let mut contexts = patch_contexts.lock().await;
    contexts.insert(event.call_id.clone(), invocation.clone());
  }

  vec![row_created_output(tool_row_entry(ToolRow {
    id: event.call_id.clone(),
    provider: Provider::Codex,
    family: ToolFamily::FileChange,
    kind: ToolKind::Edit,
    status: ToolStatus::Running,
    title: first_file.clone(),
    subtitle: Some(files.join(", ")),
    summary: None,
    preview: None,
    started_at: Some(iso_now()),
    ended_at: None,
    duration_ms: None,
    grouping_key: None,
    invocation,
    result: None,
    render_hints: Default::default(),
    tool_display: None,
    shell_execution: None,
  }))]
}

pub(crate) async fn handle_patch_apply_updated(
  event: PatchApplyUpdatedEvent,
  patch_contexts: &SharedPatchContexts,
) -> ConnectorOutputs {
  let (files, invocation) = patch_apply_context_from_changes(&event.changes);
  let first_file = files.first().cloned().unwrap_or_default();

  {
    let mut contexts = patch_contexts.lock().await;
    contexts.insert(event.call_id.clone(), invocation.clone());
  }

  vec![row_updated_output(
    event.call_id.clone(),
    tool_row_entry(ToolRow {
      id: event.call_id,
      provider: Provider::Codex,
      family: ToolFamily::FileChange,
      kind: ToolKind::Edit,
      status: ToolStatus::Running,
      title: first_file,
      subtitle: Some(files.join(", ")),
      summary: Some("Patch updated".to_string()),
      preview: None,
      started_at: None,
      ended_at: None,
      duration_ms: None,
      grouping_key: None,
      invocation,
      result: None,
      render_hints: Default::default(),
      tool_display: None,
      shell_execution: None,
    }),
  )]
}

pub(crate) async fn handle_patch_apply_end(
  event: PatchApplyEndEvent,
  patch_contexts: &SharedPatchContexts,
) -> ConnectorOutputs {
  // Retrieve the begin context (removes it from the map)
  let begin_context = {
    let mut contexts = patch_contexts.lock().await;
    contexts.remove(&event.call_id)
  };

  let mut output_lines: Vec<String> = Vec::new();
  output_lines.push(format!("status: {:?}", event.status));
  if event.success {
    output_lines.push("result: applied successfully".to_string());
  } else {
    output_lines.push("result: failed".to_string());
  }
  if !event.stdout.trim().is_empty() {
    output_lines.push(String::new());
    output_lines.push("stdout:".to_string());
    output_lines.push(event.stdout);
  }
  if !event.stderr.trim().is_empty() {
    output_lines.push(String::new());
    output_lines.push("stderr:".to_string());
    output_lines.push(event.stderr);
  }
  let output = output_lines.join("\n");

  let status = if event.success {
    ToolStatus::Completed
  } else {
    ToolStatus::Failed
  };

  // Merge begin context (path + diff) into the end invocation
  let invocation = if let Some(ctx) = begin_context {
    json!({
        "path": ctx.get("path").and_then(|v| v.as_str()).unwrap_or(""),
        "diff": ctx.get("diff").and_then(|v| v.as_str()).unwrap_or(""),
        "summary": output.clone(),
    })
  } else {
    json!({
        "summary": output.clone(),
    })
  };

  let entry = tool_row_entry(ToolRow {
    id: event.call_id.clone(),
    provider: Provider::Codex,
    family: ToolFamily::FileChange,
    kind: ToolKind::Edit,
    status,
    title: String::new(),
    subtitle: None,
    summary: Some(output.clone()),
    preview: None,
    started_at: None,
    ended_at: Some(iso_now()),
    duration_ms: None,
    grouping_key: None,
    invocation,
    result: Some(json!({
        "tool_name": "Edit",
        "output": output,
    })),
    render_hints: Default::default(),
    tool_display: None,
    shell_execution: None,
  });
  vec![row_updated_output(event.call_id, entry)]
}

pub(crate) fn handle_mcp_tool_call_begin(event: McpToolCallBeginEvent) -> ConnectorOutputs {
  let server = event.invocation.server.clone();
  let tool = event.invocation.tool.clone();
  let call_id = event.call_id.clone();
  let mut invocation = json!({
      "server": server,
      "tool_name": tool,
      "input": event
          .invocation
          .arguments
          .as_ref()
          .and_then(|args| serde_json::to_value(args).ok()),
  });
  if let Some(resource_uri) = event.mcp_app_resource_uri {
    invocation["mcp_app_resource_uri"] = json!(resource_uri);
  }

  vec![row_created_output(tool_row_entry(ToolRow {
    id: call_id,
    provider: Provider::Codex,
    family: ToolFamily::Mcp,
    kind: ToolKind::McpToolCall,
    status: ToolStatus::Running,
    title: tool.clone(),
    subtitle: Some(server.clone()),
    summary: None,
    preview: None,
    started_at: Some(iso_now()),
    ended_at: None,
    duration_ms: None,
    grouping_key: None,
    invocation,
    result: None,
    render_hints: Default::default(),
    tool_display: None,
    shell_execution: None,
  }))]
}

pub(crate) fn handle_mcp_tool_call_end(event: McpToolCallEndEvent) -> ConnectorOutputs {
  let (output_value, is_error) = match &event.result {
    Ok(result) => (serde_json::to_value(result).ok(), false),
    Err(message) => (Some(json!(message)), true),
  };

  let status = if is_error {
    ToolStatus::Failed
  } else {
    ToolStatus::Completed
  };
  let server = event.invocation.server.clone();
  let tool = event.invocation.tool.clone();
  let resource_uri = event.mcp_app_resource_uri.clone();
  let mut invocation = json!({
      "server": server,
      "tool_name": tool,
      "output": output_value.clone(),
  });
  let mut result = json!({
      "tool_name": event.invocation.tool,
      "raw_output": output_value,
  });
  if let Some(resource_uri) = resource_uri {
    invocation["mcp_app_resource_uri"] = json!(resource_uri);
    result["mcp_app_resource_uri"] = json!(resource_uri);
  }

  let entry = tool_row_entry(ToolRow {
    id: event.call_id.clone(),
    provider: Provider::Codex,
    family: ToolFamily::Mcp,
    kind: ToolKind::McpToolCall,
    status,
    title: String::new(),
    subtitle: None,
    summary: None,
    preview: None,
    started_at: None,
    ended_at: Some(iso_now()),
    duration_ms: Some(event.duration.as_millis() as u64),
    grouping_key: None,
    invocation,
    result: Some(result),
    render_hints: Default::default(),
    tool_display: None,
    shell_execution: None,
  });
  vec![row_updated_output(event.call_id, entry)]
}

pub(crate) fn handle_web_search_begin(event: WebSearchBeginEvent) -> ConnectorOutputs {
  vec![row_created_output(tool_row_entry(ToolRow {
    id: event.call_id,
    provider: Provider::Codex,
    family: ToolFamily::Web,
    kind: ToolKind::WebSearch,
    status: ToolStatus::Running,
    title: "Searching the web".to_string(),
    subtitle: None,
    summary: None,
    preview: None,
    started_at: Some(iso_now()),
    ended_at: None,
    duration_ms: None,
    grouping_key: None,
    invocation: json!({
        "query": "",
        "results": [],
    }),
    result: None,
    render_hints: Default::default(),
    tool_display: None,
    shell_execution: None,
  }))]
}

pub(crate) fn handle_web_search_end(event: WebSearchEndEvent) -> ConnectorOutputs {
  let output = serde_json::to_string_pretty(&event.action)
    .or_else(|_| serde_json::to_string(&event.action))
    .unwrap_or_default();
  let entry = tool_row_entry(ToolRow {
    id: event.call_id.clone(),
    provider: Provider::Codex,
    family: ToolFamily::Web,
    kind: ToolKind::WebSearch,
    status: ToolStatus::Completed,
    title: event.query.clone(),
    subtitle: None,
    summary: None,
    preview: None,
    started_at: None,
    ended_at: Some(iso_now()),
    duration_ms: None,
    grouping_key: None,
    invocation: json!({
        "query": event.query,
        "results": [],
    }),
    result: Some(json!({
        "tool_name": "websearch",
        "output": output,
    })),
    render_hints: Default::default(),
    tool_display: None,
    shell_execution: None,
  });
  vec![row_updated_output(event.call_id, entry)]
}

pub(crate) fn handle_view_image_tool_call(event: ViewImageToolCallEvent) -> ConnectorOutputs {
  let path = event.path.to_string_lossy().to_string();
  vec![row_created_output(tool_row_entry(ToolRow {
    id: event.call_id,
    provider: Provider::Codex,
    family: ToolFamily::Image,
    kind: ToolKind::ViewImage,
    status: ToolStatus::Completed,
    title: path.clone(),
    subtitle: None,
    summary: Some("Image loaded".to_string()),
    preview: None,
    started_at: Some(iso_now()),
    ended_at: Some(iso_now()),
    duration_ms: None,
    grouping_key: None,
    invocation: json!({
        "image_paths": [&path],
    }),
    result: Some(json!({
        "image_paths": [event.path.to_string_lossy().to_string()],
        "caption": "Image loaded",
    })),
    render_hints: expandable_image_render_hints(),
    tool_display: None,
    shell_execution: None,
  }))]
}

pub(crate) fn handle_image_generation_begin(event: ImageGenerationBeginEvent) -> ConnectorOutputs {
  vec![row_created_output(tool_row_entry(ToolRow {
    id: event.call_id,
    provider: Provider::Codex,
    family: ToolFamily::Image,
    kind: ToolKind::ImageGeneration,
    status: ToolStatus::Running,
    title: "Image generation".to_string(),
    subtitle: None,
    summary: Some("Generating image".to_string()),
    preview: None,
    started_at: Some(iso_now()),
    ended_at: None,
    duration_ms: None,
    grouping_key: None,
    invocation: json!({
        "tool_name": "image_generation",
        "status": "in_progress",
    }),
    result: None,
    render_hints: expandable_image_render_hints(),
    tool_display: None,
    shell_execution: None,
  }))]
}

pub(crate) fn handle_image_generation_end(event: ImageGenerationEndEvent) -> ConnectorOutputs {
  let status = image_generation_status(event.status.as_str());
  let saved_path = image_generation_saved_path(&event);
  let image_paths: Vec<String> = saved_path.iter().cloned().collect();
  let summary = image_generation_summary(status, saved_path.as_deref());
  let output = image_generation_output(status, saved_path.as_deref());
  let revised_prompt = image_generation_revised_prompt(&event);

  let mut invocation = json!({
      "tool_name": "image_generation",
      "status": event.status.as_str(),
      "image_paths": image_paths.clone(),
  });
  if let Some(revised_prompt) = revised_prompt {
    invocation["revised_prompt"] = json!(revised_prompt);
  }

  let mut result = json!({
      "tool_name": "image_generation",
      "status": event.status.as_str(),
      "image_paths": image_paths,
      "output": output,
  });
  if let Some(revised_prompt) = revised_prompt {
    result["revised_prompt"] = json!(revised_prompt);
  }

  vec![row_updated_output(
    event.call_id.clone(),
    tool_row_entry(ToolRow {
      id: event.call_id,
      provider: Provider::Codex,
      family: ToolFamily::Image,
      kind: ToolKind::ImageGeneration,
      status,
      title: "Image generation".to_string(),
      subtitle: saved_path.clone(),
      summary: Some(summary),
      preview: None,
      started_at: None,
      ended_at: Some(iso_now()),
      duration_ms: None,
      grouping_key: None,
      invocation,
      result: Some(result),
      render_hints: expandable_image_render_hints(),
      tool_display: None,
      shell_execution: None,
    }),
  )]
}

pub(crate) fn handle_dynamic_tool_call_request(event: DynamicToolCallRequest) -> ConnectorOutputs {
  let call_id = event.call_id.clone();
  let tool = event.tool.clone();
  let arguments = event.arguments.clone();
  let (family, kind, title) = dynamic_tool_identity_from_name(&tool).unwrap_or((
    ToolFamily::Generic,
    ToolKind::DynamicToolCall,
    tool.as_str(),
  ));
  vec![
    row_created_output(tool_row_entry(ToolRow {
      id: call_id.clone(),
      provider: Provider::Codex,
      family,
      kind,
      status: ToolStatus::Running,
      title: title.to_string(),
      subtitle: None,
      summary: None,
      preview: None,
      started_at: Some(iso_now()),
      ended_at: None,
      duration_ms: None,
      grouping_key: None,
      invocation: json!({
          "tool_name": tool,
          "raw_input": arguments,
      }),
      result: None,
      render_hints: Default::default(),
      tool_display: None,
      shell_execution: None,
    })),
    runtime_output(ConnectorRuntimeDirective::DynamicToolCallRequested {
      call_id,
      tool_name: event.tool,
      arguments: event.arguments,
    }),
  ]
}

pub(crate) fn handle_dynamic_tool_call_response(
  event: DynamicToolCallResponseEvent,
) -> ConnectorOutputs {
  let tool_name = event.tool.clone();
  let arguments = event.arguments.clone();
  let output = dynamic_tool_output_to_text(&event.content_items, event.error);
  let status = if event.success {
    ToolStatus::Completed
  } else {
    ToolStatus::Failed
  };

  let identity_from_name = dynamic_tool_identity_from_name(&tool_name);
  let resolved_identity = if tool_name == "plan_write" {
    identity_from_name
  } else {
    dynamic_tool_identity_from_output(output.as_ref()).or(identity_from_name)
  };
  let (family, kind, title) = resolved_identity.unwrap_or((
    ToolFamily::Generic,
    ToolKind::DynamicToolCall,
    tool_name.as_str(),
  ));
  let (summary, result) =
    dynamic_tool_result_payload(tool_name.as_str(), kind, &arguments, output.as_ref());

  let entry = tool_row_entry(ToolRow {
    id: event.call_id.clone(),
    provider: Provider::Codex,
    family,
    kind,
    status,
    title: title.to_string(),
    subtitle: None,
    summary,
    preview: None,
    started_at: None,
    ended_at: Some(iso_now()),
    duration_ms: Some(event.duration.as_millis() as u64),
    grouping_key: None,
    invocation: json!({
        "tool_name": tool_name.clone(),
        "raw_input": arguments,
    }),
    result: Some(result),
    render_hints: Default::default(),
    tool_display: None,
    shell_execution: None,
  });
  vec![row_updated_output(event.call_id, entry)]
}

pub(crate) async fn handle_terminal_interaction(
  event: TerminalInteractionEvent,
  output_buffers: &SharedOutputBuffers,
) -> ConnectorOutputs {
  let snippet = terminal_stdin_echo(&event.stdin);
  let shell_payload = {
    let mut buffers = output_buffers.lock().await;
    let Some(buffer) = buffers.get_mut(&event.call_id) else {
      return Vec::new();
    };
    if buffer.command.trim().is_empty() || buffer.cwd.trim().is_empty() {
      return Vec::new();
    }
    buffer.append(&snippet);
    buffer.last_broadcast = Instant::now();
    let live_preview = buffer.preview();
    shell_execution_payload(
      buffer.command.clone(),
      buffer.cwd.clone(),
      buffer.process_id.clone(),
      buffer.command_actions.clone(),
      live_preview.clone(),
      None,
      None,
    )
  };

  let entry = tool_row_entry(ToolRow {
    id: event.call_id.clone(),
    provider: Provider::Codex,
    family: ToolFamily::Shell,
    kind: ToolKind::Bash,
    status: ToolStatus::Running,
    title: shell_payload.command.clone(),
    subtitle: Some(shell_payload.cwd.clone()),
    summary: None,
    preview: None,
    started_at: None,
    ended_at: None,
    duration_ms: None,
    grouping_key: None,
    invocation: json!({
      "command": shell_payload.command.clone(),
      "cwd": shell_payload.cwd.clone(),
    }),
    result: None,
    render_hints: expandable_command_render_hints(),
    tool_display: None,
    shell_execution: Some(shell_payload),
  });
  vec![row_updated_output(event.call_id, entry)]
}

fn terminal_stdin_echo(stdin: &str) -> String {
  if stdin.ends_with('\n') {
    stdin.to_string()
  } else {
    format!("{stdin}\n")
  }
}

#[cfg(test)]
mod tests {
  use super::{
    display_command_from_exec_tokens, handle_dynamic_tool_call_request,
    handle_dynamic_tool_call_response, handle_exec_command_begin, handle_exec_command_end,
    handle_exec_command_output_delta, handle_image_generation_begin, handle_image_generation_end,
    handle_patch_apply_end, handle_patch_apply_updated, handle_terminal_interaction,
  };
  use crate::event_mapping::{SharedEnvironmentTracker, SharedOutputBuffers, SharedPatchContexts};
  use crate::runtime::EnvironmentTracker;
  use codex_protocol::dynamic_tools::{DynamicToolCallOutputContentItem, DynamicToolCallRequest};
  use codex_protocol::parse_command::ParsedCommand;
  use codex_protocol::protocol::{
    DynamicToolCallResponseEvent, ExecCommandBeginEvent, ExecCommandEndEvent,
    ExecCommandOutputDeltaEvent, ExecCommandSource, ExecCommandStatus, ExecOutputStream,
    FileChange, ImageGenerationBeginEvent, ImageGenerationEndEvent, PatchApplyEndEvent,
    PatchApplyStatus, PatchApplyUpdatedEvent,
  };
  use codex_utils_absolute_path::AbsolutePathBuf;
  use orbitdock_connector_core::{ConnectorOutput, ConnectorStateEvent};
  use orbitdock_protocol::conversation_contracts::ConversationRow;
  use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
  use std::collections::HashMap;
  use std::path::PathBuf;
  use std::sync::Arc;
  use std::time::Duration;

  fn shared_output_buffers() -> SharedOutputBuffers {
    Arc::new(tokio::sync::Mutex::new(HashMap::new()))
  }

  fn absolute_test_path(path: &str) -> AbsolutePathBuf {
    AbsolutePathBuf::from_absolute_path(path).expect("absolute test path")
  }

  fn shared_env_tracker() -> SharedEnvironmentTracker {
    Arc::new(tokio::sync::Mutex::new(EnvironmentTracker {
      cwd: None,
      branch: None,
      sha: None,
    }))
  }

  fn shared_current_cwd(path: &str) -> Arc<tokio::sync::Mutex<String>> {
    Arc::new(tokio::sync::Mutex::new(path.to_string()))
  }

  fn shared_patch_contexts() -> SharedPatchContexts {
    Arc::new(tokio::sync::Mutex::new(HashMap::new()))
  }

  fn created_entry(
    output: ConnectorOutput,
  ) -> Option<orbitdock_protocol::conversation_contracts::ConversationRowEntry> {
    match output.into_state_event() {
      Ok(ConnectorStateEvent::ConversationRowCreated(entry)) => Some(entry),
      Ok(_) | Err(_) => None,
    }
  }

  fn updated_entry(
    output: ConnectorOutput,
  ) -> Option<orbitdock_protocol::conversation_contracts::ConversationRowEntry> {
    match output.into_state_event() {
      Ok(ConnectorStateEvent::ConversationRowUpdated { entry, .. }) => Some(entry),
      Ok(_) | Err(_) => None,
    }
  }

  #[test]
  fn image_generation_begin_creates_running_image_row() {
    let events = handle_image_generation_begin(ImageGenerationBeginEvent {
      call_id: "ig-1".to_string(),
    });

    let created = events.into_iter().find_map(created_entry);
    let entry = created.expect("tool row created");
    let ConversationRow::Tool(tool) = entry.row else {
      panic!("expected tool row");
    };

    assert_eq!(tool.family, ToolFamily::Image);
    assert_eq!(tool.kind, ToolKind::ImageGeneration);
    assert_eq!(tool.status, ToolStatus::Running);
    assert_eq!(tool.invocation["status"], "in_progress");
    let display = tool.tool_display.expect("image generation display");
    assert_eq!(display.glyph_symbol, "sparkles");
    assert_eq!(display.tool_type, "image");
  }

  #[test]
  fn image_generation_end_updates_row_without_base64_payload() {
    let events = handle_image_generation_end(ImageGenerationEndEvent {
      call_id: "ig-1".to_string(),
      status: "completed".to_string(),
      revised_prompt: Some("A tiny mission control dashboard".to_string()),
      result: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB".to_string(),
      saved_path: Some(absolute_test_path("/tmp/generated/ig-1.png")),
    });

    let updated = events.into_iter().find_map(updated_entry);
    let entry = updated.expect("tool row updated");
    let ConversationRow::Tool(tool) = entry.row else {
      panic!("expected tool row");
    };

    assert_eq!(tool.family, ToolFamily::Image);
    assert_eq!(tool.kind, ToolKind::ImageGeneration);
    assert_eq!(tool.status, ToolStatus::Completed);
    assert_eq!(tool.subtitle.as_deref(), Some("/tmp/generated/ig-1.png"));

    let result = tool.result.expect("tool result");
    assert_eq!(result["image_paths"][0], "/tmp/generated/ig-1.png");
    assert_eq!(result["revised_prompt"], "A tiny mission control dashboard");
    assert!(result.get("result").is_none());

    let display = tool.tool_display.expect("tool display");
    assert_eq!(display.glyph_symbol, "sparkles");
    assert_eq!(
      display.output_preview.as_deref(),
      Some("Saved generated image to /tmp/generated/ig-1.png")
    );
  }

  #[tokio::test]
  async fn patch_apply_updated_refreshes_running_diff_for_final_row() {
    let patch_contexts = shared_patch_contexts();
    let mut changes = HashMap::new();
    changes.insert(
      PathBuf::from("src/main.rs"),
      FileChange::Update {
        unified_diff: "@@ -1 +1 @@\n-old\n+new".to_string(),
        move_path: None,
      },
    );

    let events = handle_patch_apply_updated(
      PatchApplyUpdatedEvent {
        call_id: "patch-1".to_string(),
        changes,
      },
      &patch_contexts,
    )
    .await;

    let updated = events.into_iter().find_map(updated_entry);
    let entry = updated.expect("tool row updated");
    let ConversationRow::Tool(tool) = entry.row else {
      panic!("expected tool row");
    };
    assert_eq!(tool.status, ToolStatus::Running);
    assert_eq!(tool.invocation["path"], "src/main.rs");
    assert!(tool.invocation["diff"]
      .as_str()
      .expect("diff")
      .contains("+new"));

    let final_events = handle_patch_apply_end(
      PatchApplyEndEvent {
        call_id: "patch-1".to_string(),
        turn_id: String::new(),
        stdout: String::new(),
        stderr: String::new(),
        success: true,
        changes: HashMap::new(),
        status: PatchApplyStatus::Completed,
      },
      &patch_contexts,
    )
    .await;

    let final_entry = final_events.into_iter().find_map(updated_entry);
    let entry = final_entry.expect("final tool row updated");
    let ConversationRow::Tool(tool) = entry.row else {
      panic!("expected final tool row");
    };
    assert_eq!(tool.status, ToolStatus::Completed);
    assert_eq!(tool.invocation["path"], "src/main.rs");
    assert!(tool.invocation["diff"]
      .as_str()
      .expect("final diff")
      .contains("+new"));
  }

  #[tokio::test]
  async fn exec_command_begin_creates_tool_row_with_shell_execution() {
    let current_cwd = shared_current_cwd("/tmp/old-project");
    let events = handle_exec_command_begin(
      ExecCommandBeginEvent {
        call_id: "cmd-1".to_string(),
        process_id: Some("pty-1".to_string()),
        turn_id: "turn-1".to_string(),
        command: vec!["sed".to_string(), "-n".to_string(), "1,40p".to_string()],
        cwd: absolute_test_path("/tmp/project"),
        parsed_cmd: vec![ParsedCommand::Read {
          cmd: "sed -n 1,40p src/main.rs".to_string(),
          name: "main.rs".to_string(),
          path: PathBuf::from("src/main.rs"),
        }],
        source: ExecCommandSource::Agent,
        interaction_input: None,
      },
      &shared_output_buffers(),
      &shared_env_tracker(),
      &current_cwd,
    )
    .await;

    let created = events.into_iter().find_map(created_entry);

    let entry = created.expect("tool row with shell_execution");
    let ConversationRow::Tool(row) = entry.row else {
      panic!("expected tool row");
    };

    assert_eq!(row.family, ToolFamily::Shell);
    assert_eq!(row.kind, ToolKind::Bash);
    assert_eq!(row.status, ToolStatus::Running);
    let shell = row.shell_execution.as_ref().expect("shell_execution");
    assert_eq!(shell.command, "sed -n 1,40p");
    assert_eq!(shell.cwd, "/tmp/project");
    assert_eq!(shell.process_id.as_deref(), Some("pty-1"));
    assert_eq!(shell.actions.len(), 1);
    let snapshot = shell.terminal_snapshot.as_ref().expect("terminal snapshot");
    assert_eq!(snapshot.command, "sed -n 1,40p");
    assert_eq!(snapshot.cwd, "/tmp/project");
    assert!(snapshot.output.is_none());
    assert_eq!(current_cwd.lock().await.as_str(), "/tmp/project");
  }

  #[tokio::test]
  async fn exec_command_end_updates_tool_row_with_shell_output() {
    let output_buffers = shared_output_buffers();
    let env_tracker = shared_env_tracker();
    let current_cwd = shared_current_cwd("/tmp/project");

    handle_exec_command_begin(
      ExecCommandBeginEvent {
        call_id: "cmd-2".to_string(),
        process_id: Some("pty-2".to_string()),
        turn_id: "turn-2".to_string(),
        command: vec!["rg".to_string(), "needle".to_string(), "src".to_string()],
        cwd: absolute_test_path("/tmp/project"),
        parsed_cmd: vec![ParsedCommand::Search {
          cmd: "rg needle src".to_string(),
          query: Some("needle".to_string()),
          path: Some("src".to_string()),
        }],
        source: ExecCommandSource::Agent,
        interaction_input: None,
      },
      &output_buffers,
      &env_tracker,
      &current_cwd,
    )
    .await;

    handle_exec_command_output_delta(
      ExecCommandOutputDeltaEvent {
        call_id: "cmd-2".to_string(),
        stream: ExecOutputStream::Stdout,
        chunk: b"src/lib.rs:needle\n".to_vec(),
      },
      &output_buffers,
    )
    .await;

    let events = handle_exec_command_end(
      ExecCommandEndEvent {
        call_id: "cmd-2".to_string(),
        process_id: Some("pty-2".to_string()),
        turn_id: "turn-2".to_string(),
        command: vec!["rg".to_string(), "needle".to_string(), "src".to_string()],
        cwd: absolute_test_path("/tmp/project"),
        parsed_cmd: vec![ParsedCommand::Search {
          cmd: "rg needle src".to_string(),
          query: Some("needle".to_string()),
          path: Some("src".to_string()),
        }],
        source: ExecCommandSource::Agent,
        interaction_input: None,
        stdout: "src/lib.rs:needle\n".to_string(),
        stderr: String::new(),
        aggregated_output: String::new(),
        exit_code: 0,
        duration: Duration::from_millis(42),
        formatted_output: "src/lib.rs:needle\n".to_string(),
        status: ExecCommandStatus::Completed,
      },
      &output_buffers,
    )
    .await;

    let updated = events.into_iter().find_map(updated_entry);

    let entry = updated.expect("updated row");
    let ConversationRow::Tool(row) = entry.row else {
      panic!("expected tool row");
    };

    assert_eq!(row.status, ToolStatus::Completed);
    let shell = row.shell_execution.as_ref().expect("shell_execution");
    assert_eq!(
      shell
        .aggregated_output
        .as_deref()
        .map(|value| value.trim_end_matches('\n')),
      Some("src/lib.rs:needle")
    );
    let snapshot = shell.terminal_snapshot.as_ref().expect("terminal snapshot");
    assert_eq!(snapshot.command, "rg needle src");
    assert_eq!(snapshot.cwd, "/tmp/project");
    assert_eq!(
      snapshot
        .output
        .as_deref()
        .map(|value| value.trim_end_matches('\n')),
      Some("src/lib.rs:needle")
    );
    assert_eq!(shell.exit_code, Some(0));
    assert_eq!(row.duration_ms, Some(42));
  }

  #[tokio::test]
  async fn exec_command_end_prefers_richer_stream_output_when_terminal_payload_is_short() {
    let output_buffers = shared_output_buffers();
    let env_tracker = shared_env_tracker();
    let current_cwd = shared_current_cwd("/tmp/project");

    handle_exec_command_begin(
      ExecCommandBeginEvent {
        call_id: "cmd-2b".to_string(),
        process_id: Some("pty-2b".to_string()),
        turn_id: "turn-2b".to_string(),
        command: vec!["cargo".to_string(), "test".to_string()],
        cwd: absolute_test_path("/tmp/project"),
        parsed_cmd: vec![ParsedCommand::Unknown {
          cmd: "cargo test".to_string(),
        }],
        source: ExecCommandSource::Agent,
        interaction_input: None,
      },
      &output_buffers,
      &env_tracker,
      &current_cwd,
    )
    .await;

    let streamed = "Compiling crate-a\nCompiling crate-b\nerror: tests failed\n";
    handle_exec_command_output_delta(
      ExecCommandOutputDeltaEvent {
        call_id: "cmd-2b".to_string(),
        stream: ExecOutputStream::Stdout,
        chunk: streamed.as_bytes().to_vec(),
      },
      &output_buffers,
    )
    .await;

    let events = handle_exec_command_end(
      ExecCommandEndEvent {
        call_id: "cmd-2b".to_string(),
        process_id: Some("pty-2b".to_string()),
        turn_id: "turn-2b".to_string(),
        command: vec!["cargo".to_string(), "test".to_string()],
        cwd: absolute_test_path("/tmp/project"),
        parsed_cmd: vec![ParsedCommand::Unknown {
          cmd: "cargo test".to_string(),
        }],
        source: ExecCommandSource::Agent,
        interaction_input: None,
        stdout: String::new(),
        stderr: String::new(),
        aggregated_output: "tests failed".to_string(),
        exit_code: 1,
        duration: Duration::from_millis(1337),
        formatted_output: "tests failed".to_string(),
        status: ExecCommandStatus::Failed,
      },
      &output_buffers,
    )
    .await;

    let updated = events.into_iter().find_map(updated_entry);

    let entry = updated.expect("updated row");
    let ConversationRow::Tool(row) = entry.row else {
      panic!("expected tool row");
    };

    let shell = row.shell_execution.as_ref().expect("shell_execution");
    let expected_streamed = streamed.trim_end_matches('\n');
    assert_eq!(
      shell
        .aggregated_output
        .as_deref()
        .map(|value| value.trim_end_matches('\n')),
      Some(expected_streamed)
    );
    let snapshot = shell.terminal_snapshot.as_ref().expect("terminal snapshot");
    assert_eq!(snapshot.command, "cargo test");
    assert_eq!(snapshot.cwd, "/tmp/project");
    assert_eq!(
      snapshot
        .output
        .as_deref()
        .map(|value| value.trim_end_matches('\n')),
      Some(expected_streamed)
    );
  }

  #[tokio::test]
  async fn exec_command_end_prefers_terminal_payloads_when_stream_buffer_is_missing() {
    let output_buffers = shared_output_buffers();

    let events = handle_exec_command_end(
      ExecCommandEndEvent {
        call_id: "cmd-3".to_string(),
        process_id: Some("pty-3".to_string()),
        turn_id: "turn-3".to_string(),
        command: vec![
          "python".to_string(),
          "-c".to_string(),
          "print('done')".to_string(),
        ],
        cwd: absolute_test_path("/tmp/project"),
        parsed_cmd: vec![ParsedCommand::Unknown {
          cmd: "python -c print('done')".to_string(),
        }],
        source: ExecCommandSource::Agent,
        interaction_input: None,
        stdout: "done\n".to_string(),
        stderr: String::new(),
        aggregated_output: String::new(),
        exit_code: 0,
        duration: Duration::from_millis(9),
        formatted_output: "done\n".to_string(),
        status: ExecCommandStatus::Completed,
      },
      &output_buffers,
    )
    .await;

    let updated = events.into_iter().find_map(updated_entry);

    let entry = updated.expect("updated row");
    let ConversationRow::Tool(row) = entry.row else {
      panic!("expected tool row");
    };

    let shell = row.shell_execution.as_ref().expect("shell_execution");
    assert_eq!(
      shell
        .aggregated_output
        .as_deref()
        .map(|value| value.trim_end_matches('\n')),
      Some("done")
    );
    assert_eq!(row.status, ToolStatus::Completed);
    let snapshot = shell.terminal_snapshot.as_ref().expect("terminal snapshot");
    assert_eq!(snapshot.command, "python -c print('done')");
    assert_eq!(snapshot.cwd, "/tmp/project");
    assert_eq!(
      snapshot
        .output
        .as_deref()
        .map(|value| value.trim_end_matches('\n')),
      Some("done")
    );
  }

  #[tokio::test]
  async fn exec_command_end_maps_declined_status_without_collapsing_to_completed() {
    let output_buffers = shared_output_buffers();

    let events = handle_exec_command_end(
      ExecCommandEndEvent {
        call_id: "cmd-4".to_string(),
        process_id: None,
        turn_id: "turn-4".to_string(),
        command: vec![
          "rm".to_string(),
          "-rf".to_string(),
          "/tmp/project".to_string(),
        ],
        cwd: absolute_test_path("/tmp/project"),
        parsed_cmd: vec![ParsedCommand::Unknown {
          cmd: "rm -rf /tmp/project".to_string(),
        }],
        source: ExecCommandSource::Agent,
        interaction_input: None,
        stdout: String::new(),
        stderr: "permission denied".to_string(),
        aggregated_output: String::new(),
        exit_code: 0,
        duration: Duration::from_millis(12),
        formatted_output: "permission denied".to_string(),
        status: ExecCommandStatus::Declined,
      },
      &output_buffers,
    )
    .await;

    let updated = events.into_iter().find_map(updated_entry);

    let entry = updated.expect("updated row");
    let ConversationRow::Tool(row) = entry.row else {
      panic!("expected tool row");
    };

    assert_eq!(row.status, ToolStatus::Cancelled);
    let shell = row.shell_execution.as_ref().expect("shell_execution");
    assert_eq!(
      shell.aggregated_output.as_deref(),
      Some("permission denied")
    );
    let snapshot = shell.terminal_snapshot.as_ref().expect("terminal snapshot");
    assert_eq!(snapshot.command, "rm -rf /tmp/project");
    assert_eq!(snapshot.cwd, "/tmp/project");
    assert_eq!(snapshot.output.as_deref(), Some("permission denied"));
  }

  #[tokio::test]
  async fn terminal_interaction_updates_shell_execution_snapshot_with_stdin() {
    let output_buffers = shared_output_buffers();
    let env_tracker = shared_env_tracker();
    let current_cwd = shared_current_cwd("/tmp/project");

    handle_exec_command_begin(
      ExecCommandBeginEvent {
        call_id: "cmd-stdin-1".to_string(),
        process_id: Some("pty-stdin-1".to_string()),
        turn_id: "turn-stdin-1".to_string(),
        command: vec!["python".to_string(), "-i".to_string()],
        cwd: absolute_test_path("/tmp/project"),
        parsed_cmd: vec![ParsedCommand::Unknown {
          cmd: "python -i".to_string(),
        }],
        source: ExecCommandSource::Agent,
        interaction_input: None,
      },
      &output_buffers,
      &env_tracker,
      &current_cwd,
    )
    .await;

    let events = handle_terminal_interaction(
      codex_protocol::protocol::TerminalInteractionEvent {
        call_id: "cmd-stdin-1".to_string(),
        process_id: "pty-stdin-1".to_string(),
        stdin: "print('hello')".to_string(),
      },
      &output_buffers,
    )
    .await;

    let updated = events.into_iter().find_map(updated_entry);

    let entry = updated.expect("updated row");
    let ConversationRow::Tool(row) = entry.row else {
      panic!("expected tool row");
    };

    let shell = row.shell_execution.as_ref().expect("shell_execution");
    let snapshot = shell.terminal_snapshot.as_ref().expect("terminal snapshot");
    assert_eq!(snapshot.command, "python -i");
    assert_eq!(snapshot.cwd, "/tmp/project");
    assert!(snapshot
      .output
      .as_deref()
      .expect("snapshot output")
      .contains("print('hello')"));
    assert!(!snapshot.transcript().contains("[stdin]"));
    assert!(snapshot.transcript().contains("print('hello')"));
  }

  #[tokio::test]
  async fn terminal_interaction_without_exec_buffer_does_not_create_empty_shell_row() {
    let events = handle_terminal_interaction(
      codex_protocol::protocol::TerminalInteractionEvent {
        call_id: "missing-buffer".to_string(),
        process_id: "pty-missing".to_string(),
        stdin: "print('hello')".to_string(),
      },
      &shared_output_buffers(),
    )
    .await;

    assert!(events.is_empty());
  }

  #[test]
  fn display_command_from_exec_tokens_strips_shell_launcher_prefixes() {
    assert_eq!(
      display_command_from_exec_tokens(&[
        "/bin/zsh".to_string(),
        "-lc".to_string(),
        "swiftc --version".to_string(),
      ]),
      "swiftc --version"
    );
    assert_eq!(
      display_command_from_exec_tokens(&[
        "/usr/bin/env".to_string(),
        "SHELL=/bin/bash".to_string(),
        "/bin/bash".to_string(),
        "-lc".to_string(),
        "cargo test -p orbitdock-server".to_string(),
      ]),
      "cargo test -p orbitdock-server"
    );
    assert_eq!(
      display_command_from_exec_tokens(&[
        "pwsh".to_string(),
        "-NoProfile".to_string(),
        "-Command".to_string(),
        "Get-Item .".to_string(),
      ]),
      "Get-Item ."
    );
  }

  #[test]
  fn display_command_from_exec_tokens_preserves_non_shell_commands() {
    assert_eq!(
      display_command_from_exec_tokens(&["swiftc".to_string(), "-print-target-info".to_string(),]),
      "swiftc -print-target-info"
    );
    assert_eq!(
      display_command_from_exec_tokens(&[
        "python3".to_string(),
        "-m".to_string(),
        "pip".to_string()
      ]),
      "python3 -m pip"
    );
  }

  #[tokio::test]
  async fn exec_command_begin_strips_shell_launcher_in_row_command() {
    let current_cwd = shared_current_cwd("/tmp/project");
    let events = handle_exec_command_begin(
      ExecCommandBeginEvent {
        call_id: "cmd-shell-wrap-1".to_string(),
        process_id: Some("pty-shell-wrap-1".to_string()),
        turn_id: "turn-shell-wrap-1".to_string(),
        command: vec![
          "/bin/zsh".to_string(),
          "-lc".to_string(),
          "swiftc -print-target-info".to_string(),
        ],
        cwd: absolute_test_path("/tmp/project"),
        parsed_cmd: vec![ParsedCommand::Unknown {
          cmd: "/bin/zsh -lc swiftc -print-target-info".to_string(),
        }],
        source: ExecCommandSource::Agent,
        interaction_input: None,
      },
      &shared_output_buffers(),
      &shared_env_tracker(),
      &current_cwd,
    )
    .await;

    let created = events.into_iter().find_map(created_entry);

    let entry = created.expect("tool row");
    let ConversationRow::Tool(row) = entry.row else {
      panic!("expected tool row");
    };
    let shell = row.shell_execution.as_ref().expect("shell_execution");
    assert_eq!(shell.command, "swiftc -print-target-info");
  }

  #[test]
  fn shell_output_summary_truncates_unicode_on_char_boundary() {
    let output = "é".repeat(120);
    let summary = super::summarize_shell_output(&output);

    assert_eq!(summary.chars().count(), 103);
    assert!(summary.ends_with("..."));
  }

  #[test]
  fn dynamic_tool_request_maps_file_write_to_native_write_kind() {
    let events = handle_dynamic_tool_call_request(DynamicToolCallRequest {
      call_id: "call-dynamic-write-1".to_string(),
      turn_id: "turn-dynamic-write-1".to_string(),
      tool: "file_write".to_string(),
      arguments: serde_json::json!({
        "path": "README.md",
        "content": "hello"
      }),
    });
    let created = events.into_iter().find_map(created_entry);
    let entry = created.expect("tool row created");
    let ConversationRow::Tool(tool) = entry.row else {
      panic!("expected tool row");
    };
    assert_eq!(tool.family, ToolFamily::FileChange);
    assert_eq!(tool.kind, ToolKind::Write);
    assert_eq!(tool.status, ToolStatus::Running);
    assert_eq!(tool.title, "Write");
  }

  #[test]
  fn dynamic_tool_request_maps_plan_write_to_native_write_kind() {
    let events = handle_dynamic_tool_call_request(DynamicToolCallRequest {
      call_id: "call-dynamic-plan-write-1".to_string(),
      turn_id: "turn-dynamic-plan-write-1".to_string(),
      tool: "plan_write".to_string(),
      arguments: serde_json::json!({
        "path": "tooling/plan.md",
        "content": "# Plan\n"
      }),
    });
    let created = events.into_iter().find_map(created_entry);
    let entry = created.expect("tool row created");
    let ConversationRow::Tool(tool) = entry.row else {
      panic!("expected tool row");
    };
    assert_eq!(tool.family, ToolFamily::Plan);
    assert_eq!(tool.kind, ToolKind::Write);
    assert_eq!(tool.status, ToolStatus::Running);
    assert_eq!(tool.title, "Plan");
    let display = tool.tool_display.expect("plan write request tool display");
    assert_eq!(display.summary, "Plan");
    assert_eq!(display.tool_type, "plan");
  }

  #[test]
  fn dynamic_tool_response_infers_native_read_kind_from_payload() {
    let events = handle_dynamic_tool_call_response(DynamicToolCallResponseEvent {
      call_id: "call-dynamic-read-1".to_string(),
      turn_id: "turn-dynamic-read-1".to_string(),
      tool: "file_read".to_string(),
      arguments: serde_json::json!({
        "path": "/tmp/readme.md"
      }),
      success: true,
      content_items: vec![DynamicToolCallOutputContentItem::InputText {
        text: "{\"content\":\"hello\",\"path\":\"/tmp/readme.md\",\"truncated\":false}".to_string(),
      }],
      error: None,
      duration: Duration::from_millis(11),
    });
    let updated = events.into_iter().find_map(updated_entry);
    let entry = updated.expect("tool row updated");
    let ConversationRow::Tool(tool) = entry.row else {
      panic!("expected tool row");
    };
    assert_eq!(tool.family, ToolFamily::FileRead);
    assert_eq!(tool.kind, ToolKind::Read);
    assert_eq!(tool.status, ToolStatus::Completed);
    assert_eq!(tool.title, "Read");
    let result = tool.result.expect("tool result");
    assert_eq!(result["path"], "/tmp/readme.md");
    assert_eq!(result["output"], "hello");
    assert_eq!(result["truncated"], false);
  }

  #[test]
  fn dynamic_tool_response_falls_back_to_tool_name_for_native_kind() {
    let events = handle_dynamic_tool_call_response(DynamicToolCallResponseEvent {
      call_id: "call-dynamic-write-2".to_string(),
      turn_id: "turn-dynamic-write-2".to_string(),
      tool: "file_write".to_string(),
      arguments: serde_json::json!({
        "path": "/tmp/readme.md",
        "content": "hello"
      }),
      success: true,
      content_items: vec![DynamicToolCallOutputContentItem::InputText {
        text: "ok".to_string(),
      }],
      error: None,
      duration: Duration::from_millis(7),
    });
    let updated = events.into_iter().find_map(updated_entry);
    let entry = updated.expect("tool row updated");
    let ConversationRow::Tool(tool) = entry.row else {
      panic!("expected tool row");
    };
    assert_eq!(tool.family, ToolFamily::FileChange);
    assert_eq!(tool.kind, ToolKind::Write);
    assert_eq!(tool.status, ToolStatus::Completed);
    assert_eq!(tool.title, "Write");
    let result = tool.result.expect("tool result");
    assert_eq!(result["output"], "ok");
  }

  #[test]
  fn dynamic_tool_response_falls_back_to_tool_name_for_plan_write() {
    let events = handle_dynamic_tool_call_response(DynamicToolCallResponseEvent {
      call_id: "call-dynamic-plan-write-2".to_string(),
      turn_id: "turn-dynamic-plan-write-2".to_string(),
      tool: "plan_write".to_string(),
      arguments: serde_json::json!({
        "path": "tooling/plan.md",
        "content": "# Plan\n"
      }),
      success: true,
      content_items: vec![DynamicToolCallOutputContentItem::InputText {
        text: "ok".to_string(),
      }],
      error: None,
      duration: Duration::from_millis(6),
    });
    let updated = events.into_iter().find_map(updated_entry);
    let entry = updated.expect("tool row updated");
    let ConversationRow::Tool(tool) = entry.row else {
      panic!("expected tool row");
    };
    assert_eq!(tool.family, ToolFamily::Plan);
    assert_eq!(tool.kind, ToolKind::Write);
    assert_eq!(tool.status, ToolStatus::Completed);
    assert_eq!(tool.title, "Plan");
    let result = tool.result.expect("tool result");
    assert_eq!(result["output"], "ok");
  }

  #[test]
  fn dynamic_tool_response_prefers_plan_identity_over_write_payload_shape() {
    let events = handle_dynamic_tool_call_response(DynamicToolCallResponseEvent {
      call_id: "call-dynamic-plan-write-3".to_string(),
      turn_id: "turn-dynamic-plan-write-3".to_string(),
      tool: "plan_write".to_string(),
      arguments: serde_json::json!({
        "path": "tooling/plan.md",
        "content": "# Plan\n"
      }),
      success: true,
      content_items: vec![DynamicToolCallOutputContentItem::InputText {
        text: "{\"path\":\"/tmp/plan.md\",\"bytes_written\":42}".to_string(),
      }],
      error: None,
      duration: Duration::from_millis(5),
    });
    let updated = events.into_iter().find_map(updated_entry);
    let entry = updated.expect("tool row updated");
    let ConversationRow::Tool(tool) = entry.row else {
      panic!("expected tool row");
    };
    assert_eq!(tool.family, ToolFamily::Plan);
    assert_eq!(tool.kind, ToolKind::Write);
    assert_eq!(tool.status, ToolStatus::Completed);
    assert_eq!(tool.title, "Plan");
    assert_eq!(
      tool.summary.as_deref(),
      Some("Saved plan (42 bytes) to /tmp/plan.md")
    );
  }

  #[test]
  fn dynamic_tool_response_infers_native_write_kind_from_payload() {
    let events = handle_dynamic_tool_call_response(DynamicToolCallResponseEvent {
      call_id: "call-dynamic-write-3".to_string(),
      turn_id: "turn-dynamic-write-3".to_string(),
      tool: "file_write".to_string(),
      arguments: serde_json::json!({
        "path": "/tmp/readme.md",
        "content": "hello"
      }),
      success: true,
      content_items: vec![DynamicToolCallOutputContentItem::InputText {
        text: "{\"path\":\"/tmp/readme.md\",\"bytes_written\":5}".to_string(),
      }],
      error: None,
      duration: Duration::from_millis(5),
    });
    let updated = events.into_iter().find_map(updated_entry);
    let entry = updated.expect("tool row updated");
    let ConversationRow::Tool(tool) = entry.row else {
      panic!("expected tool row");
    };
    assert_eq!(tool.family, ToolFamily::FileChange);
    assert_eq!(tool.kind, ToolKind::Write);
    assert_eq!(tool.status, ToolStatus::Completed);
    assert_eq!(tool.title, "Write");
    assert_eq!(
      tool.summary.as_deref(),
      Some("Wrote 5 bytes to /tmp/readme.md")
    );
    let result = tool.result.expect("tool result");
    assert_eq!(result["path"], "/tmp/readme.md");
    assert_eq!(result["bytes_written"], 5);
    assert_eq!(result["output"], "Wrote 5 bytes to /tmp/readme.md");
  }

  #[test]
  fn dynamic_tool_response_infers_native_edit_kind_from_payload() {
    let events = handle_dynamic_tool_call_response(DynamicToolCallResponseEvent {
      call_id: "call-dynamic-edit-1".to_string(),
      turn_id: "turn-dynamic-edit-1".to_string(),
      tool: "file_edit".to_string(),
      arguments: serde_json::json!({
        "path": "/tmp/readme.md",
        "old_string": "hello",
        "new_string": "hi"
      }),
      success: true,
      content_items: vec![DynamicToolCallOutputContentItem::InputText {
        text: "{\"path\":\"/tmp/readme.md\",\"replacements\":2}".to_string(),
      }],
      error: None,
      duration: Duration::from_millis(8),
    });
    let updated = events.into_iter().find_map(updated_entry);
    let entry = updated.expect("tool row updated");
    let ConversationRow::Tool(tool) = entry.row else {
      panic!("expected tool row");
    };
    assert_eq!(tool.family, ToolFamily::FileChange);
    assert_eq!(tool.kind, ToolKind::Edit);
    assert_eq!(tool.status, ToolStatus::Completed);
    assert_eq!(tool.title, "Edit");
    assert_eq!(
      tool.summary.as_deref(),
      Some("Applied 2 replacement(s) in /tmp/readme.md")
    );
    let result = tool.result.expect("tool result");
    assert_eq!(result["path"], "/tmp/readme.md");
    assert_eq!(result["replacements"], 2);
    assert_eq!(
      result["output"],
      "Applied 2 replacement(s) in /tmp/readme.md"
    );
  }

  #[test]
  fn dynamic_tool_response_unwraps_json_encoded_string_payload_for_compact_summary() {
    let events = handle_dynamic_tool_call_response(DynamicToolCallResponseEvent {
      call_id: "call-dynamic-edit-encoded-json-1".to_string(),
      turn_id: "turn-dynamic-edit-encoded-json-1".to_string(),
      tool: "file_edit".to_string(),
      arguments: serde_json::json!({
        "path": "/tmp/readme.md",
        "old_string": "hello",
        "new_string": "hi"
      }),
      success: true,
      content_items: vec![DynamicToolCallOutputContentItem::InputText {
        text: "\"{\\\"path\\\":\\\"/tmp/readme.md\\\",\\\"replacements\\\":1}\"".to_string(),
      }],
      error: None,
      duration: Duration::from_millis(6),
    });
    let updated = events.into_iter().find_map(updated_entry);
    let entry = updated.expect("tool row updated");
    let ConversationRow::Tool(tool) = entry.row else {
      panic!("expected tool row");
    };
    assert_eq!(tool.family, ToolFamily::FileChange);
    assert_eq!(tool.kind, ToolKind::Edit);
    assert_eq!(
      tool.summary.as_deref(),
      Some("Applied 1 replacement(s) in /tmp/readme.md")
    );
    let result = tool.result.expect("tool result");
    assert_eq!(result["path"], "/tmp/readme.md");
    assert_eq!(result["replacements"], 1);
    assert_eq!(
      result["output"],
      "Applied 1 replacement(s) in /tmp/readme.md"
    );
  }
}
