use std::sync::Arc;

use axum::extract::State;
use axum::Json;
use orbitdock_protocol::SessionsSummarySnapshot;

use crate::runtime::session_registry::SessionRegistry;

use super::errors::ApiResult;

pub async fn get_sessions_summary(
  State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<SessionsSummarySnapshot> {
  Ok(Json(state.current_sessions_summary_snapshot().await))
}
