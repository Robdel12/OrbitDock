use std::sync::Arc;
use std::time::Instant;

use orbitdock_protocol::Provider;

use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::{PendingClaudeSession, PendingHookSession, SessionRegistry};
use crate::support::session_paths::project_name_from_cwd;

use super::routing::{
  cleanup_claude_shadow_session, resolve_claude_hook_routing, ClaudeHookRoutingDecision,
};
use super::session_materialization::is_codex_rollout_payload;

pub(crate) async fn handle_claude_session_start(
  state: &Arc<SessionRegistry>,
  session_id: String,
  cwd: String,
  model: Option<String>,
  source: Option<String>,
  context_label: Option<String>,
  transcript_path: Option<String>,
  permission_mode: Option<String>,
  agent_type: Option<String>,
  terminal_session_id: Option<String>,
  terminal_app: Option<String>,
) {
  if context_label.as_deref() == Some("codex_cli_rs") {
    return;
  }

  if is_codex_rollout_payload(transcript_path.as_deref(), model.as_deref()) {
    return;
  }

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

  if let Some(owning_id) = state.find_unregistered_direct_claude_session(&cwd) {
    state.register_claude_runtime_owner(&session_id, &owning_id);
    let persisted = state
      .persist()
      .send(PersistCommand::SetClaudeSdkSessionId {
        session_id: owning_id.clone(),
        claude_sdk_session_id: session_id.clone(),
      })
      .await
      .is_ok();
    if persisted {
      return;
    }
    state.unregister_claude_runtime_owner(&session_id);
  }

  if let Some(existing) = state.get_session(&session_id) {
    if existing.snapshot().provider == Provider::Codex {
      return;
    }
    if let Some(ref m) = model {
      existing
        .send(SessionCommand::ProcessEvent {
          event: crate::domain::sessions::transition::Input::ModelUpdated(m.clone()),
        })
        .await;
    }
    if transcript_path.is_some() {
      existing
        .send(SessionCommand::ProcessEvent {
          event: crate::domain::sessions::transition::Input::TranscriptPathUpdated(
            transcript_path.clone(),
          ),
        })
        .await;
    }
    let git_info = crate::domain::git::repo::resolve_git_info(&cwd).await;
    let git_branch = git_info.as_ref().map(|g| g.branch.clone());
    let git_sha = git_info.as_ref().map(|g| g.sha.clone());
    let repository_root = git_info.as_ref().map(|g| g.common_dir_root.clone());
    let is_worktree = git_info.as_ref().is_some_and(|g| g.is_worktree);

    let effective_project_path = repository_root.clone().unwrap_or_else(|| cwd.clone());

    crate::runtime::session_state_transitions::transition_work_status(
      &existing,
      &session_id,
      orbitdock_protocol::WorkStatus::Waiting,
      Some(orbitdock_protocol::StateChanges {
        current_cwd: Some(Some(cwd.clone())),
        git_branch: git_branch.as_ref().map(|b| Some(b.clone())),
        git_sha: git_sha.as_ref().map(|s| Some(s.clone())),
        repository_root: repository_root.as_ref().map(|r| Some(r.clone())),
        is_worktree: if is_worktree { Some(true) } else { None },
        ..Default::default()
      }),
    )
    .await;
    existing
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
    let _ = state
      .persist()
      .send(PersistCommand::ClaudeSessionUpsert {
        id: session_id,
        project_path: effective_project_path.clone(),
        project_name: project_name_from_cwd(&effective_project_path),
        branch: git_branch,
        model,
        context_label,
        transcript_path,
        source,
        agent_type,
        permission_mode,
        terminal_session_id,
        terminal_app,
        forked_from_session_id: None,
        repository_root,
        is_worktree,
        git_sha,
      })
      .await;
    return;
  }

  state.cache_pending_hook_session(
    session_id,
    PendingHookSession::Claude(PendingClaudeSession {
      cwd,
      model,
      source,
      context_label,
      transcript_path,
      permission_mode,
      agent_type,
      terminal_session_id,
      terminal_app,
      cached_at: Instant::now(),
    }),
  );
}
