use std::collections::HashMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::sync::oneshot;
use tracing::debug;

use orbitdock_protocol::conversation_contracts::rows::MessageDeliveryStatus;
use orbitdock_protocol::PermissionGrantScope;
use orbitdock_protocol::{
  ImageInput, MentionInput, SessionControlMode, SessionLifecycleState, SessionStatus, SkillInput,
  WorkStatus,
};

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::message_dispatch_policy::{
  build_user_row_entry, plan_send_message, PromptRowKind,
};
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_runtime_helpers::mark_session_working_after_send;
use crate::support::normalization::{
  build_question_answers, normalize_non_empty, normalize_permission_response,
};

#[path = "message_dispatch_flow.rs"]
mod message_dispatch_flow;

use self::message_dispatch_flow::{send_steer_turn_to_connector, send_user_message_to_connector};

#[derive(Debug)]
pub(crate) enum DispatchMessageError {
  SessionNotFound,
  ConnectorUnavailable,
  NotSteerable,
}

pub(crate) struct AnswerQuestionResult {
  pub outcome: String,
  pub active_request_id: Option<String>,
  pub approval_version: u64,
}

pub(crate) struct DispatchSendMessage {
  pub session_id: String,
  pub content: String,
  pub model: Option<String>,
  pub effort: Option<String>,
  pub skills: Vec<SkillInput>,
  pub images: Vec<ImageInput>,
  pub mentions: Vec<MentionInput>,
  pub message_id: String,
}

fn ensure_session_exists(
  state: &Arc<SessionRegistry>,
  session_id: &str,
) -> Result<(), &'static str> {
  if state.get_session(session_id).is_some() {
    Ok(())
  } else {
    Err("session_not_found")
  }
}

pub(crate) async fn dispatch_send_message(
  state: &Arc<SessionRegistry>,
  request: DispatchSendMessage,
) -> Result<orbitdock_protocol::conversation_contracts::ConversationRowEntry, DispatchMessageError>
{
  let DispatchSendMessage {
    session_id,
    content,
    model,
    effort,
    skills,
    images,
    mentions,
    message_id,
  } = request;
  let codex_tx = state.get_codex_action_tx(&session_id);
  let claude_tx = state.get_claude_action_tx(&session_id);
  let Some(actor) = state.get_session(&session_id) else {
    return Err(DispatchMessageError::SessionNotFound);
  };

  let snapshot = actor.snapshot();
  let provider = snapshot.provider;

  if codex_tx.is_none() && claude_tx.is_none() {
    return Err(DispatchMessageError::ConnectorUnavailable);
  }

  let requested_effort = normalize_non_empty(effort.clone());
  let plan = plan_send_message(
    provider,
    snapshot.codex_config_mode,
    &content,
    model,
    effort,
  );

  let ts_millis = SystemTime::now()
    .duration_since(UNIX_EPOCH)
    .unwrap_or_default()
    .as_millis();
  let persisted_images =
    crate::infrastructure::images::materialize_images_for_message(&session_id, &images);
  let connector_images =
    crate::infrastructure::images::resolve_images_for_connector(&session_id, &persisted_images);
  let row_content = content.clone();
  let action_model = plan.action_model.clone();
  let connector_effort = plan.connector_effort.clone();
  let first_prompt = plan.first_prompt.clone();
  let session_effort_update = plan.session_effort_update.clone();

  if let Err(error) = send_user_message_to_connector(
    state,
    &session_id,
    codex_tx,
    claude_tx,
    content,
    action_model.clone(),
    connector_effort,
    skills,
    connector_images,
    mentions,
  )
  .await
  {
    return Err(error);
  }

  let user_entry = build_user_row_entry(
    &session_id,
    message_id,
    row_content,
    ts_millis,
    persisted_images.clone(),
    PromptRowKind::User,
    Some(MessageDeliveryStatus::Accepted),
  );

  let (reply_tx, reply_rx) = oneshot::channel();
  actor
    .send(SessionCommand::AddRowAndBroadcastAndReply {
      entry: user_entry.clone(),
      reply: reply_tx,
    })
    .await;
  let user_entry = reply_rx
    .await
    .map_err(|_| DispatchMessageError::ConnectorUnavailable)?;

  if let Some(prompt) = first_prompt {
    // First message: persist prompt_count + first_prompt + broadcast via transition
    actor
      .send(SessionCommand::ProcessEvent {
        event: crate::domain::sessions::transition::Input::FirstPromptCaptured(prompt.clone()),
      })
      .await;

    if state.naming_guard().try_claim(&session_id) {
      crate::support::ai_naming::spawn_naming_task(session_id.clone(), prompt, actor.clone());
    }
  } else {
    // Subsequent messages: just increment prompt_count
    let _ = state
      .persist()
      .send(PersistCommand::CodexPromptIncrement {
        id: session_id.clone(),
        first_prompt: None,
      })
      .await;
  }

  if let Some(ref model_name) = action_model {
    actor
      .send(SessionCommand::ProcessEvent {
        event: crate::domain::sessions::transition::Input::ModelUpdated(model_name.clone()),
      })
      .await;
  }

  if let Some(ref effort_name) = session_effort_update {
    actor
      .send(SessionCommand::ProcessEvent {
        event: crate::domain::sessions::transition::Input::EffortUpdated(Some(effort_name.clone())),
      })
      .await;
  } else if provider == orbitdock_protocol::Provider::Claude {
    if let Some(ref requested_effort) = requested_effort {
      debug!(
          component = "session",
          event = "session.message.effort_ignored_for_claude",
          session_id = %session_id,
          effort = %requested_effort,
          "Claude sessions do not support effort updates after create"
      );
    }
  }

  mark_session_working_after_send(state, &session_id).await;

  Ok(user_entry)
}

pub(crate) async fn dispatch_steer_turn(
  state: &Arc<SessionRegistry>,
  session_id: String,
  content: String,
  images: Vec<ImageInput>,
  mentions: Vec<MentionInput>,
  message_id: String,
) -> Result<orbitdock_protocol::conversation_contracts::ConversationRowEntry, DispatchMessageError>
{
  let codex_tx = state.get_codex_action_tx(&session_id);
  let claude_tx = state.get_claude_action_tx(&session_id);
  let Some(actor) = state.get_session(&session_id) else {
    return Err(DispatchMessageError::SessionNotFound);
  };

  if codex_tx.is_none() && claude_tx.is_none() {
    return Err(DispatchMessageError::ConnectorUnavailable);
  }

  let snapshot = actor.snapshot();
  if snapshot.status != SessionStatus::Active
    || snapshot.control_mode != SessionControlMode::Direct
    || snapshot.lifecycle_state != SessionLifecycleState::Open
    || snapshot.work_status != WorkStatus::Working
    || !snapshot.steerable
  {
    return Err(DispatchMessageError::NotSteerable);
  }

  let ts_millis = SystemTime::now()
    .duration_since(UNIX_EPOCH)
    .unwrap_or_default()
    .as_millis();
  let persisted_images =
    crate::infrastructure::images::materialize_images_for_message(&session_id, &images);
  let connector_images =
    crate::infrastructure::images::resolve_images_for_connector(&session_id, &persisted_images);
  let steer_entry = build_user_row_entry(
    &session_id,
    message_id.clone(),
    content.clone(),
    ts_millis,
    persisted_images.clone(),
    PromptRowKind::Steer,
    Some(MessageDeliveryStatus::Pending),
  );

  if let Err(error) = send_steer_turn_to_connector(
    state,
    &session_id,
    codex_tx,
    claude_tx,
    content,
    message_id,
    connector_images,
    mentions,
  )
  .await
  {
    return Err(error);
  }

  let (reply_tx, reply_rx) = oneshot::channel();
  actor
    .send(SessionCommand::AddRowAndBroadcastAndReply {
      entry: steer_entry.clone(),
      reply: reply_tx,
    })
    .await;
  let steer_entry = reply_rx
    .await
    .map_err(|_| DispatchMessageError::ConnectorUnavailable)?;

  Ok(steer_entry)
}

pub(crate) async fn dispatch_session_shell_command(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  command: String,
) -> Result<(), &'static str> {
  ensure_session_exists(state, session_id)?;

  if let Some(tx) = state.get_codex_action_tx(session_id) {
    tx.send(CodexAction::ShellCommand { command })
      .await
      .map_err(|_| {
        state.remove_codex_action_tx(session_id);
        "connector_unavailable"
      })
  } else if state.get_claude_action_tx(session_id).is_some() {
    Err("unsupported_session_shell")
  } else {
    Err("connector_unavailable")
  }
}

pub(crate) async fn dispatch_stop_active_turn(
  state: &Arc<SessionRegistry>,
  session_id: &str,
) -> Result<(), &'static str> {
  ensure_session_exists(state, session_id)?;

  if let Some(tx) = state.get_codex_action_tx(session_id) {
    tx.send(CodexAction::Interrupt).await.map_err(|_| {
      state.remove_codex_action_tx(session_id);
      "connector_unavailable"
    })
  } else if let Some(tx) = state.get_claude_action_tx(session_id) {
    tx.send(ClaudeAction::Interrupt).await.map_err(|_| {
      state.remove_claude_action_tx(session_id);
      "connector_unavailable"
    })
  } else {
    Err("connector_unavailable")
  }
}

pub(crate) async fn dispatch_interrupt(
  state: &Arc<SessionRegistry>,
  session_id: &str,
) -> Result<(), &'static str> {
  dispatch_stop_active_turn(state, session_id).await
}

pub(crate) async fn dispatch_compact_context(
  state: &Arc<SessionRegistry>,
  session_id: &str,
) -> Result<(), &'static str> {
  ensure_session_exists(state, session_id)?;

  if let Some(tx) = state.get_codex_action_tx(session_id) {
    let _ = tx.send(CodexAction::Compact).await;
    Ok(())
  } else if let Some(tx) = state.get_claude_action_tx(session_id) {
    let _ = tx.send(ClaudeAction::Compact).await;
    Ok(())
  } else {
    Err("connector_unavailable")
  }
}

pub(crate) async fn dispatch_compact(
  state: &Arc<SessionRegistry>,
  session_id: &str,
) -> Result<(), &'static str> {
  dispatch_compact_context(state, session_id).await
}

pub(crate) async fn dispatch_undo_last_turn(
  state: &Arc<SessionRegistry>,
  session_id: &str,
) -> Result<(), &'static str> {
  ensure_session_exists(state, session_id)?;

  if let Some(tx) = state.get_codex_action_tx(session_id) {
    let _ = tx.send(CodexAction::Undo).await;
    Ok(())
  } else if let Some(tx) = state.get_claude_action_tx(session_id) {
    let _ = tx.send(ClaudeAction::Undo).await;
    Ok(())
  } else {
    Err("connector_unavailable")
  }
}

pub(crate) async fn dispatch_undo(
  state: &Arc<SessionRegistry>,
  session_id: &str,
) -> Result<(), &'static str> {
  dispatch_undo_last_turn(state, session_id).await
}

pub(crate) async fn dispatch_rollback_turns(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  num_turns: u32,
) -> Result<(), &'static str> {
  ensure_session_exists(state, session_id)?;

  if let Some(tx) = state.get_codex_action_tx(session_id) {
    let _ = tx.send(CodexAction::ThreadRollback { num_turns }).await;
    Ok(())
  } else if let Some(tx) = state.get_claude_action_tx(session_id) {
    let actor = state.get_session(session_id).ok_or("session_not_found")?;
    match actor.resolve_user_message_id(num_turns).await {
      Ok(Some(user_message_id)) => {
        let _ = tx.send(ClaudeAction::RewindFiles { user_message_id }).await;
        Ok(())
      }
      Ok(None) => Err("rollback_failed"),
      Err(_) => Err("actor_closed"),
    }
  } else {
    Err("connector_unavailable")
  }
}

pub(crate) async fn dispatch_rollback(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  num_turns: u32,
) -> Result<(), &'static str> {
  dispatch_rollback_turns(state, session_id, num_turns).await
}

pub(crate) async fn dispatch_stop_target(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  task_id: String,
) -> Result<(), &'static str> {
  ensure_session_exists(state, session_id)?;

  if let Some(tx) = state.get_claude_action_tx(session_id) {
    let _ = tx.send(ClaudeAction::StopTask { task_id }).await;
    Ok(())
  } else if state.get_codex_action_tx(session_id).is_some() {
    Err("unsupported_control")
  } else {
    Err("connector_unavailable")
  }
}

pub(crate) async fn dispatch_stop_task(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  task_id: String,
) -> Result<(), &'static str> {
  dispatch_stop_target(state, session_id, task_id).await
}

pub(crate) async fn dispatch_rewind_to_message(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  user_message_id: String,
) -> Result<(), &'static str> {
  ensure_session_exists(state, session_id)?;

  if let Some(tx) = state.get_claude_action_tx(session_id) {
    let _ = tx.send(ClaudeAction::RewindFiles { user_message_id }).await;
    Ok(())
  } else if state.get_codex_action_tx(session_id).is_some() {
    Err("unsupported_control")
  } else {
    Err("connector_unavailable")
  }
}

pub(crate) async fn dispatch_rewind_files(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  user_message_id: String,
) -> Result<(), &'static str> {
  dispatch_rewind_to_message(state, session_id, user_message_id).await
}

pub(crate) async fn dispatch_answer_question(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  request_id: String,
  answer: String,
  question_id: Option<String>,
  answers: HashMap<String, Vec<String>>,
) -> Result<AnswerQuestionResult, &'static str> {
  let normalized_answers = build_question_answers(&answer, question_id.as_deref(), Some(answers));
  if normalized_answers.is_empty() {
    return Err("invalid_answer_payload");
  }

  let fallback_work_status = WorkStatus::Working;
  let mut next_pending_request_id: Option<String> = None;
  let mut approval_version: u64 = 0;
  if let Some(actor) = state.get_session(session_id) {
    let (reply_tx, reply_rx) = oneshot::channel();
    actor
      .send(SessionCommand::ResolvePendingApproval {
        request_id: request_id.clone(),
        fallback_work_status,
        reply: reply_tx,
      })
      .await;
    if let Ok(resolution) = reply_rx.await {
      let resolved = resolution.approval_type.is_some();
      next_pending_request_id = resolution.next_pending_approval.map(|a| a.id);
      approval_version = resolution.approval_version;

      if !resolved {
        return Ok(AnswerQuestionResult {
          outcome: "stale".to_string(),
          active_request_id: next_pending_request_id,
          approval_version,
        });
      }
    }
  } else {
    return Err("session_not_found");
  }

  let _ = state
    .persist()
    .send(PersistCommand::ApprovalDecision {
      session_id: session_id.to_string(),
      request_id: request_id.clone(),
      decision: "approved".to_string(),
    })
    .await;

  // Build the answer text for recording on the tool row
  let answer_text = if answer.is_empty() {
    normalized_answers
      .values()
      .flat_map(|v| v.iter())
      .cloned()
      .collect::<Vec<_>>()
      .join("\n")
  } else {
    answer.clone()
  };

  if let Some(tx) = state.get_codex_action_tx(session_id) {
    let _ = tx
      .send(CodexAction::AnswerQuestion {
        request_id,
        answers: normalized_answers,
      })
      .await;
  } else if let Some(tx) = state.get_claude_action_tx(session_id) {
    let _ = tx
      .send(ClaudeAction::AnswerQuestion {
        request_id,
        answers: normalized_answers,
      })
      .await;
  } else {
    return Err("connector_unavailable");
  }

  // Record the answer on the question tool row so the UI shows
  // the response instead of "Pending" / "No response recorded".
  if let Some(actor) = state.get_session(session_id) {
    if !answer_text.is_empty() {
      actor
        .send(SessionCommand::RecordQuestionAnswer { answer_text })
        .await;
    }
  }

  Ok(AnswerQuestionResult {
    outcome: "applied".to_string(),
    active_request_id: next_pending_request_id,
    approval_version,
  })
}

pub(crate) async fn dispatch_request_permissions_response(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  request_id: String,
  permissions: Option<serde_json::Value>,
  scope: Option<PermissionGrantScope>,
) -> Result<AnswerQuestionResult, &'static str> {
  let normalized_permissions = normalize_permission_response(permissions)?;
  let scope = scope.unwrap_or(PermissionGrantScope::Turn);
  let fallback_work_status = WorkStatus::Working;
  let mut next_pending_request_id: Option<String> = None;
  let mut approval_version: u64 = 0;

  if let Some(actor) = state.get_session(session_id) {
    let (reply_tx, reply_rx) = oneshot::channel();
    actor
      .send(SessionCommand::ResolvePendingApproval {
        request_id: request_id.clone(),
        fallback_work_status,
        reply: reply_tx,
      })
      .await;
    if let Ok(resolution) = reply_rx.await {
      let resolved = resolution.approval_type.is_some();
      next_pending_request_id = resolution.next_pending_approval.map(|a| a.id);
      approval_version = resolution.approval_version;

      if !resolved {
        return Ok(AnswerQuestionResult {
          outcome: "stale".to_string(),
          active_request_id: next_pending_request_id,
          approval_version,
        });
      }
    }
  } else {
    return Err("session_not_found");
  }

  let decision = if normalized_permissions
    .as_object()
    .is_some_and(|map| map.is_empty())
  {
    "denied".to_string()
  } else if scope == PermissionGrantScope::Session {
    "approved_for_session".to_string()
  } else {
    "approved".to_string()
  };

  let _ = state
    .persist()
    .send(PersistCommand::ApprovalDecision {
      session_id: session_id.to_string(),
      request_id: request_id.clone(),
      decision,
    })
    .await;

  if let Some(tx) = state.get_codex_action_tx(session_id) {
    let _ = tx
      .send(CodexAction::RequestPermissionsResponse {
        request_id,
        permissions: normalized_permissions,
        scope,
      })
      .await;
  } else {
    return Err("connector_unavailable");
  }

  Ok(AnswerQuestionResult {
    outcome: "applied".to_string(),
    active_request_id: next_pending_request_id,
    approval_version,
  })
}

#[cfg(test)]
#[path = "message_dispatch_tests.rs"]
mod message_dispatch_tests;
