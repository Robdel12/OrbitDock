use std::sync::Arc;

use axum::{
  extract::{Path, State},
  Json,
};
use serde::{Deserialize, Serialize};
use tracing::info;

use crate::{
  infrastructure::persistence::{load_mission_by_id, PersistCommand},
  runtime::session_registry::SessionRegistry,
  transport::http::{
    errors::{bad_request, internal, not_found},
    ApiResult,
  },
};

use super::{db_read, flush_persistence};

#[derive(Serialize)]
pub struct LinearKeyStatusResponse {
  pub configured: bool,
}

#[derive(Deserialize)]
pub struct SetLinearKeyRequest {
  pub key: String,
}

/// GET /api/server/linear-key
pub async fn check_linear_key() -> Json<LinearKeyStatusResponse> {
  Json(LinearKeyStatusResponse {
    configured: crate::support::api_keys::resolve_linear_api_key().is_some(),
  })
}

/// POST /api/server/linear-key
pub async fn set_linear_key(
  State(registry): State<Arc<SessionRegistry>>,
  Json(body): Json<SetLinearKeyRequest>,
) -> ApiResult<LinearKeyStatusResponse> {
  let key = body.key.trim().to_string();
  if key.is_empty() {
    return Err(bad_request("invalid_key", "Linear API key cannot be empty"));
  }

  info!(
    component = "mission_control",
    event = "api.linear_key.set",
    "Linear API key set via REST"
  );

  registry
    .persist()
    .send(PersistCommand::SetConfig {
      key: "linear_api_key".into(),
      value: key,
    })
    .await
    .map_err(|_| {
      internal(
        "persistence_unavailable",
        "Persistence writer is unavailable",
      )
    })?;
  flush_persistence(&registry).await?;

  Ok(Json(LinearKeyStatusResponse { configured: true }))
}

/// DELETE /api/server/linear-key
pub async fn delete_linear_key(
  State(registry): State<Arc<SessionRegistry>>,
) -> ApiResult<LinearKeyStatusResponse> {
  info!(
    component = "mission_control",
    event = "api.linear_key.deleted",
    "Linear API key deleted via REST"
  );

  registry
    .persist()
    .send(PersistCommand::DeleteConfig {
      key: "linear_api_key".into(),
    })
    .await
    .map_err(|_| {
      internal(
        "persistence_unavailable",
        "Persistence writer is unavailable",
      )
    })?;
  flush_persistence(&registry).await?;

  Ok(Json(LinearKeyStatusResponse { configured: false }))
}

#[derive(Serialize)]
pub struct GitHubKeyStatusResponse {
  pub configured: bool,
}

#[derive(Deserialize)]
pub struct SetGitHubKeyRequest {
  pub key: String,
}

/// GET /api/server/github-key
pub async fn check_github_key() -> Json<GitHubKeyStatusResponse> {
  Json(GitHubKeyStatusResponse {
    configured: crate::support::api_keys::resolve_github_api_key().is_some(),
  })
}

/// POST /api/server/github-key
pub async fn set_github_key(
  State(registry): State<Arc<SessionRegistry>>,
  Json(body): Json<SetGitHubKeyRequest>,
) -> ApiResult<GitHubKeyStatusResponse> {
  let key = body.key.trim().to_string();
  if key.is_empty() {
    return Err(bad_request("invalid_key", "GitHub token cannot be empty"));
  }

  info!(
    component = "mission_control",
    event = "api.github_key.set",
    "GitHub token set via REST"
  );

  registry
    .persist()
    .send(PersistCommand::SetConfig {
      key: "github_api_key".into(),
      value: key,
    })
    .await
    .map_err(|_| {
      internal(
        "persistence_unavailable",
        "Persistence writer is unavailable",
      )
    })?;
  flush_persistence(&registry).await?;

  Ok(Json(GitHubKeyStatusResponse { configured: true }))
}

/// DELETE /api/server/github-key
pub async fn delete_github_key(
  State(registry): State<Arc<SessionRegistry>>,
) -> ApiResult<GitHubKeyStatusResponse> {
  info!(
    component = "mission_control",
    event = "api.github_key.deleted",
    "GitHub token deleted via REST"
  );

  registry
    .persist()
    .send(PersistCommand::DeleteConfig {
      key: "github_api_key".into(),
    })
    .await
    .map_err(|_| {
      internal(
        "persistence_unavailable",
        "Persistence writer is unavailable",
      )
    })?;
  flush_persistence(&registry).await?;

  Ok(Json(GitHubKeyStatusResponse { configured: false }))
}

#[derive(Serialize)]
pub struct MissionTrackerKeyResponse {
  pub configured: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub source: Option<String>,
}

#[derive(Deserialize)]
pub struct SetMissionTrackerKeyRequest {
  pub key: String,
}

/// GET /api/missions/:id/tracker-key
pub async fn get_mission_tracker_key(
  State(registry): State<Arc<SessionRegistry>>,
  Path(mission_id): Path<String>,
) -> ApiResult<MissionTrackerKeyResponse> {
  let mid = mission_id.clone();
  let mission = db_read(&registry, move |conn| load_mission_by_id(conn, &mid))
    .await?
    .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;

  let source =
    crate::support::api_keys::tracker_key_source_for_mission(&mission.id, &mission.tracker_kind);
  Ok(Json(MissionTrackerKeyResponse {
    configured: source.is_some(),
    source: source.map(|s| s.to_string()),
  }))
}

/// PUT /api/missions/:id/tracker-key
pub async fn set_mission_tracker_key(
  State(registry): State<Arc<SessionRegistry>>,
  Path(mission_id): Path<String>,
  Json(body): Json<SetMissionTrackerKeyRequest>,
) -> ApiResult<MissionTrackerKeyResponse> {
  let mid = mission_id.clone();
  let _mission = db_read(&registry, move |conn| load_mission_by_id(conn, &mid))
    .await?
    .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;

  info!(
      component = "mission_control",
      event = "api.mission_tracker_key.set",
      mission_id = %mission_id,
      "Mission-scoped tracker key set via REST"
  );

  registry
    .persist()
    .send(PersistCommand::MissionSetTrackerKey {
      mission_id: mission_id.clone(),
      key: Some(body.key),
    })
    .await
    .map_err(|_| {
      internal(
        "persistence_unavailable",
        "Persistence writer is unavailable",
      )
    })?;
  flush_persistence(&registry).await?;

  // Notify mission detail + list surfaces to refresh via HTTP.
  registry.publish_mission_invalidation(&mission_id);

  Ok(Json(MissionTrackerKeyResponse {
    configured: true,
    source: Some("mission".to_string()),
  }))
}

/// DELETE /api/missions/:id/tracker-key
pub async fn delete_mission_tracker_key(
  State(registry): State<Arc<SessionRegistry>>,
  Path(mission_id): Path<String>,
) -> ApiResult<MissionTrackerKeyResponse> {
  let mid = mission_id.clone();
  let mission = db_read(&registry, move |conn| load_mission_by_id(conn, &mid))
    .await?
    .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;

  info!(
      component = "mission_control",
      event = "api.mission_tracker_key.deleted",
      mission_id = %mission_id,
      "Mission-scoped tracker key deleted via REST"
  );

  registry
    .persist()
    .send(PersistCommand::MissionSetTrackerKey {
      mission_id: mission_id.clone(),
      key: None,
    })
    .await
    .map_err(|_| {
      internal(
        "persistence_unavailable",
        "Persistence writer is unavailable",
      )
    })?;
  flush_persistence(&registry).await?;

  // Notify mission detail + list surfaces to refresh via HTTP.
  registry.publish_mission_invalidation(&mission_id);

  // Check if global fallback still provides a key
  let source = crate::support::api_keys::resolve_tracker_api_key(&mission.tracker_kind).map(|_| {
    if std::env::var(match mission.tracker_kind.as_str() {
      "github" => "GITHUB_TOKEN",
      _ => "LINEAR_API_KEY",
    })
    .map(|k| !k.is_empty())
    .unwrap_or(false)
    {
      "env"
    } else {
      "global"
    }
  });

  Ok(Json(MissionTrackerKeyResponse {
    configured: source.is_some(),
    source: source.map(|s| s.to_string()),
  }))
}

/// POST /api/missions/:id/adopt-global-key
///
/// Copies the currently-resolved global tracker key into the mission's
/// scoped credential. This is the migration path for existing missions.
pub async fn adopt_global_tracker_key(
  State(registry): State<Arc<SessionRegistry>>,
  Path(mission_id): Path<String>,
) -> ApiResult<MissionTrackerKeyResponse> {
  let mid = mission_id.clone();
  let mission = db_read(&registry, move |conn| load_mission_by_id(conn, &mid))
    .await?
    .ok_or_else(|| not_found("not_found", format!("Mission {mission_id} not found")))?;

  let global_key = crate::support::api_keys::resolve_tracker_api_key(&mission.tracker_kind)
    .ok_or_else(|| {
      bad_request(
        "no_global_key",
        format!("No global {} key configured to adopt", mission.tracker_kind),
      )
    })?;

  info!(
      component = "mission_control",
      event = "api.mission_tracker_key.adopted",
      mission_id = %mission_id,
      tracker_kind = %mission.tracker_kind,
      "Adopted global tracker key into mission scope"
  );

  registry
    .persist()
    .send(PersistCommand::MissionSetTrackerKey {
      mission_id: mission_id.clone(),
      key: Some(global_key),
    })
    .await
    .map_err(|_| {
      internal(
        "persistence_unavailable",
        "Persistence writer is unavailable",
      )
    })?;
  flush_persistence(&registry).await?;

  // Notify mission detail + list surfaces to refresh via HTTP.
  registry.publish_mission_invalidation(&mission_id);

  Ok(Json(MissionTrackerKeyResponse {
    configured: true,
    source: Some("mission".to_string()),
  }))
}

#[derive(Serialize)]
pub struct TrackerKeysResponse {
  pub linear: TrackerKeyInfo,
  pub github: TrackerKeyInfo,
}

#[derive(Serialize)]
pub struct TrackerKeyInfo {
  pub configured: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub source: Option<String>,
}

/// GET /api/server/tracker-keys
pub async fn get_tracker_keys() -> Json<TrackerKeysResponse> {
  let linear_key = crate::support::api_keys::resolve_linear_api_key();
  let linear_source = if linear_key.is_some() {
    if std::env::var("LINEAR_API_KEY")
      .map(|k| !k.is_empty())
      .unwrap_or(false)
    {
      Some("env".to_string())
    } else {
      Some("settings".to_string())
    }
  } else {
    None
  };

  let github_key = crate::support::api_keys::resolve_github_api_key();
  let github_source = if github_key.is_some() {
    if std::env::var("GITHUB_TOKEN")
      .map(|k| !k.is_empty())
      .unwrap_or(false)
    {
      Some("env".to_string())
    } else {
      Some("settings".to_string())
    }
  } else {
    None
  };

  Json(TrackerKeysResponse {
    linear: TrackerKeyInfo {
      configured: linear_key.is_some(),
      source: linear_source,
    },
    github: TrackerKeyInfo {
      configured: github_key.is_some(),
      source: github_source,
    },
  })
}
