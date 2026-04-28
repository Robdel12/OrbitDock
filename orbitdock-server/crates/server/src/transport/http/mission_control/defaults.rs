use std::sync::Arc;

use axum::{extract::State, Json};
use serde::{Deserialize, Serialize};

use crate::{
  infrastructure::persistence::PersistCommand,
  runtime::session_registry::SessionRegistry,
  transport::http::{errors::internal, ApiResult},
};

use super::flush_persistence;

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
  Json(current_mission_defaults())
}

fn current_mission_defaults() -> MissionDefaultsResponse {
  let strategy = crate::infrastructure::persistence::load_config_value("mission_default_strategy")
    .unwrap_or_else(|| "single".to_string());
  let primary = crate::infrastructure::persistence::load_config_value("mission_default_primary")
    .unwrap_or_else(|| "claude".to_string());
  let secondary =
    crate::infrastructure::persistence::load_config_value("mission_default_secondary")
      .filter(|value| !value.is_empty());

  MissionDefaultsResponse {
    provider_strategy: strategy,
    primary_provider: primary,
    secondary_provider: secondary,
  }
}

/// PUT /api/server/mission-defaults
pub async fn update_mission_defaults(
  State(registry): State<Arc<SessionRegistry>>,
  Json(req): Json<UpdateMissionDefaultsRequest>,
) -> ApiResult<MissionDefaultsResponse> {
  if let Some(v) = &req.provider_strategy {
    registry
      .persist()
      .send(PersistCommand::SetConfig {
        key: "mission_default_strategy".into(),
        value: v.clone(),
      })
      .await
      .map_err(|_| {
        internal(
          "persistence_unavailable",
          "Persistence writer is unavailable",
        )
      })?;
  }
  if let Some(v) = &req.primary_provider {
    registry
      .persist()
      .send(PersistCommand::SetConfig {
        key: "mission_default_primary".into(),
        value: v.clone(),
      })
      .await
      .map_err(|_| {
        internal(
          "persistence_unavailable",
          "Persistence writer is unavailable",
        )
      })?;
  }
  if let Some(v) = &req.secondary_provider {
    let command = match v {
      Some(value) if !value.is_empty() => PersistCommand::SetConfig {
        key: "mission_default_secondary".into(),
        value: value.clone(),
      },
      _ => PersistCommand::DeleteConfig {
        key: "mission_default_secondary".into(),
      },
    };
    registry.persist().send(command).await.map_err(|_| {
      internal(
        "persistence_unavailable",
        "Persistence writer is unavailable",
      )
    })?;
  }
  flush_persistence(&registry).await?;

  Ok(Json(current_mission_defaults()))
}
