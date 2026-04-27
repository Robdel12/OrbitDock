//! Periodic git info refresh for active subscribed sessions.
//!
//! Every second, iterates all sessions in the registry. For each session
//! that is Active and has at least one WebSocket subscriber, resolves
//! git info from the session's cwd and broadcasts a SessionDelta only
//! if the branch or SHA has actually changed.

use std::sync::Arc;
use std::time::Duration;

use orbitdock_protocol::{SessionStatus, StateChanges};
use tracing::debug;

use crate::domain::git::repo::{resolve_git_info, GitInfo};
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;

const REFRESH_INTERVAL: Duration = Duration::from_secs(1);

#[derive(Debug, Clone, PartialEq, Eq)]
struct GitRefreshCandidate {
  session_id: String,
  cwd: String,
  old_branch: Option<String>,
  old_sha: Option<String>,
}

pub async fn start_git_refresh_loop(state: Arc<SessionRegistry>) {
  let mut interval = tokio::time::interval(REFRESH_INTERVAL);
  loop {
    interval.tick().await;
    refresh_subscribed_sessions(&state).await;
  }
}

async fn refresh_subscribed_sessions(state: &SessionRegistry) {
  // Collect candidates: active sessions with at least one subscriber and a cwd
  let candidates: Vec<_> = state
    .iter_sessions()
    .filter_map(|entry| {
      let actor = entry.value();
      let snap = actor.snapshot();
      let candidate = build_git_refresh_candidate(
        &snap.id,
        snap.status,
        snap.subscriber_count,
        snap.current_cwd.as_deref(),
        &snap.project_path,
        snap.git_branch.as_deref(),
        snap.git_sha.as_deref(),
      )?;
      Some((actor.clone(), candidate))
    })
    .collect();

  if candidates.is_empty() {
    return;
  }

  for (actor, candidate) in candidates {
    let GitRefreshCandidate {
      session_id,
      cwd,
      old_branch,
      old_sha,
    } = candidate;
    let info = resolve_git_info(&cwd).await;
    if let Some(info) = info.as_ref() {
      if let Some(changes) = plan_git_refresh_delta(old_branch.as_deref(), old_sha.as_deref(), info)
      {
        debug!(
            component = "git_refresh",
            session_id = %session_id,
            old_branch = ?old_branch,
            new_branch = %info.branch,
            old_sha = ?old_sha,
            new_sha = %info.sha,
            "Git info changed, broadcasting delta"
        );

        actor
          .send(SessionCommand::ApplyDelta {
            changes: Box::new(changes),
            persist_op: None,
          })
          .await;
      }
    }
  }
}

fn build_git_refresh_candidate(
  session_id: &str,
  status: SessionStatus,
  subscriber_count: usize,
  current_cwd: Option<&str>,
  project_path: &str,
  old_branch: Option<&str>,
  old_sha: Option<&str>,
) -> Option<GitRefreshCandidate> {
  if status != SessionStatus::Active || subscriber_count == 0 {
    return None;
  }

  let cwd = current_cwd.unwrap_or(project_path).trim();
  if cwd.is_empty() {
    return None;
  }

  Some(GitRefreshCandidate {
    session_id: session_id.to_string(),
    cwd: cwd.to_string(),
    old_branch: old_branch.map(str::to_string),
    old_sha: old_sha.map(str::to_string),
  })
}

fn plan_git_refresh_delta(
  old_branch: Option<&str>,
  old_sha: Option<&str>,
  info: &GitInfo,
) -> Option<StateChanges> {
  let branch_changed = old_branch != Some(info.branch.as_str());
  let sha_changed = old_sha != Some(info.sha.as_str());
  if !branch_changed && !sha_changed {
    return None;
  }

  Some(StateChanges {
    git_branch: Some(Some(info.branch.clone())),
    git_sha: Some(Some(info.sha.clone())),
    repository_root: Some(Some(info.common_dir_root.clone())),
    is_worktree: if info.is_worktree { Some(true) } else { None },
    ..Default::default()
  })
}

#[cfg(test)]
#[path = "git_refresh_tests.rs"]
mod git_refresh_tests;
