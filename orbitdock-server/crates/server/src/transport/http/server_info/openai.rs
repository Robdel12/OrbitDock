use std::sync::Arc;

use axum::{extract::State, Json};
use tracing::info;

use crate::{
  infrastructure::persistence::PersistCommand, runtime::session_registry::SessionRegistry,
  transport::http::ApiResult,
};

use super::{OpenAiKeyStatusResponse, SetOpenAiKeyRequest};

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
