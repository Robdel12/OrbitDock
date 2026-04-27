use std::sync::Arc;

use axum::{
  extract::{Query, State},
  Json,
};
use orbitdock_protocol::{DashboardSnapshot, LibrarySnapshot};

use crate::{
  runtime::{session_queries::load_library_snapshot, session_registry::SessionRegistry},
  transport::http::ApiResult,
};

use super::{
  common::{clamp_library_limit, map_session_load_error},
  LibrarySnapshotQuery,
};

pub async fn get_active_sessions_snapshot(
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<DashboardSnapshot> {
  let cached = state.cached_dashboard_snapshot();
  Ok(Json(cached.1.clone()))
}

pub async fn get_archived_sessions_snapshot(
  Query(query): Query<LibrarySnapshotQuery>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<LibrarySnapshot> {
  let limit = clamp_library_limit(query.limit);
  let offset = query.offset.unwrap_or(0);
  let search_query = query.q.and_then(|value| {
    let trimmed = value.trim();
    if trimmed.is_empty() {
      None
    } else {
      Some(trimmed.to_string())
    }
  });

  match load_library_snapshot(&state, limit, offset, search_query.as_deref()).await {
    Ok(snapshot) => Ok(Json(snapshot)),
    Err(crate::runtime::session_queries::SessionLoadError::NotFound) => Ok(Json(LibrarySnapshot {
      revision: state.current_library_revision(),
      sessions: Vec::new(),
      next_offset: None,
      total_count: 0,
    })),
    Err(error) => Err(map_session_load_error("", error)),
  }
}
