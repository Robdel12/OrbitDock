use std::sync::Arc;

use axum::{
  extract::{Path, Query, State},
  Json,
};
use orbitdock_protocol::SessionDetailSnapshot;

use crate::{
  runtime::{session_queries::load_full_session_state, session_registry::SessionRegistry},
  transport::http::ApiResult,
};

use super::{
  common::{map_session_load_error, trim_session_workers},
  SessionSnapshotQuery,
};

pub async fn get_session_detail(
  Path(session_id): Path<String>,
  Query(query): Query<SessionSnapshotQuery>,
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<SessionDetailSnapshot> {
  match load_full_session_state(
    &state,
    &session_id,
    query.include_messages,
    query.include_diffs,
  )
  .await
  {
    Ok(session) => Ok(Json(SessionDetailSnapshot {
      revision: session.revision.unwrap_or_default(),
      session: trim_session_workers(session),
    })),
    Err(error) => Err(map_session_load_error(&session_id, error)),
  }
}
