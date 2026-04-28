use codex_app_server_protocol::{FileUpdateChange, PatchApplyStatus, PatchChangeKind};
use orbitdock_connector_core::ConnectorOutput;
use orbitdock_protocol::conversation_contracts::ToolRow;
use orbitdock_protocol::domain_events::{ToolFamily, ToolKind, ToolStatus};
use serde_json::json;

use crate::row_mapping::{row_created_output, row_updated_output, tool_row_entry};
use crate::workers::iso_now;

pub(crate) struct ToolRowArgs {
  pub(crate) id: String,
  pub(crate) family: ToolFamily,
  pub(crate) kind: ToolKind,
  pub(crate) title: String,
  pub(crate) summary: Option<String>,
  pub(crate) invocation: serde_json::Value,
  pub(crate) result: Option<serde_json::Value>,
  pub(crate) started: bool,
  pub(crate) success: bool,
  pub(crate) duration_ms: Option<u64>,
}

pub(crate) fn map_tool_row(args: ToolRowArgs) -> Vec<ConnectorOutput> {
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
    provider: orbitdock_protocol::Provider::Codex,
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

pub(crate) fn duration_millis(value: Option<i64>) -> Option<u64> {
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
    provider: orbitdock_protocol::Provider::Codex,
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
  let payload = orbitdock_protocol::domain_events::GuardianAssessmentPayload {
    action: serde_json::to_value(&action).ok(),
    risk_level: risk_level.clone(),
    risk_score: None,
    rationale: review.rationale.clone(),
    status_label: Some(status_label.clone()),
  };
  let output = serde_json::to_string(&payload).unwrap_or_else(|_| status_label.clone());

  ToolRow {
    id: format!("guardian-{review_id}"),
    provider: orbitdock_protocol::Provider::Codex,
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
