use std::collections::HashMap;

use codex_app_server_protocol::{
  DynamicToolCallOutputContentItem, FileUpdateChange, PatchApplyStatus, PatchChangeKind,
  ThreadItem, UserInput,
};
use orbitdock_connector_core::{ConnectorOutput, ConnectorStateEvent, ConnectorTransportEffect};
use orbitdock_protocol::conversation_contracts::{
  classify_tool_name, ConversationRow, MessageRowContent, NoticeRow, NoticeRowKind,
  NoticeRowSeverity, ToolRow,
};
use orbitdock_protocol::domain_events::{
  AgentType, GuardianAssessmentPayload, ToolFamily, ToolKind, ToolStatus,
};
use orbitdock_protocol::{Provider, SubagentInfo, SubagentStatus};
use serde_json::{json, Value};
use tracing::debug;

use super::AppServerSessionRoute;
use crate::row_mapping::{row_created_output, row_updated_output, tool_row_entry};
use crate::runtime::{apply_delta_thinking, finalized_thinking_row_entry, row_entry};
use crate::workers::iso_now;

pub(crate) async fn map_item(
  item: ThreadItem,
  started: bool,
  route: &AppServerSessionRoute,
) -> Vec<ConnectorOutput> {
  match item {
    ThreadItem::UserMessage { id, content } if !started => {
      let text = content
        .into_iter()
        .filter_map(|input| match input {
          UserInput::Text { text, .. } => Some(text),
          _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n");
      vec![row_created_output(row_entry(ConversationRow::User(
        MessageRowContent {
          id,
          content: text,
          turn_id: None,
          timestamp: Some(iso_now()),
          is_streaming: false,
          images: vec![],
          memory_citation: None,
          delivery_status: None,
        },
      )))]
    }
    ThreadItem::AgentMessage { id, text, .. } if !started => {
      route.state.streaming_message.lock().await.take();
      vec![row_updated_output(
        id.clone(),
        row_entry(ConversationRow::Assistant(MessageRowContent {
          id,
          content: text,
          turn_id: None,
          timestamp: Some(iso_now()),
          is_streaming: false,
          images: vec![],
          memory_citation: None,
          delivery_status: None,
        })),
      )]
    }
    ThreadItem::Plan { id, text } => {
      let message_id = format!("plan-{id}");
      if started {
        apply_delta_thinking(&route.state.delta_buffers, message_id, text).await
      } else {
        route.state.delta_buffers.lock().await.remove(&message_id);
        let mut outputs = vec![row_updated_output(
          message_id.clone(),
          finalized_thinking_row_entry(message_id, text.clone()),
        )];
        if !text.trim().is_empty() {
          outputs.push(ConnectorStateEvent::PlanUpdated(text).into());
        }
        outputs
      }
    }
    ThreadItem::Reasoning {
      id,
      summary,
      content,
    } if !started => {
      let mut outputs = Vec::new();
      for (idx, text) in summary.into_iter().enumerate() {
        let message_id = format!("reasoning-summary-{id}-{idx}");
        route.state.delta_buffers.lock().await.remove(&message_id);
        outputs.push(row_updated_output(
          message_id.clone(),
          finalized_thinking_row_entry(message_id, text),
        ));
      }
      for (idx, text) in content.into_iter().enumerate() {
        let message_id = format!("reasoning-raw-{id}-{idx}");
        route.state.delta_buffers.lock().await.remove(&message_id);
        outputs.push(row_updated_output(
          message_id.clone(),
          finalized_thinking_row_entry(message_id, text),
        ));
      }
      outputs
    }
    ThreadItem::CommandExecution {
      id,
      command,
      cwd,
      process_id,
      status,
      command_actions,
      aggregated_output,
      exit_code,
      duration_ms,
      ..
    } => {
      let buffered_output = if started {
        None
      } else {
        route
          .state
          .delta_buffers
          .lock()
          .await
          .remove(&output_buffer_key("command", &id))
      };
      let output = aggregated_output.or(buffered_output);
      let is_running = started
        || matches!(
          status,
          codex_app_server_protocol::CommandExecutionStatus::InProgress
        );
      let row = ToolRow {
        id: id.clone(),
        provider: Provider::Codex,
        family: ToolFamily::Shell,
        kind: ToolKind::Bash,
        status: command_execution_tool_status(status, is_running, exit_code),
        title: command.clone(),
        subtitle: Some(cwd.display().to_string()),
        summary: output.clone(),
        preview: None,
        started_at: started.then(iso_now),
        ended_at: (!is_running).then(iso_now),
        duration_ms: duration_millis(duration_ms),
        grouping_key: None,
        invocation: json!({
          "command": command,
          "cwd": cwd.display().to_string(),
          "command_actions": command_actions,
        }),
        result: output.map(|output| {
          json!({
            "output": output,
            "exit_code": exit_code,
          })
        }),
        render_hints: Default::default(),
        tool_display: None,
        shell_execution: None,
      };
      let mut outputs = tool_row_outputs(id.clone(), row, started);
      if started {
        outputs.push(ConnectorOutput::Transport(
          ConnectorTransportEffect::ToolPtyCreated {
            tool_id: id.clone(),
          },
        ));
      } else {
        outputs.push(ConnectorOutput::Transport(
          ConnectorTransportEffect::ToolPtyExited {
            tool_id: id,
            exit_code,
          },
        ));
      }
      let _ = process_id;
      outputs
    }
    ThreadItem::FileChange {
      id,
      changes,
      status,
    } => {
      let output = if started {
        None
      } else {
        route
          .state
          .delta_buffers
          .lock()
          .await
          .remove(&output_buffer_key("file-change", &id))
      };
      let row = file_change_tool_row(id.clone(), changes, status, started, output);
      tool_row_outputs(id, row, started)
    }
    ThreadItem::McpToolCall {
      id,
      server,
      tool,
      status,
      arguments,
      result,
      error,
      duration_ms,
      ..
    } => {
      let is_running = started
        || matches!(
          status,
          codex_app_server_protocol::McpToolCallStatus::InProgress
        );
      let row = ToolRow {
        id: id.clone(),
        provider: Provider::Codex,
        family: ToolFamily::Mcp,
        kind: ToolKind::McpToolCall,
        status: if is_running {
          ToolStatus::Running
        } else if error.is_none() {
          ToolStatus::Completed
        } else {
          ToolStatus::Failed
        },
        title: tool.clone(),
        subtitle: Some(server.clone()),
        summary: error.as_ref().map(|error| error.message.clone()),
        preview: None,
        started_at: started.then(iso_now),
        ended_at: (!is_running).then(iso_now),
        duration_ms: duration_millis(duration_ms),
        grouping_key: None,
        invocation: json!({
          "server": server,
          "tool": tool,
          "arguments": arguments,
        }),
        result: serde_json::to_value(result).ok(),
        render_hints: Default::default(),
        tool_display: None,
        shell_execution: None,
      };
      tool_row_outputs(id, row, started)
    }
    ThreadItem::DynamicToolCall {
      id,
      namespace,
      tool,
      arguments,
      status,
      content_items,
      success,
      duration_ms,
    } => map_dynamic_tool(DynamicToolCallArgs {
      id,
      namespace,
      tool,
      arguments,
      content_items,
      success: success.unwrap_or(!matches!(
        status,
        codex_app_server_protocol::DynamicToolCallStatus::Failed
      )),
      duration_ms,
      started,
    }),
    ThreadItem::CollabAgentToolCall {
      id,
      tool,
      status,
      sender_thread_id,
      receiver_thread_ids,
      prompt,
      model,
      reasoning_effort,
      agents_states,
    } => map_collab_agent_tool(CollabAgentToolCallArgs {
      id,
      tool,
      status,
      sender_thread_id,
      receiver_thread_ids,
      prompt,
      model,
      reasoning_effort: reasoning_effort.map(|value| format!("{value:?}")),
      agents_states,
      started,
    }),
    ThreadItem::WebSearch { id, query, action } => {
      let (family, kind) = classify_tool_name("web_search");
      map_tool_row(ToolRowArgs {
        id,
        family,
        kind,
        title: "web_search".to_string(),
        summary: None,
        invocation: json!({ "query": query, "action": action }),
        result: None,
        started,
        success: true,
        duration_ms: None,
      })
    }
    ThreadItem::ImageView { id, path } => map_tool_row(ToolRowArgs {
      id,
      family: ToolFamily::Image,
      kind: ToolKind::ViewImage,
      title: path.display().to_string(),
      summary: None,
      invocation: json!({ "path": path.display().to_string() }),
      result: None,
      started,
      success: true,
      duration_ms: None,
    }),
    ThreadItem::ImageGeneration {
      id,
      status,
      revised_prompt,
      result,
      saved_path,
    } => map_tool_row(ToolRowArgs {
      id,
      family: ToolFamily::Image,
      kind: ToolKind::ImageGeneration,
      title: "Image generation".to_string(),
      summary: revised_prompt,
      invocation: json!({ "status": status }),
      result: Some(json!({ "result": result, "saved_path": saved_path })),
      started,
      success: true,
      duration_ms: None,
    }),
    ThreadItem::EnteredReviewMode { id, review } if !started => {
      vec![row_created_output(row_entry(ConversationRow::Notice(
        NoticeRow {
          id,
          kind: NoticeRowKind::Generic,
          severity: NoticeRowSeverity::Info,
          title: "Review mode".to_string(),
          summary: Some(review.clone()),
          body: Some(review),
          render_hints: Default::default(),
        },
      )))]
    }
    ThreadItem::ExitedReviewMode { id, review } if !started => {
      vec![row_created_output(row_entry(ConversationRow::Assistant(
        MessageRowContent {
          id,
          content: review,
          turn_id: None,
          timestamp: Some(iso_now()),
          is_streaming: false,
          images: vec![],
          memory_citation: None,
          delivery_status: None,
        },
      )))]
    }
    ThreadItem::ContextCompaction { id } => map_tool_row(ToolRowArgs {
      id,
      family: ToolFamily::Context,
      kind: ToolKind::CompactContext,
      title: if started {
        "Compacting context".to_string()
      } else {
        "Context compacted".to_string()
      },
      summary: None,
      invocation: json!({}),
      result: (!started).then(|| json!({ "summary": "Context compacted" })),
      started,
      success: true,
      duration_ms: None,
    }),
    other => {
      debug!(item = ?other, started, "Unhandled Codex app-server item");
      Vec::new()
    }
  }
}

pub(crate) fn map_terminal_interaction(
  event: codex_app_server_protocol::TerminalInteractionNotification,
) -> Vec<ConnectorOutput> {
  if event.stdin.is_empty() {
    return Vec::new();
  }
  vec![ConnectorOutput::Transport(
    ConnectorTransportEffect::ToolPtyOutput {
      tool_id: event.item_id,
      bytes: event.stdin.into_bytes(),
    },
  )]
}

pub(crate) struct CollabAgentToolCallArgs {
  pub(crate) id: String,
  pub(crate) tool: codex_app_server_protocol::CollabAgentTool,
  pub(crate) status: codex_app_server_protocol::CollabAgentToolCallStatus,
  pub(crate) sender_thread_id: String,
  pub(crate) receiver_thread_ids: Vec<String>,
  pub(crate) prompt: Option<String>,
  pub(crate) model: Option<String>,
  pub(crate) reasoning_effort: Option<String>,
  pub(crate) agents_states: HashMap<String, codex_app_server_protocol::CollabAgentState>,
  pub(crate) started: bool,
}

pub(crate) fn map_collab_agent_tool(args: CollabAgentToolCallArgs) -> Vec<ConnectorOutput> {
  let CollabAgentToolCallArgs {
    id,
    tool,
    status,
    sender_thread_id,
    receiver_thread_ids,
    prompt,
    model,
    reasoning_effort,
    agents_states,
    started,
  } = args;
  let (kind, title) = collab_agent_tool_identity(&tool);
  let running = started
    || matches!(
      status,
      codex_app_server_protocol::CollabAgentToolCallStatus::InProgress
    );
  let success = !matches!(
    status,
    codex_app_server_protocol::CollabAgentToolCallStatus::Failed
  );
  let worker_summary = collab_agent_worker_summary(&receiver_thread_ids);
  let worker_id = receiver_thread_ids.first().cloned();
  let worker_ids = receiver_thread_ids.clone();
  let summary = if running {
    None
  } else {
    Some(format!(
      "{} {}",
      title,
      if success { "completed" } else { "failed" }
    ))
  };
  let invocation = json!({
    "agent_type": collab_agent_tool_name(&tool),
    "worker_ids": worker_ids,
    "worker_id": worker_id,
    "sender_thread_id": sender_thread_id,
    "task_summary": prompt.clone(),
    "model": model.clone(),
    "reasoning_effort": reasoning_effort,
  });
  let result = (!running).then(|| {
    json!({
      "summary": summary,
      "worker_ids": invocation["worker_ids"].clone(),
      "agents_states": agents_states.clone(),
    })
  });
  let row = ToolRow {
    id: id.clone(),
    provider: Provider::Codex,
    family: ToolFamily::Agent,
    kind,
    status: if running {
      ToolStatus::Running
    } else if success {
      ToolStatus::Completed
    } else {
      ToolStatus::Failed
    },
    title: title.to_string(),
    subtitle: prompt.clone().or(worker_summary),
    summary,
    preview: None,
    started_at: started.then(iso_now),
    ended_at: (!running).then(iso_now),
    duration_ms: None,
    grouping_key: None,
    invocation,
    result,
    render_hints: Default::default(),
    tool_display: None,
    shell_execution: None,
  };

  let mut outputs = tool_row_outputs(id, row, started);
  let subagents = collab_agent_subagents(
    &sender_thread_id,
    prompt.as_deref(),
    model.as_deref(),
    &agents_states,
  );
  if !subagents.is_empty() {
    outputs.push(ConnectorStateEvent::SubagentsUpdated { subagents }.into());
  }
  outputs
}

fn collab_agent_tool_identity(
  tool: &codex_app_server_protocol::CollabAgentTool,
) -> (ToolKind, &'static str) {
  match tool {
    codex_app_server_protocol::CollabAgentTool::SpawnAgent => (ToolKind::SpawnAgent, "Agent"),
    codex_app_server_protocol::CollabAgentTool::SendInput => {
      (ToolKind::SendAgentInput, "Agent interaction")
    }
    codex_app_server_protocol::CollabAgentTool::ResumeAgent => {
      (ToolKind::ResumeAgent, "Resume agent")
    }
    codex_app_server_protocol::CollabAgentTool::Wait => (ToolKind::WaitAgent, "Waiting for agents"),
    codex_app_server_protocol::CollabAgentTool::CloseAgent => (ToolKind::CloseAgent, "Close agent"),
  }
}

fn collab_agent_tool_name(tool: &codex_app_server_protocol::CollabAgentTool) -> &'static str {
  match tool {
    codex_app_server_protocol::CollabAgentTool::SpawnAgent => "spawn_agent",
    codex_app_server_protocol::CollabAgentTool::SendInput => "send_input",
    codex_app_server_protocol::CollabAgentTool::ResumeAgent => "resume_agent",
    codex_app_server_protocol::CollabAgentTool::Wait => "wait",
    codex_app_server_protocol::CollabAgentTool::CloseAgent => "close_agent",
  }
}

fn collab_agent_worker_summary(receiver_thread_ids: &[String]) -> Option<String> {
  match receiver_thread_ids {
    [] => None,
    [worker_id] => Some(worker_id.clone()),
    many => Some(format!("{} agents", many.len())),
  }
}

fn collab_agent_subagents(
  sender_thread_id: &str,
  prompt: Option<&str>,
  model: Option<&str>,
  agents_states: &HashMap<String, codex_app_server_protocol::CollabAgentState>,
) -> Vec<SubagentInfo> {
  agents_states
    .iter()
    .map(|(agent_id, state)| {
      let now = iso_now();
      let status = map_collab_agent_status(state.status.clone());
      let is_terminal = matches!(
        status,
        SubagentStatus::Completed
          | SubagentStatus::Failed
          | SubagentStatus::Shutdown
          | SubagentStatus::NotFound
      );
      SubagentInfo {
        id: agent_id.clone(),
        agent_type: AgentType::GeneralPurpose,
        started_at: now.clone(),
        ended_at: is_terminal.then(|| now.clone()),
        provider: Some(Provider::Codex),
        label: Some(agent_id.clone()),
        status,
        task_summary: prompt
          .map(str::trim)
          .filter(|value| !value.is_empty())
          .map(ToOwned::to_owned),
        result_summary: (status == SubagentStatus::Completed)
          .then(|| state.message.clone())
          .flatten(),
        error_summary: (status == SubagentStatus::Failed).then(|| {
          state
            .message
            .clone()
            .unwrap_or_else(|| "Agent failed".to_string())
        }),
        parent_subagent_id: Some(sender_thread_id.to_string()),
        model: model.map(ToOwned::to_owned),
        last_activity_at: Some(now),
      }
    })
    .collect()
}

fn map_collab_agent_status(status: codex_app_server_protocol::CollabAgentStatus) -> SubagentStatus {
  match status {
    codex_app_server_protocol::CollabAgentStatus::PendingInit => SubagentStatus::Pending,
    codex_app_server_protocol::CollabAgentStatus::Running => SubagentStatus::Running,
    codex_app_server_protocol::CollabAgentStatus::Interrupted => SubagentStatus::Interrupted,
    codex_app_server_protocol::CollabAgentStatus::Completed => SubagentStatus::Completed,
    codex_app_server_protocol::CollabAgentStatus::Errored => SubagentStatus::Failed,
    codex_app_server_protocol::CollabAgentStatus::Shutdown => SubagentStatus::Shutdown,
    codex_app_server_protocol::CollabAgentStatus::NotFound => SubagentStatus::NotFound,
  }
}

pub(crate) struct DynamicToolCallArgs {
  pub(crate) id: String,
  pub(crate) namespace: Option<String>,
  pub(crate) tool: String,
  pub(crate) arguments: Value,
  pub(crate) content_items: Option<Vec<DynamicToolCallOutputContentItem>>,
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
    return map_tool_row(ToolRowArgs {
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

  map_tool_row(ToolRowArgs {
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
  json!({
    "namespace": namespace,
    "tool_name": tool_name,
    "raw_input": arguments,
  })
}

fn dynamic_tool_output_to_text(
  content_items: Option<&[DynamicToolCallOutputContentItem]>,
) -> Option<String> {
  let mut lines = Vec::new();
  for item in content_items.unwrap_or_default() {
    match item {
      DynamicToolCallOutputContentItem::InputText { text } if !text.is_empty() => {
        lines.push(text.clone());
      }
      DynamicToolCallOutputContentItem::InputImage { image_url } => {
        lines.push(format!("[image] {image_url}"));
      }
      DynamicToolCallOutputContentItem::InputText { .. } => {}
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

struct ToolRowArgs {
  id: String,
  family: ToolFamily,
  kind: ToolKind,
  title: String,
  summary: Option<String>,
  invocation: serde_json::Value,
  result: Option<serde_json::Value>,
  started: bool,
  success: bool,
  duration_ms: Option<u64>,
}

fn map_tool_row(args: ToolRowArgs) -> Vec<ConnectorOutput> {
  let ToolRowArgs {
    id,
    family,
    kind,
    title,
    summary,
    invocation,
    result,
    started,
    success,
    duration_ms,
  } = args;
  let row = ToolRow {
    id: id.clone(),
    provider: Provider::Codex,
    family,
    kind,
    status: if started {
      ToolStatus::Running
    } else if success {
      ToolStatus::Completed
    } else {
      ToolStatus::Failed
    },
    title,
    subtitle: None,
    summary,
    preview: None,
    started_at: started.then(iso_now),
    ended_at: (!started).then(iso_now),
    duration_ms,
    grouping_key: None,
    invocation,
    result,
    render_hints: Default::default(),
    tool_display: None,
    shell_execution: None,
  };
  tool_row_outputs(id, row, started)
}

pub(crate) fn tool_row_outputs(id: String, row: ToolRow, started: bool) -> Vec<ConnectorOutput> {
  if started {
    vec![row_created_output(tool_row_entry(row))]
  } else {
    vec![row_updated_output(id, tool_row_entry(row))]
  }
}

fn duration_millis(value: Option<i64>) -> Option<u64> {
  value.and_then(|inner| u64::try_from(inner).ok())
}

pub(crate) fn command_execution_tool_status(
  status: codex_app_server_protocol::CommandExecutionStatus,
  is_running: bool,
  exit_code: Option<i32>,
) -> ToolStatus {
  if is_running {
    return ToolStatus::Running;
  }

  match status {
    codex_app_server_protocol::CommandExecutionStatus::Completed => ToolStatus::Completed,
    codex_app_server_protocol::CommandExecutionStatus::Failed => ToolStatus::Failed,
    codex_app_server_protocol::CommandExecutionStatus::Declined => ToolStatus::Cancelled,
    codex_app_server_protocol::CommandExecutionStatus::InProgress => {
      if exit_code.unwrap_or(1) == 0 {
        ToolStatus::Completed
      } else {
        ToolStatus::Failed
      }
    }
  }
}

pub(crate) fn output_buffer_key(kind: &str, item_id: &str) -> String {
  format!("{kind}-output-{item_id}")
}

pub(crate) fn file_change_tool_row(
  id: String,
  changes: Vec<FileUpdateChange>,
  status: PatchApplyStatus,
  started: bool,
  output: Option<String>,
) -> ToolRow {
  let (files, diff, invocation) = file_change_invocation(&changes);
  let first_file = files
    .first()
    .cloned()
    .unwrap_or_else(|| "Apply patch".to_string());
  let tool_status = file_change_tool_status(status, started);
  let output = output.filter(|value| !value.trim().is_empty());
  let summary = match tool_status {
    ToolStatus::Running => None,
    ToolStatus::Completed => output.clone().or_else(|| Some("Patch applied".to_string())),
    ToolStatus::Cancelled => Some("Patch declined".to_string()),
    ToolStatus::Failed => output.clone().or_else(|| Some("Patch failed".to_string())),
    ToolStatus::Pending | ToolStatus::Blocked | ToolStatus::NeedsInput => None,
  };
  let result = if output.is_some() || !diff.is_empty() {
    Some(json!({
      "tool_name": "Edit",
      "summary": summary.clone(),
      "output": output.unwrap_or_default(),
      "diff": diff,
    }))
  } else {
    None
  };

  ToolRow {
    id,
    provider: Provider::Codex,
    family: ToolFamily::FileChange,
    kind: ToolKind::Edit,
    status: tool_status,
    title: first_file,
    subtitle: (!files.is_empty()).then(|| files.join(", ")),
    summary,
    preview: None,
    started_at: started.then(iso_now),
    ended_at: (tool_status != ToolStatus::Running).then(iso_now),
    duration_ms: None,
    grouping_key: None,
    invocation,
    result,
    render_hints: Default::default(),
    tool_display: None,
    shell_execution: None,
  }
}

fn file_change_tool_status(status: PatchApplyStatus, started: bool) -> ToolStatus {
  if started || matches!(status, PatchApplyStatus::InProgress) {
    ToolStatus::Running
  } else {
    match status {
      PatchApplyStatus::Completed => ToolStatus::Completed,
      PatchApplyStatus::Failed => ToolStatus::Failed,
      PatchApplyStatus::Declined => ToolStatus::Cancelled,
      PatchApplyStatus::InProgress => ToolStatus::Running,
    }
  }
}

fn file_change_invocation(
  changes: &[FileUpdateChange],
) -> (Vec<String>, String, serde_json::Value) {
  let mut changes = changes.iter().collect::<Vec<_>>();
  changes.sort_by(|left, right| left.path.cmp(&right.path));

  let files = changes
    .iter()
    .map(|change| change.path.clone())
    .collect::<Vec<_>>();
  let diff = changes
    .iter()
    .map(|change| file_update_change_unified_diff(change))
    .collect::<Vec<_>>()
    .join("\n\n");
  let first_file = files.first().cloned().unwrap_or_default();

  (
    files,
    diff.clone(),
    json!({
      "path": first_file,
      "diff": diff,
      "changes": changes,
    }),
  )
}

fn file_update_change_unified_diff(change: &FileUpdateChange) -> String {
  if change.diff.starts_with("--- ") || change.diff.starts_with("diff --git ") {
    return change.diff.clone();
  }

  match &change.kind {
    PatchChangeKind::Add => {
      let content = prefixed_lines(&change.diff, '+');
      format!("--- /dev/null\n+++ {}\n{}", change.path, content)
    }
    PatchChangeKind::Delete => {
      let content = prefixed_lines(&change.diff, '-');
      format!("--- {}\n+++ /dev/null\n{}", change.path, content)
    }
    PatchChangeKind::Update { move_path } => {
      let new_path = move_path
        .as_ref()
        .map(|path| path.display().to_string())
        .unwrap_or_else(|| change.path.clone());
      format!("--- {}\n+++ {}\n{}", change.path, new_path, change.diff)
    }
  }
}

fn prefixed_lines(value: &str, prefix: char) -> String {
  value
    .lines()
    .map(|line| format!("{prefix}{line}"))
    .collect::<Vec<_>>()
    .join("\n")
}

pub(crate) fn guardian_review_tool_row(
  review_id: String,
  turn_id: String,
  target_item_id: Option<String>,
  review: codex_app_server_protocol::GuardianApprovalReview,
  action: codex_app_server_protocol::GuardianApprovalReviewAction,
  started: bool,
) -> ToolRow {
  let status = guardian_review_status(review.status, started);
  let risk_level = review
    .risk_level
    .map(|value| format!("{value:?}").to_lowercase());
  let status_label = guardian_review_status_label(review.status).to_string();
  let payload = GuardianAssessmentPayload {
    action: serde_json::to_value(&action).ok(),
    risk_level: risk_level.clone(),
    risk_score: None,
    rationale: review.rationale.clone(),
    status_label: Some(status_label.clone()),
  };
  let output = serde_json::to_string(&payload).unwrap_or_else(|_| status_label.clone());

  ToolRow {
    id: format!("guardian-{review_id}"),
    provider: Provider::Codex,
    family: ToolFamily::Approval,
    kind: ToolKind::GuardianAssessment,
    status,
    title: "Auto-review".to_string(),
    subtitle: risk_level.as_ref().map(|level| format!("{level} risk")),
    summary: review
      .rationale
      .clone()
      .or_else(|| Some(status_label.clone())),
    preview: None,
    started_at: started.then(iso_now),
    ended_at: (status != ToolStatus::Running).then(iso_now),
    duration_ms: None,
    grouping_key: Some(turn_id),
    invocation: json!({
      "action": action,
      "target_item_id": target_item_id,
    }),
    result: Some(json!({
      "output": output,
      "action": payload.action,
      "risk_level": payload.risk_level,
      "rationale": payload.rationale,
      "status_label": payload.status_label,
    })),
    render_hints: Default::default(),
    tool_display: None,
    shell_execution: None,
  }
}

fn guardian_review_status(
  status: codex_app_server_protocol::GuardianApprovalReviewStatus,
  started: bool,
) -> ToolStatus {
  if started
    || matches!(
      status,
      codex_app_server_protocol::GuardianApprovalReviewStatus::InProgress
    )
  {
    return ToolStatus::Running;
  }
  match status {
    codex_app_server_protocol::GuardianApprovalReviewStatus::Approved => ToolStatus::Completed,
    codex_app_server_protocol::GuardianApprovalReviewStatus::Denied
    | codex_app_server_protocol::GuardianApprovalReviewStatus::TimedOut => ToolStatus::Failed,
    codex_app_server_protocol::GuardianApprovalReviewStatus::Aborted => ToolStatus::Cancelled,
    codex_app_server_protocol::GuardianApprovalReviewStatus::InProgress => ToolStatus::Running,
  }
}

fn guardian_review_status_label(
  status: codex_app_server_protocol::GuardianApprovalReviewStatus,
) -> &'static str {
  match status {
    codex_app_server_protocol::GuardianApprovalReviewStatus::InProgress => "reviewing",
    codex_app_server_protocol::GuardianApprovalReviewStatus::Approved => "approved",
    codex_app_server_protocol::GuardianApprovalReviewStatus::Denied => "denied",
    codex_app_server_protocol::GuardianApprovalReviewStatus::TimedOut => "timed out",
    codex_app_server_protocol::GuardianApprovalReviewStatus::Aborted => "aborted",
  }
}
