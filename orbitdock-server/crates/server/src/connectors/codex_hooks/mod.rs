use std::sync::Arc;
use std::time::Instant;

use serde_json::Value;
use tokio::sync::mpsc;

use orbitdock_protocol::{ClientMessage, Provider, WorkStatus};

use crate::domain::sessions::transition::Input;
use crate::infrastructure::persistence::{extract_summary_from_transcript_path, PersistCommand};
use crate::runtime::session_actor::SessionActorHandle;
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::{PendingCodexSession, PendingHookSession, SessionRegistry};
use crate::runtime::session_runtime_helpers::sync_transcript_messages;

#[path = "codex_hook_session.rs"]
mod codex_hook_session;

use self::codex_hook_session::{
  apply_codex_hook_metadata, cleanup_codex_shadow_session, ensure_passive_codex_session,
  maybe_claim_direct_codex_session, resolve_codex_hook_routing, CodexHookHandlingOptions,
  CodexHookRoutingDecision,
};

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

async fn handle_hook_message_with_options(
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
