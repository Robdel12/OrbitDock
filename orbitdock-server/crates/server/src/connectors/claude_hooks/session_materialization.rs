use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::sync::mpsc;

use orbitdock_protocol::{Provider, ServerMessage, SessionListItem, SessionSummary};

use crate::domain::sessions::session::SessionHandle;
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_actor::SessionActorHandle;
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_runtime_helpers::is_stale_empty_claude_shell;
use crate::support::session_paths::{claude_transcript_path_from_cwd, project_name_from_cwd};

pub(crate) async fn materialize_claude_session(
    session_id: &str,
    fallback_cwd: &str,
    fallback_transcript_path: Option<String>,
    fallback_git_info: Option<&crate::domain::git::repo::GitInfo>,
    state: &Arc<SessionRegistry>,
    persist_tx: &mpsc::Sender<PersistCommand>,
) -> SessionActorHandle {
    let pending = state.take_pending_claude(session_id);

    let cwd = pending
        .as_ref()
        .map(|pending| pending.cwd.clone())
        .unwrap_or_else(|| fallback_cwd.to_string());
    let model = pending.as_ref().and_then(|pending| pending.model.clone());
    let transcript_path = pending
        .as_ref()
        .and_then(|pending| pending.transcript_path.clone())
        .or(fallback_transcript_path);
    let source = pending.as_ref().and_then(|pending| pending.source.clone());
    let context_label = pending
        .as_ref()
        .and_then(|pending| pending.context_label.clone());
    let agent_type = pending
        .as_ref()
        .and_then(|pending| pending.agent_type.clone());
    let permission_mode = pending
        .as_ref()
        .and_then(|pending| pending.permission_mode.clone());
    let terminal_session_id = pending
        .as_ref()
        .and_then(|pending| pending.terminal_session_id.clone());
    let terminal_app = pending
        .as_ref()
        .and_then(|pending| pending.terminal_app.clone());

    let resolved_git_info = if pending.is_some() {
        crate::domain::git::repo::resolve_git_info(&cwd).await
    } else {
        fallback_git_info.cloned()
    };

    let git_branch = resolved_git_info.as_ref().map(|info| info.branch.clone());
    let git_sha = resolved_git_info.as_ref().map(|info| info.sha.clone());
    let repository_root = resolved_git_info
        .as_ref()
        .map(|info| info.common_dir_root.clone());
    let is_worktree = resolved_git_info
        .as_ref()
        .is_some_and(|info| info.is_worktree);
    let effective_project_path = repository_root.clone().unwrap_or_else(|| cwd.clone());

    let forked_from_session_id = if matches!(source.as_deref(), Some("resume") | Some("clear")) {
        find_most_recent_claude_session(session_id, &effective_project_path, state)
    } else {
        None
    };

    run_stale_shell_pruning(session_id, &effective_project_path, state, persist_tx).await;

    let mut handle = SessionHandle::new(
        session_id.to_string(),
        Provider::Claude,
        effective_project_path.clone(),
    );
    handle.set_claude_integration_mode(Some(orbitdock_protocol::ClaudeIntegrationMode::Passive));
    handle.set_project_name(project_name_from_cwd(&effective_project_path));
    handle.set_model(model.clone());
    handle.set_transcript_path(transcript_path.clone());
    handle.set_work_status(orbitdock_protocol::WorkStatus::Waiting);
    handle.set_terminal_info(terminal_session_id.clone(), terminal_app.clone());
    handle.set_worktree_info(repository_root.clone(), is_worktree, None);
    if let Some(ref fork_src) = forked_from_session_id {
        handle.set_forked_from(fork_src.clone());
    }
    let actor = state.add_session(handle);

    if git_branch.is_some() || repository_root.is_some() {
        actor
            .send(SessionCommand::ApplyDelta {
                changes: Box::new(orbitdock_protocol::StateChanges {
                    git_branch: git_branch.as_ref().map(|value| Some(value.clone())),
                    git_sha: git_sha.as_ref().map(|value| Some(value.clone())),
                    repository_root: repository_root.as_ref().map(|value| Some(value.clone())),
                    is_worktree: if is_worktree { Some(true) } else { None },
                    ..Default::default()
                }),
                persist_op: None,
            })
            .await;
    }

    if let Ok(summary) = actor.summary().await {
        state.broadcast_to_list(ServerMessage::SessionCreated {
            session: SessionListItem::from_summary(&summary),
        });
    }

    let _ = persist_tx
        .send(PersistCommand::ClaudeSessionUpsert {
            id: session_id.to_string(),
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
            forked_from_session_id,
            repository_root,
            is_worktree,
            git_sha,
        })
        .await;

    emit_capabilities_from_transcript(session_id, &actor).await;
    actor
}

pub(crate) async fn emit_capabilities_from_transcript(
    session_id: &str,
    actor: &SessionActorHandle,
) {
    let transcript_path = {
        let snapshot = actor.snapshot();
        snapshot
            .transcript_path
            .clone()
            .or_else(|| claude_transcript_path_from_cwd(&snapshot.project_path, session_id))
    };
    let Some(transcript_path) = transcript_path else {
        return;
    };

    let Some(capabilities) =
        crate::infrastructure::persistence::load_capabilities_from_transcript_path(
            &transcript_path,
        )
        .await
    else {
        return;
    };

    if capabilities.skills.is_empty()
        && capabilities.tools.is_empty()
        && capabilities.slash_commands.is_empty()
    {
        return;
    }

    tracing::info!(
        component = "hook_handler",
        event = "claude.capabilities_from_transcript",
        session_id = %session_id,
        skills_count = capabilities.skills.len(),
        tools_count = capabilities.tools.len(),
        slash_commands_count = capabilities.slash_commands.len(),
        "Extracted capabilities from transcript for CLI session"
    );
    actor
        .send(SessionCommand::Broadcast {
            msg: ServerMessage::ClaudeCapabilities {
                session_id: session_id.to_string(),
                slash_commands: capabilities.slash_commands,
                skills: capabilities.skills,
                tools: capabilities.tools,
                models: vec![],
            },
        })
        .await;
}

pub(crate) fn is_codex_rollout_payload(transcript_path: Option<&str>, model: Option<&str>) -> bool {
    if let Some(path) = transcript_path {
        if path.contains("/.codex/sessions/") {
            return true;
        }
    }
    if let Some(model) = model {
        let lower = model.to_lowercase();
        if lower.contains("codex") || lower.starts_with("gpt-") {
            return true;
        }
    }
    false
}

pub(crate) fn most_recent_claude_session_id<'a>(
    current_session_id: &str,
    project_path: &str,
    sessions: impl IntoIterator<Item = &'a SessionSummary>,
) -> Option<String> {
    sessions
        .into_iter()
        .filter(|session| {
            session.provider == Provider::Claude
                && session.id != current_session_id
                && session.project_path == project_path
        })
        .max_by(|left, right| left.last_activity_at.cmp(&right.last_activity_at))
        .map(|session| session.id.clone())
}

fn find_most_recent_claude_session(
    current_session_id: &str,
    project_path: &str,
    state: &Arc<SessionRegistry>,
) -> Option<String> {
    let summaries = state.get_session_summaries();
    most_recent_claude_session_id(current_session_id, project_path, summaries.iter())
}

async fn run_stale_shell_pruning(
    session_id: &str,
    cwd: &str,
    state: &Arc<SessionRegistry>,
    persist_tx: &mpsc::Sender<PersistCommand>,
) {
    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    let stale_shell_ids: Vec<String> = state
        .get_session_summaries()
        .into_iter()
        .filter(|summary| is_stale_empty_claude_shell(summary, session_id, cwd, now_secs))
        .map(|summary| summary.id)
        .collect();

    for stale_id in stale_shell_ids {
        let _ = persist_tx
            .send(PersistCommand::ClaudeSessionEnd {
                id: stale_id.clone(),
                reason: Some("stale_empty_shell".to_string()),
            })
            .await;
        if state.remove_session(&stale_id).is_some() {
            state.broadcast_to_list(ServerMessage::SessionListItemRemoved {
                session_id: stale_id,
            });
        }
    }
}
