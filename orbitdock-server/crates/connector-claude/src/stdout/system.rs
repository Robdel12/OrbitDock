use serde_json::Value;

use orbitdock_connector_core::{ConnectorOutput, ConnectorRuntimeDirective, ConnectorStateEvent};
use orbitdock_protocol::conversation_contracts::ConversationRow;
use orbitdock_protocol::domain_events::ToolStatus;

use crate::rows::{make_entry, make_tool_row, now_iso};

use super::{runtime_output, state_output, ClaudeEventLoopState};

pub(super) async fn handle_system_message(
  raw: &Value,
  state: &mut ClaudeEventLoopState,
) -> Vec<ConnectorOutput> {
  let session_id_slot = &state.session_id;
  let task_tool_use_map = &mut state.task_tool_use_map;
  let compacting_msg_id = &mut state.compacting_msg_id;
  let tool_rows = &mut state.tool_rows;
  let subtype = raw.get("subtype").and_then(Value::as_str).unwrap_or("");

  match subtype {
    "init" => {
      let mut events = vec![];
      if let Some(sid) = raw.get("session_id").and_then(Value::as_str) {
        *session_id_slot.lock().await = Some(sid.to_string());
        let model = raw.get("model").and_then(Value::as_str);

        let parse_string_array = |key: &str| -> Vec<String> {
          raw
            .get(key)
            .and_then(Value::as_array)
            .map(|values| {
              values
                .iter()
                .filter_map(|value| value.as_str().map(String::from))
                .collect()
            })
            .unwrap_or_default()
        };

        let slash_commands = parse_string_array("slash_commands");
        let skills = parse_string_array("skills");
        let tools = parse_string_array("tools");

        if let Some(model) = model {
          events.push(state_output(ConnectorStateEvent::ModelUpdated(
            model.to_string(),
          )));
        }

        events.push(state_output(ConnectorStateEvent::ClaudeInitialized {
          slash_commands,
          skills,
          tools,
          models: vec![],
        }));

        if let Some(mcp_servers) = raw.get("mcp_servers").and_then(Value::as_array) {
          let mut ready = Vec::new();
          let mut failed = Vec::new();
          for server in mcp_servers {
            let name = server
              .get("name")
              .and_then(Value::as_str)
              .unwrap_or("unknown")
              .to_string();
            let status_str = server
              .get("status")
              .and_then(Value::as_str)
              .unwrap_or("unknown");

            let mcp_status = match status_str {
              "connected" | "ready" => {
                ready.push(name.clone());
                orbitdock_protocol::McpStartupStatus::Ready
              }
              "failed" | "error" => {
                let error = server
                  .get("error")
                  .and_then(Value::as_str)
                  .unwrap_or("Connection failed")
                  .to_string();
                failed.push(orbitdock_protocol::McpStartupFailure {
                  server: name.clone(),
                  error: error.clone(),
                });
                orbitdock_protocol::McpStartupStatus::Failed { error }
              }
              "needs-auth" | "needs_auth" => orbitdock_protocol::McpStartupStatus::NeedsAuth,
              _ => orbitdock_protocol::McpStartupStatus::Connecting,
            };

            events.push(state_output(ConnectorStateEvent::McpStartupUpdate {
              server: name,
              status: mcp_status,
            }));
          }

          events.push(state_output(ConnectorStateEvent::McpStartupComplete {
            ready,
            failed,
            cancelled: vec![],
          }));
        }
      }
      events
    }
    "compact_boundary" => {
      let mut events = vec![];
      let session_id = session_id_slot.lock().await.clone().unwrap_or_default();
      if let Some(row_id) = compacting_msg_id.take() {
        if let Some(mut tool_row) = tool_rows.remove(&row_id) {
          tool_row.status = ToolStatus::Completed;
          tool_row.ended_at = Some(now_iso());
          tool_row.result = Some(serde_json::json!({
            "tool_name": "CompactContext",
            "summary": "Done",
          }));
          events.push(state_output(ConnectorStateEvent::ConversationRowUpdated {
            row_id: row_id.clone(),
            entry: make_entry(&session_id, ConversationRow::Tool(tool_row)),
          }));
        }
      }
      events.push(state_output(ConnectorStateEvent::ContextCompacted));
      events
    }
    "hook_started" => {
      if let Some(sid) = raw.get("session_id").and_then(Value::as_str) {
        vec![runtime_output(ConnectorRuntimeDirective::HookSessionId(
          sid.to_string(),
        ))]
      } else {
        vec![]
      }
    }
    "task_started" => {
      let task_id = raw
        .get("task_id")
        .and_then(Value::as_str)
        .unwrap_or("unknown-task");
      let tool_use_id_opt = raw.get("tool_use_id").and_then(Value::as_str);
      let session_id = session_id_slot.lock().await.clone().unwrap_or_default();

      if let Some(tool_use_id) = tool_use_id_opt {
        if let Some(existing_row) = tool_rows.remove(tool_use_id) {
          task_tool_use_map.insert(tool_use_id.to_string(), task_id.to_string());
          tool_rows.insert(task_id.to_string(), existing_row);
          return vec![];
        }
        task_tool_use_map.insert(tool_use_id.to_string(), task_id.to_string());
      }

      let description = raw.get("description").and_then(Value::as_str).unwrap_or("");
      let task_type = raw
        .get("task_type")
        .and_then(Value::as_str)
        .unwrap_or("Agent");

      let raw_input = Some(serde_json::json!({
        "subagent_type": task_type,
        "description": description,
      }));
      let mut tool_row = make_tool_row(
        task_id.to_string(),
        "task",
        raw_input.as_ref(),
        ToolStatus::Running,
      );
      tool_row.subtitle = if description.is_empty() {
        None
      } else {
        Some(description.to_string())
      };

      tool_rows.insert(task_id.to_string(), tool_row.clone());
      vec![state_output(ConnectorStateEvent::ConversationRowCreated(
        make_entry(&session_id, ConversationRow::Tool(tool_row)),
      ))]
    }
    "task_progress" => {
      let task_id = raw
        .get("task_id")
        .and_then(Value::as_str)
        .unwrap_or("unknown-task");
      let tool_uses = raw
        .pointer("/usage/tool_uses")
        .and_then(Value::as_u64)
        .unwrap_or(0);
      let duration_ms = raw
        .pointer("/usage/duration_ms")
        .and_then(Value::as_u64)
        .unwrap_or(0);
      let last_tool = raw
        .get("last_tool_name")
        .and_then(Value::as_str)
        .unwrap_or("");
      let description = raw.get("description").and_then(Value::as_str).unwrap_or("");

      let duration_s = duration_ms / 1000;
      let mut progress = format!("Agent running - {tool_uses} tool uses, {duration_s}s");
      if !last_tool.is_empty() {
        progress.push_str(&format!(", last: {last_tool}"));
      }
      if !description.is_empty() {
        progress.push_str(&format!("\n{description}"));
      }

      let session_id = session_id_slot.lock().await.clone().unwrap_or_default();
      if let Some(tool_row) = tool_rows.get_mut(task_id) {
        tool_row.summary = Some(progress);
        tool_row.duration_ms = Some(duration_ms);
        vec![state_output(ConnectorStateEvent::ConversationRowUpdated {
          row_id: task_id.to_string(),
          entry: make_entry(&session_id, ConversationRow::Tool(tool_row.clone())),
        })]
      } else {
        vec![]
      }
    }
    "task_notification" => {
      let task_id = raw
        .get("task_id")
        .and_then(Value::as_str)
        .unwrap_or("unknown-task");
      let status_str = raw
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("completed");
      let summary = raw.get("summary").and_then(Value::as_str).unwrap_or("");
      let duration_ms = raw.pointer("/usage/duration_ms").and_then(Value::as_u64);

      let session_id = session_id_slot.lock().await.clone().unwrap_or_default();
      if let Some(mut tool_row) = tool_rows.remove(task_id) {
        tool_row.status = if status_str == "failed" {
          ToolStatus::Failed
        } else {
          ToolStatus::Completed
        };
        tool_row.ended_at = Some(now_iso());
        tool_row.summary = Some(summary.to_string());
        tool_row.duration_ms = duration_ms;
        tool_row.result = Some(serde_json::json!({
          "tool_name": "task",
          "summary": summary,
        }));
        vec![state_output(ConnectorStateEvent::ConversationRowUpdated {
          row_id: task_id.to_string(),
          entry: make_entry(&session_id, ConversationRow::Tool(tool_row)),
        })]
      } else {
        vec![]
      }
    }
    "status" => {
      let mut events = vec![];

      if let Some(mode) = raw
        .get("permissionMode")
        .or_else(|| raw.get("permission_mode"))
        .and_then(Value::as_str)
      {
        events.push(state_output(ConnectorStateEvent::PermissionModeChanged {
          mode: mode.to_string(),
        }));
      }

      if let Some(status) = raw.get("status").and_then(Value::as_str) {
        if status == "compacting" && compacting_msg_id.is_none() {
          let session_id = session_id_slot.lock().await.clone().unwrap_or_default();
          let msg_id = format!("compacting-{}", uuid::Uuid::new_v4());
          *compacting_msg_id = Some(msg_id.clone());

          let tool_row = make_tool_row(
            msg_id.clone(),
            "CompactContext",
            Some(&serde_json::json!(
              "Compacting context to keep session within model context window..."
            )),
            ToolStatus::Running,
          );
          tool_rows.insert(msg_id.clone(), tool_row.clone());
          events.push(state_output(ConnectorStateEvent::ConversationRowCreated(
            make_entry(&session_id, ConversationRow::Tool(tool_row)),
          )));
        }
      }

      events
    }
    "hook_progress" | "hook_response" => vec![],
    "files_persisted" => {
      let files = raw
        .get("files")
        .and_then(Value::as_array)
        .map(|values| {
          values
            .iter()
            .filter_map(|value| value.as_str().map(str::to_string))
            .collect()
        })
        .unwrap_or_default();
      vec![state_output(ConnectorStateEvent::FilesPersisted { files })]
    }
    _ => vec![],
  }
}
