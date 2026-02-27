use std::sync::Arc;

use tokio::sync::mpsc;
use tracing::info;

use orbitdock_protocol::ClientMessage;

use crate::persistence::PersistCommand;
use crate::state::SessionRegistry;
use crate::websocket::{send_json, send_rest_only_error, server_info_message, OutboundMessage};

pub(crate) async fn handle(
    msg: ClientMessage,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<SessionRegistry>,
    conn_id: u64,
) {
    match msg {
        ClientMessage::SetServerRole { is_primary } => {
            info!(
                component = "config",
                event = "config.server_role.set",
                connection_id = conn_id,
                is_primary = is_primary,
                "Server role updated via WebSocket"
            );

            let _changed = state.set_primary(is_primary);

            let role_value = if is_primary {
                "primary".to_string()
            } else {
                "secondary".to_string()
            };
            let _ = state
                .persist()
                .send(PersistCommand::SetConfig {
                    key: "server_role".into(),
                    value: role_value,
                })
                .await;

            let update = server_info_message(state);
            send_json(client_tx, update.clone()).await;
            state.broadcast_to_list(update);
        }

        ClientMessage::SetClientPrimaryClaim {
            client_id,
            device_name,
            is_primary,
        } => {
            info!(
                component = "config",
                event = "config.client_primary_claim.set",
                connection_id = conn_id,
                client_id = %client_id,
                device_name = %device_name,
                is_primary = is_primary,
                "Client primary claim updated"
            );

            state.set_client_primary_claim(conn_id, client_id, device_name, is_primary);

            let update = server_info_message(state);
            send_json(client_tx, update.clone()).await;
            state.broadcast_to_list(update);
        }

        ClientMessage::SetOpenAiKey { key } => {
            info!(
                component = "config",
                event = "config.openai_key.set",
                connection_id = conn_id,
                "OpenAI API key set via UI"
            );

            let _ = state
                .persist()
                .send(PersistCommand::SetConfig {
                    key: "openai_api_key".into(),
                    value: key,
                })
                .await;
        }

        ClientMessage::ListModels => {
            send_rest_only_error(client_tx, "GET /api/models/codex", None).await;
        }

        ClientMessage::ListClaudeModels => {
            send_rest_only_error(client_tx, "GET /api/models/claude", None).await;
        }

        _ => unreachable!("config::handle called with non-config message"),
    }
}
