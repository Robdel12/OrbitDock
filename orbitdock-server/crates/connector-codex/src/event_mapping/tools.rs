use super::{SharedEnvironmentTracker, SharedOutputBuffers, SharedPatchContexts};
use crate::runtime::row_entry;
use crate::timeline::dynamic_tool_output_to_text;
use crate::workers::iso_now;
use codex_protocol::dynamic_tools::DynamicToolCallRequest;
use codex_protocol::parse_command::ParsedCommand;
use codex_protocol::protocol::DynamicToolCallResponseEvent;
use codex_protocol::protocol::{
  ExecCommandBeginEvent, ExecCommandEndEvent, ExecCommandOutputDeltaEvent, FileChange,
  McpToolCallBeginEvent, McpToolCallEndEvent, PatchApplyBeginEvent, PatchApplyEndEvent,
  TerminalInteractionEvent, ViewImageToolCallEvent, WebSearchBeginEvent, WebSearchEndEvent,
};
use orbitdock_connector_core::ConnectorEvent;
use orbitdock_protocol::conversation_contracts::render_hints::RenderHints;
use orbitdock_protocol::conversation_contracts::{
  command_execution_terminal_snapshot, compute_command_execution_preview, compute_tool_display,
  extract_compact_result_text, CommandExecutionAction, CommandExecutionRow, CommandExecutionStatus,
  ConversationRow, ConversationRowEntry, ToolDisplayInput, ToolRow,
};
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
use orbitdock_protocol::Provider;
use serde_json::{json, Value};
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

fn command_execution_status(event: &ExecCommandEndEvent) -> CommandExecutionStatus {
  match event.status {
    codex_protocol::protocol::ExecCommandStatus::Declined => CommandExecutionStatus::Declined,
    codex_protocol::protocol::ExecCommandStatus::Failed => CommandExecutionStatus::Failed,
    codex_protocol::protocol::ExecCommandStatus::Completed => {
      if event.exit_code == 0 {
        CommandExecutionStatus::Completed
      } else {
        CommandExecutionStatus::Failed
      }
    }
  }
}

fn tool_row_entry(row: ToolRow) -> ConversationRowEntry {
  row_entry(ConversationRow::Tool(with_display(row)))
}

fn command_execution_row_entry(row: CommandExecutionRow) -> ConversationRowEntry {
  row_entry(ConversationRow::CommandExecution(row))
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

fn command_actions_from_parsed(parsed_cmd: &[ParsedCommand]) -> Vec<CommandExecutionAction> {
  parsed_cmd
    .iter()
    .map(|command| match command {
      ParsedCommand::Read { cmd, name, path } => CommandExecutionAction::Read {
        command: cmd.clone(),
        name: name.clone(),
        path: path.display().to_string(),
      },
      ParsedCommand::ListFiles { cmd, path } => CommandExecutionAction::ListFiles {
        command: cmd.clone(),
        path: path.clone(),
      },
      ParsedCommand::Search { cmd, query, path } => CommandExecutionAction::Search {
        command: cmd.clone(),
        query: query.clone(),
        path: path.clone(),
      },
      ParsedCommand::Unknown { cmd } => CommandExecutionAction::Unknown {
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

fn command_preview(
  actions: &[CommandExecutionAction],
  live_output_preview: Option<&str>,
  aggregated_output: Option<&str>,
) -> Option<orbitdock_protocol::conversation_contracts::CommandExecutionPreview> {
  compute_command_execution_preview(actions, aggregated_output.or(live_output_preview))
}

/// Compute and attach tool_display to a ToolRow from its own fields.
fn with_display(mut row: ToolRow) -> ToolRow {
  let invocation_ref = row.invocation.is_object().then_some(&row.invocation);
  let result_str = extract_compact_result_text(row.result.as_ref());
  row.tool_display = Some(compute_tool_display(ToolDisplayInput {
    kind: row.kind,
    family: row.family,
    status: row.status,
    title: &row.title,
    subtitle: row.subtitle.as_deref(),
    summary: row.summary.as_deref(),
    duration_ms: row.duration_ms,
    invocation_input: invocation_ref,
    result_output: result_str.as_deref(),
  }));
  row
}

fn dynamic_tool_identity_from_name(
  tool_name: &str,
) -> Option<(ToolFamily, ToolKind, &'static str)> {
  match tool_name {
    "file_read" => Some((ToolFamily::FileRead, ToolKind::Read, "Read")),
    "file_write" => Some((ToolFamily::FileChange, ToolKind::Write, "Write")),
    "file_edit" => Some((ToolFamily::FileChange, ToolKind::Edit, "Edit")),
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
        path
          .as_deref()
          .map(|value| format!("Wrote {count} bytes to {value}"))
          .unwrap_or_else(|| format!("Wrote {count} bytes"))
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
) -> Vec<ConnectorEvent> {
  let command_str = display_command_from_exec_tokens(&event.command);
  let cwd = event.cwd.display().to_string();
  let command_actions = command_actions_from_parsed(&event.parsed_cmd);

  {
    let mut buffers = output_buffers.lock().await;
    buffers.insert(
      event.call_id.clone(),
      super::OutputBufferState {
        command: command_str.clone(),
        cwd: cwd.clone(),
        process_id: event.process_id.clone(),
        command_actions: command_actions.clone(),
        ..Default::default()
      },
    );
  }

  let new_cwd = event.cwd.to_string_lossy().to_string();
  let git_info = codex_git_utils::collect_git_info(&event.cwd).await;
  let (new_branch, new_sha) = match git_info {
    Some(info) => (info.branch, info.commit_hash.map(|s| s.0)),
    None => (None, None),
  };

  let mut connector_events = Vec::new();
  {
    let mut tracker = env_tracker.lock().await;
    let cwd_changed = tracker.cwd.as_deref() != Some(&new_cwd);
    let branch_changed = tracker.branch != new_branch;
    let sha_changed = tracker.sha != new_sha;
    if cwd_changed || branch_changed || sha_changed {
      tracker.cwd = Some(new_cwd.clone());
      tracker.branch = new_branch.clone();
      tracker.sha = new_sha.clone();
      connector_events.push(ConnectorEvent::EnvironmentChanged {
        cwd: Some(new_cwd.clone()),
        git_branch: new_branch,
        git_sha: new_sha,
      });
    }
  }

  let terminal_snapshot = command_execution_terminal_snapshot(&command_str, &cwd, None);
  connector_events.push(ConnectorEvent::ConversationRowCreated(
    command_execution_row_entry(CommandExecutionRow {
      id: event.call_id.clone(),
      status: CommandExecutionStatus::InProgress,
      command: command_str,
      cwd,
      process_id: event.process_id,
      command_actions,
      live_output_preview: None,
      aggregated_output: None,
      terminal_snapshot,
      preview: None,
      exit_code: None,
      duration_ms: None,
      render_hints: expandable_command_render_hints(),
    }),
  ));

  connector_events
}

pub(crate) async fn handle_exec_command_output_delta(
  event: ExecCommandOutputDeltaEvent,
  output_buffers: &SharedOutputBuffers,
) -> Vec<ConnectorEvent> {
  let chunk_str = String::from_utf8_lossy(&event.chunk).to_string();
  let next_row = {
    let mut buffers = output_buffers.lock().await;
    if let Some(buffer) = buffers.get_mut(&event.call_id) {
      buffer.append(&chunk_str);
      let now = Instant::now();
      if now.duration_since(buffer.last_broadcast).as_millis() < OUTPUT_STREAM_THROTTLE_MS {
        return vec![];
      }
      buffer.last_broadcast = now;
      CommandExecutionRow {
        id: event.call_id.clone(),
        status: CommandExecutionStatus::InProgress,
        command: buffer.command.clone(),
        cwd: buffer.cwd.clone(),
        process_id: buffer.process_id.clone(),
        command_actions: buffer.command_actions.clone(),
        live_output_preview: buffer.preview(),
        aggregated_output: None,
        terminal_snapshot: command_execution_terminal_snapshot(
          &buffer.command,
          &buffer.cwd,
          buffer.preview().as_deref(),
        ),
        preview: command_preview(&buffer.command_actions, buffer.preview().as_deref(), None),
        exit_code: None,
        duration_ms: None,
        render_hints: expandable_command_render_hints(),
      }
    } else {
      return vec![];
    }
  };

  if next_row.live_output_preview.is_none() {
    vec![]
  } else {
    let entry = command_execution_row_entry(next_row);
    vec![ConnectorEvent::ConversationRowUpdated {
      row_id: event.call_id,
      entry,
    }]
  }
}

pub(crate) async fn handle_exec_command_end(
  event: ExecCommandEndEvent,
  output_buffers: &SharedOutputBuffers,
) -> Vec<ConnectorEvent> {
  let streamed_output = {
    let mut buffers = output_buffers.lock().await;
    buffers
      .remove(&event.call_id)
      .map(|state| state.full_output)
      .unwrap_or_default()
  };

  let duration_ms = Some(event.duration.as_millis() as u64);
  let status = command_execution_status(&event);
  let command_actions = command_actions_from_parsed(&event.parsed_cmd);
  let command = display_command_from_exec_tokens(&event.command);
  let cwd = event.cwd.display().to_string();
  let aggregated_output = terminal_exec_output(&event, streamed_output);
  let terminal_snapshot =
    command_execution_terminal_snapshot(&command, &cwd, aggregated_output.as_deref());
  let preview = command_preview(&command_actions, None, aggregated_output.as_deref());

  let entry = command_execution_row_entry(CommandExecutionRow {
    id: event.call_id.clone(),
    status,
    command: command.clone(),
    cwd: cwd.clone(),
    process_id: event.process_id,
    command_actions,
    live_output_preview: None,
    aggregated_output,
    terminal_snapshot,
    preview,
    exit_code: Some(event.exit_code),
    duration_ms,
    render_hints: expandable_command_render_hints(),
  });
  vec![ConnectorEvent::ConversationRowUpdated {
    row_id: event.call_id,
    entry,
  }]
}

pub(crate) async fn handle_patch_apply_begin(
  event: PatchApplyBeginEvent,
  patch_contexts: &SharedPatchContexts,
) -> Vec<ConnectorEvent> {
  let files: Vec<String> = event
    .changes
    .keys()
    .map(|path| path.display().to_string())
    .collect();
  let first_file = files.first().cloned().unwrap_or_default();

  let unified_diff = event
    .changes
    .iter()
    .map(|(path, change)| match change {
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
    })
    .collect::<Vec<_>>()
    .join("\n\n");

  let invocation = json!({
      "path": first_file,
      "diff": unified_diff,
  });

  // Store for the end handler to merge
  {
    let mut contexts = patch_contexts.lock().await;
    contexts.insert(event.call_id.clone(), invocation.clone());
  }

  vec![ConnectorEvent::ConversationRowCreated(tool_row_entry(
    ToolRow {
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
    },
  ))]
}

pub(crate) async fn handle_patch_apply_end(
  event: PatchApplyEndEvent,
  patch_contexts: &SharedPatchContexts,
) -> Vec<ConnectorEvent> {
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
  });
  vec![ConnectorEvent::ConversationRowUpdated {
    row_id: event.call_id,
    entry,
  }]
}

pub(crate) fn handle_mcp_tool_call_begin(event: McpToolCallBeginEvent) -> Vec<ConnectorEvent> {
  let server = event.invocation.server.clone();
  let tool = event.invocation.tool.clone();
  let call_id = event.call_id.clone();

  vec![ConnectorEvent::ConversationRowCreated(tool_row_entry(
    ToolRow {
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
      invocation: json!({
          "server": server,
          "tool_name": tool,
          "input": event
              .invocation
              .arguments
              .as_ref()
              .and_then(|args| serde_json::to_value(args).ok()),
      }),
      result: None,
      render_hints: Default::default(),
      tool_display: None,
    },
  ))]
}

pub(crate) fn handle_mcp_tool_call_end(event: McpToolCallEndEvent) -> Vec<ConnectorEvent> {
  let (output_value, is_error) = match &event.result {
    Ok(result) => (serde_json::to_value(result).ok(), false),
    Err(message) => (Some(json!(message)), true),
  };

  let status = if is_error {
    ToolStatus::Failed
  } else {
    ToolStatus::Completed
  };

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
    invocation: json!({
        "server": event.invocation.server,
        "tool_name": event.invocation.tool,
        "output": output_value.clone(),
    }),
    result: Some(json!({
        "tool_name": event.invocation.tool,
        "raw_output": output_value,
    })),
    render_hints: Default::default(),
    tool_display: None,
  });
  vec![ConnectorEvent::ConversationRowUpdated {
    row_id: event.call_id,
    entry,
  }]
}

pub(crate) fn handle_web_search_begin(event: WebSearchBeginEvent) -> Vec<ConnectorEvent> {
  vec![ConnectorEvent::ConversationRowCreated(tool_row_entry(
    ToolRow {
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
    },
  ))]
}

pub(crate) fn handle_web_search_end(event: WebSearchEndEvent) -> Vec<ConnectorEvent> {
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
  });
  vec![ConnectorEvent::ConversationRowUpdated {
    row_id: event.call_id,
    entry,
  }]
}

pub(crate) fn handle_view_image_tool_call(event: ViewImageToolCallEvent) -> Vec<ConnectorEvent> {
  let path = event.path.to_string_lossy().to_string();
  vec![ConnectorEvent::ConversationRowCreated(tool_row_entry(
    ToolRow {
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
      render_hints: Default::default(),
      tool_display: None,
    },
  ))]
}

pub(crate) fn handle_dynamic_tool_call_request(
  event: DynamicToolCallRequest,
) -> Vec<ConnectorEvent> {
  let call_id = event.call_id.clone();
  let tool = event.tool.clone();
  let arguments = event.arguments.clone();
  let (family, kind, title) = dynamic_tool_identity_from_name(&tool).unwrap_or((
    ToolFamily::Generic,
    ToolKind::DynamicToolCall,
    tool.as_str(),
  ));
  vec![
    ConnectorEvent::ConversationRowCreated(tool_row_entry(ToolRow {
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
    })),
    ConnectorEvent::DynamicToolCallRequested {
      call_id,
      tool_name: event.tool,
      arguments: event.arguments,
    },
  ]
}

pub(crate) fn handle_dynamic_tool_call_response(
  event: DynamicToolCallResponseEvent,
) -> Vec<ConnectorEvent> {
  let tool_name = event.tool.clone();
  let arguments = event.arguments.clone();
  let output = dynamic_tool_output_to_text(&event.content_items, event.error);
  let status = if event.success {
    ToolStatus::Completed
  } else {
    ToolStatus::Failed
  };

  let (family, kind, title) = dynamic_tool_identity_from_output(output.as_ref())
    .or_else(|| dynamic_tool_identity_from_name(&tool_name))
    .unwrap_or((
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
  });
  vec![ConnectorEvent::ConversationRowUpdated {
    row_id: event.call_id,
    entry,
  }]
}

pub(crate) async fn handle_terminal_interaction(
  event: TerminalInteractionEvent,
  output_buffers: &SharedOutputBuffers,
) -> Vec<ConnectorEvent> {
  let snippet = format!("\n[stdin] {}\n", event.stdin);
  let next_row = {
    let mut buffers = output_buffers.lock().await;
    let entry = buffers.entry(event.call_id.clone()).or_default();
    entry.append(&snippet);
    entry.last_broadcast = Instant::now();
    CommandExecutionRow {
      id: event.call_id.clone(),
      status: CommandExecutionStatus::InProgress,
      command: entry.command.clone(),
      cwd: entry.cwd.clone(),
      process_id: entry.process_id.clone(),
      command_actions: entry.command_actions.clone(),
      live_output_preview: entry.preview(),
      aggregated_output: None,
      terminal_snapshot: command_execution_terminal_snapshot(
        &entry.command,
        &entry.cwd,
        entry.preview().as_deref(),
      ),
      preview: command_preview(&entry.command_actions, entry.preview().as_deref(), None),
      exit_code: None,
      duration_ms: None,
      render_hints: expandable_command_render_hints(),
    }
  };

  let entry = command_execution_row_entry(next_row);
  vec![ConnectorEvent::ConversationRowUpdated {
    row_id: event.call_id,
    entry,
  }]
}

#[cfg(test)]
mod tests {
  use super::{
    display_command_from_exec_tokens, handle_dynamic_tool_call_request,
    handle_dynamic_tool_call_response, handle_exec_command_begin, handle_exec_command_end,
    handle_exec_command_output_delta, handle_terminal_interaction,
  };
  use crate::event_mapping::{SharedEnvironmentTracker, SharedOutputBuffers};
  use crate::runtime::EnvironmentTracker;
  use codex_protocol::dynamic_tools::{DynamicToolCallOutputContentItem, DynamicToolCallRequest};
  use codex_protocol::parse_command::ParsedCommand;
  use codex_protocol::protocol::{
    DynamicToolCallResponseEvent, ExecCommandBeginEvent, ExecCommandEndEvent,
    ExecCommandOutputDeltaEvent, ExecCommandSource, ExecCommandStatus, ExecOutputStream,
  };
  use orbitdock_connector_core::ConnectorEvent;
  use orbitdock_protocol::conversation_contracts::ConversationRow;
  use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
  use std::collections::HashMap;
  use std::path::PathBuf;
  use std::sync::Arc;
  use std::time::Duration;

  fn shared_output_buffers() -> SharedOutputBuffers {
    Arc::new(tokio::sync::Mutex::new(HashMap::new()))
  }

  fn shared_env_tracker() -> SharedEnvironmentTracker {
    Arc::new(tokio::sync::Mutex::new(EnvironmentTracker {
      cwd: None,
      branch: None,
      sha: None,
    }))
  }

  #[tokio::test]
  async fn exec_command_begin_creates_command_execution_row() {
    let events = handle_exec_command_begin(
      ExecCommandBeginEvent {
        call_id: "cmd-1".to_string(),
        process_id: Some("pty-1".to_string()),
        turn_id: "turn-1".to_string(),
        command: vec!["sed".to_string(), "-n".to_string(), "1,40p".to_string()],
        cwd: PathBuf::from("/tmp/project"),
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
    )
    .await;

    let created = events.into_iter().find_map(|event| match event {
      ConnectorEvent::ConversationRowCreated(entry) => Some(entry),
      _ => None,
    });

    let entry = created.expect("command execution row");
    let ConversationRow::CommandExecution(row) = entry.row else {
      panic!("expected command execution row");
    };

    assert_eq!(row.command, "sed -n 1,40p");
    assert_eq!(row.cwd, "/tmp/project");
    assert_eq!(row.process_id.as_deref(), Some("pty-1"));
    assert_eq!(
      row.status,
      orbitdock_protocol::conversation_contracts::CommandExecutionStatus::InProgress
    );
    assert_eq!(row.command_actions.len(), 1);
    let snapshot = row.terminal_snapshot.as_ref().expect("terminal snapshot");
    assert_eq!(snapshot.command, "sed -n 1,40p");
    assert_eq!(snapshot.cwd, "/tmp/project");
    assert!(snapshot.output.is_none());
  }

  #[tokio::test]
  async fn exec_command_end_updates_command_execution_row_with_output() {
    let output_buffers = shared_output_buffers();
    let env_tracker = shared_env_tracker();

    handle_exec_command_begin(
      ExecCommandBeginEvent {
        call_id: "cmd-2".to_string(),
        process_id: Some("pty-2".to_string()),
        turn_id: "turn-2".to_string(),
        command: vec!["rg".to_string(), "needle".to_string(), "src".to_string()],
        cwd: PathBuf::from("/tmp/project"),
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
        cwd: PathBuf::from("/tmp/project"),
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

    let updated = events.into_iter().find_map(|event| match event {
      ConnectorEvent::ConversationRowUpdated { entry, .. } => Some(entry),
      _ => None,
    });

    let entry = updated.expect("updated row");
    let ConversationRow::CommandExecution(row) = entry.row else {
      panic!("expected command execution row");
    };

    assert_eq!(
      row.status,
      orbitdock_protocol::conversation_contracts::CommandExecutionStatus::Completed
    );
    assert_eq!(
      row
        .aggregated_output
        .as_deref()
        .map(|value| value.trim_end_matches('\n')),
      Some("src/lib.rs:needle")
    );
    let snapshot = row.terminal_snapshot.as_ref().expect("terminal snapshot");
    assert_eq!(snapshot.command, "rg needle src");
    assert_eq!(snapshot.cwd, "/tmp/project");
    assert_eq!(
      snapshot
        .output
        .as_deref()
        .map(|value| value.trim_end_matches('\n')),
      Some("src/lib.rs:needle")
    );
    assert_eq!(row.exit_code, Some(0));
    assert_eq!(row.duration_ms, Some(42));
  }

  #[tokio::test]
  async fn exec_command_end_prefers_richer_stream_output_when_terminal_payload_is_short() {
    let output_buffers = shared_output_buffers();
    let env_tracker = shared_env_tracker();

    handle_exec_command_begin(
      ExecCommandBeginEvent {
        call_id: "cmd-2b".to_string(),
        process_id: Some("pty-2b".to_string()),
        turn_id: "turn-2b".to_string(),
        command: vec!["cargo".to_string(), "test".to_string()],
        cwd: PathBuf::from("/tmp/project"),
        parsed_cmd: vec![ParsedCommand::Unknown {
          cmd: "cargo test".to_string(),
        }],
        source: ExecCommandSource::Agent,
        interaction_input: None,
      },
      &output_buffers,
      &env_tracker,
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
        cwd: PathBuf::from("/tmp/project"),
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

    let updated = events.into_iter().find_map(|event| match event {
      ConnectorEvent::ConversationRowUpdated { entry, .. } => Some(entry),
      _ => None,
    });

    let entry = updated.expect("updated row");
    let ConversationRow::CommandExecution(row) = entry.row else {
      panic!("expected command execution row");
    };

    let expected_streamed = streamed.trim_end_matches('\n');
    assert_eq!(
      row
        .aggregated_output
        .as_deref()
        .map(|value| value.trim_end_matches('\n')),
      Some(expected_streamed)
    );
    let snapshot = row.terminal_snapshot.as_ref().expect("terminal snapshot");
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
        cwd: PathBuf::from("/tmp/project"),
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

    let updated = events.into_iter().find_map(|event| match event {
      ConnectorEvent::ConversationRowUpdated { entry, .. } => Some(entry),
      _ => None,
    });

    let entry = updated.expect("updated row");
    let ConversationRow::CommandExecution(row) = entry.row else {
      panic!("expected command execution row");
    };

    assert_eq!(
      row
        .aggregated_output
        .as_deref()
        .map(|value| value.trim_end_matches('\n')),
      Some("done")
    );
    assert_eq!(
      row.status,
      orbitdock_protocol::conversation_contracts::CommandExecutionStatus::Completed
    );
    let snapshot = row.terminal_snapshot.as_ref().expect("terminal snapshot");
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
        cwd: PathBuf::from("/tmp/project"),
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

    let updated = events.into_iter().find_map(|event| match event {
      ConnectorEvent::ConversationRowUpdated { entry, .. } => Some(entry),
      _ => None,
    });

    let entry = updated.expect("updated row");
    let ConversationRow::CommandExecution(row) = entry.row else {
      panic!("expected command execution row");
    };

    assert_eq!(
      row.status,
      orbitdock_protocol::conversation_contracts::CommandExecutionStatus::Declined
    );
    assert_eq!(row.aggregated_output.as_deref(), Some("permission denied"));
    let snapshot = row.terminal_snapshot.as_ref().expect("terminal snapshot");
    assert_eq!(snapshot.command, "rm -rf /tmp/project");
    assert_eq!(snapshot.cwd, "/tmp/project");
    assert_eq!(snapshot.output.as_deref(), Some("permission denied"));
  }

  #[tokio::test]
  async fn terminal_interaction_updates_command_execution_snapshot_with_stdin() {
    let output_buffers = shared_output_buffers();
    let env_tracker = shared_env_tracker();

    handle_exec_command_begin(
      ExecCommandBeginEvent {
        call_id: "cmd-stdin-1".to_string(),
        process_id: Some("pty-stdin-1".to_string()),
        turn_id: "turn-stdin-1".to_string(),
        command: vec!["python".to_string(), "-i".to_string()],
        cwd: PathBuf::from("/tmp/project"),
        parsed_cmd: vec![ParsedCommand::Unknown {
          cmd: "python -i".to_string(),
        }],
        source: ExecCommandSource::Agent,
        interaction_input: None,
      },
      &output_buffers,
      &env_tracker,
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

    let updated = events.into_iter().find_map(|event| match event {
      ConnectorEvent::ConversationRowUpdated { entry, .. } => Some(entry),
      _ => None,
    });

    let entry = updated.expect("updated row");
    let ConversationRow::CommandExecution(row) = entry.row else {
      panic!("expected command execution row");
    };

    let snapshot = row.terminal_snapshot.as_ref().expect("terminal snapshot");
    assert_eq!(snapshot.command, "python -i");
    assert_eq!(snapshot.cwd, "/tmp/project");
    assert!(snapshot
      .output
      .as_deref()
      .expect("snapshot output")
      .contains("[stdin] print('hello')"));
    assert!(snapshot.transcript().contains("[stdin] print('hello')"));
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
        cwd: PathBuf::from("/tmp/project"),
        parsed_cmd: vec![ParsedCommand::Unknown {
          cmd: "/bin/zsh -lc swiftc -print-target-info".to_string(),
        }],
        source: ExecCommandSource::Agent,
        interaction_input: None,
      },
      &shared_output_buffers(),
      &shared_env_tracker(),
    )
    .await;

    let created = events.into_iter().find_map(|event| match event {
      ConnectorEvent::ConversationRowCreated(entry) => Some(entry),
      _ => None,
    });

    let entry = created.expect("command execution row");
    let ConversationRow::CommandExecution(row) = entry.row else {
      panic!("expected command execution row");
    };
    assert_eq!(row.command, "swiftc -print-target-info");
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
    let created = events.into_iter().find_map(|event| match event {
      ConnectorEvent::ConversationRowCreated(entry) => Some(entry),
      _ => None,
    });
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
    let updated = events.into_iter().find_map(|event| match event {
      ConnectorEvent::ConversationRowUpdated { entry, .. } => Some(entry),
      _ => None,
    });
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
    let updated = events.into_iter().find_map(|event| match event {
      ConnectorEvent::ConversationRowUpdated { entry, .. } => Some(entry),
      _ => None,
    });
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
    let updated = events.into_iter().find_map(|event| match event {
      ConnectorEvent::ConversationRowUpdated { entry, .. } => Some(entry),
      _ => None,
    });
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
    let updated = events.into_iter().find_map(|event| match event {
      ConnectorEvent::ConversationRowUpdated { entry, .. } => Some(entry),
      _ => None,
    });
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
    let updated = events.into_iter().find_map(|event| match event {
      ConnectorEvent::ConversationRowUpdated { entry, .. } => Some(entry),
      _ => None,
    });
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
