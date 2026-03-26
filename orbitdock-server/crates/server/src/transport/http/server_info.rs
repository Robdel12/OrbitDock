use super::*;
use crate::infrastructure::protocol_compat::compatibility_status_from_headers;
use crate::runtime::server_info::{server_info_message, server_meta};
use axum::http::HeaderMap;
use orbitdock_protocol::WorkspaceProviderKind;

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

#[derive(Debug, Serialize)]
pub struct WorkspaceProviderConfigResponse {
    pub workspace_provider: WorkspaceProviderKind,
}

#[derive(Debug, Deserialize)]
pub struct SetWorkspaceProviderRequest {
    pub workspace_provider: WorkspaceProviderKind,
}

pub async fn get_server_meta(
    headers: HeaderMap,
    State(state): State<Arc<SessionRegistry>>,
) -> Json<orbitdock_protocol::ServerMeta> {
    Json(server_meta(
        &state,
        compatibility_status_from_headers(&headers),
    ))
}

#[derive(Debug, Deserialize)]
pub struct SetClientPrimaryClaimRequest {
    pub client_id: String,
    pub device_name: String,
    pub is_primary: bool,
}

pub async fn check_open_ai_key() -> Json<OpenAiKeyStatusResponse> {
    Json(OpenAiKeyStatusResponse {
        configured: crate::support::ai_naming::resolve_api_key().is_some(),
    })
}

pub async fn get_workspace_provider(
    State(state): State<Arc<SessionRegistry>>,
) -> Json<WorkspaceProviderConfigResponse> {
    Json(WorkspaceProviderConfigResponse {
        workspace_provider: state.workspace_provider_kind(),
    })
}

pub async fn set_workspace_provider(
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<SetWorkspaceProviderRequest>,
) -> ApiResult<WorkspaceProviderConfigResponse> {
    info!(
        component = "api",
        event = "api.workspace_provider.set",
        provider = body.workspace_provider.as_str(),
        "Workspace provider updated via REST"
    );

    state.set_workspace_provider_kind(body.workspace_provider);
    let _ = state
        .persist()
        .send(PersistCommand::SetConfig {
            key: "workspace_provider".into(),
            value: body.workspace_provider.as_str().to_string(),
        })
        .await;

    Ok(Json(WorkspaceProviderConfigResponse {
        workspace_provider: body.workspace_provider,
    }))
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
    Json(AcceptedResponse { accepted: true })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transport::http::test_support::new_persist_test_state;

    #[tokio::test]
    async fn workspace_provider_endpoint_returns_authoritative_state_and_enqueues_config_write() {
        let (state, mut persist_rx, _db_path, guard) = new_persist_test_state(true).await;
        drop(guard);

        let Json(updated) = set_workspace_provider(
            State(state.clone()),
            Json(SetWorkspaceProviderRequest {
                workspace_provider: WorkspaceProviderKind::Local,
            }),
        )
        .await
        .expect("set workspace provider should succeed");

        assert_eq!(updated.workspace_provider, WorkspaceProviderKind::Local);
        assert_eq!(
            state.workspace_provider_kind(),
            WorkspaceProviderKind::Local
        );

        let command = persist_rx
            .recv()
            .await
            .expect("workspace provider update should enqueue persistence");
        assert!(matches!(
            command,
            PersistCommand::SetConfig { ref key, ref value }
                if key == "workspace_provider" && value == "local"
        ));

        let Json(reloaded) = get_workspace_provider(State(state)).await;
        assert_eq!(reloaded.workspace_provider, WorkspaceProviderKind::Local);
    }
}
