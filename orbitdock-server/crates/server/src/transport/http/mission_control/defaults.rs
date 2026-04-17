use std::sync::Arc;

use axum::{extract::State, Json};
use serde::{Deserialize, Serialize};

use crate::{
  infrastructure::persistence::PersistCommand, runtime::session_registry::SessionRegistry,
  transport::http::ApiResult,
};

#[derive(Serialize, Deserialize)]
pub struct MissionDefaultsResponse {
  pub provider_strategy: String,
  pub primary_provider: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub secondary_provider: Option<String>,
}

#[derive(Deserialize)]
pub struct UpdateMissionDefaultsRequest {
  pub provider_strategy: Option<String>,
  pub primary_provider: Option<String>,
  pub secondary_provider: Option<Option<String>>,
}

/// GET /api/server/mission-defaults
pub async fn get_mission_defaults() -> Json<MissionDefaultsResponse> {
  let strategy = crate::infrastructure::persistence::load_config_value("mission_default_strategy")
    .unwrap_or_else(|| "single".to_string());
  let primary = crate::infrastructure::persistence::load_config_value("mission_default_primary")
    .unwrap_or_else(|| "claude".to_string());
  let secondary =
    crate::infrastructure::persistence::load_config_value("mission_default_secondary");

  Json(MissionDefaultsResponse {
    provider_strategy: strategy,
    primary_provider: primary,
    secondary_provider: secondary,
  })
}

/// PUT /api/server/mission-defaults
pub async fn update_mission_defaults(
  State(registry): State<Arc<SessionRegistry>>,
  Json(req): Json<UpdateMissionDefaultsRequest>,
) -> ApiResult<MissionDefaultsResponse> {
  if let Some(v) = &req.provider_strategy {
    let _ = registry
      .persist()
      .send(PersistCommand::SetConfig {
        key: "mission_default_strategy".into(),
        value: v.clone(),
      })
      .await;
  }
  if let Some(v) = &req.primary_provider {
    let _ = registry
      .persist()
      .send(PersistCommand::SetConfig {
        key: "mission_default_primary".into(),
        value: v.clone(),
      })
      .await;
  }
  if let Some(v) = &req.secondary_provider {
    let _ = registry
      .persist()
      .send(PersistCommand::SetConfig {
        key: "mission_default_secondary".into(),
        value: v.clone().unwrap_or_default(),
      })
      .await;
  }

  // Return current state
  let strategy = req
    .provider_strategy
    .or_else(|| crate::infrastructure::persistence::load_config_value("mission_default_strategy"))
    .unwrap_or_else(|| "single".to_string());
  let primary = req
    .primary_provider
    .or_else(|| crate::infrastructure::persistence::load_config_value("mission_default_primary"))
    .unwrap_or_else(|| "claude".to_string());
  let secondary = match req.secondary_provider {
    Some(v) => v,
    None => crate::infrastructure::persistence::load_config_value("mission_default_secondary"),
  };

  Ok(Json(MissionDefaultsResponse {
    provider_strategy: strategy,
    primary_provider: primary,
    secondary_provider: secondary,
  }))
}
