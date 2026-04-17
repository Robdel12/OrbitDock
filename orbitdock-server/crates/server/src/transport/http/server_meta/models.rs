use crate::transport::http::{ApiErrorResponse, ApiResult};
use axum::{extract::Query, http::StatusCode, Json};
use orbitdock_connector_codex::{discover_models, discover_models_for_context};

use super::{ClaudeModelsResponse, CodexModelsQuery, CodexModelsResponse};

pub async fn list_codex_models(
  Query(query): Query<CodexModelsQuery>,
) -> ApiResult<CodexModelsResponse> {
  let result = if query.cwd.is_some() || query.model_provider.is_some() {
    discover_models_for_context(query.cwd.as_deref(), query.model_provider.as_deref()).await
  } else {
    discover_models().await
  };

  match result {
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
    models: orbitdock_protocol::ClaudeModelOption::defaults(),
  })
}
