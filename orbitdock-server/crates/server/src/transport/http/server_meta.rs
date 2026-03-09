use std::sync::Arc;

use axum::{extract::State, http::StatusCode, Json};
use orbitdock_connector_codex::discover_models;
use orbitdock_protocol::{
    ClaudeModelOption, ClaudeUsageSnapshot, CodexModelOption, CodexUsageSnapshot, UsageErrorInfo,
};
use serde::Serialize;

use crate::runtime::session_registry::SessionRegistry;

use super::errors::{ApiErrorResponse, ApiResult};
use super::server_info::not_control_plane_endpoint_error;

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
        models: crate::infrastructure::persistence::load_cached_claude_models(),
    })
}
