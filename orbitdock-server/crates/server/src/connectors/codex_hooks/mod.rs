use std::collections::HashSet;
use std::sync::Arc;
use std::time::Instant;

use serde_json::Value;
use tokio::sync::mpsc;
use tracing::warn;

use orbitdock_protocol::{
  ClientMessage, CodexIntegrationMode, Provider, SessionControlMode, SessionLifecycleState,
  SessionStatus, WorkStatus,
};

use crate::domain::sessions::session::SessionHandle;
use crate::domain::sessions::transition::Input;
use crate::infrastructure::persistence::{
  extract_summary_from_transcript_path, load_direct_codex_owner_by_thread_id, PersistCommand,
  SessionCreateParams,
};
use crate::runtime::session_actor::SessionActorHandle;
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::{PendingCodexSession, PendingHookSession, SessionRegistry};
use crate::runtime::session_runtime_helpers::sync_transcript_messages;
use crate::support::session_paths::project_name_from_cwd;

enum CodexHookRoutingDecision {
  ManagedDirect { owner_session_id: String },
  IgnoreShadowedByDirect,
  IgnoreOwnershipLookupFailed,
  Passive,
}

#[derive(Clone, Default)]
pub struct CodexHookHandlingOptions {
  transcript_sync_gate: Option<Arc<tokio::sync::Mutex<HashSet<String>>>>,
}

impl CodexHookHandlingOptions {
  async fn should_sync_transcript(&self, session_id: &str) -> bool {
    let Some(gate) = self.transcript_sync_gate.as_ref() else {
      return true;
    };

    let mut seen = gate.lock().await;
    seen.insert(session_id.to_string())
  }
}

async fn cleanup_codex_shadow_session(state: &Arc<SessionRegistry>, thread_id: &str, reason: &str) {
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

async fn resolve_codex_hook_routing(
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

async fn apply_codex_hook_metadata(
  actor: &SessionActorHandle,
  _persist_tx: &mpsc::Sender<PersistCommand>,
  _session_id: &str,
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

async fn ensure_passive_codex_session(
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

async fn maybe_claim_direct_codex_session(
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

async fn mark_passive_turn_started(actor: &SessionActorHandle, session_id: &str) {
  crate::runtime::session_state_transitions::transition_work_status(
    actor,
    session_id,
    WorkStatus::Working,
    None,
  )
  .await;
}

async fn mark_passive_turn_stopped(actor: &SessionActorHandle, session_id: &str) {
  crate::runtime::session_state_transitions::transition_work_status(
    actor,
    session_id,
    WorkStatus::Reply,
    None,
  )
  .await;
}

async fn maybe_extract_transcript_summary(
  actor: &SessionActorHandle,
  _persist_tx: &mpsc::Sender<PersistCommand>,
  _session_id: &str,
  transcript_path: Option<&String>,
) {
  let snapshot = actor.snapshot();
  if snapshot.summary.is_some() {
    return;
  }

  let path = snapshot
    .transcript_path
    .clone()
    .or_else(|| transcript_path.cloned());
  let Some(path) = path else {
    return;
  };

  let Some(summary) = extract_summary_from_transcript_path(&path).await else {
    return;
  };

  actor
    .send(SessionCommand::ProcessEvent {
      event: crate::domain::sessions::transition::Input::SummaryUpdated(summary),
    })
    .await;
}

fn serialized_tool_input(tool_input: Option<&Value>) -> Option<String> {
  tool_input.and_then(|value| serde_json::to_string(value).ok())
}

fn codex_tool_question(tool_input: Option<&Value>) -> Option<String> {
  tool_input
    .and_then(|value| value.get("question"))
    .and_then(Value::as_str)
    .map(str::to_string)
}

async fn maybe_sync_transcript_messages(
  actor: &SessionActorHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
  session_id: &str,
  options: &CodexHookHandlingOptions,
) {
  if !options.should_sync_transcript(session_id).await {
    return;
  }

  sync_transcript_messages(actor, persist_tx).await;
}

async fn handle_codex_pre_tool_use(
  actor: &SessionActorHandle,
  session_id: &str,
  tool_name: &str,
  tool_input: Option<&Value>,
) {
  let serialized_input = serialized_tool_input(tool_input);
  let pending_question = codex_tool_question(tool_input);

  let ws = if pending_question.is_some() {
    WorkStatus::Question
  } else {
    WorkStatus::Working
  };

  let attention_reason = crate::runtime::session_state_transitions::attention_reason_for_status(ws);
  actor
    .send(SessionCommand::ProcessEvent {
      event: Input::AttentionUpdated {
        attention_reason,
        last_tool: Some(tool_name.to_string()),
        pending_tool_name: Some(Some(tool_name.to_string())),
        pending_tool_input: Some(serialized_input),
        pending_question: Some(pending_question),
      },
    })
    .await;
  crate::runtime::session_state_transitions::transition_work_status(actor, session_id, ws, None)
    .await;
}

async fn handle_codex_post_tool_use(
  actor: &SessionActorHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
  session_id: &str,
) {
  actor
    .send(SessionCommand::ProcessEvent {
      event: Input::AttentionUpdated {
        attention_reason: Some(Some("none".to_string())),
        last_tool: None,
        pending_tool_name: Some(None),
        pending_tool_input: Some(None),
        pending_question: Some(None),
      },
    })
    .await;
  mark_passive_turn_started(actor, session_id).await;
  let _ = persist_tx
    .send(PersistCommand::ToolCountIncrement {
      session_id: session_id.to_string(),
    })
    .await;
}

pub async fn handle_hook_message(msg: ClientMessage, state: &Arc<SessionRegistry>) {
  handle_hook_message_with_options(msg, state, CodexHookHandlingOptions::default()).await;
}

pub async fn handle_hook_message_with_options(
  msg: ClientMessage,
  state: &Arc<SessionRegistry>,
  options: CodexHookHandlingOptions,
) {
  match msg {
    ClientMessage::CodexSessionStart {
      session_id,
      cwd,
      transcript_path,
      model,
      source: _,
    } => {
      match resolve_codex_hook_routing(state, &session_id).await {
        CodexHookRoutingDecision::ManagedDirect { .. } => {
          cleanup_codex_shadow_session(state, &session_id, "managed_direct_session").await;
          return;
        }
        CodexHookRoutingDecision::IgnoreShadowedByDirect => {
          cleanup_codex_shadow_session(state, &session_id, "direct_owner_exists").await;
          return;
        }
        CodexHookRoutingDecision::IgnoreOwnershipLookupFailed => {
          return;
        }
        CodexHookRoutingDecision::Passive => {}
      }

      if maybe_claim_direct_codex_session(state, &cwd, &session_id).await {
        return;
      }

      let persist_tx = state.persist().clone();
      if let Some(existing) = state.get_session(&session_id) {
        if existing.snapshot().provider == Provider::Claude {
          return;
        }
        apply_codex_hook_metadata(
          &existing,
          &persist_tx,
          &session_id,
          model.as_ref(),
          transcript_path.as_ref(),
        )
        .await;
        return;
      }

      state.cache_pending_hook_session(
        session_id,
        PendingHookSession::Codex(PendingCodexSession {
          cwd,
          model,
          transcript_path,
          cached_at: Instant::now(),
        }),
      );
    }

    ClientMessage::CodexUserPromptSubmit {
      session_id,
      cwd,
      transcript_path,
      model,
      turn_id: _,
      prompt,
    } => {
      match resolve_codex_hook_routing(state, &session_id).await {
        CodexHookRoutingDecision::ManagedDirect { owner_session_id } => {
          cleanup_codex_shadow_session(state, &session_id, "managed_direct_session").await;
          if let Some(actor) = state.get_session(&owner_session_id) {
            let persist_tx = state.persist().clone();
            apply_codex_hook_metadata(
              &actor,
              &persist_tx,
              &owner_session_id,
              model.as_ref(),
              transcript_path.as_ref(),
            )
            .await;
          }
          return;
        }
        CodexHookRoutingDecision::IgnoreShadowedByDirect => {
          cleanup_codex_shadow_session(state, &session_id, "direct_owner_exists").await;
          return;
        }
        CodexHookRoutingDecision::IgnoreOwnershipLookupFailed => {
          return;
        }
        CodexHookRoutingDecision::Passive => {}
      }

      let actor = ensure_passive_codex_session(
        state,
        &session_id,
        &cwd,
        transcript_path.clone(),
        model.clone(),
      )
      .await;
      let persist_tx = state.persist().clone();
      apply_codex_hook_metadata(
        &actor,
        &persist_tx,
        &session_id,
        model.as_ref(),
        transcript_path.as_ref(),
      )
      .await;
      mark_passive_turn_started(&actor, &session_id).await;
      let _ = actor.summary().await;

      let _ = persist_tx
        .send(PersistCommand::CodexPromptIncrement {
          id: session_id.clone(),
          first_prompt: Some(prompt.clone()),
        })
        .await;
    }

    ClientMessage::CodexStopEvent {
      session_id,
      cwd,
      transcript_path,
      model,
      turn_id: _,
      stop_hook_active: _,
      last_assistant_message: _,
    } => {
      match resolve_codex_hook_routing(state, &session_id).await {
        CodexHookRoutingDecision::ManagedDirect { owner_session_id } => {
          cleanup_codex_shadow_session(state, &session_id, "managed_direct_session").await;
          if let Some(actor) = state.get_session(&owner_session_id) {
            let persist_tx = state.persist().clone();
            apply_codex_hook_metadata(
              &actor,
              &persist_tx,
              &owner_session_id,
              model.as_ref(),
              transcript_path.as_ref(),
            )
            .await;
            let _ = actor.summary().await;
            maybe_sync_transcript_messages(&actor, &persist_tx, &owner_session_id, &options).await;
            maybe_extract_transcript_summary(
              &actor,
              &persist_tx,
              &owner_session_id,
              transcript_path.as_ref(),
            )
            .await;
          }
          return;
        }
        CodexHookRoutingDecision::IgnoreShadowedByDirect => {
          cleanup_codex_shadow_session(state, &session_id, "direct_owner_exists").await;
          return;
        }
        CodexHookRoutingDecision::IgnoreOwnershipLookupFailed => {
          return;
        }
        CodexHookRoutingDecision::Passive => {}
      }

      let actor = ensure_passive_codex_session(
        state,
        &session_id,
        &cwd,
        transcript_path.clone(),
        model.clone(),
      )
      .await;
      let persist_tx = state.persist().clone();
      apply_codex_hook_metadata(
        &actor,
        &persist_tx,
        &session_id,
        model.as_ref(),
        transcript_path.as_ref(),
      )
      .await;
      let _ = actor.summary().await;
      maybe_sync_transcript_messages(&actor, &persist_tx, &session_id, &options).await;
      mark_passive_turn_stopped(&actor, &session_id).await;
      maybe_extract_transcript_summary(&actor, &persist_tx, &session_id, transcript_path.as_ref())
        .await;
    }

    ClientMessage::CodexToolEvent {
      session_id,
      cwd,
      transcript_path,
      model,
      hook_event_name,
      turn_id: _,
      tool_name,
      tool_use_id: _,
      tool_input,
      tool_response: _,
    } => {
      match resolve_codex_hook_routing(state, &session_id).await {
        CodexHookRoutingDecision::ManagedDirect { owner_session_id } => {
          cleanup_codex_shadow_session(state, &session_id, "managed_direct_session").await;
          if let Some(actor) = state.get_session(&owner_session_id) {
            let persist_tx = state.persist().clone();
            apply_codex_hook_metadata(
              &actor,
              &persist_tx,
              &owner_session_id,
              model.as_ref(),
              transcript_path.as_ref(),
            )
            .await;

            match hook_event_name.as_str() {
              "PreToolUse" => {
                handle_codex_pre_tool_use(
                  &actor,
                  &owner_session_id,
                  &tool_name,
                  tool_input.as_ref(),
                )
                .await;
              }
              "PostToolUse" | "PostToolUseFailure" => {
                handle_codex_post_tool_use(&actor, &persist_tx, &owner_session_id).await;
              }
              _ => {}
            }
          }
          return;
        }
        CodexHookRoutingDecision::IgnoreShadowedByDirect => {
          cleanup_codex_shadow_session(state, &session_id, "direct_owner_exists").await;
          return;
        }
        CodexHookRoutingDecision::IgnoreOwnershipLookupFailed => {
          return;
        }
        CodexHookRoutingDecision::Passive => {}
      }

      let actor = ensure_passive_codex_session(
        state,
        &session_id,
        &cwd,
        transcript_path.clone(),
        model.clone(),
      )
      .await;
      let persist_tx = state.persist().clone();
      apply_codex_hook_metadata(
        &actor,
        &persist_tx,
        &session_id,
        model.as_ref(),
        transcript_path.as_ref(),
      )
      .await;

      match hook_event_name.as_str() {
        "PreToolUse" => {
          handle_codex_pre_tool_use(&actor, &session_id, &tool_name, tool_input.as_ref()).await;
        }
        "PostToolUse" | "PostToolUseFailure" => {
          handle_codex_post_tool_use(&actor, &persist_tx, &session_id).await;
        }
        _ => {}
      }
    }

    _ => {}
  }
}

#[cfg(test)]
#[path = "codex_hooks_tests.rs"]
mod tests;
