use std::sync::Arc;

use serde_json::Value;

use orbitdock_protocol::Provider;

use crate::domain::sessions::transition::{approval_question, Input};
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::support::session_paths::claude_transcript_path_from_cwd;

use super::approval::{
  classify_permission_request, claude_permission_request_id, extract_plan_from_tool_input,
  extract_question_from_tool_input, permission_request_matches_snapshot,
  resolve_pending_approvals_after_tool_outcome, PermissionRequestSnapshotMatch,
};
use super::routing::{
  cleanup_claude_shadow_session, resolve_claude_hook_routing, ClaudeHookHandlingOptions,
  ClaudeHookRoutingDecision,
};
use super::session_materialization::materialize_claude_session;
use super::transcript_sync::maybe_sync_transcript_messages;

pub(crate) struct ClaudeToolEventPayload {
  pub session_id: String,
  pub cwd: String,
  pub hook_event_name: String,
  pub tool_name: String,
  pub tool_input: Option<Value>,
  pub tool_use_id: Option<String>,
  pub permission_suggestions: Option<Value>,
  pub is_interrupt: Option<bool>,
  pub permission_mode: Option<String>,
}

pub(crate) async fn handle_claude_tool_event(
  state: &Arc<SessionRegistry>,
  options: &ClaudeHookHandlingOptions,
  event: ClaudeToolEventPayload,
) {
  let ClaudeToolEventPayload {
    session_id,
    cwd,
    hook_event_name,
    tool_name,
    tool_input,
    tool_use_id,
    permission_suggestions,
    is_interrupt,
    permission_mode,
  } = event;
  match resolve_claude_hook_routing(state, &session_id).await {
    ClaudeHookRoutingDecision::ManagedDirect { owner_session_id } => {
      cleanup_claude_shadow_session(state, &session_id, "managed_direct_session").await;
      let persist_tx = state.persist().clone();

      match hook_event_name.as_str() {
        "PreToolUse" => {
          if let Some(actor) = state.get_session(&owner_session_id) {
            actor
              .send(SessionCommand::ProcessEvent {
                event: Input::AttentionUpdated {
                  attention_reason: None,
                  last_tool: Some(tool_name.clone()),
                  pending_tool_name: None,
                  pending_tool_input: None,
                  pending_question: None,
                },
              })
              .await;
          }
        }
        "PermissionRequest" => {
          if let Some(actor) = state.get_session(&owner_session_id) {
            actor
              .send(SessionCommand::ProcessEvent {
                event: Input::AttentionUpdated {
                  attention_reason: None,
                  last_tool: Some(tool_name),
                  pending_tool_name: None,
                  pending_tool_input: None,
                  pending_question: None,
                },
              })
              .await;
          }
        }
        "PostToolUse" | "PostToolUseFailure" => {
          let _ = persist_tx
            .send(PersistCommand::ClaudeToolIncrement {
              id: owner_session_id.clone(),
            })
            .await;
        }
        _ => {}
      }
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

  let persist_tx = state.persist().clone();
  let derived_transcript_path = claude_transcript_path_from_cwd(&cwd, &session_id);

  let git_info = crate::domain::git::repo::resolve_git_info(&cwd).await;
  let git_branch = git_info.as_ref().map(|g| g.branch.clone());
  let git_sha = git_info.as_ref().map(|g| g.sha.clone());
  let repository_root = git_info.as_ref().map(|g| g.common_dir_root.clone());
  let is_worktree = git_info.as_ref().is_some_and(|g| g.is_worktree);

  let actor = if let Some(existing) = state.get_session(&session_id) {
    if existing.snapshot().provider == Provider::Codex {
      return;
    }
    if git_branch.is_some() && existing.snapshot().git_branch.is_none() {
      existing
        .send(SessionCommand::ProcessEvent {
          event: Input::EnvironmentChanged {
            cwd: None,
            git_branch: git_branch.clone(),
            git_sha: git_sha.clone(),
            repository_root: repository_root.clone(),
            is_worktree: if is_worktree { Some(true) } else { None },
          },
        })
        .await;
    }
    existing
  } else {
    materialize_claude_session(
      &session_id,
      &cwd,
      derived_transcript_path.clone(),
      git_info.as_ref(),
      state,
      &persist_tx,
    )
    .await
  };

  let effective_project_path = repository_root.clone().unwrap_or_else(|| cwd.clone());
  let _ = persist_tx
    .send(PersistCommand::ClaudeSessionUpsert {
      id: session_id.clone(),
      project_path: effective_project_path.clone(),
      project_name: crate::support::session_paths::project_name_from_cwd(&effective_project_path),
      branch: git_branch,
      model: None,
      context_label: None,
      transcript_path: derived_transcript_path,
      source: None,
      agent_type: None,
      permission_mode: permission_mode.clone(),
      terminal_session_id: None,
      terminal_app: None,
      forked_from_session_id: None,
      repository_root,
      is_worktree,
      git_sha,
    })
    .await;

  match hook_event_name.as_str() {
    "PreToolUse" => {
      let snapshot = actor.snapshot();
      let was_permission = snapshot.work_status == orbitdock_protocol::WorkStatus::Permission;
      let had_pending_approval = snapshot.pending_approval_id.is_some();

      let question = tool_input
        .as_ref()
        .and_then(|value| value.get("question"))
        .and_then(Value::as_str)
        .map(|s| s.to_string());
      let serialized_input = tool_input
        .as_ref()
        .and_then(|value| serde_json::to_string(value).ok());

      actor
        .send(SessionCommand::ProcessEvent {
          event: Input::AttentionUpdated {
            attention_reason: None,
            last_tool: Some(tool_name.clone()),
            pending_tool_name: if was_permission || had_pending_approval {
              None
            } else {
              Some(Some(tool_name.clone()))
            },
            pending_tool_input: if was_permission || had_pending_approval {
              None
            } else {
              Some(serialized_input)
            },
            pending_question: if was_permission || had_pending_approval {
              None
            } else {
              Some(question)
            },
          },
        })
        .await;
      actor
        .send(SessionCommand::ApplyDelta {
          changes: Box::new(orbitdock_protocol::StateChanges {
            work_status: Some(orbitdock_protocol::WorkStatus::Working),
            last_activity_at: Some(crate::support::session_time::chrono_now()),
            ..Default::default()
          }),
          persist_op: None,
        })
        .await;

      if let Some(ref pm) = permission_mode {
        actor
          .send(SessionCommand::ProcessEvent {
            event: Input::PermissionModeChanged { mode: pm.clone() },
          })
          .await;
      }
    }
    "PostToolUse" => {
      resolve_pending_approvals_after_tool_outcome(
        &actor,
        &persist_tx,
        &session_id,
        "approved",
        orbitdock_protocol::WorkStatus::Working,
      )
      .await;

      let _ = persist_tx
        .send(PersistCommand::ClaudeToolIncrement {
          id: session_id.clone(),
        })
        .await;
      actor
        .send(SessionCommand::ProcessEvent {
          event: Input::AttentionUpdated {
            attention_reason: None,
            last_tool: None,
            pending_tool_name: Some(None),
            pending_tool_input: Some(None),
            pending_question: Some(None),
          },
        })
        .await;

      if let Some(ref pm) = permission_mode {
        actor
          .send(SessionCommand::ProcessEvent {
            event: Input::PermissionModeChanged { mode: pm.clone() },
          })
          .await;
      }
      actor
        .send(SessionCommand::ApplyDelta {
          changes: Box::new(orbitdock_protocol::StateChanges {
            work_status: Some(orbitdock_protocol::WorkStatus::Working),
            last_activity_at: Some(crate::support::session_time::chrono_now()),
            ..Default::default()
          }),
          persist_op: None,
        })
        .await;
    }
    "PostToolUseFailure" => {
      let decision = if is_interrupt.unwrap_or(false) {
        "denied"
      } else {
        "approved"
      };
      resolve_pending_approvals_after_tool_outcome(
        &actor,
        &persist_tx,
        &session_id,
        decision,
        orbitdock_protocol::WorkStatus::Working,
      )
      .await;

      let _ = persist_tx
        .send(PersistCommand::ClaudeToolIncrement {
          id: session_id.clone(),
        })
        .await;
      {
        use crate::runtime::session_state_transitions::{
          attention_reason_for_status, transition_work_status,
        };
        actor
          .send(SessionCommand::ProcessEvent {
            event: Input::AttentionUpdated {
              attention_reason: attention_reason_for_status(
                orbitdock_protocol::WorkStatus::Working,
              ),
              last_tool: None,
              pending_tool_name: None,
              pending_tool_input: None,
              pending_question: None,
            },
          })
          .await;
        transition_work_status(
          &actor,
          &session_id,
          orbitdock_protocol::WorkStatus::Working,
          None,
        )
        .await;
      }
    }
    "PermissionRequest" => {
      let serialized_input = tool_input
        .as_ref()
        .and_then(|value| serde_json::to_string(value).ok());
      let (approval_type, work_status) = classify_permission_request(&tool_name);
      let request_id =
        claude_permission_request_id(Some(&actor), &tool_name, tool_use_id.as_deref());
      let fallback_question = extract_question_from_tool_input(tool_input.as_ref());
      let question_text =
        approval_question(serialized_input.as_deref(), fallback_question.as_deref());
      let plan_text = extract_plan_from_tool_input(tool_input.as_ref());
      let snapshot = actor.snapshot();
      let is_duplicate_request = permission_request_matches_snapshot(
        &snapshot,
        &PermissionRequestSnapshotMatch {
          request_id: request_id.as_str(),
          tool_name: tool_name.as_str(),
          tool_input: serialized_input.as_deref(),
          question: question_text.as_deref(),
          work_status,
          permission_mode: permission_mode.as_deref(),
          plan_text: plan_text.as_deref(),
        },
      );

      if !is_duplicate_request {
        actor
          .send(SessionCommand::ProcessEvent {
            event: Input::AttentionUpdated {
              attention_reason:
                crate::runtime::session_state_transitions::attention_reason_for_status(work_status),
              last_tool: Some(tool_name.clone()),
              pending_tool_name: None,
              pending_tool_input: None,
              pending_question: None,
            },
          })
          .await;

        if let Some(plan_text) = plan_text {
          actor
            .send(SessionCommand::ProcessEvent {
              event: Input::PlanUpdated(plan_text),
            })
            .await;
        }

        actor
          .send(SessionCommand::ProcessEvent {
            event: Input::ApprovalRequested {
              request_id: request_id.clone(),
              approval_type,
              tool_name: Some(tool_name.clone()),
              tool_input: serialized_input.clone(),
              command: None,
              file_path: None,
              diff: None,
              question: question_text.clone(),
              permission_reason: None,
              requested_permissions: None,
              proposed_amendment: None,
              permission_suggestions: permission_suggestions.clone(),
              elicitation_mode: None,
              elicitation_schema: None,
              elicitation_url: None,
              elicitation_message: None,
              mcp_server_name: None,
              network_host: None,
              network_protocol: None,
            },
          })
          .await;

        if let Some(ref pm) = permission_mode {
          actor
            .send(SessionCommand::ProcessEvent {
              event: Input::PermissionModeChanged { mode: pm.clone() },
            })
            .await;
        }

        crate::runtime::session_registry::flush_and_publish_conversation(
          &persist_tx,
          state,
          &session_id,
        )
        .await;
      }
    }
    _ => {}
  }

  maybe_sync_transcript_messages(&actor, &persist_tx, options).await;
}
