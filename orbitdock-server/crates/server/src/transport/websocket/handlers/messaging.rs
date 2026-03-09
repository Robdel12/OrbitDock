use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::sync::mpsc;
use tracing::{info, warn};

use orbitdock_protocol::{ClientMessage, ServerMessage};

use crate::runtime::message_dispatch::{
    dispatch_answer_question, dispatch_compact, dispatch_interrupt, dispatch_rewind_files,
    dispatch_rollback, dispatch_send_message, dispatch_steer_turn, dispatch_stop_task,
    dispatch_undo,
};
use crate::runtime::session_registry::SessionRegistry;
use crate::support::normalization::build_question_answers;
use crate::transport::websocket::{send_json, OutboundMessage};

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
                send_not_found(client_tx, &session_id).await;
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
                send_not_found(client_tx, &session_id).await;
            }
        }

        ClientMessage::AnswerQuestion {
            session_id,
            request_id,
            answer,
            question_id,
            answers,
        } => {
            let normalized_answers =
                build_question_answers(&answer, question_id.as_deref(), answers.clone());

            info!(
                component = "approval",
                event = "approval.answer.submitted",
                connection_id = conn_id,
                session_id = %session_id,
                request_id = %request_id,
                answer_chars = answer.trim().chars().count(),
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
                send_invalid_answer_payload(client_tx, &session_id).await;
                return;
            }

            let result = match dispatch_answer_question(
                state,
                &session_id,
                request_id.clone(),
                answer,
                question_id,
                answers.unwrap_or_default(),
            )
            .await
            {
                Ok(result) => result,
                Err("invalid_answer_payload") => {
                    send_invalid_answer_payload(client_tx, &session_id).await;
                    return;
                }
                Err(_) => {
                    send_not_found(client_tx, &session_id).await;
                    return;
                }
            };

            send_json(
                client_tx,
                ServerMessage::ApprovalDecisionResult {
                    session_id: session_id.clone(),
                    request_id: request_id.clone(),
                    outcome: result.outcome,
                    active_request_id: result.active_request_id.clone(),
                    approval_version: result.approval_version,
                },
            )
            .await;

            if let Some(next_pending_request_id) = result.active_request_id {
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

            match dispatch_interrupt(state, &session_id).await {
                Ok(()) => {
                    info!(
                        component = "session",
                        event = "session.interrupt.dispatched",
                        session_id = %session_id,
                        "Interrupt dispatched to connector"
                    );
                }
                Err(_) => {
                    warn!(
                        component = "session",
                        event = "session.interrupt.failed",
                        session_id = %session_id,
                        "Interrupt failed"
                    );
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

            let _ = dispatch_compact(state, &session_id).await;
        }

        ClientMessage::UndoLastTurn { session_id } => {
            info!(
                component = "session",
                event = "session.undo.requested",
                connection_id = conn_id,
                session_id = %session_id,
                "Undo last turn requested"
            );

            let _ = dispatch_undo(state, &session_id).await;
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

            match dispatch_rollback(state, &session_id, num_turns).await {
                Ok(()) => {}
                Err("rollback_failed") => {
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
                        event = "session.rollback.failed",
                        session_id = %session_id,
                        num_turns = num_turns,
                        "Rollback failed"
                    );
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

            if dispatch_stop_task(state, &session_id, task_id)
                .await
                .is_err()
            {
                send_not_found(client_tx, &session_id).await;
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

            if dispatch_rewind_files(state, &session_id, user_message_id)
                .await
                .is_err()
            {
                send_not_found(client_tx, &session_id).await;
            }
        }

        _ => {}
    }
}

async fn send_not_found(client_tx: &mpsc::Sender<OutboundMessage>, session_id: &str) {
    send_json(
        client_tx,
        ServerMessage::Error {
            code: "not_found".into(),
            message: format!(
                "Session {} not found or has no active connector",
                session_id
            ),
            session_id: Some(session_id.to_string()),
        },
    )
    .await;
}

async fn send_invalid_answer_payload(client_tx: &mpsc::Sender<OutboundMessage>, session_id: &str) {
    send_json(
        client_tx,
        ServerMessage::Error {
            code: "invalid_answer_payload".into(),
            message: "Question approvals require a non-empty answer or answers map".into(),
            session_id: Some(session_id.to_string()),
        },
    )
    .await;
}
