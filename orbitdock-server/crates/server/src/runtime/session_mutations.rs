use std::sync::Arc;

use orbitdock_protocol::{
  conversation_contracts::{
    ConversationRow, ConversationRowEntry, NoticeRow, NoticeRowKind, NoticeRowSeverity, TurnStatus,
  },
  CodexApprovalPolicy, CodexApprovalsReviewer, CodexConfigMode, ServerMessage, SessionSummary,
};

use orbitdock_protocol::StateChanges;

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;
use crate::domain::codex_tools::{write_plan_markdown, CodexWorkspaceToolContext};
use crate::domain::sessions::session::SessionSnapshot;
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::codex_config::{
  resolve_codex_settings, serialize_codex_overrides, CodexConfigSelection,
};
use crate::runtime::session_commands::{PersistOp, SessionCommand, SessionConfigPersist};
use crate::runtime::session_registry::SessionRegistry;
use crate::support::session_modes::is_passive_rollout_session;

#[derive(Debug)]
pub(crate) enum SessionMutationError {
  NotFound(String),
  InvalidCodexConfig(String),
}

#[derive(Debug, Clone, Default)]
pub(crate) struct SessionConfigUpdate {
  pub approval_policy: Option<Option<String>>,
  pub approval_policy_details: Option<Option<CodexApprovalPolicy>>,
  pub sandbox_mode: Option<Option<String>>,
  pub approvals_reviewer: Option<Option<CodexApprovalsReviewer>>,
  pub permission_mode: Option<Option<String>>,
  pub collaboration_mode: Option<Option<String>>,
  pub multi_agent: Option<Option<bool>>,
  pub personality: Option<Option<String>>,
  pub service_tier: Option<Option<String>>,
  pub developer_instructions: Option<Option<String>>,
  pub model: Option<Option<String>>,
  pub effort: Option<Option<String>>,
  pub codex_config_mode: Option<Option<CodexConfigMode>>,
  pub codex_config_profile: Option<Option<String>>,
  pub codex_model_provider: Option<Option<String>>,
}

impl SessionMutationError {
  pub(crate) fn code(&self) -> &'static str {
    match self {
      Self::NotFound(_) => "not_found",
      Self::InvalidCodexConfig(_) => "invalid_codex_config",
    }
  }

  pub(crate) fn message(&self) -> String {
    match self {
      Self::NotFound(session_id) => format!("Session {session_id} not found"),
      Self::InvalidCodexConfig(message) => message.clone(),
    }
  }
}

pub(crate) async fn rename_session(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  name: Option<String>,
) -> Result<(), SessionMutationError> {
  let actor = state
    .get_session(session_id)
    .ok_or_else(|| SessionMutationError::NotFound(session_id.to_string()))?;

  let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();
  actor
    .send(SessionCommand::SetCustomNameAndNotify {
      name: name.clone(),
      persist_op: Some(PersistOp::SetCustomName {
        session_id: session_id.to_string(),
        name: name.clone(),
      }),
      reply: reply_tx,
    })
    .await;

  if reply_rx.await.is_ok() {
    state.publish_dashboard_snapshot();
  }

  if let Some(ref name) = name {
    if let Some(tx) = state.get_codex_action_tx(session_id) {
      let _ = tx
        .send(CodexAction::SetThreadName { name: name.clone() })
        .await;
    }
  }

  Ok(())
}

pub(crate) async fn set_summary(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  summary: String,
) -> Result<(), SessionMutationError> {
  let actor = state
    .get_session(session_id)
    .ok_or_else(|| SessionMutationError::NotFound(session_id.to_string()))?;

  // Apply summary delta to in-memory state and broadcast to session subscribers
  actor
    .send(SessionCommand::ApplyDelta {
      changes: Box::new(StateChanges {
        summary: Some(Some(summary.clone())),
        ..Default::default()
      }),
      persist_op: None,
    })
    .await;

  state.publish_dashboard_snapshot();

  // Persist to DB
  let _ = state
    .persist()
    .send(PersistCommand::SetSummary {
      session_id: session_id.to_string(),
      summary,
    })
    .await;

  Ok(())
}

pub(crate) async fn update_session_config(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  update: SessionConfigUpdate,
) -> Result<(), SessionMutationError> {
  let SessionConfigUpdate {
    approval_policy,
    approval_policy_details,
    sandbox_mode,
    approvals_reviewer,
    permission_mode,
    collaboration_mode,
    multi_agent,
    personality,
    service_tier,
    developer_instructions,
    model,
    effort,
    codex_config_mode,
    codex_config_profile,
    codex_model_provider,
  } = update;
  let actor = state
    .get_session(session_id)
    .ok_or_else(|| SessionMutationError::NotFound(session_id.to_string()))?;
  let current_summary = actor
    .summary()
    .await
    .map_err(|_| SessionMutationError::NotFound(session_id.to_string()))?;

  if current_summary.provider == orbitdock_protocol::Provider::Codex
    && state.get_codex_action_tx(session_id).is_some()
    && (codex_config_mode.is_some()
      || codex_config_profile.is_some()
      || codex_model_provider.is_some())
  {
    return Err(SessionMutationError::InvalidCodexConfig(
            "Provider and profile selection are set when a Codex session starts. Start a new session to change them."
                .to_string(),
        ));
  }

  let (
    approval_policy,
    approval_policy_details,
    sandbox_mode,
    collaboration_mode,
    multi_agent,
    personality,
    service_tier,
    developer_instructions,
    model,
    effort,
    codex_config_mode,
    codex_config_profile,
    codex_model_provider,
    codex_config_source,
    codex_config_overrides,
  ) = if current_summary.provider == orbitdock_protocol::Provider::Codex {
    let mut overrides = current_summary
      .codex_config_overrides
      .clone()
      .unwrap_or_default();
    if let Some(value) = model {
      overrides.model = value;
    }
    if let Some(value) = approval_policy {
      overrides.approval_policy = value;
    }
    if let Some(value) = approval_policy_details.clone() {
      overrides.approval_policy_details = value;
      if let Some(ref details) = overrides.approval_policy_details {
        overrides.approval_policy = Some(details.legacy_summary());
      }
    }
    if let Some(value) = sandbox_mode {
      overrides.sandbox_mode = value;
    }
    if let Some(value) = approvals_reviewer {
      overrides.approvals_reviewer = value;
    }
    if let Some(value) = collaboration_mode {
      overrides.collaboration_mode = value;
    }
    if let Some(value) = multi_agent {
      overrides.multi_agent = value;
    }
    if let Some(value) = personality {
      overrides.personality = value;
    }
    if let Some(value) = service_tier {
      overrides.service_tier = value;
    }
    if let Some(value) = developer_instructions {
      overrides.developer_instructions = value;
    }
    if let Some(value) = effort {
      overrides.effort = value;
    }
    if let Some(value) = codex_model_provider.clone() {
      overrides.model_provider = value;
    }

    let source = current_summary
      .codex_config_source
      .unwrap_or(orbitdock_protocol::CodexConfigSource::User);
    let config_mode = match codex_config_mode {
      Some(Some(value)) => value,
      Some(None) => orbitdock_protocol::CodexConfigMode::Inherit,
      None => current_summary
        .codex_config_mode
        .unwrap_or(orbitdock_protocol::CodexConfigMode::Inherit),
    };
    let config_profile = match codex_config_profile.clone() {
      Some(value) => value,
      None => current_summary.codex_config_profile.clone(),
    };
    let model_provider = match codex_model_provider.clone() {
      Some(value) => value,
      None => current_summary.codex_model_provider.clone(),
    };
    let resolved = resolve_codex_settings(
      &current_summary.project_path,
      CodexConfigSelection {
        config_source: source,
        config_mode,
        config_profile: config_profile.clone(),
        model_provider: model_provider.clone(),
        overrides: overrides.clone(),
      },
    )
    .await
    .map_err(SessionMutationError::InvalidCodexConfig)?;
    (
      Some(resolved.effective_settings.approval_policy.clone()),
      Some(resolved.effective_settings.approval_policy_details.clone()),
      Some(resolved.effective_settings.sandbox_mode.clone()),
      Some(resolved.effective_settings.collaboration_mode.clone()),
      Some(resolved.effective_settings.multi_agent),
      Some(resolved.effective_settings.personality.clone()),
      Some(resolved.effective_settings.service_tier.clone()),
      Some(resolved.effective_settings.developer_instructions.clone()),
      Some(resolved.effective_settings.model.clone()),
      Some(resolved.effective_settings.effort.clone()),
      Some(Some(config_mode)),
      Some(config_profile),
      Some(resolved.effective_settings.model_provider.clone()),
      Some(source),
      Some(overrides),
    )
  } else {
    (
      approval_policy,
      approval_policy_details,
      sandbox_mode,
      collaboration_mode,
      multi_agent,
      personality,
      service_tier,
      developer_instructions,
      model,
      effort,
      codex_config_mode,
      codex_config_profile,
      codex_model_provider,
      None,
      None,
    )
  };

  let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();

  let send_result = actor
    .send_checked(SessionCommand::ApplyDeltaAndWait {
      changes: Box::new(orbitdock_protocol::StateChanges {
        approval_policy: approval_policy.clone(),
        approval_policy_details: approval_policy_details.clone(),
        sandbox_mode: sandbox_mode.clone(),
        permission_mode: permission_mode.clone(),
        collaboration_mode: collaboration_mode.clone(),
        multi_agent,
        personality: personality.clone(),
        service_tier: service_tier.clone(),
        developer_instructions: developer_instructions.clone(),
        model: model.clone(),
        effort: effort.clone(),
        codex_config_mode,
        codex_config_profile: codex_config_profile.clone(),
        codex_model_provider: codex_model_provider.clone(),
        codex_config_source: codex_config_source.map(Some),
        codex_config_overrides: codex_config_overrides.clone().map(Some),
        ..Default::default()
      }),
      persist_op: Some(PersistOp::SetSessionConfig(Box::new(
        SessionConfigPersist {
          session_id: session_id.to_string(),
          approval_policy: approval_policy.clone(),
          sandbox_mode: sandbox_mode.clone(),
          permission_mode: permission_mode.clone(),
          collaboration_mode: collaboration_mode.clone(),
          multi_agent,
          personality: personality.clone(),
          service_tier: service_tier.clone(),
          developer_instructions: developer_instructions.clone(),
          model: model.clone(),
          effort: effort.clone(),
          codex_config_mode: codex_config_mode.flatten(),
          codex_config_profile: codex_config_profile.flatten(),
          codex_model_provider: codex_model_provider.flatten(),
          codex_config_source,
          codex_config_overrides_json: codex_config_overrides
            .as_ref()
            .and_then(serialize_codex_overrides),
        },
      ))),
      reply: reply_tx,
    })
    .await;

  if send_result.is_err() {
    return Err(SessionMutationError::NotFound(session_id.to_string()));
  }

  if reply_rx.await.is_err() {
    return Err(SessionMutationError::NotFound(session_id.to_string()));
  }

  let updated_snapshot = actor.snapshot();
  let updated_summary = actor
    .summary()
    .await
    .map_err(|_| SessionMutationError::NotFound(session_id.to_string()))?;

  if let Some(entry) =
    build_session_config_change_notice_row(session_id, &current_summary, &updated_summary)
  {
    let row_id = entry.id().to_string();
    actor
      .send_checked(SessionCommand::AddRowAndBroadcast { entry })
      .await
      .map_err(|_| SessionMutationError::NotFound(session_id.to_string()))?;
    tracing::info!(
      component = "session",
      event = "session.config.notice_row_emitted",
      session_id = %session_id,
      row_id = %row_id,
      "Emitted session-config notice row"
    );
  }

  if let Some(result) = maybe_save_plan_on_collaboration_mode_exit(
    session_id,
    current_summary.collaboration_mode.as_deref(),
    updated_summary.collaboration_mode.as_deref(),
    updated_snapshot.as_ref(),
  ) {
    match result {
      Ok(saved) => {
        let entry = build_plan_snapshot_saved_notice_row(session_id, &saved.relative_path);
        let row_id = entry.id().to_string();
        actor
          .send_checked(SessionCommand::AddRowAndBroadcast { entry })
          .await
          .map_err(|_| SessionMutationError::NotFound(session_id.to_string()))?;
        tracing::info!(
          component = "session",
          event = "session.plan_snapshot.saved",
          session_id = %session_id,
          row_id = %row_id,
          path = %saved.path,
          "Saved latest plan snapshot after collaboration mode exit"
        );
      }
      Err(error) => {
        let entry = build_plan_snapshot_failed_notice_row(session_id, &error);
        let row_id = entry.id().to_string();
        actor
          .send_checked(SessionCommand::AddRowAndBroadcast { entry })
          .await
          .map_err(|_| SessionMutationError::NotFound(session_id.to_string()))?;
        tracing::warn!(
          component = "session",
          event = "session.plan_snapshot.save_failed",
          session_id = %session_id,
          row_id = %row_id,
          error = %error,
          "Failed to save latest plan snapshot after collaboration mode exit"
        );
      }
    }
  }

  if let Some(entry) = maybe_build_plan_reentry_notice_row(
    session_id,
    current_summary.collaboration_mode.as_deref(),
    updated_summary.collaboration_mode.as_deref(),
    updated_snapshot.as_ref(),
  ) {
    let row_id = entry.id().to_string();
    actor
      .send_checked(SessionCommand::AddRowAndBroadcast { entry })
      .await
      .map_err(|_| SessionMutationError::NotFound(session_id.to_string()))?;
    tracing::info!(
      component = "session",
      event = "session.plan_context.restored",
      session_id = %session_id,
      row_id = %row_id,
      "Emitted plan re-entry reminder row"
    );
  }

  state.publish_dashboard_snapshot();

  if let Some(Some(ref mode)) = permission_mode {
    if let Some(tx) = state.get_claude_action_tx(session_id) {
      let _ = tx
        .send(ClaudeAction::SetPermissionMode { mode: mode.clone() })
        .await;
    }
  }

  if let Some(tx) = state.get_codex_action_tx(session_id) {
    let _ = tx
      .send(CodexAction::UpdateConfig {
        approval_policy: approval_policy.flatten(),
        sandbox_mode: sandbox_mode.flatten(),
        approvals_reviewer: approvals_reviewer
          .flatten()
          .map(|value| value.as_str().to_string()),
        permission_mode: permission_mode.flatten(),
        collaboration_mode: collaboration_mode.flatten(),
        multi_agent: multi_agent.flatten(),
        personality: personality.flatten(),
        service_tier: service_tier.flatten(),
        developer_instructions: developer_instructions.flatten(),
        model: model.flatten(),
        effort: effort.flatten(),
      })
      .await;
  }

  Ok(())
}

#[derive(Debug, Clone)]
struct SavedPlanSnapshot {
  path: String,
  relative_path: String,
}

fn maybe_save_plan_on_collaboration_mode_exit(
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

fn maybe_build_plan_reentry_notice_row(
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

fn build_plan_snapshot_saved_notice_row(
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

fn build_plan_snapshot_failed_notice_row(session_id: &str, error: &str) -> ConversationRowEntry {
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

fn build_session_config_change_notice_row(
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

pub(crate) async fn end_session(state: &Arc<SessionRegistry>, session_id: &str) -> usize {
  let actor = state.get_session(session_id);
  let is_passive_rollout = actor.as_ref().is_some_and(|actor| {
    let snap = actor.snapshot();
    is_passive_rollout_session(
      snap.provider,
      snap.codex_integration_mode,
      snap.transcript_path.is_some(),
    )
  });

  let canceled_shells = state.shell_service().cancel_session(session_id);

  if !is_passive_rollout {
    if let Some(tx) = state.get_codex_action_tx(session_id) {
      let _ = tx.send(CodexAction::EndSession).await;
    } else if let Some(tx) = state.get_claude_action_tx(session_id) {
      let _ = tx.send(ClaudeAction::EndSession).await;
    }
  }

  let _ = state
    .persist()
    .send(PersistCommand::SessionEnd {
      id: session_id.to_string(),
      reason: "user_requested".to_string(),
    })
    .await;

  // Emit an authoritative local ended delta before any potential runtime teardown,
  // so detail/composer/conversation subscribers observe the state transition.
  if let Some(actor) = actor.as_ref() {
    actor.send(SessionCommand::EndLocally).await;
  }

  if is_passive_rollout || state.remove_session(session_id).is_some() {
    state.broadcast_to_list(ServerMessage::SessionEnded {
      session_id: session_id.to_string(),
      reason: "user_requested".to_string(),
    });
  }

  canceled_shells
}

pub(crate) async fn send_continuation_message(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  content: &str,
) -> bool {
  if let Some(tx) = state.get_claude_action_tx(session_id) {
    tx.send(ClaudeAction::SendMessage {
      content: content.to_string(),
      model: None,
      effort: None,
      images: vec![],
    })
    .await
    .is_ok()
  } else {
    false
  }
}

/// When a session with a mission_id is resumed, update the linked mission issue
/// back to `running` so mission control reflects reality.
pub(crate) async fn sync_mission_issue_on_resume(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  mission_id: &str,
) {
  let now = chrono::Utc::now().to_rfc3339();

  // Find the mission issue linked to this session_id
  let db_path = state.db_path().clone();
  let sid = session_id.to_string();
  let mid = mission_id.to_string();
  let issue_id = tokio::task::spawn_blocking(move || {
    let conn = rusqlite::Connection::open(&db_path).ok()?;
    let mut stmt = conn
      .prepare(
        "SELECT issue_id FROM mission_issues \
                 WHERE mission_id = ?1 AND session_id = ?2 \
                 LIMIT 1",
      )
      .ok()?;
    stmt
      .query_row(rusqlite::params![mid, sid], |row| row.get::<_, String>(0))
      .ok()
  })
  .await
  .ok()
  .flatten();

  let Some(issue_id) = issue_id else {
    tracing::debug!(
        component = "mission_control",
        event = "resume_hook.no_linked_issue",
        session_id = %session_id,
        mission_id = %mission_id,
        "No mission issue linked to resumed session"
    );
    return;
  };

  // Update the issue back to running
  let _ = state
    .persist()
    .send(PersistCommand::MissionIssueUpdateState {
      mission_id: mission_id.to_string(),
      issue_id: issue_id.clone(),
      orchestration_state: "running".to_string(),
      session_id: Some(session_id.to_string()),
      workspace_id: None,
      attempt: None,
      last_error: Some(None), // clear error
      retry_due_at: None,
      started_at: Some(Some(now)),
      completed_at: Some(None), // clear completed_at
    })
    .await;

  // Broadcast updated mission state
  crate::runtime::mission_orchestrator::broadcast_mission_delta_by_id(state, mission_id).await;

  tracing::info!(
      component = "mission_control",
      event = "resume_hook.issue_reactivated",
      session_id = %session_id,
      mission_id = %mission_id,
      issue_id = %issue_id,
      "Reactivated mission issue on session resume"
  );
}

pub(crate) async fn end_failed_direct_session(state: &Arc<SessionRegistry>, session_id: &str) {
  let _ = state
    .persist()
    .send(PersistCommand::SessionEnd {
      id: session_id.to_string(),
      reason: "connector_failed".to_string(),
    })
    .await;
  state.broadcast_to_list(ServerMessage::SessionEnded {
    session_id: session_id.to_string(),
    reason: "connector_failed".into(),
  });
}

#[cfg(test)]
mod tests {
  use std::fs;
  use std::sync::Arc;

  use orbitdock_protocol::{
    conversation_contracts::ConversationRow, CodexIntegrationMode, Provider, ServerMessage,
    SessionStatus, StateChanges, WorkStatus,
  };
  use tokio::sync::{mpsc, oneshot};
  use tokio::time::{timeout, Duration};

  use super::{end_session, update_session_config, SessionConfigUpdate};
  use crate::domain::sessions::session::SessionHandle;
  use crate::runtime::session_commands::{SessionCommand, SubscribeResult};
  use crate::runtime::session_registry::SessionRegistry;
  use crate::support::test_support::{ensure_server_test_data_dir, new_test_session_registry};

  fn count_settings_notice_rows(
    rows: &[orbitdock_protocol::conversation_contracts::ConversationRowEntry],
  ) -> usize {
    rows
      .iter()
      .filter(|entry| {
        matches!(
          &entry.row,
          ConversationRow::Notice(notice) if notice.title == "Session settings updated"
        )
      })
      .count()
  }

  fn count_plan_snapshot_notice_rows(
    rows: &[orbitdock_protocol::conversation_contracts::ConversationRowEntry],
  ) -> usize {
    rows
      .iter()
      .filter(|entry| {
        matches!(
          &entry.row,
          ConversationRow::Notice(notice) if notice.title == "Plan snapshot saved"
        )
      })
      .count()
  }

  fn count_plan_context_restored_notice_rows(
    rows: &[orbitdock_protocol::conversation_contracts::ConversationRowEntry],
  ) -> usize {
    rows
      .iter()
      .filter(|entry| {
        matches!(
          &entry.row,
          ConversationRow::Notice(notice) if notice.title == "Plan context restored"
        )
      })
      .count()
  }

  #[tokio::test]
  async fn ending_direct_session_emits_local_ended_delta_before_removal() {
    ensure_server_test_data_dir();
    let (persist_tx, _persist_rx) = mpsc::channel(32);
    let state = Arc::new(SessionRegistry::new_with_primary(persist_tx, true));

    let session_id = "direct-end-test";
    let mut handle = SessionHandle::new(
      session_id.to_string(),
      Provider::Codex,
      "/tmp/direct-end-test".to_string(),
    );
    handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
    handle.set_status(SessionStatus::Active);
    handle.set_work_status(WorkStatus::Waiting);
    handle.refresh_snapshot();

    let actor = state.add_session(handle);

    let (reply_tx, reply_rx) = oneshot::channel();
    actor
      .send(SessionCommand::Subscribe {
        since_revision: None,
        reply: reply_tx,
      })
      .await;
    let mut rx = match reply_rx.await.expect("subscribe response should arrive") {
      SubscribeResult::Replay { rx, .. } | SubscribeResult::ResyncRequired { rx } => rx,
    };

    let _ = end_session(&state, session_id).await;

    let msg = timeout(Duration::from_secs(2), rx.recv())
      .await
      .expect("session should emit a local ended delta before teardown")
      .expect("session delta channel should remain open");

    match msg {
      ServerMessage::SessionDelta { changes, .. } => {
        assert_eq!(changes.status, Some(SessionStatus::Ended));
        assert_eq!(changes.work_status, Some(WorkStatus::Ended));
      }
      other => panic!("expected SessionDelta with ended state, got {other:?}"),
    }

    assert!(
      state.get_session(session_id).is_none(),
      "direct session should be removed from runtime after local ended delta"
    );
  }

  #[tokio::test]
  async fn update_session_config_updates_runtime_snapshot_before_handler_returns() {
    let state = new_test_session_registry(true);
    let session_id = "control-deck-update-runtime";

    state.add_session(SessionHandle::new(
      session_id.to_string(),
      Provider::Claude,
      "/tmp/control-deck-update-runtime".to_string(),
    ));

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        model: Some(Some("opus-4.1".to_string())),
        effort: Some(Some("high".to_string())),
        permission_mode: Some(Some("full".to_string())),
        collaboration_mode: Some(Some("enabled".to_string())),
        ..Default::default()
      },
    )
    .await
    .expect("control deck config update should succeed");

    let snapshot = state
      .get_session(session_id)
      .expect("session still exists after config update")
      .summary()
      .await
      .expect("summary command should be answered");

    assert_eq!(snapshot.model.as_deref(), Some("opus-4.1"));
    assert_eq!(snapshot.effort.as_deref(), Some("high"));
    assert_eq!(snapshot.permission_mode.as_deref(), Some("full"));
    assert_eq!(snapshot.collaboration_mode.as_deref(), Some("enabled"));
  }

  #[tokio::test]
  async fn update_session_config_emits_notice_row_for_effective_changes() {
    let state = new_test_session_registry(true);
    let session_id = "control-deck-update-row";

    state.add_session(SessionHandle::new(
      session_id.to_string(),
      Provider::Claude,
      "/tmp/control-deck-update-row".to_string(),
    ));

    let actor = state
      .get_session(session_id)
      .expect("session should exist before config update");
    let before = actor
      .summary()
      .await
      .expect("summary should be available before update");

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        model: Some(Some("row-test-model".to_string())),
        ..Default::default()
      },
    )
    .await
    .expect("control deck config update should succeed");

    let actor = state
      .get_session(session_id)
      .expect("session still exists after config update");
    let after = actor
      .summary()
      .await
      .expect("summary should be available after update");
    assert_ne!(
      before.model, after.model,
      "test requires an actual model change to validate notice-row behavior"
    );
    assert_eq!(after.model.as_deref(), Some("row-test-model"));

    let page = actor
      .conversation_page(None, 50)
      .await
      .expect("conversation page should be available");

    assert_eq!(
      count_settings_notice_rows(&page.rows),
      1,
      "one settings notice row should be appended"
    );
    let row = page
      .rows
      .first()
      .expect("notice row should be present after config update");

    let ConversationRow::Notice(notice) = &row.row else {
      panic!("expected notice row for config change, got {:?}", row.row);
    };

    assert_eq!(notice.title, "Session settings updated");
    let summary = notice
      .summary
      .as_deref()
      .expect("summary should describe changed settings");
    assert!(summary.contains("Model:"));
    assert!(summary.contains("row-test-model"));
    assert!(
      notice.body.is_none(),
      "single-change settings notice should not duplicate summary in body"
    );
  }

  #[tokio::test]
  async fn update_session_config_skips_notice_row_when_values_do_not_change() {
    let state = new_test_session_registry(true);
    let session_id = "control-deck-update-noop-row";

    state.add_session(SessionHandle::new(
      session_id.to_string(),
      Provider::Claude,
      "/tmp/control-deck-update-noop-row".to_string(),
    ));

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        model: Some(Some("row-test-model".to_string())),
        ..Default::default()
      },
    )
    .await
    .expect("initial config update should succeed");

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        model: Some(Some("row-test-model".to_string())),
        ..Default::default()
      },
    )
    .await
    .expect("second config update should succeed");

    let page = state
      .get_session(session_id)
      .expect("session should still exist")
      .conversation_page(None, 50)
      .await
      .expect("conversation page should be available");

    assert_eq!(
      count_settings_notice_rows(&page.rows),
      1,
      "no-op config update should not append an extra settings notice row"
    );
  }

  #[tokio::test]
  async fn update_session_config_saves_plan_snapshot_on_plan_mode_exit() {
    let state = new_test_session_registry(true);
    let temp = tempfile::tempdir().expect("tempdir");
    let session_id = "plan-exit-snapshot";

    state.add_session(SessionHandle::new(
      session_id.to_string(),
      Provider::Claude,
      temp.path().to_string_lossy().to_string(),
    ));

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        collaboration_mode: Some(Some("plan".to_string())),
        ..Default::default()
      },
    )
    .await
    .expect("should enter plan mode");

    let actor = state
      .get_session(session_id)
      .expect("session should exist after entering plan mode");
    actor
      .send(SessionCommand::ApplyDelta {
        changes: Box::new(StateChanges {
          current_plan: Some(Some(
            "## Implementation Plan\n- [ ] Add a plan_write integration\n".to_string(),
          )),
          ..Default::default()
        }),
        persist_op: None,
      })
      .await;

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        collaboration_mode: Some(Some("default".to_string())),
        ..Default::default()
      },
    )
    .await
    .expect("should exit plan mode");

    let plan_path = temp.path().join("plans/auto/plan-exit-snapshot.md");
    let content = fs::read_to_string(&plan_path).expect("plan snapshot should be written");
    assert!(content.contains("# Plan Snapshot"));
    assert!(content.contains("## Implementation Plan"));
    assert!(content.contains("collaboration mode exit"));

    let page = state
      .get_session(session_id)
      .expect("session should exist")
      .conversation_page(None, 100)
      .await
      .expect("conversation page should be available");

    assert_eq!(
      count_plan_snapshot_notice_rows(&page.rows),
      1,
      "plan mode exit should emit exactly one plan snapshot notice row"
    );
  }

  #[tokio::test]
  async fn update_session_config_skips_plan_snapshot_on_plan_exit_without_plan() {
    let state = new_test_session_registry(true);
    let temp = tempfile::tempdir().expect("tempdir");
    let session_id = "plan-exit-no-plan";

    state.add_session(SessionHandle::new(
      session_id.to_string(),
      Provider::Claude,
      temp.path().to_string_lossy().to_string(),
    ));

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        collaboration_mode: Some(Some("plan".to_string())),
        ..Default::default()
      },
    )
    .await
    .expect("should enter plan mode");

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        collaboration_mode: Some(Some("default".to_string())),
        ..Default::default()
      },
    )
    .await
    .expect("should exit plan mode");

    assert!(
      !temp.path().join("plans/auto/plan-exit-no-plan.md").exists(),
      "no plan snapshot should be written when there is no current plan"
    );

    let page = state
      .get_session(session_id)
      .expect("session should exist")
      .conversation_page(None, 100)
      .await
      .expect("conversation page should be available");

    assert_eq!(
      count_plan_snapshot_notice_rows(&page.rows),
      0,
      "no plan snapshot notice row should be emitted without a plan"
    );
  }

  #[tokio::test]
  async fn update_session_config_emits_plan_context_restored_notice_on_plan_reentry() {
    let state = new_test_session_registry(true);
    let temp = tempfile::tempdir().expect("tempdir");
    let session_id = "plan-context-restored";

    state.add_session(SessionHandle::new(
      session_id.to_string(),
      Provider::Claude,
      temp.path().to_string_lossy().to_string(),
    ));

    let actor = state
      .get_session(session_id)
      .expect("session should exist before update");
    actor
      .send(SessionCommand::ApplyDelta {
        changes: Box::new(StateChanges {
          current_plan: Some(Some(
            "## Existing Plan\n- [ ] Keep iterating in plan mode\n".to_string(),
          )),
          ..Default::default()
        }),
        persist_op: None,
      })
      .await;

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        collaboration_mode: Some(Some("plan".to_string())),
        ..Default::default()
      },
    )
    .await
    .expect("should enter plan mode");

    let page = state
      .get_session(session_id)
      .expect("session should exist")
      .conversation_page(None, 100)
      .await
      .expect("conversation page should be available");

    assert_eq!(
      count_plan_context_restored_notice_rows(&page.rows),
      1,
      "entering plan mode with an existing plan should emit a re-entry reminder row"
    );

    let restored_notice = page
      .rows
      .iter()
      .find_map(|entry| match &entry.row {
        ConversationRow::Notice(notice) if notice.title == "Plan context restored" => Some(notice),
        _ => None,
      })
      .expect("plan context restored notice should exist");
    assert!(
      restored_notice
        .summary
        .as_deref()
        .is_some_and(|summary| summary.contains("plans/auto/plan-context-restored.md")),
      "re-entry notice should include the auto-save path"
    );
  }

  #[tokio::test]
  async fn update_session_config_skips_plan_context_restored_notice_without_existing_plan() {
    let state = new_test_session_registry(true);
    let temp = tempfile::tempdir().expect("tempdir");
    let session_id = "plan-context-no-existing-plan";

    state.add_session(SessionHandle::new(
      session_id.to_string(),
      Provider::Claude,
      temp.path().to_string_lossy().to_string(),
    ));

    update_session_config(
      &state,
      session_id,
      SessionConfigUpdate {
        collaboration_mode: Some(Some("plan".to_string())),
        ..Default::default()
      },
    )
    .await
    .expect("should enter plan mode");

    let page = state
      .get_session(session_id)
      .expect("session should exist")
      .conversation_page(None, 100)
      .await
      .expect("conversation page should be available");

    assert_eq!(
      count_plan_context_restored_notice_rows(&page.rows),
      0,
      "entering plan mode without a prior plan should not emit a re-entry reminder row"
    );
  }
}
