use std::sync::Arc;

use axum::{
  extract::State,
  http::{HeaderMap, StatusCode},
  Json,
};
use serde::Serialize;

use crate::infrastructure::{
  auth_tokens,
  persistence::{
    apply_workspace_sync_batch, resolve_workspace_sync_target, update_workspace_heartbeat,
    SyncBatchRequest,
  },
};
use crate::runtime::session_registry::SessionRegistry;

use super::errors::{api_error, conflict, internal, ApiResult};

#[derive(Debug, Serialize)]
pub struct SyncBatchAckResponse {
  pub acked_through: u64,
}

pub async fn post_sync_batch(
  State(registry): State<Arc<SessionRegistry>>,
  headers: HeaderMap,
  Json(request): Json<SyncBatchRequest>,
) -> ApiResult<SyncBatchAckResponse> {
  let token = extract_bearer_token(&headers).ok_or_else(|| {
    api_error(
      StatusCode::UNAUTHORIZED,
      "missing_bearer_token",
      "Authorization header with Bearer token is required",
    )
  })?;

  let token_id = auth_tokens::resolve_active_token_id(token)
    .map_err(|error| {
      internal(
        "token_lookup_failed",
        format!("token lookup failed: {error}"),
      )
    })?
    .ok_or_else(|| {
      api_error(
        StatusCode::UNAUTHORIZED,
        "invalid_workspace_token",
        "Workspace sync token is invalid or expired",
      )
    })?;

  let db_path = registry.db_path().clone();
  let request_clone = request.clone();
  let token_id_clone = token_id.clone();
  let outcome = tokio::task::spawn_blocking(move || -> anyhow::Result<_> {
    let mut conn = rusqlite::Connection::open(&db_path)?;
    conn.execute_batch(
      "PRAGMA journal_mode = WAL;
             PRAGMA busy_timeout = 5000;
             PRAGMA synchronous = NORMAL;
             PRAGMA foreign_keys = ON;",
    )?;

    let target = resolve_workspace_sync_target(&conn, &token_id_clone)?
      .ok_or_else(|| anyhow::anyhow!("workspace token is not assigned to a workspace"))?;

    let apply_result = match apply_workspace_sync_batch(&mut conn, &target, &request_clone.commands)
    {
      Ok(result) => result,
      Err(error) => {
        if error.to_string().contains("sequence gap")
          || error.to_string().contains("batch overlaps already-acked")
        {
          update_workspace_heartbeat(&conn, &target.workspace_id)?;
        }
        return Err(error);
      }
    };

    Ok((apply_result, target.workspace_id))
  })
  .await
  .map_err(|error| internal("sync_join_failed", format!("sync join failed: {error}")))?;

  let (apply_result, _workspace_id) = match outcome {
    Ok(result) => result,
    Err(error) => {
      let message = error.to_string();
      if message.contains("workspace token is not assigned") {
        return Err(api_error(
          StatusCode::UNAUTHORIZED,
          "workspace_not_found",
          "Workspace token is not assigned to an active workspace",
        ));
      }
      if message.contains("sequence gap")
        || message.contains("batch overlaps already-acked")
        || message.contains("non-contiguous sequence")
        || message.contains("workspace mismatch")
      {
        return Err(conflict("sync_sequence_conflict", message));
      }
      return Err(internal("sync_apply_failed", message));
    }
  };

  if !request.commands.is_empty() {
    registry.publish_active_sessions_invalidation();
  }
  for mission_id in &apply_result.touched_mission_ids {
    registry.publish_mission_invalidation(mission_id);
  }

  Ok(Json(SyncBatchAckResponse {
    acked_through: apply_result.acked_through,
  }))
}

fn extract_bearer_token(headers: &HeaderMap) -> Option<&str> {
  headers
    .get(axum::http::header::AUTHORIZATION)
    .and_then(|value| value.to_str().ok())
    .and_then(|value| value.strip_prefix("Bearer "))
    .filter(|value| !value.is_empty())
}

#[cfg(test)]
#[path = "sync_tests.rs"]
mod tests;
