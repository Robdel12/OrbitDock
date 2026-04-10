use std::sync::Arc;

use orbitdock_protocol::Provider;

use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::support::session_paths::claude_transcript_path_from_cwd;

use super::routing::{
  cleanup_claude_shadow_session, resolve_claude_hook_routing, ClaudeHookHandlingOptions,
  ClaudeHookRoutingDecision,
};
use super::session_materialization::{
  emit_capabilities_from_transcript, materialize_claude_session,
};
use super::transcript_sync::maybe_sync_transcript_messages;

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_claude_status_event(
  state: &Arc<SessionRegistry>,
  options: &ClaudeHookHandlingOptions,
  session_id: String,
  cwd: Option<String>,
  transcript_path: Option<String>,
  hook_event_name: String,
  notification_type: Option<String>,
  tool_name: Option<String>,
  prompt: Option<String>,
  permission_mode: Option<String>,
) {
  match resolve_claude_hook_routing(state, &session_id).await {
    ClaudeHookRoutingDecision::ManagedDirect { owner_session_id } => {
      cleanup_claude_shadow_session(state, &session_id, "managed_direct_session").await;

      if let Some(actor) = state.get_session(&owner_session_id) {
        let persist_tx = state.persist().clone();

        let next_work_status = match hook_event_name.as_str() {
          "UserPromptSubmit" => Some(orbitdock_protocol::WorkStatus::Working),
          "Stop" => {
            let is_question =
              actor.last_tool().await.ok().flatten().as_deref() == Some("AskUserQuestion");
            if is_question {
              Some(orbitdock_protocol::WorkStatus::Question)
            } else {
              Some(orbitdock_protocol::WorkStatus::Reply)
            }
          }
          "Notification" => match notification_type.as_deref() {
            Some("idle_prompt") => {
              let is_question =
                actor.last_tool().await.ok().flatten().as_deref() == Some("AskUserQuestion");
              if is_question {
                Some(orbitdock_protocol::WorkStatus::Question)
              } else {
                Some(orbitdock_protocol::WorkStatus::Reply)
              }
            }
            _ => None,
          },
          "TeammateIdle" => Some(orbitdock_protocol::WorkStatus::Reply),
          _ => None,
        };

        if let Some(ws) = next_work_status {
          use crate::runtime::session_state_transitions::{
            attention_reason_for_status, transition_work_status,
          };
          actor
            .send(SessionCommand::ProcessEvent {
              event: crate::domain::sessions::transition::Input::AttentionUpdated {
                attention_reason: attention_reason_for_status(ws),
                last_tool: None,
                pending_tool_name: None,
                pending_tool_input: None,
                pending_question: None,
              },
            })
            .await;
          transition_work_status(&actor, &owner_session_id, ws, None).await;

          crate::runtime::session_registry::flush_and_publish_conversation(
            &persist_tx,
            state,
            &owner_session_id,
          )
          .await;
        }

        if hook_event_name == "Stop" {
          let snap = actor.snapshot();
          if snap.summary.is_none() {
            let derived = cwd
              .as_deref()
              .and_then(|p| claude_transcript_path_from_cwd(p, &session_id));
            let tp = snap
              .transcript_path
              .clone()
              .or_else(|| transcript_path.clone())
              .or(derived);
            if let Some(path) = tp {
              if let Some(summary) =
                crate::infrastructure::persistence::extract_summary_from_transcript_path(&path)
                  .await
              {
                actor
                  .send(SessionCommand::ProcessEvent {
                    event: crate::domain::sessions::transition::Input::SummaryUpdated(summary),
                  })
                  .await;
              }
            }
          }
        }

        if hook_event_name == "PreCompact" {
          let _ = persist_tx
            .send(PersistCommand::ClaudeSessionUpdate {
              id: owner_session_id.clone(),
              work_status: None,
              attention_reason: None,
              last_tool: None,
              last_tool_at: None,
              pending_tool_name: None,
              pending_tool_input: None,
              pending_question: None,
              source: None,
              agent_type: None,
              permission_mode: None,
              active_subagent_id: None,
              active_subagent_type: None,
              first_prompt: None,
              compact_count_increment: true,
            })
            .await;
        }

        if let Some(ref tool_name) = tool_name {
          actor
            .send(SessionCommand::ProcessEvent {
              event: crate::domain::sessions::transition::Input::AttentionUpdated {
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
  let derived_transcript_path = cwd
    .as_deref()
    .and_then(|path| claude_transcript_path_from_cwd(path, &session_id));

  let git_info = match cwd.as_deref() {
    Some(path) => crate::domain::git::repo::resolve_git_info(path).await,
    None => None,
  };
  let git_branch = git_info.as_ref().map(|g| g.branch.clone());
  let git_sha = git_info.as_ref().map(|g| g.sha.clone());
  let repository_root = git_info.as_ref().map(|g| g.common_dir_root.clone());
  let is_worktree = git_info.as_ref().is_some_and(|g| g.is_worktree);

  let actor = if let Some(existing) = state.get_session(&session_id) {
    if existing.snapshot().provider == Provider::Codex {
      return;
    }
    if cwd.is_some() || git_branch.is_some() || repository_root.is_some() {
      existing
        .send(SessionCommand::ProcessEvent {
          event: crate::domain::sessions::transition::Input::EnvironmentChanged {
            cwd: cwd.clone(),
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
    let fallback_cwd = cwd.clone().unwrap_or_else(|| "/unknown".to_string());
    materialize_claude_session(
      &session_id,
      &fallback_cwd,
      transcript_path
        .clone()
        .or_else(|| derived_transcript_path.clone()),
      git_info.as_ref(),
      state,
      &persist_tx,
    )
    .await
  };

  if transcript_path.is_some() || derived_transcript_path.is_some() {
    actor
      .send(SessionCommand::ProcessEvent {
        event: crate::domain::sessions::transition::Input::TranscriptPathUpdated(
          transcript_path
            .clone()
            .or_else(|| derived_transcript_path.clone()),
        ),
      })
      .await;
  }

  if let Some(cwd) = cwd.clone() {
    let effective_project_path = repository_root.clone().unwrap_or_else(|| cwd.clone());
    actor
      .send(SessionCommand::ProcessEvent {
        event: crate::domain::sessions::transition::Input::EnvironmentChanged {
          cwd: Some(cwd.clone()),
          git_branch: git_branch.clone(),
          git_sha: git_sha.clone(),
          repository_root: repository_root.clone(),
          is_worktree: Some(is_worktree),
        },
      })
      .await;
    let _ = persist_tx
      .send(PersistCommand::ClaudeSessionUpsert {
        id: session_id.clone(),
        project_path: effective_project_path.clone(),
        project_name: crate::support::session_paths::project_name_from_cwd(&effective_project_path),
        branch: git_branch.clone(),
        model: None,
        context_label: None,
        transcript_path: transcript_path
          .clone()
          .or_else(|| derived_transcript_path.clone()),
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
  }

  let next_work_status = match hook_event_name.as_str() {
    "UserPromptSubmit" => Some(orbitdock_protocol::WorkStatus::Working),
    "Stop" => {
      let is_question =
        actor.last_tool().await.ok().flatten().as_deref() == Some("AskUserQuestion");
      if is_question {
        Some(orbitdock_protocol::WorkStatus::Question)
      } else {
        Some(orbitdock_protocol::WorkStatus::Reply)
      }
    }
    "Notification" => match notification_type.as_deref() {
      Some("permission_prompt") => None,
      Some("elicitation_dialog") => None,
      Some("idle_prompt") => {
        let is_question =
          actor.last_tool().await.ok().flatten().as_deref() == Some("AskUserQuestion");
        if is_question {
          Some(orbitdock_protocol::WorkStatus::Question)
        } else {
          Some(orbitdock_protocol::WorkStatus::Reply)
        }
      }
      _ => None,
    },
    "TeammateIdle" => Some(orbitdock_protocol::WorkStatus::Reply),
    _ => None,
  };

  if hook_event_name == "UserPromptSubmit" {
    let _ = persist_tx
      .send(PersistCommand::ClaudePromptIncrement {
        id: session_id.clone(),
        first_prompt: prompt.clone(),
      })
      .await;

    if let Some(ref prompt_text) = prompt {
      actor
        .send(SessionCommand::ProcessEvent {
          event: crate::domain::sessions::transition::Input::FirstPromptCaptured(
            prompt_text.clone(),
          ),
        })
        .await;
    }

    if let Some(ref prompt_cwd) = cwd {
      let fresh_info = crate::domain::git::repo::resolve_git_info(prompt_cwd).await;
      if let Some(ref info) = fresh_info {
        actor
          .send(SessionCommand::ProcessEvent {
            event: crate::domain::sessions::transition::Input::EnvironmentChanged {
              cwd: Some(prompt_cwd.clone()),
              git_branch: Some(info.branch.clone()),
              git_sha: Some(info.sha.clone()),
              repository_root: Some(info.common_dir_root.clone()),
              is_worktree: Some(info.is_worktree),
            },
          })
          .await;
      }
    }
  }

  if hook_event_name == "UserPromptSubmit" {
    emit_capabilities_from_transcript(&session_id, &actor).await;
  }

  if hook_event_name == "Stop" {
    let snap = actor.snapshot();
    if snap.summary.is_none() {
      let tp = snap
        .transcript_path
        .clone()
        .or_else(|| transcript_path.clone())
        .or_else(|| derived_transcript_path.clone());
      if let Some(path) = tp {
        if let Some(extracted_summary) =
          crate::infrastructure::persistence::extract_summary_from_transcript_path(&path).await
        {
          actor
            .send(SessionCommand::ProcessEvent {
              event: crate::domain::sessions::transition::Input::SummaryUpdated(extracted_summary),
            })
            .await;
        }
      }
    }
  }

  if hook_event_name == "PreCompact" {
    let _ = persist_tx
      .send(PersistCommand::ClaudeSessionUpdate {
        id: session_id.clone(),
        work_status: None,
        attention_reason: None,
        last_tool: None,
        last_tool_at: None,
        pending_tool_name: None,
        pending_tool_input: None,
        pending_question: None,
        source: None,
        agent_type: None,
        permission_mode: None,
        active_subagent_id: None,
        active_subagent_type: None,
        first_prompt: None,
        compact_count_increment: true,
      })
      .await;
  }

  if let Some(tool_name) = tool_name {
    actor
      .send(SessionCommand::ProcessEvent {
        event: crate::domain::sessions::transition::Input::AttentionUpdated {
          attention_reason: None,
          last_tool: Some(tool_name),
          pending_tool_name: None,
          pending_tool_input: None,
          pending_question: None,
        },
      })
      .await;
  }

  if let Some(work_status) = next_work_status {
    use crate::runtime::session_state_transitions::{
      attention_reason_for_status, transition_work_status,
    };
    actor
      .send(SessionCommand::ProcessEvent {
        event: crate::domain::sessions::transition::Input::AttentionUpdated {
          attention_reason: attention_reason_for_status(work_status),
          last_tool: None,
          pending_tool_name: None,
          pending_tool_input: None,
          pending_question: None,
        },
      })
      .await;
    transition_work_status(&actor, &session_id, work_status, None).await;

    if let Some(ref pm) = permission_mode {
      actor
        .send(SessionCommand::ProcessEvent {
          event: crate::domain::sessions::transition::Input::PermissionModeChanged {
            mode: pm.clone(),
          },
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

  maybe_sync_transcript_messages(&actor, &persist_tx, options).await;
}
