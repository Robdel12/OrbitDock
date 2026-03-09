use std::sync::Arc;

use tokio::sync::mpsc;
use tracing::{error, info};

use orbitdock_protocol::{Provider, ServerMessage};

use crate::connectors::codex_session::CodexAction;
use crate::runtime::session_fork_policy::{plan_fork_config, ForkConfigInputs};
use crate::runtime::session_fork_runtime::{
    finalize_codex_fork_session, start_claude_fork_session,
};
use crate::runtime::session_fork_targets::{
    create_fork_target_worktree, resolve_existing_fork_worktree_path, ForkTargetError,
};
use crate::runtime::session_registry::SessionRegistry;
use crate::transport::websocket::{send_json, OutboundMessage};

async fn send_fork_target_error(
    client_tx: &mpsc::Sender<OutboundMessage>,
    session_id: String,
    error: ForkTargetError,
) {
    send_json(
        client_tx,
        ServerMessage::Error {
            code: error.code.into(),
            message: error.message,
            session_id: Some(session_id),
        },
    )
    .await;
}

pub(crate) async fn handle_fork_to_worktree(
    source_session_id: String,
    branch_name: String,
    base_branch: Option<String>,
    nth_user_message: Option<u32>,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<SessionRegistry>,
    conn_id: u64,
) {
    let source_snapshot = match state.get_session(&source_session_id) {
        Some(session) => session.snapshot(),
        None => {
            send_json(
                client_tx,
                ServerMessage::Error {
                    code: "not_found".into(),
                    message: format!("Source session {} not found", source_session_id),
                    session_id: Some(source_session_id),
                },
            )
            .await;
            return;
        }
    };

    let worktree_summary = match create_fork_target_worktree(
        state,
        &source_snapshot,
        &branch_name,
        base_branch.as_deref(),
    )
    .await
    {
        Ok(summary) => summary,
        Err(error) => {
            send_fork_target_error(client_tx, source_session_id.clone(), error).await;
            return;
        }
    };
    let fork_worktree_path = worktree_summary.worktree_path.clone();

    state.broadcast_to_list(ServerMessage::WorktreeCreated {
        request_id: String::new(),
        repo_root: worktree_summary.repo_root.clone(),
        worktree_revision: crate::transport::http::revision_now(),
        worktree: worktree_summary,
    });

    handle_fork_session(
        source_session_id,
        nth_user_message,
        None,
        None,
        None,
        Some(fork_worktree_path),
        None,
        Vec::new(),
        Vec::new(),
        client_tx,
        state,
        conn_id,
    )
    .await;
}

pub(crate) async fn handle_fork_to_existing_worktree(
    source_session_id: String,
    worktree_id: String,
    nth_user_message: Option<u32>,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<SessionRegistry>,
    conn_id: u64,
) {
    let source_snapshot = match state.get_session(&source_session_id) {
        Some(session) => session.snapshot(),
        None => {
            send_json(
                client_tx,
                ServerMessage::Error {
                    code: "not_found".into(),
                    message: format!("Source session {} not found", source_session_id),
                    session_id: Some(source_session_id),
                },
            )
            .await;
            return;
        }
    };

    let target_worktree_path =
        match resolve_existing_fork_worktree_path(state.db_path(), &source_snapshot, &worktree_id)
            .await
        {
            Ok(path) => path,
            Err(error) => {
                send_fork_target_error(client_tx, source_session_id.clone(), error).await;
                return;
            }
        };

    handle_fork_session(
        source_session_id,
        nth_user_message,
        None,
        None,
        None,
        Some(target_worktree_path),
        None,
        Vec::new(),
        Vec::new(),
        client_tx,
        state,
        conn_id,
    )
    .await;
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_fork_session(
    source_session_id: String,
    nth_user_message: Option<u32>,
    model: Option<String>,
    approval_policy: Option<String>,
    sandbox_mode: Option<String>,
    cwd: Option<String>,
    permission_mode: Option<String>,
    allowed_tools: Vec<String>,
    disallowed_tools: Vec<String>,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<SessionRegistry>,
    conn_id: u64,
) {
    info!(
        component = "session",
        event = "session.fork.requested",
        connection_id = conn_id,
        source_session_id = %source_session_id,
        nth_user_message = ?nth_user_message,
        "Fork session requested"
    );

    let source_snapshot = state.get_session(&source_session_id).map(|s| s.snapshot());
    let source_provider = source_snapshot.as_ref().map(|s| s.provider);
    let fork_plan = plan_fork_config(ForkConfigInputs {
        requested_model: model.clone(),
        requested_approval_policy: approval_policy.clone(),
        requested_sandbox_mode: sandbox_mode.clone(),
        requested_cwd: cwd.clone(),
        source_cwd: source_snapshot.as_ref().map(|s| s.project_path.clone()),
        source_model: source_snapshot.as_ref().and_then(|s| s.model.clone()),
        source_approval_policy: source_snapshot
            .as_ref()
            .and_then(|s| s.approval_policy.clone()),
        source_sandbox_mode: source_snapshot
            .as_ref()
            .and_then(|s| s.sandbox_mode.clone()),
    });

    match source_provider {
        Some(Provider::Claude) => {
            let effective_cwd = fork_plan
                .effective_cwd
                .clone()
                .unwrap_or_else(|| ".".to_string());
            match start_claude_fork_session(
                state,
                &source_session_id,
                &effective_cwd,
                fork_plan.effective_model.as_deref(),
                permission_mode.as_deref(),
                &allowed_tools,
                &disallowed_tools,
            )
            .await
            {
                Ok(started) => {
                    send_json(
                        client_tx,
                        ServerMessage::SessionSnapshot {
                            session: started.snapshot,
                        },
                    )
                    .await;
                    send_json(
                        client_tx,
                        ServerMessage::SessionForked {
                            source_session_id: source_session_id.clone(),
                            new_session_id: started.new_session_id.clone(),
                            forked_from_thread_id: started.forked_from_thread_id.clone(),
                        },
                    )
                    .await;
                    state.broadcast_to_list(ServerMessage::SessionCreated {
                        session: started.summary,
                    });

                    info!(
                        component = "session",
                        event = "session.fork.claude_completed",
                        connection_id = conn_id,
                        source_session_id = %source_session_id,
                        new_session_id = %started.new_session_id,
                        "Claude session forked successfully"
                    );
                }
                Err(error_message) => {
                    error!(
                        component = "session",
                        event = "session.fork.claude_failed",
                        connection_id = conn_id,
                        source_session_id = %source_session_id,
                        error = %error_message,
                        "Failed to fork Claude session"
                    );
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "fork_failed".into(),
                            message: error_message,
                            session_id: Some(source_session_id),
                        },
                    )
                    .await;
                }
            }
        }
        Some(Provider::Codex) => {
            let source_action_tx = match state.get_codex_action_tx(&source_session_id) {
                Some(tx) => tx,
                None => {
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "not_found".into(),
                            message: format!(
                                "Source session {} has no active Codex connector",
                                source_session_id
                            ),
                            session_id: Some(source_session_id),
                        },
                    )
                    .await;
                    return;
                }
            };

            let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();
            let effective_cwd = fork_plan.effective_cwd.clone();
            if source_action_tx
                .send(CodexAction::ForkSession {
                    source_session_id: source_session_id.clone(),
                    nth_user_message,
                    model: fork_plan.effective_model.clone(),
                    approval_policy: fork_plan.effective_approval_policy.clone(),
                    sandbox_mode: fork_plan.effective_sandbox_mode.clone(),
                    cwd: effective_cwd.clone(),
                    reply_tx,
                })
                .await
                .is_err()
            {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "channel_closed".into(),
                        message: "Source session's action channel is closed".into(),
                        session_id: Some(source_session_id),
                    },
                )
                .await;
                return;
            }

            let fork_result = match reply_rx.await {
                Ok(result) => result,
                Err(_) => {
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "fork_failed".into(),
                            message: "Fork operation was cancelled".into(),
                            session_id: Some(source_session_id),
                        },
                    )
                    .await;
                    return;
                }
            };

            let (new_connector, new_thread_id) = match fork_result {
                Ok(result) => result,
                Err(error) => {
                    error!(
                        component = "session",
                        event = "session.fork.failed",
                        connection_id = conn_id,
                        source_session_id = %source_session_id,
                        error = %error,
                        "Failed to fork session"
                    );
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "fork_failed".into(),
                            message: error.to_string(),
                            session_id: Some(source_session_id),
                        },
                    )
                    .await;
                    return;
                }
            };

            let fork_cwd = effective_cwd.unwrap_or_else(|| ".".to_string());
            match finalize_codex_fork_session(
                state,
                &source_session_id,
                nth_user_message,
                &fork_cwd,
                fork_plan.effective_model.as_deref(),
                fork_plan.effective_approval_policy.as_deref(),
                fork_plan.effective_sandbox_mode.as_deref(),
                new_connector,
                new_thread_id,
            )
            .await
            {
                Ok(started) => {
                    send_json(
                        client_tx,
                        ServerMessage::SessionSnapshot {
                            session: started.snapshot,
                        },
                    )
                    .await;
                    send_json(
                        client_tx,
                        ServerMessage::SessionForked {
                            source_session_id: source_session_id.clone(),
                            new_session_id: started.new_session_id.clone(),
                            forked_from_thread_id: started.forked_from_thread_id.clone(),
                        },
                    )
                    .await;
                    state.broadcast_to_list(ServerMessage::SessionCreated {
                        session: started.summary,
                    });
                }
                Err(error_message) => {
                    error!(
                        component = "session",
                        event = "session.fork.finalize_failed",
                        connection_id = conn_id,
                        source_session_id = %source_session_id,
                        error = %error_message,
                        "Failed to finalize Codex forked session"
                    );
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "fork_failed".into(),
                            message: error_message,
                            session_id: Some(source_session_id),
                        },
                    )
                    .await;
                }
            }
        }
        None => {
            send_json(
                client_tx,
                ServerMessage::Error {
                    code: "not_found".into(),
                    message: format!("Source session {} not found", source_session_id),
                    session_id: Some(source_session_id),
                },
            )
            .await;
        }
    }
}
