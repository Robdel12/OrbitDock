use orbitdock_protocol::conversation_contracts::{
  ConversationRow, PlanRow, RenderHints, WorkerRow,
};
use orbitdock_protocol::domain_events::{
  PlanModePayload, PlanStepPayload, PlanStepStatus, ToolStatus, WorkerStateSnapshot,
};
use orbitdock_protocol::Provider;
use serde_json::Value;

#[cfg(test)]
const HANDLED_WRAPPERS: &[&str] = &["subagent_notification", "proposed_plan", "provider_event"];

#[cfg(test)]
pub(crate) fn handled_wrappers() -> &'static [&'static str] {
  HANDLED_WRAPPERS
}

pub(crate) fn upgrade_row(row: ConversationRow) -> ConversationRow {
  match row {
    ConversationRow::User(message) => {
      if let Some(worker) = parse_subagent_notification(&message.id, &message.content) {
        return ConversationRow::Worker(worker);
      }
      ConversationRow::User(message)
    }
    ConversationRow::Steer(message) => {
      if let Some(worker) = parse_subagent_notification(&message.id, &message.content) {
        return ConversationRow::Worker(worker);
      }
      ConversationRow::Steer(message)
    }
    ConversationRow::Assistant(message) => {
      if let Some(worker) = parse_subagent_notification(&message.id, &message.content) {
        return ConversationRow::Worker(worker);
      }
      if let Some(plan) = parse_proposed_plan(&message.id, &message.content) {
        return ConversationRow::Plan(plan);
      }
      ConversationRow::Assistant(message)
    }
    ConversationRow::System(message) => {
      if let Some(worker) = parse_subagent_notification(&message.id, &message.content) {
        return ConversationRow::Worker(worker);
      }
      if let Some(plan) = parse_proposed_plan(&message.id, &message.content) {
        return ConversationRow::Plan(plan);
      }
      ConversationRow::System(message)
    }
    other => other,
  }
}

fn parse_subagent_notification(id: &str, content: &str) -> Option<WorkerRow> {
  if !content.trim().starts_with("<subagent_notification>") {
    return None;
  }
  let json = extract_tag(content, "subagent_notification")?;
  let payload: Value = serde_json::from_str(&json).ok()?;
  let agent_id = payload
    .get("agent_id")
    .and_then(Value::as_str)
    .unwrap_or(id)
    .to_string();
  let status_object = payload.get("status").and_then(Value::as_object)?;
  let (status_key, status_value) = status_object.iter().next()?;
  let summary = match status_value {
    Value::String(text) => Some(text.clone()),
    other => stringify_json(other),
  };

  Some(WorkerRow {
    id: id.to_string(),
    title: payload
      .get("name")
      .and_then(Value::as_str)
      .map(ToString::to_string)
      .unwrap_or_else(|| format!("Worker {agent_id}")),
    subtitle: Some(status_key.replace('_', " ")),
    summary: summary.clone(),
    worker: WorkerStateSnapshot {
      id: agent_id,
      label: payload
        .get("name")
        .and_then(Value::as_str)
        .map(ToString::to_string),
      agent_type: payload
        .get("agent_type")
        .and_then(Value::as_str)
        .map(ToString::to_string),
      provider: Some(Provider::Codex),
      model: payload
        .get("model")
        .and_then(Value::as_str)
        .map(ToString::to_string),
      status: match status_key.as_str() {
        "completed" => ToolStatus::Completed,
        "failed" => ToolStatus::Failed,
        "running" => ToolStatus::Running,
        _ => ToolStatus::Pending,
      },
      task_summary: payload
        .get("task")
        .and_then(Value::as_str)
        .map(ToString::to_string),
      result_summary: (status_key == "completed")
        .then_some(summary.clone())
        .flatten(),
      error_summary: (status_key == "failed")
        .then_some(summary.clone())
        .flatten(),
      parent_worker_id: payload
        .get("parent_agent_id")
        .and_then(Value::as_str)
        .map(ToString::to_string),
      started_at: None,
      last_activity_at: None,
      ended_at: None,
    },
    operation: None,
    render_hints: worker_hints(),
  })
}

fn parse_proposed_plan(id: &str, content: &str) -> Option<PlanRow> {
  if !content.trim().starts_with("<proposed_plan>") {
    return None;
  }
  let body = extract_tag(content, "proposed_plan")?;
  let steps = body
    .lines()
    .map(str::trim)
    .filter(|line| !line.is_empty())
    .map(|line| PlanStepPayload {
      id: None,
      title: line
        .trim_start_matches(|ch: char| ch.is_ascii_digit() || ch == '.' || ch == '-' || ch == '*')
        .trim()
        .to_string(),
      status: PlanStepStatus::Pending,
      detail: None,
    })
    .filter(|step| !step.title.is_empty())
    .collect::<Vec<_>>();

  Some(PlanRow {
    id: id.to_string(),
    title: "Proposed plan".to_string(),
    subtitle: None,
    summary: steps.first().map(|step| step.title.clone()),
    payload: PlanModePayload {
      mode: Some("plan".to_string()),
      summary: None,
      steps,
      review_mode: None,
      explanation: Some(body),
    },
    render_hints: worker_hints(),
  })
}

fn extract_tag(content: &str, tag: &str) -> Option<String> {
  let start_token = format!("<{tag}>");
  let end_token = format!("</{tag}>");
  let start = content.find(&start_token)?;
  let rest = &content[start + start_token.len()..];
  let end = rest.find(&end_token)?;
  Some(rest[..end].trim().to_string())
}

fn stringify_json(value: &Value) -> Option<String> {
  serde_json::to_string(value).ok()
}

fn worker_hints() -> RenderHints {
  RenderHints {
    can_expand: true,
    default_expanded: false,
    emphasized: false,
    monospace_summary: false,
    accent_tone: Some("worker".to_string()),
  }
}

#[cfg(test)]
mod tests {
  use super::handled_wrappers;

  #[test]
  fn reports_handled_wrapper_inventory() {
    assert!(handled_wrappers().contains(&"subagent_notification"));
    assert!(handled_wrappers().contains(&"proposed_plan"));
  }
}
