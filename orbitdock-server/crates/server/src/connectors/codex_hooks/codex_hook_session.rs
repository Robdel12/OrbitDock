use std::collections::HashSet;
use std::sync::Arc;

use tokio::sync::mpsc;
use tracing::warn;

use orbitdock_protocol::{
  CodexIntegrationMode, Provider, SessionControlMode, SessionLifecycleState, SessionStatus,
  WorkStatus,
};

use crate::domain::sessions::session::SessionHandle;
use crate::domain::sessions::transition::Input;
use crate::infrastructure::persistence::{
  load_direct_codex_owner_by_thread_id, PersistCommand, SessionCreateParams,
};
use crate::runtime::session_actor::SessionActorHandle;
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::support::session_paths::project_name_from_cwd;

pub(super) enum CodexHookRoutingDecision {
  ManagedDirect { owner_session_id: String },
  IgnoreShadowedByDirect,
  IgnoreOwnershipLookupFailed,
  Passive,
}

#[derive(Clone, Default)]
pub(super) struct CodexHookHandlingOptions {
  transcript_sync_gate: Option<Arc<tokio::sync::Mutex<HashSet<String>>>>,
}

impl CodexHookHandlingOptions {
  pub(super) async fn should_sync_transcript(&self, session_id: &str) -> bool {
    let Some(gate) = self.transcript_sync_gate.as_ref() else {
      return true;
    };

    let mut seen = gate.lock().await;
    seen.insert(session_id.to_string())
  }
}

pub(super) async fn cleanup_codex_shadow_session(
  state: &Arc<SessionRegistry>,
  thread_id: &str,
  reason: &str,
) {
  let _ = state
    .persist()
    .send(PersistCommand::CleanupThreadShadowSession {
      thread_id: thread_id.to_string(),
      reason: reason.to_string(),
    })
    .await;

  let should_remove_runtime_shadow = state.get_session(thread_id).is_some_and(|actor| {
    let snapshot = actor.snapshot();
    snapshot.provider == Provider::Codex
      && snapshot.control_mode != SessionControlMode::Direct
      && snapshot.id == thread_id
  });

  if should_remove_runtime_shadow && state.remove_session(thread_id).is_some() {
    state.publish_active_session_removed(thread_id);
  }
}

pub(super) async fn resolve_codex_hook_routing(
  state: &Arc<SessionRegistry>,
  thread_id: &str,
) -> CodexHookRoutingDecision {
  let managed_owner = state.resolve_codex_thread(thread_id);
  let persisted_owner = if managed_owner.is_none() {
    match load_direct_codex_owner_by_thread_id(thread_id).await {
      Ok(owner) => owner.map(|owner| owner.session_id),
      Err(error) => {
        warn!(
          component = "hook_handler",
          event = "codex.hook.ownership_lookup_failed",
          thread_id = %thread_id,
          error = %error,
          "Failed to resolve Codex direct-session ownership; suppressing hook to avoid shadow session materialization"
        );
        return CodexHookRoutingDecision::IgnoreOwnershipLookupFailed;
      }
    }
  } else {
    None
  };

  let Some(owner_session_id) = managed_owner.or(persisted_owner) else {
    return CodexHookRoutingDecision::Passive;
  };

  let Some(actor) = state.get_session(&owner_session_id) else {
    return CodexHookRoutingDecision::IgnoreShadowedByDirect;
  };

  let snapshot = actor.snapshot();
  if snapshot.provider != Provider::Codex || snapshot.control_mode != SessionControlMode::Direct {
    return CodexHookRoutingDecision::IgnoreShadowedByDirect;
  }

  if snapshot.status != SessionStatus::Active
    || snapshot.lifecycle_state == SessionLifecycleState::Ended
  {
    return CodexHookRoutingDecision::IgnoreShadowedByDirect;
  }

  // Hooks are passive reporters — they never mutate direct session state.
  // The direct session already has its codex_thread_id set via PersistCommand.
  CodexHookRoutingDecision::ManagedDirect { owner_session_id }
}

pub(super) async fn apply_codex_hook_metadata(
  actor: &SessionActorHandle,
  _: &mpsc::Sender<PersistCommand>,
  _: &str,
  model: Option<&String>,
  transcript_path: Option<&String>,
) {
  if let Some(model) = model {
    actor
      .send(SessionCommand::ProcessEvent {
        event: Input::ModelUpdated(model.clone()),
      })
      .await;
  }

  if let Some(transcript_path) = transcript_path {
    actor
      .send(SessionCommand::ProcessEvent {
        event: Input::TranscriptPathUpdated(Some(transcript_path.clone())),
      })
      .await;
  }
}

async fn materialize_codex_session(
  thread_id: &str,
  fallback_cwd: &str,
  fallback_transcript_path: Option<String>,
  fallback_model: Option<String>,
  state: &Arc<SessionRegistry>,
  persist_tx: &mpsc::Sender<PersistCommand>,
) -> SessionActorHandle {
  let pending = state
    .take_pending_hook_session(Provider::Codex, thread_id)
    .and_then(|pending| pending.into_codex());

  let cwd = pending
    .as_ref()
    .map(|pending| pending.cwd.clone())
    .unwrap_or_else(|| fallback_cwd.to_string());
  let model = pending
    .as_ref()
    .and_then(|pending| pending.model.clone())
    .or(fallback_model);
  let transcript_path = pending
    .as_ref()
    .and_then(|pending| pending.transcript_path.clone())
    .or(fallback_transcript_path);

  let mut handle = SessionHandle::new(thread_id.to_string(), Provider::Codex, cwd.clone());
  handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
  handle.set_project_name(project_name_from_cwd(&cwd));
  handle.set_model(model.clone());
  handle.set_transcript_path(transcript_path.clone());
  handle.set_work_status(WorkStatus::Waiting);
  let actor = state.add_session(handle);

  let _ = actor.summary().await;
  state.notify_active_session_updated(thread_id);

  let _ = persist_tx
    .send(PersistCommand::ReactivateSession {
      id: thread_id.to_string(),
    })
    .await;
  let _ = persist_tx
    .send(PersistCommand::SessionCreate(Box::new(
      SessionCreateParams {
        id: thread_id.to_string(),
        provider: Provider::Codex,
        control_mode: SessionControlMode::Passive,
        project_path: cwd.clone(),
        project_name: project_name_from_cwd(&cwd),
        branch: None,
        model: model.clone(),
        approval_policy: None,
        sandbox_mode: None,
        permission_mode: None,
        collaboration_mode: None,
        multi_agent: None,
        personality: None,
        service_tier: None,
        developer_instructions: None,
        codex_config_mode: None,
        codex_config_profile: None,
        codex_model_provider: None,
        codex_config_source: None,
        codex_config_overrides_json: None,
        forked_from_session_id: None,
        mission_id: None,
        issue_identifier: None,
        allow_bypass_permissions: false,
        worktree_id: None,
      },
    )))
    .await;
  let _ = persist_tx
    .send(PersistCommand::SetThreadId {
      session_id: thread_id.to_string(),
      thread_id: thread_id.to_string(),
    })
    .await;
  if let Some(transcript_path) = transcript_path {
    actor
      .send(SessionCommand::ProcessEvent {
        event: Input::TranscriptPathUpdated(Some(transcript_path)),
      })
      .await;
  }
  if let Some(model) = model {
    actor
      .send(SessionCommand::ProcessEvent {
        event: Input::ModelUpdated(model),
      })
      .await;
  }

  actor
}

pub(super) async fn ensure_passive_codex_session(
  state: &Arc<SessionRegistry>,
  session_id: &str,
  cwd: &str,
  transcript_path: Option<String>,
  model: Option<String>,
) -> SessionActorHandle {
  let persist_tx = state.persist().clone();
  if let Some(existing) = state.get_session(session_id) {
    return existing;
  }

  materialize_codex_session(session_id, cwd, transcript_path, model, state, &persist_tx).await
}

pub(super) async fn maybe_claim_direct_codex_session(
  state: &Arc<SessionRegistry>,
  cwd: &str,
  thread_id: &str,
) -> bool {
  let Some(owning_id) = state.find_unregistered_direct_codex_session(cwd) else {
    return false;
  };

  state.register_codex_runtime_owner(thread_id, &owning_id);

  // Write goes through PersistCommand only — single mutation path with immutability guard.
  let persisted = state
    .persist()
    .send(PersistCommand::SetThreadId {
      session_id: owning_id.clone(),
      thread_id: thread_id.to_string(),
    })
    .await
    .is_ok();

  if !persisted {
    state.unregister_codex_runtime_owner(thread_id);
  }

  persisted
}
