//! WebSocket handling

use std::sync::Arc;

use axum::{
    extract::{
        ws::{Message, WebSocket},
        State, WebSocketUpgrade,
    },
    response::IntoResponse,
};
use bytes::Bytes;
use futures::{SinkExt, StreamExt};
use tokio::sync::{mpsc, Mutex};
use tracing::{debug, error, info, warn};

use orbitdock_protocol::{ClientMessage, Provider, ServerMessage};

use crate::codex_session::{CodexAction, CodexSession};
use crate::persistence::PersistCommand;
use crate::state::AppState;

/// Messages that can be sent through the WebSocket
enum OutboundMessage {
    /// JSON-serialized ServerMessage
    Json(ServerMessage),
    /// Raw pong response
    Pong(Bytes),
}

/// WebSocket upgrade handler
pub async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<Arc<Mutex<AppState>>>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

/// Handle a WebSocket connection
async fn handle_socket(socket: WebSocket, state: Arc<Mutex<AppState>>) {
    info!("New WebSocket connection");

    let (mut ws_tx, mut ws_rx) = socket.split();

    // Channel for sending messages to this client (supports both JSON and raw frames)
    let (outbound_tx, mut outbound_rx) = mpsc::channel::<OutboundMessage>(100);

    // Spawn task to forward messages to WebSocket
    let send_task = tokio::spawn(async move {
        while let Some(msg) = outbound_rx.recv().await {
            let result = match msg {
                OutboundMessage::Json(server_msg) => {
                    match serde_json::to_string(&server_msg) {
                        Ok(json) => ws_tx.send(Message::Text(json.into())).await,
                        Err(e) => {
                            error!("Failed to serialize message: {}", e);
                            continue;
                        }
                    }
                }
                OutboundMessage::Pong(data) => ws_tx.send(Message::Pong(data)).await,
            };

            if result.is_err() {
                debug!("WebSocket send failed, client disconnected");
                break;
            }
        }
    });

    // Wrapper to send JSON messages (used by handle_client_message)
    let client_tx = outbound_tx.clone();

    // Handle incoming messages
    while let Some(result) = ws_rx.next().await {
        let msg = match result {
            Ok(Message::Text(text)) => text,
            Ok(Message::Ping(data)) => {
                // Respond to ping with pong
                let _ = outbound_tx.send(OutboundMessage::Pong(data)).await;
                continue;
            }
            Ok(Message::Close(_)) => {
                info!("Client sent close frame");
                break;
            }
            Ok(_) => continue,
            Err(e) => {
                warn!("WebSocket error: {}", e);
                break;
            }
        };

        // Parse client message
        let client_msg: ClientMessage = match serde_json::from_str(&msg) {
            Ok(m) => m,
            Err(e) => {
                warn!("Failed to parse client message: {} - {}", e, msg);
                send_json(
                    &client_tx,
                    ServerMessage::Error {
                        code: "parse_error".into(),
                        message: e.to_string(),
                        session_id: None,
                    },
                )
                .await;
                continue;
            }
        };

        // Handle the message
        handle_client_message(client_msg, &client_tx, &state).await;
    }

    info!("WebSocket connection closed");
    send_task.abort();
}

/// Send a ServerMessage through the outbound channel
async fn send_json(tx: &mpsc::Sender<OutboundMessage>, msg: ServerMessage) {
    let _ = tx.send(OutboundMessage::Json(msg)).await;
}

/// Create a ServerMessage sender that wraps an OutboundMessage sender
fn wrap_sender(tx: mpsc::Sender<OutboundMessage>) -> mpsc::Sender<ServerMessage> {
    let (server_tx, mut server_rx) = mpsc::channel::<ServerMessage>(100);
    tokio::spawn(async move {
        while let Some(msg) = server_rx.recv().await {
            if tx.send(OutboundMessage::Json(msg)).await.is_err() {
                break;
            }
        }
    });
    server_tx
}

/// Handle a client message
async fn handle_client_message(
    msg: ClientMessage,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<Mutex<AppState>>,
) {
    debug!("Received: {:?}", msg);

    match msg {
        ClientMessage::SubscribeList => {
            let mut state = state.lock().await;
            state.subscribe_list(wrap_sender(client_tx.clone()));

            // Send current list
            let sessions = state.get_session_summaries().await;
            send_json(client_tx, ServerMessage::SessionsList { sessions }).await;
        }

        ClientMessage::SubscribeSession { session_id } => {
            let state = state.lock().await;
            if let Some(session) = state.get_session(&session_id) {
                let mut session = session.lock().await;
                session.subscribe(wrap_sender(client_tx.clone()));

                // Send current state
                let snapshot = session.state();
                send_json(client_tx, ServerMessage::SessionSnapshot { session: snapshot }).await;
            } else {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "not_found".into(),
                        message: format!("Session {} not found", session_id),
                        session_id: Some(session_id),
                    },
                )
                .await;
            }
        }

        ClientMessage::UnsubscribeSession { session_id } => {
            let state = state.lock().await;
            if let Some(session) = state.get_session(&session_id) {
                let mut session = session.lock().await;
                // Note: unsubscribe won't match the wrapped sender, but that's OK
                // The session will clean up closed channels on broadcast
                session.unsubscribe_by_closed();
            }
        }

        ClientMessage::CreateSession {
            provider,
            cwd,
            model,
            approval_policy,
            sandbox_mode,
        } => {
            info!("Creating {:?} session in {}", provider, cwd);

            let id = orbitdock_protocol::new_id();
            let project_name = cwd.split('/').last().map(String::from);
            let mut handle =
                crate::session::SessionHandle::new(id.clone(), provider, cwd.clone());

            // Subscribe the creator
            handle.subscribe(wrap_sender(client_tx.clone()));

            let summary = handle.summary();
            let snapshot = handle.state();

            let mut state_guard = state.lock().await;

            // Persist session creation
            let persist_tx = state_guard.persist().clone();
            let _ = persist_tx
                .send(PersistCommand::SessionCreate {
                    id: id.clone(),
                    provider,
                    project_path: cwd.clone(),
                    project_name,
                    model: model.clone(),
                    approval_policy: approval_policy.clone(),
                    sandbox_mode: sandbox_mode.clone(),
                })
                .await;

            let session_arc = state_guard.add_session(handle);

            // Notify creator
            send_json(client_tx, ServerMessage::SessionSnapshot { session: snapshot }).await;

            // Notify list subscribers
            state_guard
                .broadcast_to_list(ServerMessage::SessionCreated { session: summary })
                .await;

            // Spawn Codex connector if it's a Codex session
            if provider == Provider::Codex {
                let session_id = id.clone();
                let cwd_clone = cwd.clone();
                let model_clone = model.clone();
                let approval_clone = approval_policy.clone();
                let sandbox_clone = sandbox_mode.clone();

                match CodexSession::new(
                    session_id.clone(),
                    &cwd_clone,
                    model_clone.as_deref(),
                    approval_clone.as_deref(),
                    sandbox_clone.as_deref(),
                ).await
                {
                    Ok(codex_session) => {
                        // Persist the codex-core thread ID so the watcher can skip this session
                        let thread_id = codex_session.thread_id().to_string();
                        let _ = persist_tx
                            .send(PersistCommand::SetThreadId {
                                session_id: session_id.clone(),
                                thread_id,
                            })
                            .await;

                        let action_tx =
                            codex_session.start_event_loop(session_arc.clone(), persist_tx);
                        state_guard.set_codex_action_tx(&session_id, action_tx);
                        info!("Codex session {} started", session_id);
                    }
                    Err(e) => {
                        error!("Failed to start Codex session: {}", e);
                        send_json(
                            client_tx,
                            ServerMessage::Error {
                                code: "codex_error".into(),
                                message: e.to_string(),
                                session_id: Some(session_id),
                            },
                        )
                        .await;
                    }
                }
            }
        }

        ClientMessage::SendMessage { session_id, content } => {
            info!("Sending message to {}: {}", session_id, content);

            let state = state.lock().await;
            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx.send(CodexAction::SendMessage { content }).await;
            } else {
                warn!("No action channel for session {}", session_id);
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "not_found".into(),
                        message: format!("Session {} not found or has no active connector", session_id),
                        session_id: Some(session_id),
                    },
                )
                .await;
            }
        }

        ClientMessage::ApproveTool {
            session_id,
            request_id,
            decision,
        } => {
            info!(
                "Approval for {} in {}: {}",
                request_id, session_id, decision
            );

            let state = state.lock().await;

            // Look up approval type and proposed amendment from session state
            let (approval_type, proposed_amendment) = if let Some(session) = state.get_session(&session_id) {
                let mut session = session.lock().await;
                let atype = session.take_pending_approval(&request_id);
                let amendment = session.take_pending_amendment(&request_id);
                (atype, amendment)
            } else {
                (None, None)
            };

            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let action = match approval_type {
                    Some(orbitdock_protocol::ApprovalType::Patch) => {
                        info!("Dispatching patch approval for {}", request_id);
                        CodexAction::ApprovePatch {
                            request_id,
                            decision,
                        }
                    }
                    _ => {
                        // Default to exec for exec and unknown types
                        CodexAction::ApproveExec {
                            request_id,
                            decision,
                            proposed_amendment,
                        }
                    }
                };
                let _ = tx.send(action).await;
            }

            // Clear pending approval and transition back to working
            if let Some(session) = state.get_session(&session_id) {
                let mut session = session.lock().await;
                session.set_work_status(orbitdock_protocol::WorkStatus::Working);

                session
                    .broadcast(ServerMessage::SessionDelta {
                        session_id: session_id.clone(),
                        changes: orbitdock_protocol::StateChanges {
                            status: None,
                            work_status: Some(orbitdock_protocol::WorkStatus::Working),
                            pending_approval: Some(None), // Explicitly clear
                            token_usage: None,
                            current_diff: None,
                            current_plan: None,
                            last_activity_at: None,
                        },
                    })
                    .await;
            }
        }

        ClientMessage::AnswerQuestion {
            session_id,
            request_id,
            answer,
        } => {
            info!("Answer for {} in {}: {}", request_id, session_id, answer);

            let state = state.lock().await;
            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let mut answers = std::collections::HashMap::new();
                answers.insert("0".to_string(), answer);
                let _ = tx.send(CodexAction::AnswerQuestion { request_id, answers }).await;
            }
        }

        ClientMessage::InterruptSession { session_id } => {
            info!("Interrupting session {}", session_id);

            let state = state.lock().await;
            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx.send(CodexAction::Interrupt).await;
            }
        }

        ClientMessage::UpdateSessionConfig {
            session_id,
            approval_policy,
            sandbox_mode,
        } => {
            info!(
                "Updating session config for {}: approval={:?}, sandbox={:?}",
                session_id, approval_policy, sandbox_mode
            );

            let state = state.lock().await;
            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx
                    .send(CodexAction::UpdateConfig {
                        approval_policy,
                        sandbox_mode,
                    })
                    .await;
            }
        }

        ClientMessage::EndSession { session_id } => {
            info!("Ending session {}", session_id);

            let mut state = state.lock().await;

            // Tell the connector to shutdown gracefully
            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx.send(CodexAction::EndSession).await;
            }

            // Persist session end
            let _ = state
                .persist()
                .send(PersistCommand::SessionEnd {
                    id: session_id.clone(),
                    reason: "user_requested".to_string(),
                })
                .await;

            // Remove from active sessions and notify
            if state.remove_session(&session_id).is_some() {
                state
                    .broadcast_to_list(ServerMessage::SessionEnded {
                        session_id,
                        reason: "user_requested".to_string(),
                    })
                    .await;
            }
        }
    }
}
