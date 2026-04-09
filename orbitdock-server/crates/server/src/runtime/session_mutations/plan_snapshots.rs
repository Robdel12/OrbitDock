use orbitdock_protocol::conversation_contracts::{
  ConversationRow, ConversationRowEntry, NoticeRow, NoticeRowKind, NoticeRowSeverity, TurnStatus,
};

use crate::domain::codex_tools::{write_plan_markdown, CodexWorkspaceToolContext};
use crate::domain::sessions::session::SessionSnapshot;

#[derive(Debug, Clone)]
pub(crate) struct SavedPlanSnapshot {
  pub path: String,
  pub relative_path: String,
}

pub(crate) fn maybe_save_plan_on_collaboration_mode_exit(
  session_id: &str,
  before_mode: Option<&str>,
  after_mode: Option<&str>,
  updated_snapshot: &SessionSnapshot,
) -> Option<Result<SavedPlanSnapshot, String>> {
  if !did_exit_plan_mode(before_mode, after_mode) {
    return None;
  }

  let plan = updated_snapshot
    .current_plan
    .as_deref()
    .map(str::trim)
    .filter(|value| !value.is_empty())?;
  let relative_path = plan_snapshot_relative_path(session_id);
  let markdown = render_plan_snapshot_markdown(session_id, plan, after_mode);
  let context = CodexWorkspaceToolContext {
    project_path: updated_snapshot.project_path.clone(),
    current_cwd: updated_snapshot.current_cwd.clone(),
  };
  Some(
    write_plan_markdown(&context, &relative_path, &markdown, true).map(|path| SavedPlanSnapshot {
      path: path.to_string_lossy().to_string(),
      relative_path: format!("plans/{relative_path}"),
    }),
  )
}

pub(crate) fn maybe_build_plan_reentry_notice_row(
  session_id: &str,
  before_mode: Option<&str>,
  after_mode: Option<&str>,
  updated_snapshot: &SessionSnapshot,
) -> Option<ConversationRowEntry> {
  if !did_enter_plan_mode(before_mode, after_mode) {
    return None;
  }

  let has_non_empty_plan = updated_snapshot
    .current_plan
    .as_deref()
    .map(str::trim)
    .is_some_and(|value| !value.is_empty());
  if !has_non_empty_plan {
    return None;
  }

  let relative_path = format!("plans/{}", plan_snapshot_relative_path(session_id));
  Some(build_plan_reentry_notice_row(session_id, &relative_path))
}

fn did_exit_plan_mode(before_mode: Option<&str>, after_mode: Option<&str>) -> bool {
  is_plan_mode(before_mode) && !is_plan_mode(after_mode)
}

fn did_enter_plan_mode(before_mode: Option<&str>, after_mode: Option<&str>) -> bool {
  !is_plan_mode(before_mode) && is_plan_mode(after_mode)
}

fn is_plan_mode(mode: Option<&str>) -> bool {
  mode.is_some_and(|value| value.trim().eq_ignore_ascii_case("plan"))
}

fn plan_snapshot_relative_path(session_id: &str) -> String {
  format!("auto/{}.md", sanitize_plan_snapshot_stem(session_id))
}

fn sanitize_plan_snapshot_stem(input: &str) -> String {
  let mut stem = String::with_capacity(input.len());
  for ch in input.chars() {
    if ch.is_ascii_alphanumeric() {
      stem.push(ch.to_ascii_lowercase());
    } else if matches!(ch, '-' | '_') {
      stem.push(ch);
    } else {
      stem.push('-');
    }
  }
  let sanitized = stem.trim_matches('-');
  if sanitized.is_empty() {
    return "session".to_string();
  }
  sanitized.to_string()
}

fn render_plan_snapshot_markdown(session_id: &str, plan: &str, next_mode: Option<&str>) -> String {
  let saved_at = chrono::Utc::now().to_rfc3339();
  let next_mode = next_mode.unwrap_or("default");
  format!(
    "# Plan Snapshot\n\n- Session: `{session_id}`\n- Saved at: `{saved_at}`\n- Trigger: collaboration mode exit (`plan` -> `{next_mode}`)\n\n## Latest Plan\n\n{plan}\n"
  )
}

pub(crate) fn build_plan_snapshot_saved_notice_row(
  session_id: &str,
  relative_path: &str,
) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: session_id.to_string(),
    sequence: 0,
    turn_id: None,
    turn_status: TurnStatus::Active,
    row: ConversationRow::Notice(NoticeRow {
      id: orbitdock_protocol::new_id(),
      kind: NoticeRowKind::Generic,
      severity: NoticeRowSeverity::Info,
      title: "Plan snapshot saved".to_string(),
      summary: Some(format!("Saved latest plan to {relative_path}")),
      body: None,
      render_hints: Default::default(),
    }),
  }
}

pub(crate) fn build_plan_snapshot_failed_notice_row(
  session_id: &str,
  error: &str,
) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: session_id.to_string(),
    sequence: 0,
    turn_id: None,
    turn_status: TurnStatus::Active,
    row: ConversationRow::Notice(NoticeRow {
      id: orbitdock_protocol::new_id(),
      kind: NoticeRowKind::Generic,
      severity: NoticeRowSeverity::Warning,
      title: "Plan snapshot failed".to_string(),
      summary: Some("Could not save latest plan to plans/".to_string()),
      body: Some(error.to_string()),
      render_hints: Default::default(),
    }),
  }
}

fn build_plan_reentry_notice_row(session_id: &str, relative_path: &str) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: session_id.to_string(),
    sequence: 0,
    turn_id: None,
    turn_status: TurnStatus::Active,
    row: ConversationRow::Notice(NoticeRow {
      id: orbitdock_protocol::new_id(),
      kind: NoticeRowKind::Generic,
      severity: NoticeRowSeverity::Info,
      title: "Plan context restored".to_string(),
      summary: Some(format!(
        "Existing plan loaded. Auto-save path: {relative_path}"
      )),
      body: Some("Use `plan_write` to persist named plan markdown in `plans/`.".to_string()),
      render_hints: Default::default(),
    }),
  }
}
