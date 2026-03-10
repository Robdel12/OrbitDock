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
                crate::runtime::message_dispatch::DispatchSendMessage {
                    session_id: session_id.clone(),
                    content,
                    model,
                    effort,
                    skills,
                    images,
                    mentions,
                    message_id,
                },
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

#[cfg(test)]
mod tests {
    use super::handle;
    use crate::connectors::claude_session::ClaudeAction;
    use crate::connectors::codex_session::CodexAction;
    use crate::domain::sessions::session::SessionHandle;
    use crate::transport::websocket::test_support::new_test_state;
    use crate::transport::websocket::OutboundMessage;
    use orbitdock_protocol::{ClientMessage, ImageInput, MentionInput, Provider};
    use tokio::sync::mpsc;

    #[tokio::test]
    async fn send_message_does_not_mark_working_when_action_channel_is_closed() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "send-message-closed-channel".to_string();
        let (action_tx, action_rx) = mpsc::channel(1);

        drop(action_rx);

        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/Users/tester/repo".to_string(),
        ));
        state.set_codex_action_tx(&session_id, action_tx);

        handle(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "ping".to_string(),
                model: None,
                effort: None,
                skills: vec![],
                images: vec![],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        tokio::task::yield_now().await;

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        let snapshot = actor.snapshot();
        assert_eq!(
            snapshot.work_status,
            orbitdock_protocol::WorkStatus::Waiting
        );
    }

    #[tokio::test]
    async fn codex_send_message_ignores_bootstrap_prompt_for_naming() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "codex-name-on-prompt".to_string();
        let (action_tx, _action_rx) = mpsc::channel(8);

        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/Users/tester/repo".to_string(),
        ));
        state.set_codex_action_tx(&session_id, action_tx);

        handle(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "<environment_context>...</environment_context>".to_string(),
                model: None,
                effort: None,
                skills: vec![],
                images: vec![],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        handle(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "Investigate flaky auth and propose a safe migration plan".to_string(),
                model: None,
                effort: None,
                skills: vec![],
                images: vec![],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        tokio::task::yield_now().await;

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        let snapshot = actor.snapshot();
        assert_eq!(
            snapshot.first_prompt.as_deref(),
            Some("Investigate flaky auth and propose a safe migration plan")
        );
        assert_eq!(
            snapshot.work_status,
            orbitdock_protocol::WorkStatus::Working
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn send_message_dispatches_extracted_images_to_codex_connector() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "send-message-images-codex".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/Users/tester/repo".to_string(),
        ));
        state.set_codex_action_tx(&session_id, action_tx);

        handle(
            ClientMessage::SendMessage {
                session_id,
                content: "ping".to_string(),
                model: None,
                effort: None,
                skills: vec![],
                images: vec![ImageInput {
                    input_type: "url".to_string(),
                    value: "data:image/png;base64,aGVsbG8=".to_string(),
                    ..Default::default()
                }],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match action_rx.recv().await.expect("expected codex action") {
            CodexAction::SendMessage { images, .. } => {
                assert_eq!(images.len(), 1);
                assert_eq!(images[0].input_type, "path");
                assert!(images[0].value.ends_with(".png"));
            }
            other => panic!("expected SendMessage action, got {:?}", other),
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn send_message_dispatches_extracted_images_to_claude_connector() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "send-message-images-claude".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Claude,
            "/Users/tester/repo".to_string(),
        ));
        state.set_claude_action_tx(&session_id, action_tx);

        handle(
            ClientMessage::SendMessage {
                session_id,
                content: "ping".to_string(),
                model: None,
                effort: None,
                skills: vec![],
                images: vec![ImageInput {
                    input_type: "url".to_string(),
                    value: "data:image/png;base64,aGVsbG8=".to_string(),
                    ..Default::default()
                }],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match action_rx.recv().await.expect("expected claude action") {
            ClaudeAction::SendMessage { images, .. } => {
                assert_eq!(images.len(), 1);
                assert_eq!(images[0].input_type, "path");
                assert!(images[0].value.ends_with(".png"));
            }
            other => panic!("expected SendMessage action, got {:?}", other),
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn steer_turn_dispatches_extracted_images_and_mentions_to_codex_connector() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "steer-turn-images-codex".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/Users/tester/repo".to_string(),
        ));
        state.set_codex_action_tx(&session_id, action_tx);

        handle(
            ClientMessage::SteerTurn {
                session_id,
                content: "consider this".to_string(),
                images: vec![ImageInput {
                    input_type: "url".to_string(),
                    value: "data:image/png;base64,aGVsbG8=".to_string(),
                    ..Default::default()
                }],
                mentions: vec![MentionInput {
                    name: "main.rs".to_string(),
                    path: "/project/src/main.rs".to_string(),
                }],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match action_rx.recv().await.expect("expected codex action") {
            CodexAction::SteerTurn {
                images, mentions, ..
            } => {
                assert_eq!(images.len(), 1);
                assert_eq!(images[0].input_type, "path");
                assert!(images[0].value.ends_with(".png"));
                assert_eq!(mentions.len(), 1);
                assert_eq!(mentions[0].name, "main.rs");
                assert_eq!(mentions[0].path, "/project/src/main.rs");
            }
            other => panic!("expected SteerTurn action, got {:?}", other),
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn steer_turn_dispatches_extracted_images_to_claude_connector() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "steer-turn-images-claude".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Claude,
            "/Users/tester/repo".to_string(),
        ));
        state.set_claude_action_tx(&session_id, action_tx);

        handle(
            ClientMessage::SteerTurn {
                session_id,
                content: "consider this".to_string(),
                images: vec![ImageInput {
                    input_type: "url".to_string(),
                    value: "data:image/png;base64,aGVsbG8=".to_string(),
                    ..Default::default()
                }],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match action_rx.recv().await.expect("expected claude action") {
            ClaudeAction::SteerTurn { images, .. } => {
                assert_eq!(images.len(), 1);
                assert_eq!(images[0].input_type, "path");
                assert!(images[0].value.ends_with(".png"));
            }
            other => panic!("expected SteerTurn action, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn send_message_without_effort_preserves_existing_effort() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "send-message-effort-preserve".to_string();
        let (action_tx, _action_rx) = mpsc::channel(8);

        let mut session_handle = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/Users/tester/repo".to_string(),
        );
        session_handle.apply_changes(&orbitdock_protocol::StateChanges {
            effort: Some(Some("xhigh".to_string())),
            ..Default::default()
        });
        state.add_session(session_handle);
        state.set_codex_action_tx(&session_id, action_tx);

        handle(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "<environment_context>...</environment_context>".to_string(),
                model: Some("gpt-5.3-codex".to_string()),
                effort: None,
                skills: vec![],
                images: vec![],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        tokio::task::yield_now().await;

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        let snapshot = actor.snapshot();
        assert_eq!(snapshot.effort.as_deref(), Some("xhigh"));
    }

    #[tokio::test]
    async fn send_message_with_model_override_updates_session_model() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "send-message-model-override".to_string();
        let (action_tx, _action_rx) = mpsc::channel(8);

        let mut session_handle = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/Users/tester/repo".to_string(),
        );
        session_handle.set_model(Some("openai".to_string()));
        state.add_session(session_handle);
        state.set_codex_action_tx(&session_id, action_tx);

        handle(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "<environment_context>...</environment_context>".to_string(),
                model: Some("gpt-5.3-codex".to_string()),
                effort: None,
                skills: vec![],
                images: vec![],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        tokio::task::yield_now().await;
        tokio::task::yield_now().await;

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        let snapshot = actor.snapshot();
        assert_eq!(snapshot.model.as_deref(), Some("gpt-5.3-codex"));
    }

    #[tokio::test]
    async fn send_message_with_effort_override_updates_codex_session_effort() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "send-message-effort-override-codex".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        let mut session_handle = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/Users/tester/repo".to_string(),
        );
        session_handle.apply_changes(&orbitdock_protocol::StateChanges {
            effort: Some(Some("xhigh".to_string())),
            ..Default::default()
        });
        state.add_session(session_handle);
        state.set_codex_action_tx(&session_id, action_tx);

        handle(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "<environment_context>...</environment_context>".to_string(),
                model: None,
                effort: Some("high".to_string()),
                skills: vec![],
                images: vec![],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match action_rx.recv().await.expect("expected codex action") {
            CodexAction::SendMessage { effort, .. } => {
                assert_eq!(effort.as_deref(), Some("high"));
            }
            other => panic!("expected Codex send action, got {:?}", other),
        }

        tokio::task::yield_now().await;
        let actor = state
            .get_session(&session_id)
            .expect("session should exist after send");
        let snapshot = actor.snapshot();
        assert_eq!(snapshot.effort.as_deref(), Some("high"));
    }

    #[tokio::test]
    async fn send_message_with_effort_override_ignored_for_claude() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "send-message-effort-override-claude".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        let mut session_handle = SessionHandle::new(
            session_id.clone(),
            Provider::Claude,
            "/Users/tester/repo".to_string(),
        );
        session_handle.apply_changes(&orbitdock_protocol::StateChanges {
            effort: Some(Some("xhigh".to_string())),
            ..Default::default()
        });
        state.add_session(session_handle);
        state.set_claude_action_tx(&session_id, action_tx);

        handle(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "<environment_context>...</environment_context>".to_string(),
                model: None,
                effort: Some("high".to_string()),
                skills: vec![],
                images: vec![],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match action_rx.recv().await.expect("expected claude action") {
            ClaudeAction::SendMessage { effort, .. } => {
                assert_eq!(effort, None);
            }
            other => panic!("expected Claude send action, got {:?}", other),
        }

        tokio::task::yield_now().await;
        let actor = state
            .get_session(&session_id)
            .expect("session should exist after send");
        let snapshot = actor.snapshot();
        assert_eq!(snapshot.effort.as_deref(), Some("xhigh"));
    }
}
