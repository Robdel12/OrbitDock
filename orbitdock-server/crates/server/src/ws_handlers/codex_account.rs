use std::sync::Arc;

use tokio::sync::mpsc;

use crate::state::SessionRegistry;
use crate::websocket::{send_json, send_rest_only_error, OutboundMessage};
use orbitdock_protocol::{ClientMessage, ServerMessage};

pub(crate) async fn handle(
    msg: ClientMessage,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<SessionRegistry>,
) {
    match msg {
        ClientMessage::CodexAccountRead { .. } => {
            send_rest_only_error(client_tx, "GET /api/codex/account", None).await;
        }

        ClientMessage::CodexLoginChatgptStart => {
            let auth = state.codex_auth();
            match auth.start_chatgpt_login().await {
                Ok((login_id, auth_url)) => {
                    send_json(
                        client_tx,
                        ServerMessage::CodexLoginChatgptStarted { login_id, auth_url },
                    )
                    .await;
                    if let Ok(status) = auth.read_account(false).await {
                        state.broadcast_to_list(ServerMessage::CodexAccountStatus { status });
                    }
                }
                Err(err) => {
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "codex_auth_login_start_failed".into(),
                            message: err,
                            session_id: None,
                        },
                    )
                    .await;
                }
            }
        }

        ClientMessage::CodexLoginChatgptCancel { login_id } => {
            let auth = state.codex_auth();
            let status = auth.cancel_chatgpt_login(login_id.clone()).await;
            send_json(
                client_tx,
                ServerMessage::CodexLoginChatgptCanceled { login_id, status },
            )
            .await;
            if let Ok(status) = auth.read_account(false).await {
                state.broadcast_to_list(ServerMessage::CodexAccountStatus { status });
            }
        }

        ClientMessage::CodexAccountLogout => {
            let auth = state.codex_auth();
            match auth.logout().await {
                Ok(status) => {
                    let updated = ServerMessage::CodexAccountUpdated {
                        status: status.clone(),
                    };
                    send_json(client_tx, updated.clone()).await;
                    state.broadcast_to_list(updated);
                }
                Err(err) => {
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "codex_auth_logout_failed".into(),
                            message: err,
                            session_id: None,
                        },
                    )
                    .await;
                }
            }
        }

        _ => {
            tracing::warn!(?msg, "codex_account::handle called with unexpected variant");
        }
    }
}
