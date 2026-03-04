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

use crate::git::resolve_git_info;
use crate::session_command::SessionCommand;
use crate::state::SessionRegistry;

const REFRESH_INTERVAL: Duration = Duration::from_secs(1);

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
            if snap.status != SessionStatus::Active || snap.subscriber_count == 0 {
                return None;
            }
            let cwd = snap
                .current_cwd
                .clone()
                .unwrap_or_else(|| snap.project_path.clone());
            if cwd.is_empty() {
                return None;
            }
            Some((
                actor.clone(),
                snap.id.clone(),
                cwd,
                snap.git_branch.clone(),
                snap.git_sha.clone(),
            ))
        })
        .collect();

    if candidates.is_empty() {
        return;
    }

    for (actor, session_id, cwd, old_branch, old_sha) in candidates {
        let info = resolve_git_info(&cwd).await;
        if let Some(info) = info {
            let branch_changed = old_branch.as_deref() != Some(&info.branch);
            let sha_changed = old_sha.as_deref() != Some(&info.sha);

            if branch_changed || sha_changed {
                debug!(
                    component = "git_refresh",
                    session_id = %session_id,
                    old_branch = ?old_branch,
                    new_branch = %info.branch,
                    old_sha = ?old_sha,
                    new_sha = %info.sha,
                    "Git info changed, broadcasting delta"
                );

                let changes = StateChanges {
                    git_branch: Some(Some(info.branch)),
                    git_sha: Some(Some(info.sha)),
                    repository_root: Some(Some(info.common_dir_root)),
                    is_worktree: if info.is_worktree { Some(true) } else { None },
                    ..Default::default()
                };

                actor
                    .send(SessionCommand::ApplyDelta {
                        changes,
                        persist_op: None,
                    })
                    .await;
            }
        }
    }
}
