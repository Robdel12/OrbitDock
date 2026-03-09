use std::sync::Arc;

use tokio::sync::mpsc;
use tracing::info;

use orbitdock_protocol::ClientMessage;

use crate::runtime::session_registry::SessionRegistry;
use crate::transport::websocket::{send_json, server_info_message, OutboundMessage};

pub(crate) async fn handle(
    msg: ClientMessage,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<SessionRegistry>,
    conn_id: u64,
) {
    match msg {
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

        _ => unreachable!("config::handle called with non-config message"),
    }
}

#[cfg(test)]
mod tests {
    use super::handle;
    use crate::transport::websocket::test_support::{new_test_state, recv_json};
    use crate::transport::websocket::OutboundMessage;
    use orbitdock_protocol::{ClientMessage, ServerMessage};
    use tokio::sync::mpsc;

    #[tokio::test]
    async fn set_client_primary_claim_updates_server_info() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);

        handle(
            ClientMessage::SetClientPrimaryClaim {
                client_id: "device-1".to_string(),
                device_name: "Robert's iPhone".to_string(),
                is_primary: true,
            },
            &client_tx,
            &state,
            7,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::ServerInfo {
                is_primary,
                client_primary_claims,
            } => {
                assert!(is_primary);
                assert_eq!(client_primary_claims.len(), 1);
                assert_eq!(client_primary_claims[0].client_id, "device-1");
                assert_eq!(client_primary_claims[0].device_name, "Robert's iPhone");
            }
            other => panic!("expected ServerInfo, got {:?}", other),
        }
    }
}
