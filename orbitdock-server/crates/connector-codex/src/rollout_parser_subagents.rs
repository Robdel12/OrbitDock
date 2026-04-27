use std::borrow::ToOwned;

use codex_protocol::protocol::AgentStatus;
use orbitdock_protocol::domain_events::AgentType;
use orbitdock_protocol::{Provider, SubagentInfo, SubagentStatus};

use super::current_time_rfc3339;

pub(super) fn build_authoritative_rollout_subagent(
  id: String,
  agent_role: Option<String>,
  agent_nickname: Option<String>,
  task_summary: Option<String>,
  parent_subagent_id: Option<String>,
  status: &AgentStatus,
) -> SubagentInfo {
  let now = current_time_rfc3339();
  let (mapped_status, ended_at, result_summary, error_summary) =
    map_rollout_agent_status(status, &now);

  SubagentInfo {
    id: id.clone(),
    agent_type: normalized_rollout_agent_type(agent_role.as_deref()),
    started_at: now.clone(),
    ended_at,
    provider: Some(Provider::Codex),
    label: normalized_rollout_agent_label(agent_nickname.as_deref(), agent_role.as_deref(), &id),
    status: mapped_status,
    task_summary: normalized_rollout_summary(task_summary),
    result_summary,
    error_summary,
    parent_subagent_id,
    model: None,
    last_activity_at: Some(now),
  }
}

pub(super) fn build_inflight_rollout_subagent(
  id: String,
  agent_role: Option<String>,
  agent_nickname: Option<String>,
  task_summary: Option<String>,
  parent_subagent_id: Option<String>,
  status: &AgentStatus,
) -> Option<SubagentInfo> {
  let mapped_status = match status {
    AgentStatus::PendingInit => SubagentStatus::Pending,
    AgentStatus::Running => SubagentStatus::Running,
    AgentStatus::Interrupted => SubagentStatus::Interrupted,
    AgentStatus::Completed(_)
    | AgentStatus::Errored(_)
    | AgentStatus::Shutdown
    | AgentStatus::NotFound => return None,
  };

  let now = current_time_rfc3339();
  Some(SubagentInfo {
    id: id.clone(),
    agent_type: normalized_rollout_agent_type(agent_role.as_deref()),
    started_at: now.clone(),
    ended_at: None,
    provider: Some(Provider::Codex),
    label: normalized_rollout_agent_label(agent_nickname.as_deref(), agent_role.as_deref(), &id),
    status: mapped_status,
    task_summary: normalized_rollout_summary(task_summary),
    result_summary: None,
    error_summary: None,
    parent_subagent_id,
    model: None,
    last_activity_at: Some(now),
  })
}

pub(super) fn build_running_rollout_subagent(
  id: String,
  agent_role: Option<String>,
  agent_nickname: Option<String>,
  task_summary: Option<String>,
  parent_subagent_id: Option<String>,
) -> SubagentInfo {
  build_inflight_rollout_subagent(
    id,
    agent_role,
    agent_nickname,
    task_summary,
    parent_subagent_id,
    &AgentStatus::Running,
  )
  .expect("running rollout subagent should always build")
}

pub(super) fn build_rollout_subagent_for_status(
  id: String,
  agent_role: Option<String>,
  agent_nickname: Option<String>,
  task_summary: Option<String>,
  parent_subagent_id: Option<String>,
  status: &AgentStatus,
) -> SubagentInfo {
  match status {
    AgentStatus::PendingInit | AgentStatus::Running | AgentStatus::Interrupted => {
      build_inflight_rollout_subagent(
        id,
        agent_role,
        agent_nickname,
        task_summary,
        parent_subagent_id,
        status,
      )
      .expect("non-terminal rollout subagent should always build")
    }
    AgentStatus::Completed(_)
    | AgentStatus::Errored(_)
    | AgentStatus::Shutdown
    | AgentStatus::NotFound => build_authoritative_rollout_subagent(
      id,
      agent_role,
      agent_nickname,
      task_summary,
      parent_subagent_id,
      status,
    ),
  }
}

fn map_rollout_agent_status(
  status: &AgentStatus,
  now: &str,
) -> (
  SubagentStatus,
  Option<String>,
  Option<String>,
  Option<String>,
) {
  match status {
    AgentStatus::PendingInit => (SubagentStatus::Pending, None, None, None),
    AgentStatus::Running => (SubagentStatus::Running, None, None, None),
    AgentStatus::Interrupted => (SubagentStatus::Interrupted, None, None, None),
    AgentStatus::Completed(summary) => (
      SubagentStatus::Completed,
      Some(now.to_string()),
      normalized_rollout_summary(summary.clone()),
      None,
    ),
    AgentStatus::Errored(message) => (
      SubagentStatus::Failed,
      Some(now.to_string()),
      None,
      normalized_rollout_summary(Some(message.clone())),
    ),
    AgentStatus::Shutdown => (SubagentStatus::Shutdown, Some(now.to_string()), None, None),
    AgentStatus::NotFound => (
      SubagentStatus::NotFound,
      Some(now.to_string()),
      None,
      Some("Agent not found".to_string()),
    ),
  }
}

fn normalized_rollout_summary(value: Option<String>) -> Option<String> {
  value.and_then(|summary| {
    let trimmed = summary.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
  })
}

fn normalized_rollout_agent_type(role: Option<&str>) -> AgentType {
  let raw = role
    .map(str::trim)
    .filter(|text| !text.is_empty())
    .unwrap_or("agent");
  AgentType::from_str_normalized(raw)
}

fn normalized_rollout_agent_label(
  nickname: Option<&str>,
  role: Option<&str>,
  id: &str,
) -> Option<String> {
  nickname
    .map(str::trim)
    .filter(|text| !text.is_empty())
    .map(ToOwned::to_owned)
    .or_else(|| {
      role
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(ToOwned::to_owned)
    })
    .or_else(|| Some(id.to_string()))
}
