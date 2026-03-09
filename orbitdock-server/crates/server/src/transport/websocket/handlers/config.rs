use std::sync::Arc;

use tokio::sync::mpsc;
use tracing::info;

use orbitdock_protocol::ClientMessage;

use crate::state::SessionRegistry;
use crate::websocket::{send_json, server_info_message, OutboundMessage};

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
