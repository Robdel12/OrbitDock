use super::{row_created_output, row_updated_output, tool_row_entry, ConnectorOutputs};
use orbitdock_protocol::conversation_contracts::ToolRow;
use orbitdock_protocol::domain_events::{
  GuardianAssessmentPayload, ToolFamily, ToolInvocationPayload, ToolKind, ToolResultPayload,
  ToolStatus,
};
use orbitdock_protocol::Provider;

pub(crate) fn handle_guardian_assessment(
  event: codex_protocol::approvals::GuardianAssessmentEvent,
) -> ConnectorOutputs {
  let is_in_progress = matches!(
    event.status,
    codex_protocol::approvals::GuardianAssessmentStatus::InProgress
  );
  let status = match event.status {
    codex_protocol::approvals::GuardianAssessmentStatus::InProgress => ToolStatus::Running,
    codex_protocol::approvals::GuardianAssessmentStatus::Approved => ToolStatus::Completed,
    codex_protocol::approvals::GuardianAssessmentStatus::Denied => ToolStatus::Failed,
    codex_protocol::approvals::GuardianAssessmentStatus::Aborted => ToolStatus::Cancelled,
  };

  let risk_level_str = event.risk_level.map(|risk| match risk {
    codex_protocol::approvals::GuardianRiskLevel::Low => "low".to_string(),
    codex_protocol::approvals::GuardianRiskLevel::Medium => "medium".to_string(),
    codex_protocol::approvals::GuardianRiskLevel::High => "high".to_string(),
  });

  let subtitle = risk_level_str.as_ref().map(|level| format!("{level} risk"));

  let summary = event.rationale.clone().or_else(|| {
    event
      .risk_score
      .map(|score| format!("Guardian risk score: {score}/100"))
  });

  let status_label = match event.status {
    codex_protocol::approvals::GuardianAssessmentStatus::InProgress => "reviewing",
    codex_protocol::approvals::GuardianAssessmentStatus::Approved => "approved",
    codex_protocol::approvals::GuardianAssessmentStatus::Denied => "denied",
    codex_protocol::approvals::GuardianAssessmentStatus::Aborted => "aborted",
  }
  .to_string();

  let payload = GuardianAssessmentPayload {
    action: event.action.clone(),
    risk_level: risk_level_str,
    risk_score: event.risk_score.map(u32::from),
    rationale: event.rationale.clone(),
    status_label: Some(status_label),
  };

  let row = ToolRow {
    id: format!("guardian-{}", event.id),
    provider: Provider::Codex,
    family: ToolFamily::Approval,
    kind: ToolKind::GuardianAssessment,
    status,
    title: "Guardian review".to_string(),
    subtitle,
    summary: summary.clone(),
    preview: None,
    started_at: None,
    ended_at: (!matches!(status, ToolStatus::Running)).then(crate::workers::iso_now),
    duration_ms: None,
    grouping_key: (!event.turn_id.is_empty()).then_some(event.turn_id.clone()),
    invocation: serde_json::to_value(ToolInvocationPayload::GuardianAssessment(payload.clone()))
      .expect("serialize guardian assessment invocation"),
    result: Some(
      serde_json::to_value(ToolResultPayload::GuardianAssessment(payload))
        .expect("serialize guardian assessment result"),
    ),
    render_hints: Default::default(),
    tool_display: None,
  };

  let row_id = row.id.clone();
  let entry = tool_row_entry(row);
  vec![if is_in_progress {
    row_created_output(entry)
  } else {
    row_updated_output(row_id, entry)
  }]
}
