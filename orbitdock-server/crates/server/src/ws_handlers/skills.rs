use std::sync::Arc;

use tokio::sync::mpsc;

use orbitdock_protocol::{ClientMessage, ServerMessage};

use crate::codex_session::CodexAction;
use crate::state::SessionRegistry;
use crate::websocket::{send_json, send_rest_only_error, OutboundMessage};

pub(crate) async fn handle(
    msg: ClientMessage,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<SessionRegistry>,
) {
    match msg {
        ClientMessage::ListSkills { session_id, .. } => {
            send_rest_only_error(
                client_tx,
                "GET /api/sessions/{session_id}/skills",
                Some(session_id),
            )
            .await;
        }

        ClientMessage::ListRemoteSkills { session_id } => {
            send_rest_only_error(
                client_tx,
                "GET /api/sessions/{session_id}/skills/remote",
                Some(session_id),
            )
            .await;
        }

        ClientMessage::DownloadRemoteSkill {
            session_id,
            hazelnut_id,
        } => {
            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx
                    .send(CodexAction::DownloadRemoteSkill { hazelnut_id })
                    .await;
            } else {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "session_not_found".into(),
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

        ClientMessage::ListMcpTools { session_id } => {
            send_rest_only_error(
                client_tx,
                "GET /api/sessions/{session_id}/mcp/tools",
                Some(session_id),
            )
            .await;
        }

        ClientMessage::RefreshMcpServers { session_id } => {
            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx.send(CodexAction::RefreshMcpServers).await;
            } else {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "session_not_found".into(),
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
