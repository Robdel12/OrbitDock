use std::collections::HashMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::sync::{mpsc, oneshot};
use tracing::{debug, info, warn};

use orbitdock_protocol::{
    ClientMessage, ImageInput, MentionInput, ServerMessage, SkillInput, WorkStatus,
};

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;
use crate::domain::sessions::session_naming::name_from_first_prompt;
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_runtime_helpers::mark_session_working_after_send;
use crate::support::normalization::{
    normalize_model_override, normalize_non_empty, normalize_question_answers,
};
use crate::support::session_time::iso_timestamp;
use crate::transport::websocket::{send_json, OutboundMessage};

pub(crate) enum DispatchMessageError {
    NotFound,
}

pub(crate) async fn dispatch_send_message(
    state: &Arc<SessionRegistry>,
    session_id: String,
    content: String,
    model: Option<String>,
    effort: Option<String>,
    skills: Vec<SkillInput>,
    images: Vec<ImageInput>,
    mentions: Vec<MentionInput>,
    message_id: String,
) -> Result<(), DispatchMessageError> {
    let codex_tx = state.get_codex_action_tx(&session_id);
    let claude_tx = state.get_claude_action_tx(&session_id);
    let Some(actor) = state.get_session(&session_id) else {
        return Err(DispatchMessageError::NotFound);
    };

    if codex_tx.is_none() && claude_tx.is_none() {
        return Err(DispatchMessageError::NotFound);
    }

    let session_is_claude = actor.snapshot().provider == orbitdock_protocol::Provider::Claude;
    let first_prompt = name_from_first_prompt(&content);

    let _ = state
        .persist()
        .send(PersistCommand::CodexPromptIncrement {
            id: session_id.clone(),
            first_prompt: first_prompt.clone(),
        })
        .await;

    if let Some(prompt) = first_prompt {
        let changes = orbitdock_protocol::StateChanges {
            first_prompt: Some(Some(prompt.clone())),
            ..Default::default()
        };
        let _ = actor
            .send(SessionCommand::ApplyDelta {
                changes,
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

    let action_model = normalize_model_override(model.clone());
    let action_effort = normalize_non_empty(effort.clone());
    let action_effort_for_connector = if session_is_claude {
        None
    } else {
        action_effort.clone()
    };

    if let Some(ref model_name) = action_model {
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
                changes,
                persist_op: None,
            })
            .await;
    }

    if let Some(ref effort_name) = action_effort {
        if session_is_claude {
            debug!(
                component = "session",
                event = "session.message.effort_ignored_for_claude",
                session_id = %session_id,
                effort = %effort_name,
                "Claude sessions do not support effort updates after create"
            );
        } else {
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
                    changes,
                    persist_op: None,
                })
                .await;
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
    let user_msg = orbitdock_protocol::Message {
        id: message_id,
        session_id: session_id.clone(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::User,
        content: content.clone(),
        tool_name: None,
        tool_input: None,
        tool_output: None,
        is_error: false,
        is_in_progress: false,
        timestamp: iso_timestamp(ts_millis),
        duration_ms: None,
        images: persisted_images.clone(),
    };

    let _ = state
        .persist()
        .send(PersistCommand::MessageAppend {
            session_id: session_id.clone(),
            message: user_msg.clone(),
        })
        .await;
    actor
        .send(SessionCommand::AddMessageAndBroadcast { message: user_msg })
        .await;

    if let Some(tx) = codex_tx {
        if tx
            .send(CodexAction::SendMessage {
                content,
                model: action_model,
                effort: action_effort_for_connector,
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
                model: action_model,
                effort: action_effort_for_connector,
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

    Ok(())
}

pub(crate) async fn dispatch_steer_turn(
    state: &Arc<SessionRegistry>,
    session_id: String,
    content: String,
    images: Vec<ImageInput>,
    mentions: Vec<MentionInput>,
    message_id: String,
) -> Result<(), DispatchMessageError> {
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
    let steer_msg = orbitdock_protocol::Message {
        id: message_id.clone(),
        session_id: session_id.clone(),
        sequence: None,
        message_type: orbitdock_protocol::MessageType::Steer,
        content: content.clone(),
        tool_name: None,
        tool_input: None,
        tool_output: None,
        is_error: false,
        is_in_progress: false,
        timestamp: iso_timestamp(ts_millis),
        duration_ms: None,
        images: persisted_images.clone(),
    };

    let _ = state
        .persist()
        .send(PersistCommand::MessageAppend {
            session_id: session_id.clone(),
            message: steer_msg.clone(),
        })
        .await;
    actor
        .send(SessionCommand::AddMessageAndBroadcast { message: steer_msg })
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

    Ok(())
}

/// Dispatch an interrupt to the active connector for a session.
/// Returns Ok(()) on success, Err with an error code on failure.
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

/// Dispatch compact context to the active connector.
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

/// Dispatch undo last turn to the active connector.
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

/// Dispatch rollback N turns to the active connector.
/// For Claude sessions, resolves the Nth user message from the end.
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

/// Dispatch stop task to the active Claude connector.
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

/// Dispatch rewind files to the active Claude connector.
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

/// Dispatch an answer to a question approval.
pub(crate) async fn dispatch_answer_question(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    request_id: String,
    answer: String,
    question_id: Option<String>,
    answers: HashMap<String, Vec<String>>,
) -> Result<AnswerQuestionResult, &'static str> {
    let mut normalized_answers = normalize_question_answers(Some(answers));
    let trimmed_answer = answer.trim().to_string();
    if normalized_answers.is_empty() && !trimmed_answer.is_empty() {
        let key = question_id.clone().unwrap_or_else(|| "0".to_string());
        normalized_answers.insert(key, vec![trimmed_answer.clone()]);
    }
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

    if let Some(tx) = state.get_codex_action_tx(session_id) {
        let _ = tx
            .send(CodexAction::AnswerQuestion {
                request_id,
                answers: normalized_answers,
            })
            .await;
    } else if let Some(tx) = state.get_claude_action_tx(session_id) {
        let mut claude_answers = normalized_answers;
        if claude_answers.is_empty() && !trimmed_answer.is_empty() {
            let key = question_id.unwrap_or_else(|| "0".to_string());
            claude_answers.insert(key, vec![trimmed_answer]);
        }
        let _ = tx
            .send(ClaudeAction::AnswerQuestion {
                request_id,
                answers: claude_answers,
            })
            .await;
    }

    let _ = state
        .persist()
        .send(PersistCommand::SessionUpdate {
            id: session_id.to_string(),
            status: None,
            work_status: Some(resolved_work_status),
            last_activity_at: None,
        })
        .await;

    Ok(AnswerQuestionResult {
        outcome: "applied".to_string(),
        active_request_id: next_pending_request_id,
        approval_version,
    })
}

pub(crate) struct AnswerQuestionResult {
    pub outcome: String,
    pub active_request_id: Option<String>,
    pub approval_version: u64,
}

pub(crate) async fn handle(
    msg: ClientMessage,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<SessionRegistry>,
    conn_id: u64,
) {
    match msg {
        ClientMessage::SendMessage {
            session_id,
            content,
            model,
            effort,
            skills,
            images,
            mentions,
        } => {
            info!(
                component = "session",
                event = "session.message.send_requested",
                connection_id = conn_id,
                session_id = %session_id,
                content_chars = content.chars().count(),
                model = ?model,
                effort = ?effort,
                skills_count = skills.len(),
                images_count = images.len(),
                mentions_count = mentions.len(),
                "Sending message to session"
            );
            let ts_millis = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis();
            let message_id = format!("user-ws-{}-{}", ts_millis, conn_id);

            if dispatch_send_message(
                state,
                session_id.clone(),
                content,
                model,
                effort,
                skills,
                images,
                mentions,
                message_id,
            )
            .await
            .is_err()
            {
                warn!(
                    component = "session",
                    event = "session.message.missing_action_channel",
                    connection_id = conn_id,
                    session_id = %session_id,
                    "No action channel for session"
                );
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "not_found".into(),
                        message: format!(
                            "Session {} not found or has no active connector",
                            session_id
                        ),
                        session_id: Some(session_id),
                    },
                )
                .await;
            }
        }

        ClientMessage::SteerTurn {
            session_id,
            content,
            images,
            mentions,
        } => {
            info!(
                component = "session",
                event = "session.steer.requested",
                connection_id = conn_id,
                session_id = %session_id,
                content_chars = content.chars().count(),
                images_count = images.len(),
                mentions_count = mentions.len(),
                "Steering active turn"
            );
            let ts_millis = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis();
            let message_id = format!("steer-ws-{}-{}", ts_millis, conn_id);

            if dispatch_steer_turn(
                state,
                session_id.clone(),
                content,
                images,
                mentions,
                message_id,
            )
            .await
            .is_err()
            {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "not_found".into(),
                        message: format!(
                            "Session {} not found or has no active connector",
                            session_id
                        ),
                        session_id: Some(session_id),
                    },
                )
                .await;
            }
        }

        ClientMessage::AnswerQuestion {
            session_id,
            request_id,
            answer,
            question_id,
            answers,
        } => {
            let mut normalized_answers = normalize_question_answers(answers);
            let trimmed_answer = answer.trim().to_string();
            if normalized_answers.is_empty() && !trimmed_answer.is_empty() {
                let key = question_id.clone().unwrap_or_else(|| "0".to_string());
                normalized_answers.insert(key, vec![trimmed_answer.clone()]);
            }

            info!(
                component = "approval",
                event = "approval.answer.submitted",
                connection_id = conn_id,
                session_id = %session_id,
                request_id = %request_id,
                answer_chars = trimmed_answer.chars().count(),
                answer_questions = normalized_answers.len(),
                "Answer submitted for question approval"
            );
            if normalized_answers.is_empty() {
                warn!(
                    component = "approval",
                    event = "approval.answer.missing_payload",
                    connection_id = conn_id,
                    session_id = %session_id,
                    request_id = %request_id,
                    "Question answer request had no usable answer payload"
                );
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "invalid_answer_payload".into(),
                        message: "Question approvals require a non-empty answer or answers map"
                            .into(),
                        session_id: Some(session_id),
                    },
                )
                .await;
                return;
            }

            let fallback_work_status = WorkStatus::Working;
            let mut resolved_work_status = fallback_work_status;
            let mut resolved = false;
            let mut next_pending_request_id: Option<String> = None;
            let mut approval_version: u64 = 0;
            if let Some(actor) = state.get_session(&session_id) {
                let (reply_tx, reply_rx) = oneshot::channel();
                actor
                    .send(SessionCommand::ResolvePendingApproval {
                        request_id: request_id.clone(),
                        fallback_work_status,
                        reply: reply_tx,
                    })
                    .await;
                if let Ok(resolution) = reply_rx.await {
                    resolved = resolution.approval_type.is_some();
                    resolved_work_status = resolution.work_status;
                    next_pending_request_id = resolution.next_pending_approval.map(|a| a.id);
                    approval_version = resolution.approval_version;
                }
            }

            if state.get_session(&session_id).is_some() && !resolved {
                send_json(
                    client_tx,
                    ServerMessage::ApprovalDecisionResult {
                        session_id: session_id.clone(),
                        request_id: request_id.clone(),
                        outcome: "stale".to_string(),
                        active_request_id: next_pending_request_id.clone(),
                        approval_version,
                    },
                )
                .await;
                return;
            }

            let request_id_for_result = request_id.clone();

            let _ = state
                .persist()
                .send(PersistCommand::ApprovalDecision {
                    session_id: session_id.clone(),
                    request_id: request_id.clone(),
                    decision: "approved".to_string(),
                })
                .await;

            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx
                    .send(CodexAction::AnswerQuestion {
                        request_id: request_id.clone(),
                        answers: normalized_answers,
                    })
                    .await;
            } else if let Some(tx) = state.get_claude_action_tx(&session_id) {
                // If the client sent a plain text answer, normalize it into the
                // answers map so the connector always gets structured data.
                let mut claude_answers = normalized_answers.clone();
                if claude_answers.is_empty() && !trimmed_answer.is_empty() {
                    let key = question_id.clone().unwrap_or_else(|| "0".to_string());
                    claude_answers.insert(key, vec![trimmed_answer]);
                }
                if claude_answers.is_empty() {
                    warn!(
                        component = "approval",
                        event = "approval.answer.missing_payload",
                        connection_id = conn_id,
                        session_id = %session_id,
                        request_id = %request_id,
                        "Question answer request had no usable answer payload"
                    );
                    return;
                }
                let _ = tx
                    .send(ClaudeAction::AnswerQuestion {
                        request_id,
                        answers: claude_answers,
                    })
                    .await;
            }

            let _ = state
                .persist()
                .send(PersistCommand::SessionUpdate {
                    id: session_id.clone(),
                    status: None,
                    work_status: Some(resolved_work_status),
                    last_activity_at: None,
                })
                .await;

            send_json(
                client_tx,
                ServerMessage::ApprovalDecisionResult {
                    session_id: session_id.clone(),
                    request_id: request_id_for_result,
                    outcome: "applied".to_string(),
                    active_request_id: next_pending_request_id.clone(),
                    approval_version,
                },
            )
            .await;

            if let Some(next_pending_request_id) = next_pending_request_id {
                info!(
                    component = "approval",
                    event = "approval.queue.promoted",
                    session_id = %session_id,
                    next_request_id = %next_pending_request_id,
                    "Promoted next queued approval"
                );
            }
        }

        ClientMessage::InterruptSession { session_id } => {
            info!(
                component = "session",
                event = "session.interrupt.requested",
                connection_id = conn_id,
                session_id = %session_id,
                "Interrupt session requested"
            );

            let send_result = if let Some(tx) = state.get_codex_action_tx(&session_id) {
                tx.send(CodexAction::Interrupt).await.map_err(|_| "codex")
            } else if let Some(tx) = state.get_claude_action_tx(&session_id) {
                tx.send(ClaudeAction::Interrupt).await.map_err(|_| "claude")
            } else {
                Err("none")
            };

            match send_result {
                Ok(()) => {
                    info!(
                        component = "session",
                        event = "session.interrupt.dispatched",
                        session_id = %session_id,
                        "Interrupt dispatched to connector"
                    );
                }
                Err(provider) => {
                    warn!(
                        component = "session",
                        event = "session.interrupt.failed",
                        session_id = %session_id,
                        provider = %provider,
                        "Interrupt failed — no active action channel"
                    );
                    // Clean up stale channels
                    if provider == "codex" {
                        state.remove_codex_action_tx(&session_id);
                    } else if provider == "claude" {
                        state.remove_claude_action_tx(&session_id);
                    }
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "interrupt_failed".into(),
                            message: format!(
                                "Could not interrupt session {}: connector not reachable",
                                session_id
                            ),
                            session_id: Some(session_id.clone()),
                        },
                    )
                    .await;
                }
            }
        }

        ClientMessage::CompactContext { session_id } => {
            info!(
                component = "session",
                event = "session.compact.requested",
                connection_id = conn_id,
                session_id = %session_id,
                "Compact context requested"
            );

            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx.send(CodexAction::Compact).await;
            } else if let Some(tx) = state.get_claude_action_tx(&session_id) {
                let _ = tx.send(ClaudeAction::Compact).await;
            }
        }

        ClientMessage::UndoLastTurn { session_id } => {
            info!(
                component = "session",
                event = "session.undo.requested",
                connection_id = conn_id,
                session_id = %session_id,
                "Undo last turn requested"
            );

            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx.send(CodexAction::Undo).await;
            } else if let Some(tx) = state.get_claude_action_tx(&session_id) {
                let _ = tx.send(ClaudeAction::Undo).await;
            }
        }

        ClientMessage::RollbackTurns {
            session_id,
            num_turns,
        } => {
            if num_turns < 1 {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "invalid_argument".into(),
                        message: "num_turns must be >= 1".into(),
                        session_id: Some(session_id),
                    },
                )
                .await;
                return;
            }

            info!(
                component = "session",
                event = "session.rollback.requested",
                connection_id = conn_id,
                session_id = %session_id,
                num_turns = num_turns,
                "Rollback turns requested"
            );

            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx.send(CodexAction::ThreadRollback { num_turns }).await;
            } else if let Some(tx) = state.get_claude_action_tx(&session_id) {
                // Claude uses rewind_files which needs a user_message_id.
                // Resolve the Nth user message from the end via session actor.
                if let Some(actor) = state.get_session(&session_id) {
                    match actor.resolve_user_message_id(num_turns).await {
                        Ok(Some(user_message_id)) => {
                            let _ = tx.send(ClaudeAction::RewindFiles { user_message_id }).await;
                        }
                        Ok(None) => {
                            warn!(
                                component = "session",
                                event = "session.rollback.no_user_message",
                                session_id = %session_id,
                                num_turns = num_turns,
                                "Could not resolve user message for rollback"
                            );
                            send_json(
                                client_tx,
                                ServerMessage::Error {
                                    code: "rollback_failed".into(),
                                    message: format!(
                                        "Could not find user message {} turns back",
                                        num_turns
                                    ),
                                    session_id: Some(session_id),
                                },
                            )
                            .await;
                        }
                        Err(_) => {
                            warn!(
                                component = "session",
                                event = "session.rollback.actor_closed",
                                session_id = %session_id,
                                "Session actor closed during rollback resolution"
                            );
                        }
                    }
                }
            }
        }

        ClientMessage::StopTask {
            session_id,
            task_id,
        } => {
            info!(
                component = "session",
                event = "session.stop_task.requested",
                connection_id = conn_id,
                session_id = %session_id,
                task_id = %task_id,
                "Stop task requested"
            );

            if let Some(tx) = state.get_claude_action_tx(&session_id) {
                let _ = tx.send(ClaudeAction::StopTask { task_id }).await;
            } else {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "not_found".into(),
                        message: format!(
                            "Session {} not found or has no active connector",
                            session_id
                        ),
                        session_id: Some(session_id),
                    },
                )
                .await;
            }
        }

        ClientMessage::RewindFiles {
            session_id,
            user_message_id,
        } => {
            info!(
                component = "session",
                event = "session.rewind.requested",
                connection_id = conn_id,
                session_id = %session_id,
                user_message_id = %user_message_id,
                "Rewind files requested"
            );

            if let Some(tx) = state.get_claude_action_tx(&session_id) {
                let _ = tx.send(ClaudeAction::RewindFiles { user_message_id }).await;
            } else {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "not_found".into(),
                        message: format!(
                            "Session {} not found or has no active connector",
                            session_id
                        ),
                        session_id: Some(session_id),
                    },
                )
                .await;
            }
        }

        _ => {}
    }
}
