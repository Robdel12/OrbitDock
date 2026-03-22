use orbitdock_connector_core::ConnectorEvent;
use orbitdock_protocol::conversation_contracts::{compute_tool_display, ConversationRow, ToolRow};
use orbitdock_protocol::domain_events::{
    GenericInvocationPayload, GenericResultPayload, ToolFamily, ToolInvocationPayload, ToolKind,
    ToolResultPayload, ToolStatus,
};
use orbitdock_protocol::Provider;

fn tool_row_entry(
    row: ToolRow,
) -> orbitdock_protocol::conversation_contracts::ConversationRowEntry {
    crate::runtime::row_entry(ConversationRow::Tool(with_display(row)))
}

fn with_display(mut row: ToolRow) -> ToolRow {
    let invocation_json = serde_json::to_value(&row.invocation).ok();
    let result_text = row.result.as_ref().and_then(|result| {
        serde_json::to_string(result)
            .ok()
            .filter(|text| !text.trim().is_empty())
    });
    row.tool_display = Some(compute_tool_display(
        row.kind,
        row.family,
        row.status,
        &row.title,
        row.subtitle.as_deref(),
        row.summary.as_deref(),
        row.duration_ms,
        invocation_json.as_ref(),
        result_text.as_deref(),
    ));
    row
}

pub(crate) fn handle_guardian_assessment(
    event: codex_protocol::approvals::GuardianAssessmentEvent,
) -> Vec<ConnectorEvent> {
    let status = match event.status {
        codex_protocol::approvals::GuardianAssessmentStatus::InProgress => ToolStatus::Running,
        codex_protocol::approvals::GuardianAssessmentStatus::Approved => ToolStatus::Completed,
        codex_protocol::approvals::GuardianAssessmentStatus::Denied => ToolStatus::Failed,
        codex_protocol::approvals::GuardianAssessmentStatus::Aborted => ToolStatus::Cancelled,
    };

    let subtitle = event.risk_level.map(|risk| match risk {
        codex_protocol::approvals::GuardianRiskLevel::Low => "low risk".to_string(),
        codex_protocol::approvals::GuardianRiskLevel::Medium => "medium risk".to_string(),
        codex_protocol::approvals::GuardianRiskLevel::High => "high risk".to_string(),
    });

    let summary = event.rationale.clone().or_else(|| {
        event
            .risk_score
            .map(|score| format!("Guardian risk score: {score}/100"))
    });

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
        invocation: serde_json::to_value(ToolInvocationPayload::Generic(
            GenericInvocationPayload {
                tool_name: "guardian_assessment".to_string(),
                raw_input: event.action.clone(),
            },
        ))
        .expect("serialize guardian assessment invocation"),
        result: Some(
            serde_json::to_value(ToolResultPayload::Generic(GenericResultPayload {
                tool_name: "guardian_assessment".to_string(),
                raw_output: event.action,
                summary,
            }))
            .expect("serialize guardian assessment result"),
        ),
        render_hints: Default::default(),
        tool_display: None,
    };

    vec![ConnectorEvent::ConversationRowCreated(tool_row_entry(row))]
}
