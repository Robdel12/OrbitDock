use std::collections::HashSet;
use std::sync::Arc;

use tracing::warn;

use orbitdock_protocol::{Provider, SessionControlMode, SessionLifecycleState, SessionStatus};

use crate::infrastructure::persistence::load_direct_claude_owner_by_sdk_session_id;
use crate::runtime::session_registry::SessionRegistry;

#[derive(Clone, Default)]
pub struct ClaudeHookHandlingOptions {
  transcript_sync_gate: Option<Arc<tokio::sync::Mutex<HashSet<String>>>>,
}

impl ClaudeHookHandlingOptions {
  pub(crate) async fn should_sync_transcript(&self, session_id: &str) -> bool {
    let Some(gate) = self.transcript_sync_gate.as_ref() else {
      return true;
    };

    let mut seen = gate.lock().await;
    seen.insert(session_id.to_string())
  }
}

pub enum ClaudeHookRoutingDecision {
  ManagedDirect { owner_session_id: String },
  IgnoreShadowedByDirect,
  IgnoreOwnershipLookupFailed,
  Passive,
}

pub async fn cleanup_claude_shadow_session(
  state: &Arc<SessionRegistry>,
  hook_session_id: &str,
  reason: &str,
) {
  let _ = state
    .persist()
    .send(
      crate::infrastructure::persistence::PersistCommand::CleanupClaudeShadowSession {
        claude_sdk_session_id: hook_session_id.to_string(),
        reason: reason.to_string(),
      },
    )
    .await;

  let should_remove_runtime_shadow = state.get_session(hook_session_id).is_some_and(|actor| {
    let snapshot = actor.snapshot();
    snapshot.provider == Provider::Claude
      && snapshot.control_mode != SessionControlMode::Direct
      && snapshot.id == hook_session_id
  });

  if should_remove_runtime_shadow && state.remove_session(hook_session_id).is_some() {
    state.publish_active_session_removed(hook_session_id);
  }
}

pub async fn resolve_claude_hook_routing(
  state: &Arc<SessionRegistry>,
  hook_session_id: &str,
) -> ClaudeHookRoutingDecision {
  let managed_owner = state.resolve_claude_thread(hook_session_id);
  let persisted_owner = if managed_owner.is_none() {
    match load_direct_claude_owner_by_sdk_session_id(hook_session_id).await {
      Ok(owner) => owner.map(|owner| owner.session_id),
      Err(error) => {
        warn!(
            component = "hook_handler",
            event = "claude.hook.ownership_lookup_failed",
            session_id = %hook_session_id,
            error = %error,
            "Failed to resolve Claude direct-session ownership; suppressing hook to avoid shadow session materialization"
        );
        return ClaudeHookRoutingDecision::IgnoreOwnershipLookupFailed;
      }
    }
  } else {
    None
  };

  let Some(owner_session_id) = managed_owner.or(persisted_owner) else {
    return ClaudeHookRoutingDecision::Passive;
  };

  let Some(actor) = state.get_session(&owner_session_id) else {
    return ClaudeHookRoutingDecision::IgnoreShadowedByDirect;
  };

  let snapshot = actor.snapshot();
  if snapshot.provider != Provider::Claude || snapshot.control_mode != SessionControlMode::Direct {
    return ClaudeHookRoutingDecision::IgnoreShadowedByDirect;
  }

  if snapshot.status != SessionStatus::Active
    || snapshot.lifecycle_state == SessionLifecycleState::Ended
  {
    return ClaudeHookRoutingDecision::IgnoreShadowedByDirect;
  }

  // Hooks are passive reporters — they never mutate direct session state.
  // The direct session already has its claude_sdk_session_id set via PersistCommand.
  ClaudeHookRoutingDecision::ManagedDirect { owner_session_id }
}
