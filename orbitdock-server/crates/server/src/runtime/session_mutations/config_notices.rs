use orbitdock_protocol::conversation_contracts::{
  ConversationRow, ConversationRowEntry, NoticeRow, NoticeRowKind, NoticeRowSeverity, TurnStatus,
};
use orbitdock_protocol::SessionSummary;

pub(crate) fn build_session_config_change_notice_row(
  session_id: &str,
  before: &SessionSummary,
  after: &SessionSummary,
) -> Option<ConversationRowEntry> {
  let mut changes = Vec::new();
  for (label, before_value, after_value) in [
    ("Model", before.model.as_deref(), after.model.as_deref()),
    (
      "Reasoning effort",
      before.effort.as_deref(),
      after.effort.as_deref(),
    ),
    (
      "Approval mode",
      before.approval_policy.as_deref(),
      after.approval_policy.as_deref(),
    ),
    (
      "Sandbox mode",
      before.sandbox_mode.as_deref(),
      after.sandbox_mode.as_deref(),
    ),
    (
      "Permission mode",
      before.permission_mode.as_deref(),
      after.permission_mode.as_deref(),
    ),
    (
      "Collaboration mode",
      before.collaboration_mode.as_deref(),
      after.collaboration_mode.as_deref(),
    ),
    (
      "Reviewer",
      codex_overrides_reviewer(before),
      codex_overrides_reviewer(after),
    ),
  ] {
    push_config_change(&mut changes, label, before_value, after_value);
  }

  if changes.is_empty() {
    return None;
  }

  let summary = changes.join(" | ");
  let body = if changes.len() > 1 {
    Some(
      changes
        .iter()
        .map(|change| format!("- {change}"))
        .collect::<Vec<_>>()
        .join("\n"),
    )
  } else {
    None
  };

  Some(ConversationRowEntry {
    session_id: session_id.to_string(),
    sequence: 0,
    turn_id: None,
    turn_status: TurnStatus::Active,
    row: ConversationRow::Notice(NoticeRow {
      id: orbitdock_protocol::new_id(),
      kind: NoticeRowKind::Generic,
      severity: NoticeRowSeverity::Info,
      title: "Session settings updated".to_string(),
      summary: Some(summary),
      body,
      render_hints: Default::default(),
    }),
  })
}

fn push_config_change(
  changes: &mut Vec<String>,
  label: &str,
  before: Option<&str>,
  after: Option<&str>,
) {
  if before == after {
    return;
  }
  changes.push(format!(
    "{label}: {} -> {}",
    format_config_value(before),
    format_config_value(after)
  ));
}

fn format_config_value(value: Option<&str>) -> String {
  value.unwrap_or("default").to_owned()
}

fn codex_overrides_reviewer(summary: &SessionSummary) -> Option<&'static str> {
  summary
    .codex_config_overrides
    .as_ref()
    .and_then(|overrides| overrides.approvals_reviewer)
    .map(|reviewer| reviewer.as_str())
}
