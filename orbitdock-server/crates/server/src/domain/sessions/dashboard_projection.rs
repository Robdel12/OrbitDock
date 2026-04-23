//! Dashboard projection — pure functions that transform SessionSnapshot into
//! DashboardConversationItem. This is the ONLY way to build dashboard items
//! from live state.
//!
//! No IO, no side effects, no DB access. Depends only on domain types and
//! protocol types.

use std::path::Path;

use orbitdock_protocol::{
  ClaudeIntegrationMode, CodexIntegrationMode, DashboardConversationItem, Provider, SessionSummary,
};

use super::session::SessionSnapshot;

/// Build a DashboardConversationItem from a session snapshot.
/// Pure function — no IO, no side effects, no DB access.
pub fn dashboard_item_from_snapshot(snap: &SessionSnapshot) -> DashboardConversationItem {
  let display_title = SessionSummary::display_title_from_parts(
    snap.custom_name.as_deref(),
    snap.summary.as_deref(),
    snap.first_prompt.as_deref(),
    snap.project_name.as_deref(),
    &snap.project_path,
  );
  let context_line = SessionSummary::context_line_from_parts(
    snap.summary.as_deref(),
    snap.first_prompt.as_deref(),
    snap.last_message.as_deref(),
  );
  let preview_text = dashboard_preview_text(snap.last_message.as_deref(), context_line.as_deref());
  let activity_summary = dashboard_activity_summary(
    snap.pending_tool_name.as_deref(),
    snap.last_message.as_deref(),
    context_line.as_deref(),
  );
  let alert_context = dashboard_alert_context(
    snap.pending_question.as_deref(),
    snap.pending_tool_name.as_deref(),
    snap.pending_tool_input.as_deref(),
    snap.last_message.as_deref(),
    context_line.as_deref(),
  );
  let (grouping_path, grouping_name) = dashboard_grouping_details(
    &snap.project_path,
    snap.repository_root.as_deref(),
    snap.project_name.as_deref(),
  );

  DashboardConversationItem {
    session_id: snap.id.clone(),
    provider: snap.provider,
    project_path: snap.project_path.clone(),
    grouping_path: Some(grouping_path),
    grouping_name: Some(grouping_name),
    project_name: snap.project_name.clone(),
    repository_root: snap.repository_root.clone(),
    git_branch: snap.git_branch.clone(),
    is_worktree: snap.is_worktree,
    worktree_id: snap.worktree_id.clone(),
    model: snap.model.clone(),
    codex_integration_mode: snap.codex_integration_mode,
    claude_integration_mode: snap.claude_integration_mode,
    status: snap.status,
    work_status: snap.work_status,
    control_mode: snap.control_mode,
    lifecycle_state: snap.lifecycle_state,
    list_status: SessionSummary::list_status_from_parts(snap.status, snap.work_status),
    display_title,
    context_line,
    last_message: snap.last_message.clone(),
    started_at: snap.started_at.clone(),
    last_activity_at: snap.last_activity_at.clone(),
    unread_count: snap.unread_count,
    has_turn_diff: snap.has_turn_diff,
    diff_preview: snap.diff_preview.clone(),
    pending_tool_name: snap.pending_tool_name.clone(),
    pending_tool_input: snap.pending_tool_input.clone(),
    pending_question: snap.pending_question.clone(),
    preview_text: Some(preview_text),
    activity_summary: Some(activity_summary),
    alert_context: Some(alert_context),
    tool_count: snap.tool_count,
    active_worker_count: snap.active_worker_count,
    issue_identifier: snap.issue_identifier.clone(),
    effort: snap.effort.clone(),
  }
}

pub(crate) fn dashboard_priority(item: &DashboardConversationItem) -> u8 {
  match item.list_status {
    orbitdock_protocol::SessionListStatus::Permission => 0,
    orbitdock_protocol::SessionListStatus::Question => 1,
    orbitdock_protocol::SessionListStatus::Working => 2,
    orbitdock_protocol::SessionListStatus::Reply => 3,
    orbitdock_protocol::SessionListStatus::Ended => 4,
  }
}

pub(crate) fn is_direct_conversation(conversation: &DashboardConversationItem) -> bool {
  matches!(
    (
      conversation.provider,
      conversation.codex_integration_mode,
      conversation.claude_integration_mode
    ),
    (Provider::Codex, Some(CodexIntegrationMode::Direct), _)
      | (Provider::Claude, _, Some(ClaudeIntegrationMode::Direct))
  )
}

// ── Private helpers ────────────────────────────────────────────

fn dashboard_grouping_details(
  project_path: &str,
  repository_root: Option<&str>,
  project_name: Option<&str>,
) -> (String, String) {
  let grouping_path = repository_root.unwrap_or(project_path).to_string();
  let grouping_name = project_name
    .map(str::trim)
    .filter(|name| !name.is_empty())
    .map(ToOwned::to_owned)
    .unwrap_or_else(|| {
      grouping_path
        .rsplit('/')
        .find(|segment| !segment.is_empty())
        .map(std::string::ToString::to_string)
        .unwrap_or_else(|| "Unknown".to_string())
    });

  (grouping_path, grouping_name)
}

fn sanitize_dashboard_text(text: &str) -> String {
  text
    .replace("**", "")
    .replace("__", "")
    .replace('`', "")
    .replace("## ", "")
    .replace("# ", "")
}

fn dashboard_preview_text(last_message: Option<&str>, context_line: Option<&str>) -> String {
  sanitize_dashboard_text(
    last_message
      .or(context_line)
      .unwrap_or("Waiting for your next message."),
  )
}

fn dashboard_activity_summary(
  pending_tool_name: Option<&str>,
  last_message: Option<&str>,
  context_line: Option<&str>,
) -> String {
  if let Some(tool_name) = pending_tool_name {
    return format!("Running {tool_name}");
  }

  sanitize_dashboard_text(last_message.or(context_line).unwrap_or("Processing…"))
}

fn format_tool_context(tool_name: &str, input: Option<&str>) -> String {
  let Some(input) = input.filter(|value| !value.is_empty()) else {
    return format!("Wants to run {tool_name}");
  };

  let Ok(json) = serde_json::from_str::<serde_json::Value>(input) else {
    return format!("Wants to run {tool_name}");
  };

  match tool_name {
    "Bash" => json
      .get("command")
      .and_then(serde_json::Value::as_str)
      .map(ToOwned::to_owned),
    "Edit" | "Write" | "Read" => json
      .get("file_path")
      .and_then(serde_json::Value::as_str)
      .and_then(|path| Path::new(path).file_name())
      .and_then(|name| name.to_str())
      .map(|name| format!("{tool_name} {name}")),
    "Grep" => json
      .get("pattern")
      .and_then(serde_json::Value::as_str)
      .map(|pattern| format!("Search for \"{pattern}\"")),
    "Glob" => json
      .get("pattern")
      .and_then(serde_json::Value::as_str)
      .map(|pattern| format!("Find files matching {pattern}")),
    _ => None,
  }
  .unwrap_or_else(|| format!("Wants to run {tool_name}"))
}

fn dashboard_alert_context(
  pending_question: Option<&str>,
  pending_tool_name: Option<&str>,
  pending_tool_input: Option<&str>,
  last_message: Option<&str>,
  context_line: Option<&str>,
) -> String {
  if let Some(question) = pending_question.filter(|value| !value.is_empty()) {
    return question.to_string();
  }

  if let Some(tool_name) = pending_tool_name {
    return format_tool_context(tool_name, pending_tool_input);
  }

  sanitize_dashboard_text(
    last_message
      .or(context_line)
      .unwrap_or("Needs your attention."),
  )
}
