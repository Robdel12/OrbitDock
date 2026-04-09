use std::sync::Arc;

use orbitdock_protocol::{Provider, ServerMessage};

use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_registry::SessionRegistry;

use super::routing::{
  cleanup_claude_shadow_session, resolve_claude_hook_routing, ClaudeHookRoutingDecision,
};

pub(crate) async fn handle_claude_session_end(
  state: &Arc<SessionRegistry>,
  session_id: String,
  reason: Option<String>,
) {
  match resolve_claude_hook_routing(state, &session_id).await {
    ClaudeHookRoutingDecision::ManagedDirect {
      owner_session_id: _,
    } => {
      cleanup_claude_shadow_session(state, &session_id, "managed_direct_session").await;
      return;
    }
    ClaudeHookRoutingDecision::IgnoreShadowedByDirect => {
      cleanup_claude_shadow_session(state, &session_id, "direct_owner_exists").await;
      return;
    }
    ClaudeHookRoutingDecision::IgnoreOwnershipLookupFailed => {
      return;
    }
    ClaudeHookRoutingDecision::Passive => {}
  }

  if state.discard_pending_hook_session(Provider::Claude, &session_id) {
    return;
  }

  let persist_tx = state.persist().clone();

  if let Some(existing) = state.get_session(&session_id) {
    if existing.snapshot().provider == Provider::Codex {
      return;
    }

    if let Some(transcript_path) = &existing.snapshot().transcript_path {
      if let Some(summary) =
        crate::infrastructure::persistence::extract_summary_from_transcript_path(transcript_path)
          .await
      {
        let _ = persist_tx
          .send(PersistCommand::SetSummary {
            session_id: session_id.clone(),
            summary,
          })
          .await;
      }
    }
  }

  let _ = persist_tx
    .send(PersistCommand::ClaudeSessionEnd {
      id: session_id.clone(),
      reason: reason.clone(),
    })
    .await;

  if state.remove_session(&session_id).is_some() {
    let _ = state.list_tx().send(ServerMessage::DashboardItemRemoved {
      session_id: session_id.clone(),
    });
  }
}
