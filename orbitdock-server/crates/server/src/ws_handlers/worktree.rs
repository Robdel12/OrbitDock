use orbitdock_protocol::{ClientMessage, ServerMessage};
use tokio::sync::mpsc;

use crate::websocket::{chrono_now, send_json, OutboundMessage};

pub(crate) async fn handle(msg: ClientMessage, client_tx: &mpsc::Sender<OutboundMessage>) {
    match msg {
        ClientMessage::ListWorktrees {
            request_id,
            repo_root,
        } => {
            let worktrees = if let Some(ref root) = repo_root {
                match crate::git::discover_worktrees(root).await {
                    Ok(discovered) => discovered
                        .into_iter()
                        .map(|w| orbitdock_protocol::WorktreeSummary {
                            id: orbitdock_protocol::new_id(),
                            repo_root: root.clone(),
                            worktree_path: w.path,
                            branch: w.branch.unwrap_or_else(|| "HEAD".to_string()),
                            base_branch: None,
                            status: orbitdock_protocol::WorktreeStatus::Active,
                            active_session_count: 0,
                            total_session_count: 0,
                            created_at: String::new(),
                            last_session_ended_at: None,
                            disk_present: true,
                            auto_prune: true,
                            custom_name: None,
                            created_by: orbitdock_protocol::WorktreeOrigin::Discovered,
                        })
                        .collect(),
                    Err(_) => Vec::new(),
                }
            } else {
                Vec::new()
            };
            send_json(
                client_tx,
                ServerMessage::WorktreesList {
                    request_id,
                    repo_root,
                    worktrees,
                },
            )
            .await;
        }

        ClientMessage::CreateWorktree {
            request_id,
            repo_path,
            branch_name,
            base_branch,
        } => {
            let worktree_path = format!(
                "{}/.orbitdock-worktrees/{}",
                repo_path.trim_end_matches('/'),
                branch_name
            );
            match crate::git::create_worktree(
                &repo_path,
                &worktree_path,
                &branch_name,
                base_branch.as_deref(),
            )
            .await
            {
                Ok(_branch) => {
                    let summary = orbitdock_protocol::WorktreeSummary {
                        id: orbitdock_protocol::new_id(),
                        repo_root: repo_path,
                        worktree_path,
                        branch: branch_name,
                        base_branch,
                        status: orbitdock_protocol::WorktreeStatus::Active,
                        active_session_count: 0,
                        total_session_count: 0,
                        created_at: chrono_now(),
                        last_session_ended_at: None,
                        disk_present: true,
                        auto_prune: true,
                        custom_name: None,
                        created_by: orbitdock_protocol::WorktreeOrigin::User,
                    };
                    // TODO: persist worktree to DB
                    send_json(
                        client_tx,
                        ServerMessage::WorktreeCreated {
                            request_id,
                            worktree: summary,
                        },
                    )
                    .await;
                }
                Err(e) => {
                    send_json(
                        client_tx,
                        ServerMessage::WorktreeError {
                            request_id,
                            code: "create_failed".to_string(),
                            message: e,
                        },
                    )
                    .await;
                }
            }
        }

        ClientMessage::RemoveWorktree {
            request_id,
            worktree_id,
            force,
        } => {
            // TODO: look up worktree_path from DB by worktree_id
            send_json(
                client_tx,
                ServerMessage::WorktreeError {
                    request_id,
                    code: "not_found".to_string(),
                    message: format!(
                        "worktree {worktree_id} not found (force={force}, persistence pending)"
                    ),
                },
            )
            .await;
        }

        ClientMessage::DiscoverWorktrees {
            request_id,
            repo_path,
        } => {
            let worktrees = match crate::git::discover_worktrees(&repo_path).await {
                Ok(discovered) => discovered
                    .into_iter()
                    .map(|w| orbitdock_protocol::WorktreeSummary {
                        id: orbitdock_protocol::new_id(),
                        repo_root: repo_path.clone(),
                        worktree_path: w.path,
                        branch: w.branch.unwrap_or_else(|| "HEAD".to_string()),
                        base_branch: None,
                        status: orbitdock_protocol::WorktreeStatus::Active,
                        active_session_count: 0,
                        total_session_count: 0,
                        created_at: String::new(),
                        last_session_ended_at: None,
                        disk_present: true,
                        auto_prune: true,
                        custom_name: None,
                        created_by: orbitdock_protocol::WorktreeOrigin::Discovered,
                    })
                    .collect(),
                Err(_) => Vec::new(),
            };
            // TODO: upsert discovered worktrees into DB
            send_json(
                client_tx,
                ServerMessage::WorktreesList {
                    request_id,
                    repo_root: Some(repo_path),
                    worktrees,
                },
            )
            .await;
        }

        _ => {} // Only worktree messages should reach here
    }
}
