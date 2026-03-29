use std::sync::Arc;

use crate::runtime::session_mutations::{
  end_session as end_runtime_session, rename_session as rename_runtime_session,
  update_session_config as update_runtime_session_config, SessionConfigUpdate,
};
use crate::runtime::session_registry::SessionRegistry;

pub(crate) async fn handle_end_session(
  session_id: String,
  state: &Arc<SessionRegistry>,
  _conn_id: u64,
) {
  end_runtime_session(state, &session_id).await;
}

pub(crate) async fn handle_rename_session(
  session_id: String,
  name: Option<String>,
  state: &Arc<SessionRegistry>,
  _conn_id: u64,
) {
  let _ = rename_runtime_session(state, &session_id, name).await;
}

pub(crate) async fn handle_update_session_config(
  session_id: String,
  update: SessionConfigUpdate,
  state: &Arc<SessionRegistry>,
  _conn_id: u64,
) {
  let _ = update_runtime_session_config(state, &session_id, update).await;
}
