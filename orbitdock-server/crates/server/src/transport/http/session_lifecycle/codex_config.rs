use std::sync::Arc;

use axum::{
  extract::{Query, State},
  http::StatusCode,
  Json,
};
use serde::Deserialize;

use super::super::errors::{unprocessable, ApiErrorResponse};
use crate::runtime::codex_config::{
  codex_config_batch_write, codex_config_catalog, codex_config_documents, codex_config_write_value,
  codex_preferences_response, resolve_codex_settings, CodexConfigBatchWriteRequest,
  CodexConfigCatalogResponse, CodexConfigDocumentsResponse, CodexConfigInspectorResponse,
  CodexConfigPreferencesResponse, CodexConfigSelection, CodexConfigValueWriteRequest,
  CodexConfigWriteResponseData,
};
use crate::runtime::session_registry::SessionRegistry;
use orbitdock_protocol::CodexSessionOverrides;
use orbitdock_protocol::{
  CodexApprovalPolicy, CodexConfigMode, CodexConfigSource, CodexSandboxPolicy,
};

#[derive(Debug, Deserialize)]
pub struct InspectCodexConfigRequest {
  pub cwd: String,
  #[serde(default)]
  pub codex_config_source: Option<CodexConfigSource>,
  #[serde(default)]
  pub model: Option<String>,
  #[serde(default)]
  pub approval_policy_details: Option<CodexApprovalPolicy>,
  #[serde(default)]
  pub sandbox_policy_details: Option<CodexSandboxPolicy>,
  #[serde(default)]
  pub collaboration_mode: Option<String>,
  #[serde(default)]
  pub multi_agent: Option<bool>,
  #[serde(default)]
  pub personality: Option<String>,
  #[serde(default)]
  pub service_tier: Option<String>,
  #[serde(default)]
  pub developer_instructions: Option<String>,
  #[serde(default)]
  pub effort: Option<String>,
  #[serde(default)]
  pub codex_config_mode: Option<CodexConfigMode>,
  #[serde(default)]
  pub codex_config_profile: Option<String>,
  #[serde(default)]
  pub codex_model_provider: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateCodexPreferencesRequest {
  pub default_config_source: CodexConfigSource,
}

#[derive(Debug, Deserialize)]
pub struct CodexConfigCatalogQuery {
  pub cwd: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct CodexConfigDocumentsQuery {
  pub cwd: String,
}

pub async fn get_codex_preferences() -> Json<CodexConfigPreferencesResponse> {
  Json(codex_preferences_response())
}

pub async fn update_codex_preferences(
  State(registry): State<Arc<SessionRegistry>>,
  Json(body): Json<UpdateCodexPreferencesRequest>,
) -> Result<Json<CodexConfigPreferencesResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  let value = match body.default_config_source {
    CodexConfigSource::Orbitdock => "orbitdock",
    CodexConfigSource::User => "user",
  };
  let _ = registry
    .persist()
    .send(
      crate::infrastructure::persistence::PersistCommand::SetConfig {
        key: "codex_default_config_source".to_string(),
        value: value.to_string(),
      },
    )
    .await;
  Ok(Json(codex_preferences_response()))
}

pub async fn inspect_codex_config(
  Json(body): Json<InspectCodexConfigRequest>,
) -> Result<Json<CodexConfigInspectorResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  let config_mode = body.codex_config_mode.unwrap_or({
    if body.codex_config_profile.is_some() {
      CodexConfigMode::Profile
    } else if body.codex_model_provider.is_some() {
      CodexConfigMode::Custom
    } else {
      CodexConfigMode::Inherit
    }
  });
  let response = resolve_codex_settings(
    &body.cwd,
    CodexConfigSelection {
      config_source: body.codex_config_source.unwrap_or(CodexConfigSource::User),
      config_mode,
      config_profile: body.codex_config_profile,
      model_provider: body.codex_model_provider.clone(),
      overrides: CodexSessionOverrides {
        model: body.model,
        model_provider: body.codex_model_provider,
        approval_policy_details: body.approval_policy_details,
        sandbox_policy_details: body.sandbox_policy_details,
        approvals_reviewer: None,
        collaboration_mode: body.collaboration_mode,
        multi_agent: body.multi_agent,
        personality: body.personality,
        service_tier: body.service_tier,
        developer_instructions: body.developer_instructions,
        effort: body.effort,
      },
    },
  )
  .await
  .map_err(|error| unprocessable("invalid_codex_config", error))?;
  Ok(Json(response))
}

pub async fn get_codex_config_catalog(
  Query(query): Query<CodexConfigCatalogQuery>,
) -> Result<Json<CodexConfigCatalogResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  let response = codex_config_catalog(query.cwd.as_deref())
    .await
    .map_err(|error| unprocessable("invalid_codex_config", error))?;
  Ok(Json(response))
}

pub async fn get_codex_config_documents(
  Query(query): Query<CodexConfigDocumentsQuery>,
) -> Result<Json<CodexConfigDocumentsResponse>, (StatusCode, Json<ApiErrorResponse>)> {
  let response = codex_config_documents(&query.cwd)
    .await
    .map_err(|error| unprocessable("invalid_codex_config", error))?;
  Ok(Json(response))
}

pub async fn write_codex_config_value(
  Json(body): Json<CodexConfigValueWriteRequest>,
) -> Result<Json<CodexConfigWriteResponseData>, (StatusCode, Json<ApiErrorResponse>)> {
  let response = codex_config_write_value(body)
    .await
    .map_err(|error| unprocessable("invalid_codex_config_write", error))?;
  Ok(Json(response))
}

pub async fn batch_write_codex_config(
  Json(body): Json<CodexConfigBatchWriteRequest>,
) -> Result<Json<CodexConfigWriteResponseData>, (StatusCode, Json<ApiErrorResponse>)> {
  let response = codex_config_batch_write(body)
    .await
    .map_err(|error| unprocessable("invalid_codex_config_write", error))?;
  Ok(Json(response))
}
