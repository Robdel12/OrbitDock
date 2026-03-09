use super::*;
use orbitdock_protocol::CodexAccountStatus;

#[derive(Debug, Serialize)]
pub struct CodexAccountResponse {
    pub status: CodexAccountStatus,
}

#[derive(Debug, Deserialize, Default)]
pub struct CodexAccountQuery {
    #[serde(default)]
    pub refresh_token: Option<bool>,
}

#[derive(Debug, Serialize)]
pub struct CodexLoginStartedResponse {
    pub login_id: String,
    pub auth_url: String,
}

#[derive(Debug, Deserialize)]
pub struct CodexLoginCancelRequest {
    pub login_id: String,
}

#[derive(Debug, Serialize)]
pub struct CodexLoginCanceledResponse {
    pub login_id: String,
    pub status: orbitdock_protocol::CodexLoginCancelStatus,
}

#[derive(Debug, Serialize)]
pub struct CodexLogoutResponse {
    pub status: CodexAccountStatus,
}

pub async fn read_codex_account(
    State(state): State<Arc<SessionRegistry>>,
    Query(query): Query<CodexAccountQuery>,
) -> ApiResult<CodexAccountResponse> {
    let auth = state.codex_auth();
    match auth
        .read_account(query.refresh_token.unwrap_or(false))
        .await
    {
        Ok(status) => Ok(Json(CodexAccountResponse { status })),
        Err(err) => Err((
            StatusCode::SERVICE_UNAVAILABLE,
            Json(ApiErrorResponse {
                code: "codex_auth_error",
                error: err,
            }),
        )),
    }
}

pub async fn codex_login_start(
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<CodexLoginStartedResponse> {
    let auth = state.codex_auth();
    match auth.start_chatgpt_login().await {
        Ok((login_id, auth_url)) => {
            if let Ok(status) = auth.read_account(false).await {
                state.broadcast_to_list(ServerMessage::CodexAccountStatus { status });
            }
            Ok(Json(CodexLoginStartedResponse { login_id, auth_url }))
        }
        Err(err) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiErrorResponse {
                code: "codex_auth_login_start_failed",
                error: err,
            }),
        )),
    }
}

pub async fn codex_login_cancel(
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<CodexLoginCancelRequest>,
) -> Json<CodexLoginCanceledResponse> {
    let auth = state.codex_auth();
    let status = auth.cancel_chatgpt_login(body.login_id.clone()).await;
    if let Ok(account_status) = auth.read_account(false).await {
        state.broadcast_to_list(ServerMessage::CodexAccountStatus {
            status: account_status,
        });
    }
    Json(CodexLoginCanceledResponse {
        login_id: body.login_id,
        status,
    })
}

pub async fn codex_logout(
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<CodexLogoutResponse> {
    let auth = state.codex_auth();
    match auth.logout().await {
        Ok(status) => {
            let updated = ServerMessage::CodexAccountUpdated {
                status: status.clone(),
            };
            state.broadcast_to_list(updated);
            Ok(Json(CodexLogoutResponse { status }))
        }
        Err(err) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiErrorResponse {
                code: "codex_auth_logout_failed",
                error: err,
            }),
        )),
    }
}
