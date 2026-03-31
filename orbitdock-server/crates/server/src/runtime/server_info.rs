use orbitdock_protocol::{
  ServerHello, ServerMessage, ServerMeta, CAPABILITY_CONVERSATION_SURFACE_V1,
  CAPABILITY_DASHBOARD_PROJECTION_V1, CAPABILITY_MISSIONS_PROJECTION_V1,
  CAPABILITY_SESSION_COMPOSER_SURFACE_V1, CAPABILITY_SESSION_DETAIL_SURFACE_V1,
};

use crate::runtime::session_registry::SessionRegistry;
use crate::{MINIMUM_CLIENT_VERSION, VERSION};

fn capabilities() -> Vec<String> {
  vec![
    CAPABILITY_DASHBOARD_PROJECTION_V1.to_string(),
    CAPABILITY_MISSIONS_PROJECTION_V1.to_string(),
    CAPABILITY_SESSION_DETAIL_SURFACE_V1.to_string(),
    CAPABILITY_SESSION_COMPOSER_SURFACE_V1.to_string(),
    CAPABILITY_CONVERSATION_SURFACE_V1.to_string(),
  ]
}

pub(crate) fn server_hello_message() -> ServerMessage {
  ServerMessage::Hello {
    hello: ServerHello {
      server_version: VERSION.to_string(),
      minimum_client_version: MINIMUM_CLIENT_VERSION.to_string(),
      capabilities: capabilities(),
    },
  }
}

pub(crate) fn server_meta(state: &SessionRegistry) -> ServerMeta {
  ServerMeta {
    server_version: VERSION.to_string(),
    minimum_client_version: MINIMUM_CLIENT_VERSION.to_string(),
    capabilities: capabilities(),
    is_primary: state.is_primary(),
    client_primary_claims: state.active_client_primary_claims(),
    update_status: state.update_status(),
  }
}

pub(crate) fn server_info_message(state: &SessionRegistry) -> ServerMessage {
  ServerMessage::ServerInfo {
    is_primary: state.is_primary(),
    client_primary_claims: state.active_client_primary_claims(),
  }
}
