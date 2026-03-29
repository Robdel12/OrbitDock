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
  compute_command_execution_preview, compute_tool_display, CommandExecutionAction,
  CommandExecutionRow, CommandExecutionStatus, ConversationRow, ConversationRowEntry,
  ToolDisplayInput, ToolRow,
};
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
use orbitdock_protocol::Provider;
use serde_json::json;
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
  [
    (!event.aggregated_output.trim().is_empty()).then(|| event.aggregated_output.clone()),
    (!event.formatted_output.trim().is_empty()).then(|| event.formatted_output.clone()),
    combined_exec_stdio(&event.stdout, &event.stderr),
    (!streamed_output.trim().is_empty()).then_some(streamed_output),
  ]
  .into_iter()
  .flatten()
  .next()
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

fn command_preview(
  actions: &[CommandExecutionAction],
  live_output_preview: Option<&str>,
  aggregated_output: Option<&str>,
) -> Option<orbitdock_protocol::conversation_contracts::CommandExecutionPreview> {
  compute_command_execution_preview(actions, aggregated_output.or(live_output_preview))
}

/// Compute and attach tool_display to a ToolRow from its own fields.
fn with_display(mut row: ToolRow) -> ToolRow {
  let invocation_ref = if row.invocation.is_object() {
    Some(&row.invocation)
  } else {
    None
  };
  let result_str = row
    .result
    .as_ref()
    .and_then(|v| v.get("output").and_then(|o| o.as_str()))
    .map(String::from);
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

pub(crate) async fn handle_exec_command_begin(
  event: ExecCommandBeginEvent,
  output_buffers: &SharedOutputBuffers,
  env_tracker: &SharedEnvironmentTracker,
) -> Vec<ConnectorEvent> {
  let command_str = event.command.join(" ");
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
  let git_info = codex_core::git_info::collect_git_info(&event.cwd).await;
  let (new_branch, new_sha) = match git_info {
    Some(info) => (info.branch, info.commit_hash),
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
  let aggregated_output = terminal_exec_output(&event, streamed_output);
  let preview = command_preview(&command_actions, None, aggregated_output.as_deref());

  let entry = command_execution_row_entry(CommandExecutionRow {
    id: event.call_id.clone(),
    status,
    command: event.command.join(" "),
    cwd: event.cwd.display().to_string(),
    process_id: event.process_id,
    command_actions,
    live_output_preview: None,
    aggregated_output,
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
  vec![
    ConnectorEvent::ConversationRowCreated(tool_row_entry(ToolRow {
      id: call_id.clone(),
      provider: Provider::Codex,
      family: ToolFamily::Generic,
      kind: ToolKind::DynamicToolCall,
      status: ToolStatus::Running,
      title: tool.clone(),
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
  let output = dynamic_tool_output_to_text(&event.content_items, event.error);
  let status = if event.success {
    ToolStatus::Completed
  } else {
    ToolStatus::Failed
  };

  let entry = tool_row_entry(ToolRow {
    id: event.call_id.clone(),
    provider: Provider::Codex,
    family: ToolFamily::Generic,
    kind: ToolKind::DynamicToolCall,
    status,
    title: String::new(),
    subtitle: None,
    summary: output.clone(),
    preview: None,
    started_at: None,
    ended_at: Some(iso_now()),
    duration_ms: Some(event.duration.as_millis() as u64),
    grouping_key: None,
    invocation: json!({
        "tool_name": "",
    }),
    result: Some(json!({
        "tool_name": "",
        "raw_output": output.as_ref().map(|o| json!(o)),
        "summary": output,
    })),
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
    handle_exec_command_begin, handle_exec_command_end, handle_exec_command_output_delta,
  };
  use crate::event_mapping::{SharedEnvironmentTracker, SharedOutputBuffers};
  use crate::runtime::EnvironmentTracker;
  use codex_protocol::parse_command::ParsedCommand;
  use codex_protocol::protocol::{
    ExecCommandBeginEvent, ExecCommandEndEvent, ExecCommandOutputDeltaEvent, ExecCommandSource,
    ExecCommandStatus, ExecOutputStream,
  };
  use orbitdock_connector_core::ConnectorEvent;
  use orbitdock_protocol::conversation_contracts::ConversationRow;
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
      row.aggregated_output.as_deref(),
      Some("src/lib.rs:needle\n")
    );
    assert_eq!(row.exit_code, Some(0));
    assert_eq!(row.duration_ms, Some(42));
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

    assert_eq!(row.aggregated_output.as_deref(), Some("done\n"));
    assert_eq!(
      row.status,
      orbitdock_protocol::conversation_contracts::CommandExecutionStatus::Completed
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
  }
}
