use std::sync::Arc;

use tokio::sync::{mpsc, oneshot};
use tracing::{debug, error, info, warn};

use orbitdock_protocol::{
    ClaudeIntegrationMode, ClientMessage, CodexIntegrationMode, Provider, ServerMessage,
};

use crate::claude_session::{ClaudeAction, ClaudeSession};
use crate::codex_session::{CodexAction, CodexSession};
use crate::persistence::{load_messages_from_transcript_path, PersistCommand};
use crate::session::SessionHandle;
use crate::session_command::{PersistOp, SessionCommand};
use crate::state::SessionRegistry;
use crate::websocket::{
    claim_codex_thread_for_direct_session, send_json, spawn_broadcast_forwarder, OutboundMessage,
};

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
                    })
                    .await;
            }
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

            // Determine source session's provider
            let source_provider = state
                .get_session(&source_session_id)
                .map(|s| s.snapshot().provider);

            let source_cwd = state
                .get_session(&source_session_id)
                .map(|s| s.snapshot().project_path.clone());

            let source_model = model.clone().or_else(|| {
                state
                    .get_session(&source_session_id)
                    .and_then(|s| s.snapshot().model.clone())
            });

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
                            approval_policy: approval_policy.clone(),
                            sandbox_mode: sandbox_mode.clone(),
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
                    handle.set_config(approval_policy.clone(), sandbox_mode.clone());
                    handle.set_forked_from(source_session_id.clone());

                    let forked_messages =
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
                                    handle.replace_messages(messages.clone());
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
                            approval_policy,
                            sandbox_mode,
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
