use std::collections::HashSet;
use std::sync::Arc;
use std::time::Instant;

use serde_json::Value;
use tokio::sync::mpsc;
use tracing::warn;

use orbitdock_protocol::{
  ClientMessage, CodexIntegrationMode, Provider, SessionControlMode, SessionLifecycleState,
  SessionStatus, StateChanges, WorkStatus,
};

use crate::domain::sessions::session::SessionHandle;
use crate::infrastructure::persistence::{
  extract_summary_from_transcript_path, load_direct_codex_owner_by_thread_id, PersistCommand,
  SessionCreateParams,
};
use crate::runtime::session_actor::SessionActorHandle;
use crate::runtime::session_commands::{PersistOp, SessionCommand};
use crate::runtime::session_registry::{PendingCodexSession, PendingHookSession, SessionRegistry};
use crate::runtime::session_runtime_helpers::sync_transcript_messages;
use crate::support::session_paths::project_name_from_cwd;
use crate::support::session_time::chrono_now;

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
  pub fn for_spool_replay() -> Self {
    Self {
      transcript_sync_gate: Some(Arc::new(tokio::sync::Mutex::new(HashSet::new()))),
    }
  }

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
    state.publish_dashboard_snapshot();
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

  state.register_codex_thread(&owner_session_id, thread_id);
  CodexHookRoutingDecision::ManagedDirect { owner_session_id }
}

async fn apply_codex_hook_metadata(
  actor: &SessionActorHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
  session_id: &str,
  model: Option<&String>,
  transcript_path: Option<&String>,
) {
  if let Some(model) = model {
    actor
      .send(SessionCommand::SetModel {
        model: Some(model.clone()),
      })
      .await;
    let _ = persist_tx
      .send(PersistCommand::ModelUpdate {
        session_id: session_id.to_string(),
        model: model.clone(),
      })
      .await;
  }

  if let Some(transcript_path) = transcript_path {
    actor
      .send(SessionCommand::SetTranscriptPath {
        path: Some(transcript_path.clone()),
      })
      .await;
    let _ = persist_tx
      .send(PersistCommand::SetTranscriptPath {
        session_id: session_id.to_string(),
        transcript_path: Some(transcript_path.clone()),
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
  state.publish_dashboard_snapshot();

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
    let _ = persist_tx
      .send(PersistCommand::SetTranscriptPath {
        session_id: thread_id.to_string(),
        transcript_path: Some(transcript_path),
      })
      .await;
  }
  if let Some(model) = model {
    let _ = persist_tx
      .send(PersistCommand::ModelUpdate {
        session_id: thread_id.to_string(),
        model,
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

  state.register_codex_thread(&owning_id, thread_id);
  let _ = state
    .persist()
    .send(PersistCommand::SetThreadId {
      session_id: owning_id,
      thread_id: thread_id.to_string(),
    })
    .await;
  true
}

async fn mark_passive_turn_started(actor: &SessionActorHandle, session_id: &str) {
  let now = chrono_now();
  actor
    .send(SessionCommand::ApplyDelta {
      changes: Box::new(StateChanges {
        work_status: Some(WorkStatus::Working),
        last_activity_at: Some(now.clone()),
        ..Default::default()
      }),
      persist_op: Some(PersistOp::SessionUpdate {
        id: session_id.to_string(),
        status: None,
        work_status: Some(WorkStatus::Working),
        lifecycle_state: None,
        last_activity_at: Some(now),
        last_progress_at: None,
      }),
    })
    .await;
}

async fn mark_passive_turn_stopped(actor: &SessionActorHandle, session_id: &str) {
  let now = chrono_now();
  actor
    .send(SessionCommand::ApplyDelta {
      changes: Box::new(StateChanges {
        work_status: Some(WorkStatus::Waiting),
        last_activity_at: Some(now.clone()),
        ..Default::default()
      }),
      persist_op: Some(PersistOp::SessionUpdate {
        id: session_id.to_string(),
        status: None,
        work_status: Some(WorkStatus::Waiting),
        lifecycle_state: None,
        last_activity_at: Some(now),
        last_progress_at: None,
      }),
    })
    .await;
}

async fn maybe_extract_transcript_summary(
  actor: &SessionActorHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
  session_id: &str,
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
    .send(SessionCommand::ApplyDelta {
      changes: Box::new(StateChanges {
        summary: Some(Some(summary.clone())),
        ..Default::default()
      }),
      persist_op: None,
    })
    .await;
  let _ = persist_tx
    .send(PersistCommand::SetSummary {
      session_id: session_id.to_string(),
      summary,
    })
    .await;
}

async fn persist_session_attention(
  persist_tx: &mpsc::Sender<PersistCommand>,
  session_id: &str,
  update: SessionAttentionUpdate,
) {
  let _ = persist_tx
    .send(PersistCommand::SessionAttentionUpdate {
      session_id: session_id.to_string(),
      attention_reason: update.attention_reason,
      last_tool: update.last_tool,
      last_tool_at: update.last_tool_at,
      pending_tool_name: update.pending_tool_name,
      pending_tool_input: update.pending_tool_input,
      pending_question: update.pending_question,
    })
    .await;
}

struct SessionAttentionUpdate {
  attention_reason: Option<Option<String>>,
  last_tool: Option<Option<String>>,
  last_tool_at: Option<Option<String>>,
  pending_tool_name: Option<Option<String>>,
  pending_tool_input: Option<Option<String>>,
  pending_question: Option<Option<String>>,
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
  persist_tx: &mpsc::Sender<PersistCommand>,
  session_id: &str,
  tool_name: &str,
  tool_input: Option<&Value>,
) {
  let serialized_input = serialized_tool_input(tool_input);
  let pending_question = codex_tool_question(tool_input);

  actor
    .send(SessionCommand::SetLastTool {
      tool: Some(tool_name.to_string()),
    })
    .await;
  mark_passive_turn_started(actor, session_id).await;
  actor
    .send(SessionCommand::SetPendingAttention {
      pending_tool_name: Some(tool_name.to_string()),
      pending_tool_input: serialized_input.clone(),
      pending_question: pending_question.clone(),
    })
    .await;
  persist_session_attention(
    persist_tx,
    session_id,
    SessionAttentionUpdate {
      attention_reason: Some(Some("none".to_string())),
      last_tool: Some(Some(tool_name.to_string())),
      last_tool_at: Some(Some(chrono_now())),
      pending_tool_name: Some(Some(tool_name.to_string())),
      pending_tool_input: Some(serialized_input),
      pending_question: Some(pending_question),
    },
  )
  .await;
}

async fn handle_codex_post_tool_use(
  actor: &SessionActorHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
  session_id: &str,
) {
  actor
    .send(SessionCommand::SetPendingAttention {
      pending_tool_name: None,
      pending_tool_input: None,
      pending_question: None,
    })
    .await;
  mark_passive_turn_started(actor, session_id).await;
  let _ = persist_tx
    .send(PersistCommand::ToolCountIncrement {
      session_id: session_id.to_string(),
    })
    .await;
  persist_session_attention(
    persist_tx,
    session_id,
    SessionAttentionUpdate {
      attention_reason: Some(Some("none".to_string())),
      last_tool: None,
      last_tool_at: None,
      pending_tool_name: Some(None),
      pending_tool_input: Some(None),
      pending_question: Some(None),
    },
  )
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
                  &persist_tx,
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
          handle_codex_pre_tool_use(
            &actor,
            &persist_tx,
            &session_id,
            &tool_name,
            tool_input.as_ref(),
          )
          .await;
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
mod tests {
  use super::{handle_hook_message, CodexHookHandlingOptions};
  use crate::domain::sessions::session::SessionHandle;
  use crate::infrastructure::persistence::PersistCommand;
  use crate::runtime::session_registry::SessionRegistry;
  use crate::support::test_support::ensure_server_test_data_dir;
  use orbitdock_protocol::{
    ClientMessage, CodexIntegrationMode, Provider, SessionControlMode, WorkStatus,
  };
  use serde_json::json;
  use std::sync::Arc;
  use tokio::sync::mpsc;

  fn collect_persist_commands(rx: &mut mpsc::Receiver<PersistCommand>) -> Vec<PersistCommand> {
    let mut commands = Vec::new();
    while let Ok(command) = rx.try_recv() {
      commands.push(command);
    }
    commands
  }

  #[tokio::test]
  async fn user_prompt_materializes_passive_codex_session_and_persists_metadata() {
    ensure_server_test_data_dir();
    let (persist_tx, mut persist_rx) = mpsc::channel(64);
    let state = Arc::new(SessionRegistry::new_with_primary(persist_tx, true));

    handle_hook_message(
      ClientMessage::CodexSessionStart {
        session_id: "codex-thread-passive".to_string(),
        cwd: "/tmp/codex-passive".to_string(),
        transcript_path: Some("/tmp/codex-passive/transcript.jsonl".to_string()),
        model: Some("gpt-5-codex".to_string()),
        source: Some("startup".to_string()),
      },
      &state,
    )
    .await;

    handle_hook_message(
      ClientMessage::CodexUserPromptSubmit {
        session_id: "codex-thread-passive".to_string(),
        cwd: "/tmp/codex-passive".to_string(),
        transcript_path: Some("/tmp/codex-passive/transcript.jsonl".to_string()),
        model: Some("gpt-5-codex".to_string()),
        turn_id: "turn-1".to_string(),
        prompt: "Ship the fix".to_string(),
      },
      &state,
    )
    .await;

    tokio::task::yield_now().await;
    tokio::task::yield_now().await;

    let actor = state
      .get_session("codex-thread-passive")
      .expect("passive session should materialize");
    let snapshot = actor.snapshot();
    assert_eq!(snapshot.provider, Provider::Codex);
    assert_eq!(snapshot.control_mode, SessionControlMode::Passive);
    assert_eq!(
      snapshot.codex_integration_mode,
      Some(CodexIntegrationMode::Passive)
    );
    assert_eq!(
      snapshot.transcript_path.as_deref(),
      Some("/tmp/codex-passive/transcript.jsonl")
    );
    assert_eq!(snapshot.model.as_deref(), Some("gpt-5-codex"));
    assert_eq!(snapshot.work_status, WorkStatus::Working);

    let commands = collect_persist_commands(&mut persist_rx);
    assert!(commands.iter().any(|command| matches!(
      command,
      PersistCommand::ReactivateSession { id } if id == "codex-thread-passive"
    )));
    assert!(commands.iter().any(|command| matches!(
      command,
      PersistCommand::SessionCreate(params)
        if params.id == "codex-thread-passive"
          && params.control_mode == SessionControlMode::Passive
    )));
    assert!(commands.iter().any(|command| matches!(
      command,
      PersistCommand::SetThreadId { session_id, thread_id }
        if session_id == "codex-thread-passive" && thread_id == "codex-thread-passive"
    )));
    assert!(commands.iter().any(|command| matches!(
      command,
      PersistCommand::SetTranscriptPath { session_id, transcript_path }
        if session_id == "codex-thread-passive"
          && transcript_path.as_deref() == Some("/tmp/codex-passive/transcript.jsonl")
    )));
    assert!(commands.iter().any(|command| matches!(
      command,
      PersistCommand::ModelUpdate { session_id, model }
        if session_id == "codex-thread-passive" && model == "gpt-5-codex"
    )));
    assert!(commands.iter().any(|command| matches!(
      command,
      PersistCommand::CodexPromptIncrement { id, first_prompt }
        if id == "codex-thread-passive" && first_prompt.as_deref() == Some("Ship the fix")
    )));
  }

  #[tokio::test]
  async fn direct_codex_hook_traffic_updates_owner_without_materializing_shadow() {
    ensure_server_test_data_dir();
    let (persist_tx, mut persist_rx) = mpsc::channel(64);
    let state = Arc::new(SessionRegistry::new_with_primary(persist_tx, true));

    let mut handle = SessionHandle::new(
      "od-direct-codex".to_string(),
      Provider::Codex,
      "/tmp/codex-direct".to_string(),
    );
    handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
    state.add_session(handle);
    state.register_codex_thread("od-direct-codex", "codex-thread-direct");

    handle_hook_message(
      ClientMessage::CodexUserPromptSubmit {
        session_id: "codex-thread-direct".to_string(),
        cwd: "/tmp/codex-direct".to_string(),
        transcript_path: Some("/tmp/codex-direct/transcript.jsonl".to_string()),
        model: Some("gpt-5-codex".to_string()),
        turn_id: "turn-1".to_string(),
        prompt: "Keep working".to_string(),
      },
      &state,
    )
    .await;

    tokio::task::yield_now().await;
    tokio::task::yield_now().await;

    assert!(state.get_session("codex-thread-direct").is_none());
    let owner = state
      .get_session("od-direct-codex")
      .expect("direct owner should still exist");
    let snapshot = owner.snapshot();
    assert_eq!(
      snapshot.codex_integration_mode,
      Some(CodexIntegrationMode::Direct)
    );
    assert_eq!(
      snapshot.transcript_path.as_deref(),
      Some("/tmp/codex-direct/transcript.jsonl")
    );
    assert_eq!(snapshot.model.as_deref(), Some("gpt-5-codex"));

    let commands = collect_persist_commands(&mut persist_rx);
    assert!(!commands.iter().any(|command| matches!(
      command,
      PersistCommand::SessionCreate(params) if params.id == "codex-thread-direct"
    )));
    assert!(commands.iter().any(|command| matches!(
      command,
      PersistCommand::SetTranscriptPath { session_id, transcript_path }
        if session_id == "od-direct-codex"
          && transcript_path.as_deref() == Some("/tmp/codex-direct/transcript.jsonl")
    )));
    assert!(commands.iter().any(|command| matches!(
      command,
      PersistCommand::ModelUpdate { session_id, model }
        if session_id == "od-direct-codex" && model == "gpt-5-codex"
    )));
  }

  #[tokio::test]
  async fn passive_pre_tool_use_sets_pending_attention_and_persists_it() {
    ensure_server_test_data_dir();
    let (persist_tx, mut persist_rx) = mpsc::channel(64);
    let state = Arc::new(SessionRegistry::new_with_primary(persist_tx, true));

    handle_hook_message(
      ClientMessage::CodexToolEvent {
        session_id: "codex-thread-tool-passive".to_string(),
        cwd: "/tmp/codex-tool-passive".to_string(),
        transcript_path: Some("/tmp/codex-tool-passive/transcript.jsonl".to_string()),
        model: Some("gpt-5-codex".to_string()),
        hook_event_name: "PreToolUse".to_string(),
        turn_id: "turn-1".to_string(),
        tool_name: "Bash".to_string(),
        tool_use_id: Some("toolu_123".to_string()),
        tool_input: Some(json!({
          "command": "cargo test -p orbitdock-server",
          "question": "Run the focused server tests?"
        })),
        tool_response: None,
      },
      &state,
    )
    .await;

    tokio::task::yield_now().await;
    tokio::task::yield_now().await;

    let actor = state
      .get_session("codex-thread-tool-passive")
      .expect("passive tool hook should materialize a session");
    let snapshot = actor.snapshot();
    assert_eq!(snapshot.provider, Provider::Codex);
    assert_eq!(snapshot.control_mode, SessionControlMode::Passive);
    assert_eq!(snapshot.work_status, WorkStatus::Working);
    assert_eq!(snapshot.pending_tool_name.as_deref(), Some("Bash"));
    assert_eq!(
      snapshot.pending_tool_input.as_deref(),
      Some("{\"command\":\"cargo test -p orbitdock-server\",\"question\":\"Run the focused server tests?\"}")
    );
    assert_eq!(
      snapshot.pending_question.as_deref(),
      Some("Run the focused server tests?")
    );

    let commands = collect_persist_commands(&mut persist_rx);
    assert!(commands.iter().any(|command| matches!(
      command,
      PersistCommand::SessionAttentionUpdate {
        session_id,
        attention_reason,
        last_tool,
        last_tool_at,
        pending_tool_name,
        pending_tool_input,
        pending_question,
      }
        if session_id == "codex-thread-tool-passive"
          && attention_reason.as_ref() == Some(&Some("none".to_string()))
          && last_tool.as_ref() == Some(&Some("Bash".to_string()))
          && last_tool_at.as_ref().is_some_and(|value| value.is_some())
          && pending_tool_name.as_ref() == Some(&Some("Bash".to_string()))
          && pending_tool_input.as_ref()
            == Some(&Some("{\"command\":\"cargo test -p orbitdock-server\",\"question\":\"Run the focused server tests?\"}".to_string()))
          && pending_question.as_ref() == Some(&Some("Run the focused server tests?".to_string()))
    )));
  }

  #[tokio::test]
  async fn passive_post_tool_use_clears_pending_attention_and_increments_tool_count() {
    ensure_server_test_data_dir();
    let (persist_tx, mut persist_rx) = mpsc::channel(64);
    let state = Arc::new(SessionRegistry::new_with_primary(persist_tx, true));

    handle_hook_message(
      ClientMessage::CodexToolEvent {
        session_id: "codex-thread-tool-finish".to_string(),
        cwd: "/tmp/codex-tool-finish".to_string(),
        transcript_path: Some("/tmp/codex-tool-finish/transcript.jsonl".to_string()),
        model: Some("gpt-5-codex".to_string()),
        hook_event_name: "PreToolUse".to_string(),
        turn_id: "turn-1".to_string(),
        tool_name: "Bash".to_string(),
        tool_use_id: Some("toolu_pre".to_string()),
        tool_input: Some(json!({ "command": "pwd" })),
        tool_response: None,
      },
      &state,
    )
    .await;

    handle_hook_message(
      ClientMessage::CodexToolEvent {
        session_id: "codex-thread-tool-finish".to_string(),
        cwd: "/tmp/codex-tool-finish".to_string(),
        transcript_path: Some("/tmp/codex-tool-finish/transcript.jsonl".to_string()),
        model: Some("gpt-5-codex".to_string()),
        hook_event_name: "PostToolUseFailure".to_string(),
        turn_id: "turn-1".to_string(),
        tool_name: "Bash".to_string(),
        tool_use_id: Some("toolu_post".to_string()),
        tool_input: Some(json!({ "command": "pwd" })),
        tool_response: Some(json!("permission denied")),
      },
      &state,
    )
    .await;

    tokio::task::yield_now().await;
    tokio::task::yield_now().await;

    let actor = state
      .get_session("codex-thread-tool-finish")
      .expect("passive tool hook session should exist");
    let snapshot = actor.snapshot();
    assert_eq!(snapshot.work_status, WorkStatus::Working);
    assert_eq!(snapshot.pending_tool_name, None);
    assert_eq!(snapshot.pending_tool_input, None);
    assert_eq!(snapshot.pending_question, None);

    let commands = collect_persist_commands(&mut persist_rx);
    assert!(commands.iter().any(|command| matches!(
      command,
      PersistCommand::ToolCountIncrement { session_id }
        if session_id == "codex-thread-tool-finish"
    )));
    assert!(commands.iter().any(|command| matches!(
      command,
      PersistCommand::SessionAttentionUpdate {
        session_id,
        attention_reason,
        last_tool,
        last_tool_at,
        pending_tool_name,
        pending_tool_input,
        pending_question,
      }
        if session_id == "codex-thread-tool-finish"
          && attention_reason.as_ref() == Some(&Some("none".to_string()))
          && last_tool.is_none()
          && last_tool_at.is_none()
          && pending_tool_name.as_ref() == Some(&None)
          && pending_tool_input.as_ref() == Some(&None)
          && pending_question.as_ref() == Some(&None)
    )));
  }

  #[tokio::test]
  async fn direct_pre_tool_use_updates_owner_without_materializing_shadow() {
    ensure_server_test_data_dir();
    let (persist_tx, mut persist_rx) = mpsc::channel(64);
    let state = Arc::new(SessionRegistry::new_with_primary(persist_tx, true));

    let mut handle = SessionHandle::new(
      "od-direct-tool-owner".to_string(),
      Provider::Codex,
      "/tmp/codex-direct-tool".to_string(),
    );
    handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
    state.add_session(handle);
    state.register_codex_thread("od-direct-tool-owner", "codex-thread-direct-tool");

    handle_hook_message(
      ClientMessage::CodexToolEvent {
        session_id: "codex-thread-direct-tool".to_string(),
        cwd: "/tmp/codex-direct-tool".to_string(),
        transcript_path: Some("/tmp/codex-direct-tool/transcript.jsonl".to_string()),
        model: Some("gpt-5-codex".to_string()),
        hook_event_name: "PreToolUse".to_string(),
        turn_id: "turn-22".to_string(),
        tool_name: "Bash".to_string(),
        tool_use_id: Some("toolu_direct".to_string()),
        tool_input: Some(json!({ "command": "git status" })),
        tool_response: None,
      },
      &state,
    )
    .await;

    tokio::task::yield_now().await;
    tokio::task::yield_now().await;

    assert!(state.get_session("codex-thread-direct-tool").is_none());
    let owner = state
      .get_session("od-direct-tool-owner")
      .expect("direct owner should still exist");
    let snapshot = owner.snapshot();
    assert_eq!(
      snapshot.codex_integration_mode,
      Some(CodexIntegrationMode::Direct)
    );
    assert_eq!(snapshot.work_status, WorkStatus::Working);
    assert_eq!(snapshot.pending_tool_name.as_deref(), Some("Bash"));
    assert_eq!(
      snapshot.pending_tool_input.as_deref(),
      Some("{\"command\":\"git status\"}")
    );

    let commands = collect_persist_commands(&mut persist_rx);
    assert!(!commands.iter().any(|command| matches!(
      command,
      PersistCommand::SessionCreate(params) if params.id == "codex-thread-direct-tool"
    )));
    assert!(commands.iter().any(|command| matches!(
      command,
      PersistCommand::SessionAttentionUpdate {
        session_id,
        last_tool,
        pending_tool_name,
        ..
      }
        if session_id == "od-direct-tool-owner"
          && last_tool.as_ref() == Some(&Some("Bash".to_string()))
          && pending_tool_name.as_ref() == Some(&Some("Bash".to_string()))
    )));
  }

  #[tokio::test]
  async fn spool_replay_transcript_sync_gate_allows_one_sync_per_session() {
    let options = CodexHookHandlingOptions::for_spool_replay();

    assert!(options.should_sync_transcript("session-1").await);
    assert!(!options.should_sync_transcript("session-1").await);
    assert!(options.should_sync_transcript("session-2").await);
  }
}
