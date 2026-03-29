use orbitdock_protocol::conversation_contracts::{
  ApprovalRow, ContextRow, ContextRowKind, ConversationRow, HandoffRow, HookRow, NoticeRow,
  NoticeRowKind, NoticeRowSeverity, PlanRow, QuestionRow, RenderHints, WorkerRow,
};
use orbitdock_protocol::domain_events::{
  ApprovalPreview, ApprovalRequestKind, ApprovalRequestPayload, GenericInvocationPayload,
  HandoffPayload, HookPayload, PermissionRequestPayload, PermissionScope, PlanModePayload,
  PlanStepPayload, PlanStepStatus, QuestionPrompt, ToolFamily, ToolInvocationPayload, ToolStatus,
  WorkerOperationKind, WorkerStateSnapshot,
};
use orbitdock_protocol::provider_normalization::shared::{
  NormalizedApprovalKind, NormalizedHookLifecycle, NormalizedQuestionKind,
  NormalizedWorkerLifecycleKind, ProviderEventEnvelope, SharedNormalizedProviderEvent,
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

#[allow(dead_code)] // Wired when provider event materialization is turned on for semantic rows.
pub(crate) fn materialize_provider_event(event: ProviderEventEnvelope) -> Vec<ConversationRow> {
  match event.event {
    SharedNormalizedProviderEvent::WorkerLifecycle(worker) => {
      vec![ConversationRow::Worker(WorkerRow {
        id: worker.worker_id.clone(),
        title: worker
          .label
          .clone()
          .unwrap_or_else(|| format!("Worker {}", worker.worker_id)),
        subtitle: worker.operation.clone(),
        summary: worker.summary.clone(),
        worker: WorkerStateSnapshot {
          id: worker.worker_id,
          label: worker.label,
          agent_type: None,
          provider: Some(Provider::Codex),
          model: None,
          status: map_worker_status(worker.lifecycle),
          task_summary: worker.summary,
          result_summary: None,
          error_summary: None,
          parent_worker_id: worker.sender_worker_id,
          started_at: event.timestamp.clone(),
          last_activity_at: event.timestamp.clone(),
          ended_at: matches!(
            worker.lifecycle,
            NormalizedWorkerLifecycleKind::Closed
              | NormalizedWorkerLifecycleKind::InteractionCompleted
          )
          .then(|| event.timestamp.clone())
          .flatten(),
        },
        operation: Some(map_worker_operation(worker.lifecycle)),
        render_hints: worker_hints(),
      })]
    }
    SharedNormalizedProviderEvent::Plan(plan) => vec![ConversationRow::Plan(PlanRow {
      id: plan.id,
      title: plan.title.unwrap_or_else(|| "Plan updated".to_string()),
      subtitle: None,
      summary: plan.summary.clone(),
      payload: PlanModePayload {
        mode: Some("plan".to_string()),
        summary: plan.summary,
        steps: plan
          .steps
          .into_iter()
          .map(|step| PlanStepPayload {
            id: None,
            title: step,
            status: PlanStepStatus::Pending,
            detail: None,
          })
          .collect(),
        review_mode: None,
        explanation: None,
      },
      render_hints: worker_hints(),
    })],
    SharedNormalizedProviderEvent::Hook(hook) => vec![ConversationRow::Hook(HookRow {
      id: hook.id,
      title: hook.hook_name.clone().unwrap_or_else(|| "Hook".to_string()),
      subtitle: hook
        .lifecycle
        .eq(&NormalizedHookLifecycle::Completed)
        .then(|| "Completed".to_string())
        .or_else(|| Some("Started".to_string())),
      summary: hook.summary.clone().or_else(|| hook.output.clone()),
      payload: HookPayload {
        hook_name: hook.hook_name,
        event_name: None,
        phase: None,
        status: Some(
          match hook.lifecycle {
            NormalizedHookLifecycle::Started => "started",
            NormalizedHookLifecycle::Completed => "completed",
          }
          .to_string(),
        ),
        source_path: None,
        summary: hook.summary,
        output: hook.output,
        duration_ms: None,
        entries: vec![],
      },
      render_hints: worker_hints(),
    })],
    SharedNormalizedProviderEvent::Handoff(handoff) => {
      vec![ConversationRow::Handoff(HandoffRow {
        id: handoff.id,
        title: "Handoff requested".to_string(),
        subtitle: handoff.target.clone(),
        summary: handoff.summary.clone(),
        payload: HandoffPayload {
          target: handoff.target,
          summary: handoff.summary,
          body: handoff.details.and_then(|value| stringify_json(&value)),
          transcript_excerpt: None,
        },
        render_hints: worker_hints(),
      })]
    }
    SharedNormalizedProviderEvent::ApprovalRequest(request) => {
      vec![ConversationRow::Approval(ApprovalRow {
        id: request.id.clone(),
        title: request
          .title
          .clone()
          .or_else(|| request.tool_name.clone())
          .unwrap_or_else(|| "Approval requested".to_string()),
        subtitle: request.tool_name.clone(),
        summary: request.summary.clone(),
        request: ApprovalRequestPayload {
          id: request.id,
          kind: map_approval_kind(request.kind),
          family: map_approval_family(request.kind),
          status: ToolStatus::NeedsInput,
          tool_name: request.tool_name.clone(),
          invocation: request.details.clone().map(|raw_input| {
            ToolInvocationPayload::Generic(GenericInvocationPayload {
              tool_name: request
                .tool_name
                .clone()
                .unwrap_or_else(|| "approval_request".to_string()),
              raw_input: Some(raw_input),
            })
          }),
          preview: request.summary.as_ref().map(|summary| ApprovalPreview {
            title: request.title,
            subtitle: request.tool_name.clone(),
            summary: Some(summary.clone()),
            snippet: request.details.as_ref().and_then(stringify_json),
          }),
          command: request
            .details
            .as_ref()
            .and_then(|value| value.get("command"))
            .and_then(Value::as_str)
            .map(ToString::to_string),
          file_path: request
            .details
            .as_ref()
            .and_then(|value| value.get("file_path"))
            .and_then(Value::as_str)
            .map(ToString::to_string),
          diff: None,
          proposed_amendment: None,
          permission: matches!(request.kind, NormalizedApprovalKind::Permissions).then(|| {
            PermissionRequestPayload {
              reason: request.summary.clone(),
              requested_permissions: vec![],
              granted_permissions: vec![],
              permission_suggestions: vec![],
              scope: Some(PermissionScope::Turn),
            }
          }),
          requested_by_worker_id: request.requestor_worker_id,
        },
        render_hints: notice_hints(),
      })]
    }
    SharedNormalizedProviderEvent::Question(question) => {
      vec![ConversationRow::Question(QuestionRow {
        id: question.id.clone(),
        title: question
          .title
          .clone()
          .unwrap_or_else(|| "Question".to_string()),
        subtitle: Some(
          match question.kind {
            NormalizedQuestionKind::AskUser => "Ask user",
            NormalizedQuestionKind::Elicitation => "Elicitation",
            NormalizedQuestionKind::Generic => "Question",
          }
          .to_string(),
        ),
        summary: question.summary,
        prompts: vec![QuestionPrompt {
          id: question.id,
          question: question.prompt,
          title: question.title,
          description: None,
          placeholder: None,
          allows_other: true,
          allows_multiple: false,
          secret: false,
          options: vec![],
        }],
        response: None,
        render_hints: notice_hints(),
      })]
    }
    SharedNormalizedProviderEvent::Context(context) => {
      vec![ConversationRow::Context(ContextRow {
        id: context.id,
        kind: ContextRowKind::Generic,
        title: "Context updated".to_string(),
        subtitle: None,
        summary: context.summary,
        body: None,
        source_path: None,
        cwd: None,
        shell: None,
        render_hints: context_hints(),
      })]
    }
    SharedNormalizedProviderEvent::System(system) => vec![ConversationRow::Notice(NoticeRow {
      id: system.id,
      kind: NoticeRowKind::Generic,
      severity: NoticeRowSeverity::Info,
      title: "System event".to_string(),
      summary: Some(system.content.clone()),
      body: Some(system.content),
      render_hints: notice_hints(),
    })],
    SharedNormalizedProviderEvent::AssistantContent(_)
    | SharedNormalizedProviderEvent::ToolInvocation(_)
    | SharedNormalizedProviderEvent::ToolResult(_)
    | SharedNormalizedProviderEvent::Reasoning(_) => vec![],
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

#[allow(dead_code)] // Used by provider event materialization.
fn map_worker_status(kind: NormalizedWorkerLifecycleKind) -> ToolStatus {
  match kind {
    NormalizedWorkerLifecycleKind::Spawned
    | NormalizedWorkerLifecycleKind::InteractionStarted
    | NormalizedWorkerLifecycleKind::Resumed
    | NormalizedWorkerLifecycleKind::Updated => ToolStatus::Running,
    NormalizedWorkerLifecycleKind::Waiting => ToolStatus::Pending,
    NormalizedWorkerLifecycleKind::InteractionCompleted | NormalizedWorkerLifecycleKind::Closed => {
      ToolStatus::Completed
    }
  }
}

#[allow(dead_code)] // Used by provider event materialization.
fn map_worker_operation(kind: NormalizedWorkerLifecycleKind) -> WorkerOperationKind {
  match kind {
    NormalizedWorkerLifecycleKind::Spawned => WorkerOperationKind::Spawn,
    NormalizedWorkerLifecycleKind::InteractionStarted
    | NormalizedWorkerLifecycleKind::InteractionCompleted => WorkerOperationKind::Interact,
    NormalizedWorkerLifecycleKind::Waiting => WorkerOperationKind::Wait,
    NormalizedWorkerLifecycleKind::Resumed => WorkerOperationKind::Resume,
    NormalizedWorkerLifecycleKind::Closed => WorkerOperationKind::Close,
    NormalizedWorkerLifecycleKind::Updated => WorkerOperationKind::Update,
  }
}

#[allow(dead_code)] // Used by provider event materialization.
fn map_approval_kind(kind: NormalizedApprovalKind) -> ApprovalRequestKind {
  match kind {
    NormalizedApprovalKind::Exec => ApprovalRequestKind::Command,
    NormalizedApprovalKind::Patch => ApprovalRequestKind::Patch,
    NormalizedApprovalKind::Permissions => ApprovalRequestKind::Permission,
    NormalizedApprovalKind::Mcp | NormalizedApprovalKind::Generic => ApprovalRequestKind::Generic,
  }
}

#[allow(dead_code)] // Used by provider event materialization.
fn map_approval_family(kind: NormalizedApprovalKind) -> ToolFamily {
  match kind {
    NormalizedApprovalKind::Exec => ToolFamily::Shell,
    NormalizedApprovalKind::Patch => ToolFamily::FileChange,
    NormalizedApprovalKind::Permissions => ToolFamily::PermissionRequest,
    NormalizedApprovalKind::Mcp => ToolFamily::Mcp,
    NormalizedApprovalKind::Generic => ToolFamily::Approval,
  }
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

#[allow(dead_code)] // Used by provider event materialization.
fn notice_hints() -> RenderHints {
  RenderHints {
    can_expand: true,
    default_expanded: false,
    emphasized: false,
    monospace_summary: false,
    accent_tone: Some("notice".to_string()),
  }
}

#[allow(dead_code)] // Used by provider event materialization.
fn context_hints() -> RenderHints {
  RenderHints {
    can_expand: true,
    default_expanded: false,
    emphasized: false,
    monospace_summary: false,
    accent_tone: Some("context".to_string()),
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
