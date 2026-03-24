use std::collections::HashMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::sync::oneshot;
use tracing::{debug, warn};

use orbitdock_protocol::conversation_contracts::rows::MessageDeliveryStatus;
use orbitdock_protocol::PermissionGrantScope;
use orbitdock_protocol::{ImageInput, MentionInput, SkillInput, WorkStatus};

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

pub(crate) enum DispatchMessageError {
    NotFound,
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
        return Err(DispatchMessageError::NotFound);
    };

    if codex_tx.is_none() && claude_tx.is_none() {
        return Err(DispatchMessageError::NotFound);
    }

    let provider = actor.snapshot().provider;
    let requested_effort = normalize_non_empty(effort.clone());
    let plan = plan_send_message(provider, &content, model, effort);

    let _ = state
        .persist()
        .send(PersistCommand::CodexPromptIncrement {
            id: session_id.clone(),
            first_prompt: plan.first_prompt.clone(),
        })
        .await;

    if let Some(prompt) = plan.first_prompt {
        let changes = orbitdock_protocol::StateChanges {
            first_prompt: Some(Some(prompt.clone())),
            ..Default::default()
        };
        let _ = actor
            .send(SessionCommand::ApplyDelta {
                changes: Box::new(changes),
                persist_op: None,
            })
            .await;

        if state.naming_guard().try_claim(&session_id) {
            crate::support::ai_naming::spawn_naming_task(
                session_id.clone(),
                prompt,
                actor.clone(),
                state.persist().clone(),
                state.list_tx(),
            );
        }
    }

    if let Some(ref model_name) = plan.action_model {
        let _ = state
            .persist()
            .send(PersistCommand::ModelUpdate {
                session_id: session_id.clone(),
                model: model_name.clone(),
            })
            .await;
        let changes = orbitdock_protocol::StateChanges {
            model: Some(Some(model_name.clone())),
            ..Default::default()
        };
        let _ = actor
            .send(SessionCommand::ApplyDelta {
                changes: Box::new(changes),
                persist_op: None,
            })
            .await;
    }

    if let Some(ref effort_name) = plan.session_effort_update {
        let _ = state
            .persist()
            .send(PersistCommand::EffortUpdate {
                session_id: session_id.clone(),
                effort: Some(effort_name.clone()),
            })
            .await;
        let changes = orbitdock_protocol::StateChanges {
            effort: Some(Some(effort_name.clone())),
            ..Default::default()
        };
        let _ = actor
            .send(SessionCommand::ApplyDelta {
                changes: Box::new(changes),
                persist_op: None,
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

    let ts_millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let persisted_images =
        crate::infrastructure::images::materialize_images_for_message(&session_id, &images);
    let connector_images =
        crate::infrastructure::images::resolve_images_for_connector(&session_id, &persisted_images);
    let user_entry = build_user_row_entry(
        &session_id,
        message_id,
        content.clone(),
        ts_millis,
        persisted_images.clone(),
        PromptRowKind::User,
        Some(MessageDeliveryStatus::Accepted),
    );

    actor
        .send(SessionCommand::AddRowAndBroadcast {
            entry: user_entry.clone(),
        })
        .await;

    if let Some(tx) = codex_tx {
        if tx
            .send(CodexAction::SendMessage {
                content,
                model: plan.action_model,
                effort: plan.connector_effort,
                skills,
                images: connector_images,
                mentions,
            })
            .await
            .is_ok()
        {
            mark_session_working_after_send(state, &session_id).await;
        } else {
            warn!(
                component = "session",
                event = "session.message.action_channel_closed",
                session_id = %session_id,
                provider = "codex",
                "Codex action channel closed while sending message"
            );
        }
    } else if let Some(tx) = claude_tx {
        if tx
            .send(ClaudeAction::SendMessage {
                content,
                model: plan.action_model,
                effort: plan.connector_effort,
                images: connector_images,
            })
            .await
            .is_ok()
        {
            mark_session_working_after_send(state, &session_id).await;
        } else {
            warn!(
                component = "session",
                event = "session.message.action_channel_closed",
                session_id = %session_id,
                provider = "claude",
                "Claude action channel closed while sending message"
            );
        }
    }

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
        return Err(DispatchMessageError::NotFound);
    };

    if codex_tx.is_none() && claude_tx.is_none() {
        return Err(DispatchMessageError::NotFound);
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

    actor
        .send(SessionCommand::AddRowAndBroadcast {
            entry: steer_entry.clone(),
        })
        .await;

    if let Some(tx) = codex_tx {
        let _ = tx
            .send(CodexAction::SteerTurn {
                content,
                message_id,
                images: connector_images,
                mentions,
            })
            .await;
    } else if let Some(tx) = claude_tx {
        let _ = tx
            .send(ClaudeAction::SteerTurn {
                content,
                message_id,
                images: connector_images,
            })
            .await;
    }

    Ok(steer_entry)
}

pub(crate) async fn dispatch_interrupt(
    state: &Arc<SessionRegistry>,
    session_id: &str,
) -> Result<(), &'static str> {
    if let Some(tx) = state.get_codex_action_tx(session_id) {
        tx.send(CodexAction::Interrupt).await.map_err(|_| {
            state.remove_codex_action_tx(session_id);
            "interrupt_failed"
        })
    } else if let Some(tx) = state.get_claude_action_tx(session_id) {
        tx.send(ClaudeAction::Interrupt).await.map_err(|_| {
            state.remove_claude_action_tx(session_id);
            "interrupt_failed"
        })
    } else {
        Err("not_found")
    }
}

pub(crate) async fn dispatch_compact(
    state: &Arc<SessionRegistry>,
    session_id: &str,
) -> Result<(), &'static str> {
    if let Some(tx) = state.get_codex_action_tx(session_id) {
        let _ = tx.send(CodexAction::Compact).await;
        Ok(())
    } else if let Some(tx) = state.get_claude_action_tx(session_id) {
        let _ = tx.send(ClaudeAction::Compact).await;
        Ok(())
    } else {
        Err("not_found")
    }
}

pub(crate) async fn dispatch_undo(
    state: &Arc<SessionRegistry>,
    session_id: &str,
) -> Result<(), &'static str> {
    if let Some(tx) = state.get_codex_action_tx(session_id) {
        let _ = tx.send(CodexAction::Undo).await;
        Ok(())
    } else if let Some(tx) = state.get_claude_action_tx(session_id) {
        let _ = tx.send(ClaudeAction::Undo).await;
        Ok(())
    } else {
        Err("not_found")
    }
}

pub(crate) async fn dispatch_rollback(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    num_turns: u32,
) -> Result<(), &'static str> {
    if let Some(tx) = state.get_codex_action_tx(session_id) {
        let _ = tx.send(CodexAction::ThreadRollback { num_turns }).await;
        Ok(())
    } else if let Some(tx) = state.get_claude_action_tx(session_id) {
        let actor = state.get_session(session_id).ok_or("not_found")?;
        match actor.resolve_user_message_id(num_turns).await {
            Ok(Some(user_message_id)) => {
                let _ = tx.send(ClaudeAction::RewindFiles { user_message_id }).await;
                Ok(())
            }
            Ok(None) => Err("rollback_failed"),
            Err(_) => Err("actor_closed"),
        }
    } else {
        Err("not_found")
    }
}

pub(crate) async fn dispatch_stop_task(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    task_id: String,
) -> Result<(), &'static str> {
    if let Some(tx) = state.get_claude_action_tx(session_id) {
        let _ = tx.send(ClaudeAction::StopTask { task_id }).await;
        Ok(())
    } else {
        Err("not_found")
    }
}

pub(crate) async fn dispatch_rewind_files(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    user_message_id: String,
) -> Result<(), &'static str> {
    if let Some(tx) = state.get_claude_action_tx(session_id) {
        let _ = tx.send(ClaudeAction::RewindFiles { user_message_id }).await;
        Ok(())
    } else {
        Err("not_found")
    }
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
    let mut resolved_work_status = fallback_work_status;
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
            resolved_work_status = resolution.work_status;
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
        return Err("not_found");
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

    let _ = state
        .persist()
        .send(PersistCommand::SessionUpdate {
            id: session_id.to_string(),
            status: None,
            work_status: Some(resolved_work_status),
            last_activity_at: None,
            last_progress_at: None,
        })
        .await;

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
    let mut resolved_work_status = fallback_work_status;
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
            resolved_work_status = resolution.work_status;
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
        return Err("not_found");
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
        return Err("not_found");
    }

    let _ = state
        .persist()
        .send(PersistCommand::SessionUpdate {
            id: session_id.to_string(),
            status: None,
            work_status: Some(resolved_work_status),
            last_activity_at: None,
            last_progress_at: None,
        })
        .await;

    Ok(AnswerQuestionResult {
        outcome: "applied".to_string(),
        active_request_id: next_pending_request_id,
        approval_version,
    })
}
