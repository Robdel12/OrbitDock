use orbitdock_protocol::ServerMessage;

use crate::runtime::session_registry::SessionRegistry;

pub(crate) fn server_info_message(state: &SessionRegistry) -> ServerMessage {
    ServerMessage::ServerInfo {
        is_primary: state.is_primary(),
        client_primary_claims: state.active_client_primary_claims(),
    }
}
