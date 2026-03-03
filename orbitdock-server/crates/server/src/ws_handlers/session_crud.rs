use std::sync::Arc;

use tokio::sync::{mpsc, oneshot};
use tracing::{debug, error, info, warn};

use orbitdock_protocol::{
    ClaudeIntegrationMode, ClientMessage, CodexIntegrationMode, Message, MessageType, Provider,
    ServerMessage, WorktreeOrigin,
};

use crate::claude_session::{ClaudeAction, ClaudeSession};
use crate::codex_session::{CodexAction, CodexSession};
use crate::persistence::{load_messages_from_transcript_path, load_worktree_by_id, PersistCommand};
use crate::session::SessionHandle;
use crate::session_command::{PersistOp, SessionCommand};
use crate::session_utils::claim_codex_thread_for_direct_session;
use crate::state::SessionRegistry;
use crate::websocket::{send_json, spawn_broadcast_forwarder, OutboundMessage};

fn truncate_messages_before_nth_user_message(
    messages: &[Message],
    nth_user_message: Option<u32>,
) -> Vec<Message> {
    let Some(nth_user_message) = nth_user_message else {
        return messages.to_vec();
    };

    let mut user_count = 0usize;
    let mut cut_idx: Option<usize> = None;

    for (idx, msg) in messages.iter().enumerate() {
        if msg.message_type == MessageType::User {
            if user_count == nth_user_message as usize {
                cut_idx = Some(idx);
                break;
            }
            user_count += 1;
        }
    }

    match cut_idx {
        Some(idx) => messages[..idx].to_vec(),
        None => Vec::new(),
    }
}

fn remap_messages_for_fork(messages: Vec<Message>, new_session_id: &str) -> Vec<Message> {
    let new_session_id = new_session_id.to_string();

    messages
        .into_iter()
        .filter(|msg| !msg.is_in_progress)
        .enumerate()
        .map(|(idx, mut msg)| {
            msg.id = format!("{new_session_id}:fork:{idx}");
            msg.session_id = new_session_id.clone();
            msg.is_in_progress = false;
            msg
        })
        .collect()
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
            let project_name = cwd.split('/').next_back().map(String::from);
            let git_branch = crate::git::resolve_git_branch(&cwd).await;

            let mut handle = crate::session::SessionHandle::new(id.clone(), provider, cwd.clone());
            handle.set_git_branch(git_branch.clone());

            if let Some(ref m) = model {
                handle.set_model(Some(m.clone()));
            }

            if provider == Provider::Codex {
                handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
                handle.set_config(approval_policy.clone(), sandbox_mode.clone());
            } else if provider == Provider::Claude {
                handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Direct));
            }

            // Subscribe the creator before handing off handle
            let rx = handle.subscribe();
            spawn_broadcast_forwarder(rx, client_tx.clone(), Some(id.clone()));

            let summary = handle.summary();
            let snapshot = handle.state();

            // Persist session creation
            let persist_tx = state.persist().clone();
            let _ = persist_tx
                .send(PersistCommand::SessionCreate {
                    id: id.clone(),
                    provider,
                    project_path: cwd.clone(),
                    project_name,
                    branch: git_branch,
                    model: model.clone(),
                    approval_policy: approval_policy.clone(),
                    sandbox_mode: sandbox_mode.clone(),
                    permission_mode: permission_mode.clone(),
                    forked_from_session_id: None,
                })
                .await;

            // Notify creator
            send_json(
                client_tx,
                ServerMessage::SessionSnapshot { session: snapshot },
            )
            .await;

            // Spawn Codex connector if it's a Codex session
            if provider == Provider::Codex {
                let session_id = id.clone();
                let cwd_clone = cwd.clone();
                let model_clone = model.clone();
                let approval_clone = approval_policy.clone();
                let sandbox_clone = sandbox_mode.clone();
                let connector_timeout = std::time::Duration::from_secs(15);
                let task_session_id = session_id.clone();

                // Codex startup does a lot of async initialization. Running it in a
                // dedicated task avoids deep poll stack growth in this large handler.
                let mut connector_task = tokio::spawn(async move {
                    CodexSession::new(
                        task_session_id.clone(),
                        &cwd_clone,
                        model_clone.as_deref(),
                        approval_clone.as_deref(),
                        sandbox_clone.as_deref(),
                    )
                    .await
                });

                let codex_start =
                    match tokio::time::timeout(connector_timeout, &mut connector_task).await {
                        Ok(Ok(Ok(codex_session))) => Ok(codex_session),
                        Ok(Ok(Err(e))) => Err(e.to_string()),
                        Ok(Err(join_err)) => Err(format!("Connector task panicked: {}", join_err)),
                        Err(_) => {
                            connector_task.abort();
                            Err("Connector creation timed out".to_string())
                        }
                    };

                match codex_start {
                    Ok(codex_session) => {
                        let thread_id = codex_session.thread_id().to_string();
                        claim_codex_thread_for_direct_session(
                            state,
                            &persist_tx,
                            &session_id,
                            &thread_id,
                            "legacy_codex_thread_row_cleanup",
                        )
                        .await;

                        handle.set_list_tx(state.list_tx());
                        let (actor_handle, action_tx) = crate::codex_session::start_event_loop(
                            codex_session,
                            handle,
                            persist_tx,
                            state.clone(),
                        );
                        state.add_session_actor(actor_handle);
                        state.set_codex_action_tx(&session_id, action_tx);
                        info!(
                            component = "session",
                            event = "session.create.connector_started",
                            connection_id = conn_id,
                            session_id = %session_id,
                            "Codex connector started"
                        );
                    }
                    Err(error_message) => {
                        // Direct sessions that failed to connect have no way to
                        // receive messages — don't keep as passive (creates ghosts).
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
                // Claude direct session
                let session_id = id.clone();
                let cwd_clone = cwd.clone();
                let model_clone = model.clone();
                let effort_clone = effort.clone();

                match ClaudeSession::new(
                    session_id.clone(),
                    &cwd_clone,
                    model_clone.as_deref(),
                    None,
                    permission_mode.as_deref(),
                    &allowed_tools,
                    &disallowed_tools,
                    effort_clone.as_deref(),
                )
                .await
                {
                    Ok(claude_session) => {
                        handle.set_list_tx(state.list_tx());
                        let (actor_handle, action_tx) = crate::claude_session::start_event_loop(
                            claude_session,
                            handle,
                            persist_tx,
                            state.list_tx(),
                            state.clone(),
                        );

                        // Emit permission_mode delta so the Swift UI picks it up.
                        // The DB row already has it from SessionCreate, but the
                        // initial SessionSnapshot doesn't include it.
                        if let Some(ref mode) = permission_mode {
                            let _ = actor_handle
                                .send(SessionCommand::ApplyDelta {
                                    changes: orbitdock_protocol::StateChanges {
                                        permission_mode: Some(Some(mode.clone())),
                                        ..Default::default()
                                    },
                                    persist_op: None,
                                })
                                .await;
                        }

                        state.add_session_actor(actor_handle);
                        state.set_claude_action_tx(&session_id, action_tx.clone());
                        info!(
                            component = "session",
                            event = "session.create.claude_connector_started",
                            connection_id = conn_id,
                            session_id = %session_id,
                            "Claude connector started"
                        );

                        // Init-timeout watchdog: if the CLI never sends system/init
                        // within 45s, the session is a ghost — kill it.
                        let watchdog_state = state.clone();
                        let watchdog_session_id = session_id.clone();
                        let watchdog_action_tx = action_tx;
                        let watchdog_persist_tx = state.persist().clone();
                        tokio::spawn(async move {
                            tokio::time::sleep(std::time::Duration::from_secs(45)).await;

                            // Check if the session registered a Claude SDK ID (set on init)
                            let has_sdk_id = watchdog_state
                                .claude_sdk_id_for_session(&watchdog_session_id)
                                .is_some();

                            if !has_sdk_id {
                                warn!(
                                    component = "session",
                                    event = "session.init_timeout",
                                    session_id = %watchdog_session_id,
                                    "Claude session never initialized after 45s — ending ghost"
                                );

                                // Kill the CLI subprocess
                                let _ = watchdog_action_tx.send(ClaudeAction::EndSession).await;

                                // End in DB
                                let _ = watchdog_persist_tx
                                    .send(PersistCommand::SessionEnd {
                                        id: watchdog_session_id.clone(),
                                        reason: "init_timeout".to_string(),
                                    })
                                    .await;

                                // Remove from registry and broadcast
                                watchdog_state.remove_session(&watchdog_session_id);
                                watchdog_state.broadcast_to_list(ServerMessage::SessionEnded {
                                    session_id: watchdog_session_id,
                                    reason: "init_timeout".into(),
                                });
                            }
                        });
                    }
                    Err(e) => {
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
                            error = %e,
                            "Failed to start Claude session — ended immediately"
                        );
                        send_json(
                            client_tx,
                            ServerMessage::Error {
                                code: "claude_error".into(),
                                message: e.to_string(),
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
                snap.provider == Provider::Codex
                    && (snap.codex_integration_mode == Some(CodexIntegrationMode::Passive)
                        || (snap.codex_integration_mode != Some(CodexIntegrationMode::Direct)
                            && snap.transcript_path.is_some()))
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

                let (sum_tx, sum_rx) = oneshot::channel();
                actor
                    .send(SessionCommand::GetSummary { reply: sum_tx })
                    .await;
                if let Ok(summary) = sum_rx.await {
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
            let trimmed_branch = branch_name.trim().to_string();
            if trimmed_branch.is_empty() {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "worktree_create_invalid_input".into(),
                        message: "Branch name is required".into(),
                        session_id: Some(source_session_id),
                    },
                )
                .await;
                return;
            }

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

            let repo_root = if let Some(root) = source_snapshot
                .repository_root
                .clone()
                .map(|r| r.trim().to_string())
                .filter(|r| !r.is_empty())
            {
                root
            } else if let Some(git_info) =
                crate::git::resolve_git_info(&source_snapshot.project_path).await
            {
                git_info.common_dir_root
            } else {
                source_snapshot.project_path.clone()
            };

            let worktree_summary = match crate::worktree_service::create_tracked_worktree(
                state,
                &repo_root,
                &trimmed_branch,
                base_branch.as_deref(),
                WorktreeOrigin::User,
            )
            .await
            {
                Ok(summary) => summary,
                Err(err) => {
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "worktree_create_failed".into(),
                            message: err,
                            session_id: Some(source_session_id),
                        },
                    )
                    .await;
                    return;
                }
            };
            let fork_worktree_path = worktree_summary.worktree_path.clone();

            state.broadcast_to_list(ServerMessage::WorktreeCreated {
                request_id: String::new(),
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

            let source_repo_root = if let Some(root) = source_snapshot
                .repository_root
                .clone()
                .map(|r| r.trim().trim_end_matches('/').to_string())
                .filter(|r| !r.is_empty())
            {
                root
            } else if let Some(git_info) =
                crate::git::resolve_git_info(&source_snapshot.project_path).await
            {
                git_info.common_dir_root.trim_end_matches('/').to_string()
            } else {
                source_snapshot
                    .project_path
                    .trim()
                    .trim_end_matches('/')
                    .to_string()
            };

            let target_worktree = match load_worktree_by_id(state.db_path(), &worktree_id) {
                Some(row) => row,
                None => {
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "worktree_not_found".into(),
                            message: format!("Worktree {} not found", worktree_id),
                            session_id: Some(source_session_id),
                        },
                    )
                    .await;
                    return;
                }
            };

            if target_worktree.status == "removed" {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "worktree_not_found".into(),
                        message: "Selected worktree has been removed".into(),
                        session_id: Some(source_session_id),
                    },
                )
                .await;
                return;
            }

            let target_repo_root = target_worktree
                .repo_root
                .trim()
                .trim_end_matches('/')
                .to_string();
            if target_repo_root != source_repo_root {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "worktree_repo_mismatch".into(),
                        message: "Selected worktree belongs to a different repository".into(),
                        session_id: Some(source_session_id),
                    },
                )
                .await;
                return;
            }

            if !crate::git::worktree_exists_on_disk(&target_worktree.worktree_path).await {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "worktree_missing".into(),
                        message: "Selected worktree no longer exists on disk".into(),
                        session_id: Some(source_session_id),
                    },
                )
                .await;
                return;
            }

            Box::pin(handle(
                ClientMessage::ForkSession {
                    source_session_id,
                    nth_user_message,
                    model: None,
                    approval_policy: None,
                    sandbox_mode: None,
                    cwd: Some(target_worktree.worktree_path),
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

            let source_cwd = source_snapshot.as_ref().map(|s| s.project_path.clone());

            let source_model = model
                .clone()
                .or_else(|| source_snapshot.as_ref().and_then(|s| s.model.clone()));
            let source_approval_policy = source_snapshot
                .as_ref()
                .and_then(|s| s.approval_policy.clone());
            let source_sandbox_mode = source_snapshot
                .as_ref()
                .and_then(|s| s.sandbox_mode.clone());
            let effective_approval_policy = approval_policy.clone().or(source_approval_policy);
            let effective_sandbox_mode = sandbox_mode.clone().or(source_sandbox_mode);

            match source_provider {
                Some(Provider::Claude) => {
                    // ── Claude fork: spawn a new CLI, copy messages ──
                    let effective_cwd = cwd
                        .clone()
                        .or(source_cwd)
                        .unwrap_or_else(|| ".".to_string());
                    let project_name = effective_cwd.split('/').next_back().map(String::from);
                    let fork_branch = crate::git::resolve_git_branch(&effective_cwd).await;

                    // Spawn new Claude CLI session (starts fresh — no message copying)
                    let new_id = orbitdock_protocol::new_id();
                    match ClaudeSession::new(
                        new_id.clone(),
                        &effective_cwd,
                        source_model.as_deref(),
                        None,
                        permission_mode.as_deref(),
                        &allowed_tools,
                        &disallowed_tools,
                        None, // effort
                    )
                    .await
                    {
                        Ok(claude_session) => {
                            let mut handle = SessionHandle::new(
                                new_id.clone(),
                                Provider::Claude,
                                effective_cwd.clone(),
                            );
                            handle.set_git_branch(fork_branch.clone());
                            handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Direct));
                            handle.set_forked_from(source_session_id.clone());
                            if let Some(ref m) = source_model {
                                handle.set_model(Some(m.clone()));
                            }

                            let rx = handle.subscribe();
                            spawn_broadcast_forwarder(rx, client_tx.clone(), Some(new_id.clone()));

                            let summary = handle.summary();
                            let snapshot = handle.state();

                            let persist_tx = state.persist().clone();
                            let _ = persist_tx
                                .send(PersistCommand::SessionCreate {
                                    id: new_id.clone(),
                                    provider: Provider::Claude,
                                    project_path: effective_cwd,
                                    project_name,
                                    branch: fork_branch,
                                    model: source_model,
                                    approval_policy: None,
                                    sandbox_mode: None,
                                    permission_mode: permission_mode.clone(),
                                    forked_from_session_id: Some(source_session_id.clone()),
                                })
                                .await;

                            handle.set_list_tx(state.list_tx());
                            let (actor_handle, action_tx) = crate::claude_session::start_event_loop(
                                claude_session,
                                handle,
                                persist_tx,
                                state.list_tx(),
                                state.clone(),
                            );
                            state.add_session_actor(actor_handle);
                            state.set_claude_action_tx(&new_id, action_tx);

                            send_json(
                                client_tx,
                                ServerMessage::SessionSnapshot { session: snapshot },
                            )
                            .await;
                            send_json(
                                client_tx,
                                ServerMessage::SessionForked {
                                    source_session_id: source_session_id.clone(),
                                    new_session_id: new_id.clone(),
                                    forked_from_thread_id: None,
                                },
                            )
                            .await;
                            state.broadcast_to_list(ServerMessage::SessionCreated {
                                session: summary,
                            });

                            info!(
                                component = "session",
                                event = "session.fork.claude_completed",
                                connection_id = conn_id,
                                source_session_id = %source_session_id,
                                new_session_id = %new_id,
                                "Claude session forked successfully"
                            );
                        }
                        Err(e) => {
                            error!(
                                component = "session",
                                event = "session.fork.claude_failed",
                                connection_id = conn_id,
                                source_session_id = %source_session_id,
                                error = %e,
                                "Failed to fork Claude session"
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
                    let effective_cwd = cwd.clone().or(source_cwd);

                    if source_action_tx
                        .send(CodexAction::ForkSession {
                            source_session_id: source_session_id.clone(),
                            nth_user_message,
                            model: model.clone(),
                            approval_policy: effective_approval_policy.clone(),
                            sandbox_mode: effective_sandbox_mode.clone(),
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

                    let new_id = orbitdock_protocol::new_id();
                    let fork_cwd = effective_cwd.unwrap_or_else(|| ".".to_string());
                    let project_name = fork_cwd.split('/').next_back().map(String::from);

                    let fork_branch = crate::git::resolve_git_branch(&fork_cwd).await;
                    let mut handle =
                        SessionHandle::new(new_id.clone(), Provider::Codex, fork_cwd.clone());
                    handle.set_git_branch(fork_branch.clone());
                    handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
                    handle.set_config(
                        effective_approval_policy.clone(),
                        effective_sandbox_mode.clone(),
                    );
                    handle.set_forked_from(source_session_id.clone());

                    let source_fork_messages =
                        if let Some(source_actor) = state.get_session(&source_session_id) {
                            let (state_tx, state_rx) = oneshot::channel();
                            source_actor
                                .send(SessionCommand::GetState { reply: state_tx })
                                .await;

                            match state_rx.await {
                                Ok(source_state) => remap_messages_for_fork(
                                    truncate_messages_before_nth_user_message(
                                        &source_state.messages,
                                        nth_user_message,
                                    ),
                                    &new_id,
                                ),
                                Err(_) => {
                                    warn!(
                                        component = "session",
                                        event = "session.fork.source_state_unavailable",
                                        source_session_id = %source_session_id,
                                        new_session_id = %new_id,
                                        "Failed to read source session state for fork hydration"
                                    );
                                    Vec::new()
                                }
                            }
                        } else {
                            Vec::new()
                        };

                    let rollout_messages =
                        if let Some(rollout_path) = new_connector.rollout_path().await {
                            match load_messages_from_transcript_path(&rollout_path, &new_id).await {
                                Ok(messages) if !messages.is_empty() => {
                                    info!(
                                        component = "session",
                                        event = "session.fork.messages_loaded",
                                        new_session_id = %new_id,
                                        message_count = messages.len(),
                                        "Loaded forked conversation history"
                                    );
                                    messages
                                }
                                Ok(_) => {
                                    debug!(
                                        component = "session",
                                        event = "session.fork.no_messages",
                                        new_session_id = %new_id,
                                        "Forked thread rollout has no parseable messages"
                                    );
                                    Vec::new()
                                }
                                Err(e) => {
                                    warn!(
                                        component = "session",
                                        event = "session.fork.messages_load_failed",
                                        new_session_id = %new_id,
                                        error = %e,
                                        "Failed to load forked conversation history"
                                    );
                                    Vec::new()
                                }
                            }
                        } else {
                            Vec::new()
                        };

                    let forked_messages = if source_fork_messages.len() >= rollout_messages.len() {
                        if !source_fork_messages.is_empty()
                            && rollout_messages.len() < source_fork_messages.len()
                        {
                            info!(
                                component = "session",
                                event = "session.fork.messages_source_selected",
                                new_session_id = %new_id,
                                source_message_count = source_fork_messages.len(),
                                rollout_message_count = rollout_messages.len(),
                                "Selected source session messages for fork hydration"
                            );
                        }
                        source_fork_messages
                    } else {
                        rollout_messages
                    };

                    if !forked_messages.is_empty() {
                        handle.replace_messages(forked_messages.clone());
                    }

                    let rx = handle.subscribe();
                    spawn_broadcast_forwarder(rx, client_tx.clone(), Some(new_id.clone()));

                    let summary = handle.summary();
                    let snapshot = handle.state();

                    let persist_tx = state.persist().clone();

                    let _ = persist_tx
                        .send(PersistCommand::SessionCreate {
                            id: new_id.clone(),
                            provider: Provider::Codex,
                            project_path: fork_cwd,
                            project_name,
                            branch: fork_branch,
                            model,
                            approval_policy: effective_approval_policy,
                            sandbox_mode: effective_sandbox_mode,
                            permission_mode: None,
                            forked_from_session_id: Some(source_session_id.clone()),
                        })
                        .await;

                    for msg in forked_messages {
                        let _ = persist_tx
                            .send(PersistCommand::MessageAppend {
                                session_id: new_id.clone(),
                                message: msg,
                            })
                            .await;
                    }

                    claim_codex_thread_for_direct_session(
                        state,
                        &persist_tx,
                        &new_id,
                        &new_thread_id,
                        "legacy_codex_thread_row_cleanup",
                    )
                    .await;

                    let codex_session = CodexSession {
                        session_id: new_id.clone(),
                        connector: new_connector,
                    };
                    handle.set_list_tx(state.list_tx());
                    let (actor_handle, action_tx) = crate::codex_session::start_event_loop(
                        codex_session,
                        handle,
                        persist_tx,
                        state.clone(),
                    );
                    state.add_session_actor(actor_handle);
                    state.set_codex_action_tx(&new_id, action_tx);

                    send_json(
                        client_tx,
                        ServerMessage::SessionSnapshot { session: snapshot },
                    )
                    .await;
                    send_json(
                        client_tx,
                        ServerMessage::SessionForked {
                            source_session_id: source_session_id.clone(),
                            new_session_id: new_id.clone(),
                            forked_from_thread_id: Some(new_thread_id),
                        },
                    )
                    .await;
                    state.broadcast_to_list(ServerMessage::SessionCreated { session: summary });
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
    use super::*;

    fn mk_msg(id: &str, message_type: MessageType, content: &str) -> Message {
        Message {
            id: id.to_string(),
            session_id: "source".to_string(),
            message_type,
            content: content.to_string(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: false,
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            duration_ms: None,
            images: Vec::new(),
        }
    }

    #[test]
    fn truncate_messages_before_nth_user_message_respects_user_boundaries() {
        let messages = vec![
            mk_msg("0", MessageType::Assistant, "a0"),
            mk_msg("1", MessageType::User, "u0"),
            mk_msg("2", MessageType::Assistant, "a1"),
            mk_msg("3", MessageType::User, "u1"),
            mk_msg("4", MessageType::Assistant, "a2"),
        ];

        let full = truncate_messages_before_nth_user_message(&messages, None);
        assert_eq!(full.len(), 5);

        let before_first_user = truncate_messages_before_nth_user_message(&messages, Some(0));
        assert_eq!(before_first_user.len(), 1);
        assert_eq!(before_first_user[0].content, "a0");

        let before_second_user = truncate_messages_before_nth_user_message(&messages, Some(1));
        assert_eq!(before_second_user.len(), 3);
        assert_eq!(before_second_user[2].content, "a1");

        let out_of_range = truncate_messages_before_nth_user_message(&messages, Some(8));
        assert!(out_of_range.is_empty());
    }

    #[test]
    fn remap_messages_for_fork_reassigns_identity_and_clears_in_progress() {
        let mut msg = mk_msg("orig", MessageType::Assistant, "reply");
        msg.is_in_progress = true;
        let mapped = remap_messages_for_fork(
            vec![msg, mk_msg("orig-2", MessageType::User, "u")],
            "od-new",
        );

        // In-progress source entries are intentionally dropped for stable fork history.
        assert_eq!(mapped.len(), 1);
        assert_eq!(mapped[0].id, "od-new:fork:0");
        assert_eq!(mapped[0].session_id, "od-new");
        assert!(!mapped[0].is_in_progress);
        assert_eq!(mapped[0].content, "u");
    }
}
