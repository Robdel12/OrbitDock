use std::sync::Arc;

use axum::{extract::State, Json};
use tracing::info;

use crate::{
  infrastructure::persistence::PersistCommand,
  runtime::{
    server_info::{server_info_message, server_meta},
    session_registry::SessionRegistry,
  },
  transport::http::{AcceptedResponse, ApiResult},
};

use super::{ServerRoleResponse, SetClientPrimaryClaimRequest, SetServerRoleRequest};

pub async fn get_server_meta(
  State(state): State<Arc<SessionRegistry>>,
) -> Json<orbitdock_protocol::ServerMeta> {
  crate::runtime::background::update_checker::maybe_trigger_check(&state);
  Json(server_meta(&state))
}

pub async fn set_server_role(
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<SetServerRoleRequest>,
) -> ApiResult<ServerRoleResponse> {
  info!(
    component = "api",
    event = "api.server_role.set",
    is_primary = body.is_primary,
    "Server role updated via REST"
  );

  let _changed = state.set_primary(body.is_primary);
  let role_value = if body.is_primary {
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

  let update = server_info_message(&state);
  state.broadcast_to_list(update);

  Ok(Json(ServerRoleResponse {
    is_primary: body.is_primary,
  }))
}

pub async fn set_client_primary_claim(
  State(state): State<Arc<SessionRegistry>>,
  Json(body): Json<SetClientPrimaryClaimRequest>,
) -> Json<AcceptedResponse> {
  state.set_client_primary_claim(0, body.client_id, body.device_name, body.is_primary);
  let update = server_info_message(&state);
  state.broadcast_to_list(update);
  Json(AcceptedResponse {
    accepted: true,
    session_detail_snapshot: None,
  })
}
