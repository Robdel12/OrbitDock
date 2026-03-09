use std::sync::Arc;

use tokio::sync::{mpsc, oneshot};
use tracing::{error, info};

use orbitdock_protocol::{ClientMessage, Provider, ServerMessage};

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_commands::{PersistOp, SessionCommand};
use crate::runtime::session_creation::{
    persist_direct_session_create, prepare_direct_session, DirectSessionCreationInputs,
};
use crate::runtime::session_direct_start::{
    start_direct_claude_session, start_direct_codex_session,
};
use crate::runtime::session_fork_policy::{plan_fork_config, ForkConfigInputs};
use crate::runtime::session_fork_runtime::{
    finalize_codex_fork_session, start_claude_fork_session,
};
use crate::runtime::session_fork_targets::{
    create_fork_target_worktree, resolve_existing_fork_worktree_path, ForkTargetError,
};
use crate::runtime::session_registry::SessionRegistry;
use crate::support::session_modes::is_passive_rollout_session;
use crate::transport::websocket::{send_json, spawn_broadcast_forwarder, OutboundMessage};

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

pub(crate) async fn handle(
    msg: ClientMessage,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<SessionRegistry>,
    conn_id: u64,
) {
    match msg {
        ClientMessage::CreateSession {
            provider,
            cwd,
            model,
            approval_policy,
            sandbox_mode,
            permission_mode,
            allowed_tools,
            disallowed_tools,
            effort,
            system_prompt: _system_prompt,
            append_system_prompt: _append_system_prompt,
        } => {
            info!(
                component = "session",
                event = "session.create.requested",
                connection_id = conn_id,
                provider = %match provider {
                    Provider::Codex => "codex",
                    Provider::Claude => "claude",
                },
                project_path = %cwd,
                "Create session requested"
            );

            let id = orbitdock_protocol::new_id();
            let git_branch = crate::domain::git::repo::resolve_git_branch(&cwd).await;
            let prepared = prepare_direct_session(DirectSessionCreationInputs {
                id: id.clone(),
                provider,
                cwd: cwd.clone(),
                git_branch: git_branch.clone(),
                model: model.clone(),
                approval_policy: approval_policy.clone(),
                sandbox_mode: sandbox_mode.clone(),
                effort: effort.clone(),
            });
            let handle = prepared.handle;

            // Subscribe the creator before handing off handle
            let rx = handle.subscribe();
            spawn_broadcast_forwarder(rx, client_tx.clone(), Some(id.clone()));

            let summary = prepared.summary;
            let snapshot = prepared.snapshot;

            // Persist session creation
            let persist_tx = state.persist().clone();
            persist_direct_session_create(
                &persist_tx,
                id.clone(),
                provider,
                cwd.clone(),
                prepared.project_name,
                git_branch,
                model.clone(),
                approval_policy.clone(),
                sandbox_mode.clone(),
                permission_mode.clone(),
                effort.clone(),
            )
            .await;

            // Notify creator
            send_json(
                client_tx,
                ServerMessage::SessionSnapshot { session: snapshot },
            )
            .await;

            if provider == Provider::Codex {
                let session_id = id.clone();
                match start_direct_codex_session(
                    state,
                    handle,
                    &session_id,
                    &cwd,
                    model.as_deref(),
                    approval_policy.as_deref(),
                    sandbox_mode.as_deref(),
                )
                .await
                {
                    Ok(()) => {}
                    Err(error_message) => {
                        let _ = persist_tx
                            .send(PersistCommand::SessionEnd {
                                id: session_id.clone(),
                                reason: "connector_failed".to_string(),
                            })
                            .await;
                        state.broadcast_to_list(ServerMessage::SessionEnded {
                            session_id: session_id.clone(),
                            reason: "connector_failed".into(),
                        });
                        error!(
                            component = "session",
                            event = "session.create.connector_failed",
                            connection_id = conn_id,
                            session_id = %session_id,
                            error = %error_message,
                            "Failed to start Codex session — ended immediately"
                        );
                        send_json(
                            client_tx,
                            ServerMessage::Error {
                                code: "codex_error".into(),
                                message: error_message,
                                session_id: Some(session_id),
                            },
                        )
                        .await;
                    }
                }
            } else if provider == Provider::Claude {
                let session_id = id.clone();
                match start_direct_claude_session(
                    state,
                    handle,
                    &session_id,
                    &cwd,
                    model.as_deref(),
                    permission_mode.as_deref(),
                    &allowed_tools,
                    &disallowed_tools,
                    effort.as_deref(),
                )
                .await
                {
                    Ok(()) => {}
                    Err(error_message) => {
                        // Direct sessions that failed to connect have no way to
                        // receive messages — don't keep as passive (creates ghosts).
                        // End immediately.
                        let _ = persist_tx
                            .send(PersistCommand::SessionEnd {
                                id: session_id.clone(),
                                reason: "connector_failed".to_string(),
                            })
                            .await;
                        state.broadcast_to_list(ServerMessage::SessionEnded {
                            session_id: session_id.clone(),
                            reason: "connector_failed".into(),
                        });
                        error!(
                            component = "session",
                            event = "session.create.claude_connector_failed",
                            connection_id = conn_id,
                            session_id = %session_id,
                            error = %error_message,
                            "Failed to start Claude session — ended immediately"
                        );
                        send_json(
                            client_tx,
                            ServerMessage::Error {
                                code: "claude_error".into(),
                                message: error_message,
                                session_id: Some(session_id),
                            },
                        )
                        .await;
                    }
                }
            } else {
                state.add_session(handle);
            }

            // Notify list subscribers
            state.broadcast_to_list(ServerMessage::SessionCreated { session: summary });
        }

        ClientMessage::EndSession { session_id } => {
            info!(
                component = "session",
                event = "session.end.requested",
                connection_id = conn_id,
                session_id = %session_id,
                "End session requested"
            );

            let actor = state.get_session(&session_id);
            let is_passive_rollout = if let Some(ref actor) = actor {
                let snap = actor.snapshot();
                is_passive_rollout_session(
                    snap.provider,
                    snap.codex_integration_mode,
                    snap.transcript_path.is_some(),
                )
            } else {
                false
            };

            let canceled_shells = state.shell_service().cancel_session(&session_id);
            if canceled_shells > 0 {
                info!(
                    component = "shell",
                    event = "shell.cancel.session_end",
                    connection_id = conn_id,
                    session_id = %session_id,
                    canceled_shells,
                    "Canceled active shell commands while ending session"
                );
            }

            // Tell direct connectors to shutdown gracefully.
            if !is_passive_rollout {
                if let Some(tx) = state.get_codex_action_tx(&session_id) {
                    let _ = tx.send(CodexAction::EndSession).await;
                } else if let Some(tx) = state.get_claude_action_tx(&session_id) {
                    let _ = tx.send(ClaudeAction::EndSession).await;
                }
            }

            // Persist session end
            let _ = state
                .persist()
                .send(PersistCommand::SessionEnd {
                    id: session_id.clone(),
                    reason: "user_requested".to_string(),
                })
                .await;

            // Passive rollout sessions must remain in-memory so watcher activity can
            // reactivate them in-place (ended -> active) without restart.
            if is_passive_rollout {
                info!(
                    component = "session",
                    event = "session.end.passive_mark_ended",
                    connection_id = conn_id,
                    session_id = %session_id,
                    "Keeping passive rollout session in memory for future watcher reactivation"
                );
                if let Some(actor) = actor {
                    actor.send(SessionCommand::EndLocally).await;
                }
                state.broadcast_to_list(ServerMessage::SessionEnded {
                    session_id,
                    reason: "user_requested".to_string(),
                });
            // Direct sessions are removed from active runtime state.
            } else if state.remove_session(&session_id).is_some() {
                info!(
                    component = "session",
                    event = "session.end.direct_removed",
                    connection_id = conn_id,
                    session_id = %session_id,
                    "Removed direct session from runtime state"
                );
                state.broadcast_to_list(ServerMessage::SessionEnded {
                    session_id,
                    reason: "user_requested".to_string(),
                });
            }
        }

        ClientMessage::RenameSession { session_id, name } => {
            info!(
                component = "session",
                event = "session.rename.requested",
                connection_id = conn_id,
                session_id = %session_id,
                has_name = name.is_some(),
                "Rename session requested"
            );

            if let Some(actor) = state.get_session(&session_id) {
                let (sum_tx, sum_rx) = oneshot::channel();
                actor
                    .send(SessionCommand::SetCustomNameAndNotify {
                        name: name.clone(),
                        persist_op: Some(PersistOp::SetCustomName {
                            session_id: session_id.clone(),
                            name: name.clone(),
                        }),
                        reply: sum_tx,
                    })
                    .await;
                if let Ok(summary) = sum_rx.await {
                    state.broadcast_to_list(ServerMessage::SessionCreated { session: summary });
                }
            }

            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                if let Some(ref n) = name {
                    let _ = tx
                        .send(CodexAction::SetThreadName { name: n.clone() })
                        .await;
                }
            }
        }

        ClientMessage::UpdateSessionConfig {
            session_id,
            approval_policy,
            sandbox_mode,
            permission_mode,
        } => {
            info!(
                component = "session",
                event = "session.config.update_requested",
                connection_id = conn_id,
                session_id = %session_id,
                approval_policy = ?approval_policy,
                sandbox_mode = ?sandbox_mode,
                permission_mode = ?permission_mode,
                "Session config update requested"
            );

            if let Some(actor) = state.get_session(&session_id) {
                actor
                    .send(SessionCommand::ApplyDelta {
                        changes: orbitdock_protocol::StateChanges {
                            approval_policy: Some(approval_policy.clone()),
                            sandbox_mode: Some(sandbox_mode.clone()),
                            permission_mode: Some(permission_mode.clone()),
                            ..Default::default()
                        },
                        persist_op: Some(PersistOp::SetSessionConfig {
                            session_id: session_id.clone(),
                            approval_policy: approval_policy.clone(),
                            sandbox_mode: sandbox_mode.clone(),
                            permission_mode: permission_mode.clone(),
                        }),
                    })
                    .await;

                if let Ok(summary) = actor.summary().await {
                    state.broadcast_to_list(ServerMessage::SessionCreated { session: summary });
                }
            }

            // Send permission_mode to Claude sessions mid-flight
            if let Some(ref mode) = permission_mode {
                if let Some(tx) = state.get_claude_action_tx(&session_id) {
                    let _ = tx
                        .send(ClaudeAction::SetPermissionMode { mode: mode.clone() })
                        .await;
                }
            }

            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx
                    .send(CodexAction::UpdateConfig {
                        approval_policy,
                        sandbox_mode,
                        permission_mode,
                    })
                    .await;
            }
        }

        ClientMessage::ForkSessionToWorktree {
            source_session_id,
            branch_name,
            base_branch,
            nth_user_message,
        } => {
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

            Box::pin(handle(
                ClientMessage::ForkSession {
                    source_session_id,
                    nth_user_message,
                    model: None,
                    approval_policy: None,
                    sandbox_mode: None,
                    cwd: Some(fork_worktree_path),
                    permission_mode: None,
                    allowed_tools: Vec::new(),
                    disallowed_tools: Vec::new(),
                },
                client_tx,
                state,
                conn_id,
            ))
            .await;
        }

        ClientMessage::ForkSessionToExistingWorktree {
            source_session_id,
            worktree_id,
            nth_user_message,
        } => {
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

            let target_worktree_path = match resolve_existing_fork_worktree_path(
                state.db_path(),
                &source_snapshot,
                &worktree_id,
            )
            .await
            {
                Ok(path) => path,
                Err(error) => {
                    send_fork_target_error(client_tx, source_session_id.clone(), error).await;
                    return;
                }
            };

            Box::pin(handle(
                ClientMessage::ForkSession {
                    source_session_id,
                    nth_user_message,
                    model: None,
                    approval_policy: None,
                    sandbox_mode: None,
                    cwd: Some(target_worktree_path),
                    permission_mode: None,
                    allowed_tools: Vec::new(),
                    disallowed_tools: Vec::new(),
                },
                client_tx,
                state,
                conn_id,
            ))
            .await;
        }

        ClientMessage::ForkSession {
            source_session_id,
            nth_user_message,
            model,
            approval_policy,
            sandbox_mode,
            cwd,
            permission_mode,
            allowed_tools,
            disallowed_tools,
        } => {
            info!(
                component = "session",
                event = "session.fork.requested",
                connection_id = conn_id,
                source_session_id = %source_session_id,
                nth_user_message = ?nth_user_message,
                "Fork session requested"
            );

            let source_snapshot = state.get_session(&source_session_id).map(|s| s.snapshot());

            // Determine source session's provider
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
                    // ── Codex fork: use codex-core fork via action channel ──
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
                        Err(e) => {
                            error!(
                                component = "session",
                                event = "session.fork.failed",
                                connection_id = conn_id,
                                source_session_id = %source_session_id,
                                error = %e,
                                "Failed to fork session"
                            );
                            send_json(
                                client_tx,
                                ServerMessage::Error {
                                    code: "fork_failed".into(),
                                    message: e.to_string(),
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

        _ => {
            tracing::warn!(?msg, "session_crud::handle called with unexpected variant");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::handle;
    use crate::domain::sessions::session::SessionHandle;
    use crate::transport::websocket::test_support::new_test_state;
    use crate::transport::websocket::OutboundMessage;
    use orbitdock_protocol::{
        ClientMessage, CodexIntegrationMode, Provider, SessionStatus, WorkStatus,
    };
    use tokio::sync::mpsc;

    #[tokio::test]
    async fn ending_passive_session_keeps_it_available_for_reactivation() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "passive-end-keep".to_string();

        let mut handle_state = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/Users/tester/repo".to_string(),
        );
        handle_state.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
        state.add_session(handle_state);

        handle(
            ClientMessage::EndSession {
                session_id: session_id.clone(),
            },
            &client_tx,
            &state,
            1,
        )
        .await;
        tokio::task::yield_now().await;
        tokio::task::yield_now().await;

        let actor = state
            .get_session(&session_id)
            .expect("passive session should remain in app state");

        let snap = actor.snapshot();
        assert_eq!(snap.status, SessionStatus::Ended);
        assert_eq!(snap.work_status, WorkStatus::Ended);
    }
}
