use std::sync::Arc;

use tracing::info;

use crate::runtime::session_mutations::{
  end_session as end_runtime_session, rename_session as rename_runtime_session,
  update_session_config as update_runtime_session_config, SessionConfigUpdate,
};
use crate::runtime::session_registry::SessionRegistry;

pub(crate) async fn handle_end_session(
  session_id: String,
  state: &Arc<SessionRegistry>,
  conn_id: u64,
) {
  info!(
      component = "session",
      event = "session.end.requested",
      connection_id = conn_id,
      session_id = %session_id,
      "End session requested"
  );

  let canceled_shells = end_runtime_session(state, &session_id).await;
  if canceled_shells > 0 {
    info!(
        component = "shell",
        event = "shell.cancel.session_end",
        connection_id = conn_id,
        session_id = %session_id,
        canceled_shells,
        "Canceled active shell commands while ending session"
    );
  }
}

pub(crate) async fn handle_rename_session(
  session_id: String,
  name: Option<String>,
  state: &Arc<SessionRegistry>,
  conn_id: u64,
) {
  info!(
      component = "session",
      event = "session.rename.requested",
      connection_id = conn_id,
      session_id = %session_id,
      has_name = name.is_some(),
      "Rename session requested"
  );

  let _ = rename_runtime_session(state, &session_id, name).await;
}

pub(crate) async fn handle_update_session_config(
  session_id: String,
  update: SessionConfigUpdate,
  state: &Arc<SessionRegistry>,
  conn_id: u64,
) {
  let SessionConfigUpdate {
    approval_policy,
    approval_policy_details,
    sandbox_mode,
    permission_mode,
    collaboration_mode,
    multi_agent,
    personality,
    service_tier,
    developer_instructions,
    model,
    effort,
    ..
  } = update;
  info!(
      component = "session",
      event = "session.config.update_requested",
      connection_id = conn_id,
      session_id = %session_id,
      approval_policy = ?approval_policy,
      approval_policy_details = ?approval_policy_details,
      sandbox_mode = ?sandbox_mode,
      permission_mode = ?permission_mode,
      collaboration_mode = ?collaboration_mode,
      multi_agent = ?multi_agent,
      personality = ?personality,
      service_tier = ?service_tier,
      developer_instructions = ?developer_instructions.as_ref().map(|_| "[set]"),
      model = ?model,
      effort = ?effort,
      "Session config update requested"
  );

  let _ = update_runtime_session_config(
    state,
    &session_id,
    SessionConfigUpdate {
      approval_policy,
      approval_policy_details,
      sandbox_mode,
      approvals_reviewer: None,
      permission_mode,
      collaboration_mode,
      multi_agent,
      personality,
      service_tier,
      developer_instructions,
      model,
      effort,
      codex_config_mode: None,
      codex_config_profile: None,
      codex_model_provider: None,
    },
  )
  .await;
}
