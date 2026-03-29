use std::sync::Arc;

use tokio::sync::mpsc;

use orbitdock_protocol::ClientMessage;

use crate::runtime::session_mutations::SessionConfigUpdate;
use crate::runtime::session_registry::SessionRegistry;
use crate::transport::websocket::handlers::session_management::{
  handle_end_session, handle_rename_session, handle_update_session_config,
};
use crate::transport::websocket::OutboundMessage;

pub(crate) async fn handle(
  msg: ClientMessage,
  client_tx: &mpsc::Sender<OutboundMessage>,
  state: &Arc<SessionRegistry>,
  conn_id: u64,
) {
  match msg {
    ClientMessage::EndSession { session_id } => {
      handle_end_session(session_id, state, conn_id).await;
    }
    ClientMessage::RenameSession { session_id, name } => {
      handle_rename_session(session_id, name, state, conn_id).await;
    }
    ClientMessage::UpdateSessionConfig {
      session_id,
      approval_policy,
      approval_policy_details,
      sandbox_mode,
      approvals_reviewer,
      permission_mode,
      collaboration_mode,
      multi_agent,
      personality,
      service_tier,
      developer_instructions,
      model,
      effort,
    } => {
      handle_update_session_config(
        session_id,
        SessionConfigUpdate {
          approval_policy: Some(approval_policy),
          approval_policy_details: Some(approval_policy_details),
          sandbox_mode: Some(sandbox_mode),
          approvals_reviewer: Some(approvals_reviewer),
          permission_mode: Some(permission_mode),
          collaboration_mode: Some(collaboration_mode),
          multi_agent: Some(multi_agent),
          personality: Some(personality),
          service_tier: Some(service_tier),
          developer_instructions: Some(developer_instructions),
          model: Some(model),
          effort: Some(effort),
          codex_config_mode: None,
          codex_config_profile: None,
          codex_model_provider: None,
        },
        state,
        conn_id,
      )
      .await;
    }
    _ => {
      let _ = client_tx;
      tracing::warn!(?msg, "session_crud::handle called with unexpected variant");
    }
  }
}
