use std::sync::Arc;

use axum::{extract::State, http::StatusCode, Json};
use orbitdock_connector_codex::discover_models;
use orbitdock_protocol::{
    ClaudeModelOption, ClaudeUsageSnapshot, CodexModelOption, CodexUsageSnapshot, UsageErrorInfo,
};
use serde::Serialize;

use crate::runtime::session_registry::SessionRegistry;
use crate::support::usage_errors::not_control_plane_endpoint_error;

use super::errors::{ApiErrorResponse, ApiResult};

#[derive(Debug, Serialize)]
pub struct CodexUsageResponse {
    pub usage: Option<CodexUsageSnapshot>,
    pub error_info: Option<UsageErrorInfo>,
}

#[derive(Debug, Serialize)]
pub struct ClaudeUsageResponse {
    pub usage: Option<ClaudeUsageSnapshot>,
    pub error_info: Option<UsageErrorInfo>,
}

#[derive(Debug, Serialize)]
pub struct CodexModelsResponse {
    pub models: Vec<CodexModelOption>,
}

#[derive(Debug, Serialize)]
pub struct ClaudeModelsResponse {
    pub models: Vec<ClaudeModelOption>,
}

pub async fn fetch_codex_usage(
    State(state): State<Arc<SessionRegistry>>,
) -> Json<CodexUsageResponse> {
    if !state.is_primary() {
        return Json(CodexUsageResponse {
            usage: None,
            error_info: Some(not_control_plane_endpoint_error()),
        });
    }

    let (usage, error_info) = match crate::infrastructure::usage_probe::fetch_codex_usage().await {
        Ok(usage) => (Some(usage), None),
        Err(err) => (None, Some(err.to_info())),
    };

    Json(CodexUsageResponse { usage, error_info })
}

pub async fn fetch_claude_usage(
    State(state): State<Arc<SessionRegistry>>,
) -> Json<ClaudeUsageResponse> {
    if !state.is_primary() {
        return Json(ClaudeUsageResponse {
            usage: None,
            error_info: Some(not_control_plane_endpoint_error()),
        });
    }

    let (usage, error_info) = match crate::infrastructure::usage_probe::fetch_claude_usage().await {
        Ok(usage) => (Some(usage), None),
        Err(err) => (None, Some(err.to_info())),
    };

    Json(ClaudeUsageResponse { usage, error_info })
}

pub async fn list_codex_models() -> ApiResult<CodexModelsResponse> {
    match discover_models().await {
        Ok(models) => Ok(Json(CodexModelsResponse { models })),
        Err(err) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiErrorResponse {
                code: "model_list_failed",
                error: format!("Failed to list models: {err}"),
            }),
        )),
    }
}

pub async fn list_claude_models() -> Json<ClaudeModelsResponse> {
    Json(ClaudeModelsResponse {
        models: ClaudeModelOption::defaults(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{extract::State, Json};

    use crate::transport::http::test_support::new_test_state;

    #[tokio::test]
    async fn usage_endpoints_return_control_plane_error_when_secondary() {
        let state = new_test_state(false);

        let Json(codex) = fetch_codex_usage(State(state.clone())).await;
        assert!(codex.usage.is_none());
        assert_eq!(
            codex.error_info.as_ref().map(|info| info.code.as_str()),
            Some("not_control_plane_endpoint")
        );

        let Json(claude) = fetch_claude_usage(State(state)).await;
        assert!(claude.usage.is_none());
        assert_eq!(
            claude.error_info.as_ref().map(|info| info.code.as_str()),
            Some("not_control_plane_endpoint")
        );
    }

    #[tokio::test]
    async fn claude_models_endpoint_returns_cached_shape() {
        crate::support::test_support::ensure_server_test_data_dir();
        let Json(response) = list_claude_models().await;
        assert!(response
            .models
            .iter()
            .all(|model| !model.value.trim().is_empty()));
    }
}
