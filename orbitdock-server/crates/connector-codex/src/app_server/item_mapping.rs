#[path = "collab_agent_mapping.rs"]
mod collab_agent_mapping;
#[path = "dynamic_tool_mapping.rs"]
mod dynamic_tool_mapping;
#[path = "tool_row_mapping.rs"]
mod tool_row_mapping;

pub(crate) use collab_agent_mapping::{map_collab_agent_tool, CollabAgentToolCallArgs};
pub(crate) use dynamic_tool_mapping::{map_dynamic_tool, DynamicToolCallArgs};
pub(crate) use tool_row_mapping::{
  command_execution_tool_status, file_change_tool_row, guardian_review_tool_row, map_tool_row,
  output_buffer_key, tool_row_outputs, ToolRowArgs,
};

use codex_app_server_protocol::{ThreadItem, UserInput};
use orbitdock_connector_core::{ConnectorOutput, ConnectorStateEvent, ConnectorTransportEffect};
use orbitdock_protocol::conversation_contracts::{
  classify_tool_name, ConversationRow, MessageRowContent, NoticeRow, NoticeRowKind,
  NoticeRowSeverity, ToolRow,
};
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
use orbitdock_protocol::Provider;
use serde_json::json;
use tracing::debug;

use self::tool_row_mapping::duration_millis;
use super::AppServerSessionRoute;
use crate::row_mapping::{row_created_output, row_updated_output};
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
