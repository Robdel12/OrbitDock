use super::*;

#[derive(Debug, Serialize)]
pub struct OpenAiKeyStatusResponse {
    pub configured: bool,
}

#[derive(Debug, Deserialize)]
pub struct SetOpenAiKeyRequest {
    pub key: String,
}

#[derive(Debug, Deserialize)]
pub struct SetServerRoleRequest {
    pub is_primary: bool,
}

#[derive(Debug, Serialize)]
pub struct ServerRoleResponse {
    pub is_primary: bool,
}

#[derive(Debug, Deserialize)]
pub struct SetClientPrimaryClaimRequest {
    pub client_id: String,
    pub device_name: String,
    pub is_primary: bool,
}

pub fn not_control_plane_endpoint_error() -> UsageErrorInfo {
    UsageErrorInfo {
        code: "not_control_plane_endpoint".to_string(),
        message: "This endpoint is not primary for control-plane usage reads.".to_string(),
    }
}

pub async fn check_open_ai_key() -> Json<OpenAiKeyStatusResponse> {
    Json(OpenAiKeyStatusResponse {
        configured: crate::support::ai_naming::resolve_api_key().is_some(),
    })
}

pub async fn set_open_ai_key(
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<SetOpenAiKeyRequest>,
) -> ApiResult<OpenAiKeyStatusResponse> {
    info!(
        component = "api",
        event = "api.openai_key.set",
        "OpenAI API key set via REST"
    );

    let _ = state
        .persist()
        .send(PersistCommand::SetConfig {
            key: "openai_api_key".into(),
            value: body.key,
        })
        .await;

    Ok(Json(OpenAiKeyStatusResponse { configured: true }))
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

    let update = crate::transport::websocket::server_info_message(&state);
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
    let update = crate::transport::websocket::server_info_message(&state);
    state.broadcast_to_list(update);
    Json(AcceptedResponse { accepted: true })
}
