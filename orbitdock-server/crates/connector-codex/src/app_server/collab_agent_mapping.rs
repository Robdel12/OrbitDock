use std::collections::HashMap;

use orbitdock_connector_core::{ConnectorOutput, ConnectorStateEvent};
use orbitdock_protocol::conversation_contracts::ToolRow;
use orbitdock_protocol::domain_events::{AgentType, ToolFamily, ToolKind, ToolStatus};
use orbitdock_protocol::{Provider, SubagentInfo, SubagentStatus};
use serde_json::json;

use crate::workers::iso_now;

use super::tool_row_mapping::tool_row_outputs;

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
