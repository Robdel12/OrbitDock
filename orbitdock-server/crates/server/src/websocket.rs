//! WebSocket handling

use std::sync::Arc;

use axum::{
    extract::{
        ws::{Message, WebSocket},
        State, WebSocketUpgrade,
    },
    response::IntoResponse,
};
use futures::{SinkExt, StreamExt};
use tokio::sync::{mpsc, Mutex};
use tracing::{debug, error, info, warn};

use orbitdock_protocol::{ClientMessage, ServerMessage};

use crate::persistence::PersistCommand;
use crate::state::AppState;

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

    // Channel for sending messages to this client
    let (client_tx, mut client_rx) = mpsc::channel::<ServerMessage>(100);

    // Spawn task to forward server messages to WebSocket
    let send_task = tokio::spawn(async move {
        while let Some(msg) = client_rx.recv().await {
            let json = match serde_json::to_string(&msg) {
                Ok(j) => j,
                Err(e) => {
                    error!("Failed to serialize message: {}", e);
                    continue;
                }
            };

            if ws_tx.send(Message::Text(json.into())).await.is_err() {
                debug!("WebSocket send failed, client disconnected");
                break;
            }
        }
    });

    // Handle incoming messages
    while let Some(result) = ws_rx.next().await {
        let msg = match result {
            Ok(Message::Text(text)) => text,
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
                let error = ServerMessage::Error {
                    code: "parse_error".into(),
                    message: e.to_string(),
                    session_id: None,
                };
                let _ = client_tx.send(error).await;
                continue;
            }
        };

        // Handle the message
        handle_client_message(client_msg, &client_tx, &state).await;
    }

    info!("WebSocket connection closed");
    send_task.abort();
}

/// Handle a client message
async fn handle_client_message(
    msg: ClientMessage,
    client_tx: &mpsc::Sender<ServerMessage>,
    state: &Arc<Mutex<AppState>>,
) {
    debug!("Received: {:?}", msg);

    match msg {
        ClientMessage::SubscribeList => {
            let mut state = state.lock().await;
            state.subscribe_list(client_tx.clone());

            // Send current list
            let sessions = state.get_session_summaries();
            let _ = client_tx
                .send(ServerMessage::SessionsList { sessions })
                .await;
        }

        ClientMessage::SubscribeSession { session_id } => {
            let mut state = state.lock().await;
            if let Some(session) = state.get_session_mut(&session_id) {
                session.subscribe(client_tx.clone());

                // Send current state
                let snapshot = session.state();
                let _ = client_tx
                    .send(ServerMessage::SessionSnapshot { session: snapshot })
                    .await;
            } else {
                let _ = client_tx
                    .send(ServerMessage::Error {
                        code: "not_found".into(),
                        message: format!("Session {} not found", session_id),
                        session_id: Some(session_id),
                    })
                    .await;
            }
        }

        ClientMessage::UnsubscribeSession { session_id } => {
            let mut state = state.lock().await;
            if let Some(session) = state.get_session_mut(&session_id) {
                session.unsubscribe(client_tx);
            }
        }

        ClientMessage::CreateSession {
            provider,
            cwd,
            model,
        } => {
            info!("Creating {:?} session in {}", provider, cwd);

            let id = orbitdock_protocol::new_id();
            let project_name = cwd.split('/').last().map(String::from);
            let mut handle =
                crate::session::SessionHandle::new(id.clone(), provider, cwd.clone());

            // Subscribe the creator
            handle.subscribe(client_tx.clone());

            let summary = handle.summary();
            let snapshot = handle.state();

            let mut state = state.lock().await;

            // Persist session creation
            let _ = state
                .persist()
                .send(PersistCommand::SessionCreate {
                    id: id.clone(),
                    provider,
                    project_path: cwd,
                    project_name,
                    model: model.clone(),
                })
                .await;

            state.add_session(handle);

            // Notify creator
            let _ = client_tx
                .send(ServerMessage::SessionSnapshot { session: snapshot })
                .await;

            // Notify list subscribers
            state
                .broadcast_to_list(ServerMessage::SessionCreated { session: summary })
                .await;

            // TODO: Actually spawn the connector
        }

        ClientMessage::SendMessage { session_id, content } => {
            info!("Sending message to {}: {}", session_id, content);
            // TODO: Forward to connector
        }

        ClientMessage::ApproveTool {
            session_id,
            request_id,
            approved,
        } => {
            info!(
                "Approval for {} in {}: {}",
                request_id, session_id, approved
            );
            // TODO: Forward to connector
        }

        ClientMessage::AnswerQuestion {
            session_id,
            request_id,
            answer,
        } => {
            info!("Answer for {} in {}: {}", request_id, session_id, answer);
            // TODO: Forward to connector
        }

        ClientMessage::InterruptSession { session_id } => {
            info!("Interrupting session {}", session_id);
            // TODO: Forward to connector
        }

        ClientMessage::EndSession { session_id } => {
            info!("Ending session {}", session_id);

            let mut state = state.lock().await;

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
