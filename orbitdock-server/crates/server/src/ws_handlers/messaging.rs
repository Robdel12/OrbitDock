use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::sync::{mpsc, oneshot};
use tracing::{info, warn};

use orbitdock_protocol::{ClientMessage, ServerMessage, WorkStatus};

use crate::claude_session::ClaudeAction;
use crate::codex_session::CodexAction;
use crate::persistence::PersistCommand;
use crate::session_command::SessionCommand;
use crate::session_naming::name_from_first_prompt;
use crate::state::SessionRegistry;
use crate::websocket::{
    iso_timestamp, mark_session_working_after_send, normalize_model_override, normalize_non_empty,
    normalize_question_answers, select_primary_answer, send_json, OutboundMessage,
};

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

            // Try Codex action channel first, then Claude
            let codex_tx = state.get_codex_action_tx(&session_id);
            let claude_tx = state.get_claude_action_tx(&session_id);

            if codex_tx.is_some() || claude_tx.is_some() {
                let first_prompt = name_from_first_prompt(&content);

                let _ = state
                    .persist()
                    .send(PersistCommand::CodexPromptIncrement {
                        id: session_id.clone(),
                        first_prompt: first_prompt.clone(),
                    })
                    .await;

                // Broadcast first_prompt delta and trigger AI naming
                if let Some(prompt) = first_prompt {
                    if let Some(actor) = state.get_session(&session_id) {
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

                        // Trigger AI naming (fire-and-forget, deduped)
                        if state.naming_guard().try_claim(&session_id) {
                            crate::ai_naming::spawn_naming_task(
                                session_id.clone(),
                                prompt,
                                actor,
                                state.persist().clone(),
                                state.list_tx(),
                            );
                        }
                    }
                }

                let action_model = normalize_model_override(model.clone());
                let action_effort = normalize_non_empty(effort.clone());

                // Persist model override and broadcast delta only when explicitly provided.
                if let Some(actor) = state.get_session(&session_id) {
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
                }

                // Persist effort override and broadcast delta only when explicitly provided.
                if let Some(actor) = state.get_session(&session_id) {
                    if let Some(ref effort_name) = action_effort {
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

                // Persist user message immediately
                let ts_millis = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis();
                let msg_id = format!("user-ws-{}-{}", ts_millis, conn_id);
                // Keep client message payload portable; only connector dispatch needs path images.
                let connector_images =
                    crate::images::extract_images_to_disk(&images, &session_id, &msg_id);
                let user_msg = orbitdock_protocol::Message {
                    id: msg_id,
                    session_id: session_id.clone(),
                    message_type: orbitdock_protocol::MessageType::User,
                    content: content.clone(),
                    tool_name: None,
                    tool_input: None,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: false,
                    timestamp: iso_timestamp(ts_millis),
                    duration_ms: None,
                    images: images.clone(),
                };

                if let Some(actor) = state.get_session(&session_id) {
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
                }

                if let Some(tx) = codex_tx {
                    if tx
                        .send(CodexAction::SendMessage {
                            content,
                            model: action_model,
                            effort: action_effort,
                            skills,
                            images: connector_images.clone(),
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
                            connection_id = conn_id,
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
                            effort: action_effort,
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
                            connection_id = conn_id,
                            session_id = %session_id,
                            provider = "claude",
                            "Claude action channel closed while sending message"
                        );
                    }
                }
            } else {
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

            // Try Codex action channel first, then Claude
            let codex_tx = state.get_codex_action_tx(&session_id);
            let claude_tx = state.get_claude_action_tx(&session_id);

            if codex_tx.is_some() || claude_tx.is_some() {
                // Persist steer message so it appears in conversation
                let ts_millis = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis();
                let steer_msg_id = format!("steer-ws-{}-{}", ts_millis, conn_id);
                let connector_images =
                    crate::images::extract_images_to_disk(&images, &session_id, &steer_msg_id);
                let steer_msg = orbitdock_protocol::Message {
                    id: steer_msg_id.clone(),
                    session_id: session_id.clone(),
                    message_type: orbitdock_protocol::MessageType::Steer,
                    content: content.clone(),
                    tool_name: None,
                    tool_input: None,
                    tool_output: None,
                    is_error: false,
                    is_in_progress: false,
                    timestamp: iso_timestamp(ts_millis),
                    duration_ms: None,
                    images: images.clone(),
                };

                if let Some(actor) = state.get_session(&session_id) {
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
                }

                if let Some(tx) = codex_tx {
                    let _ = tx
                        .send(CodexAction::SteerTurn {
                            content,
                            message_id: steer_msg_id,
                            images: connector_images.clone(),
                            mentions,
                        })
                        .await;
                } else if let Some(tx) = claude_tx {
                    let _ = tx
                        .send(ClaudeAction::SteerTurn {
                            content,
                            message_id: steer_msg_id,
                            images: connector_images,
                        })
                        .await;
                }
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
                let claude_answer = if trimmed_answer.is_empty() {
                    select_primary_answer(&normalized_answers, question_id.as_deref())
                        .unwrap_or_default()
                } else {
                    trimmed_answer
                };
                if claude_answer.is_empty() {
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
                        answer: claude_answer,
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
            }
        }

        _ => {}
    }
}
