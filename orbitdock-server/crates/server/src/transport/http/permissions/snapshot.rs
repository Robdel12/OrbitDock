use std::sync::Arc;

use orbitdock_protocol::SessionDetailSnapshot;

use crate::runtime::{session_queries::load_full_session_state, session_registry::SessionRegistry};

pub async fn load_session_detail_snapshot(
  state: &Arc<SessionRegistry>,
  session_id: &str,
) -> Option<SessionDetailSnapshot> {
  match load_full_session_state(state, session_id, false, false).await {
    Ok(session) => Some(SessionDetailSnapshot {
      revision: session.revision.unwrap_or_default(),
      session,
    }),
    Err(
      crate::runtime::session_queries::SessionLoadError::NotFound
      | crate::runtime::session_queries::SessionLoadError::Db(_)
      | crate::runtime::session_queries::SessionLoadError::Runtime(_),
    ) => None,
  }
}
