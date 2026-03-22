use std::sync::Arc;

use tokio::sync::{mpsc, oneshot};
use tracing::{error, info, warn};

use orbitdock_protocol::conversation_contracts::RowPageSummary;
use orbitdock_protocol::{
    ClaudeIntegrationMode, ClientMessage, CodexIntegrationMode, Provider, ServerMessage,
    SessionListItem, SessionStatus, StateChanges, WorkStatus,
};

use crate::connectors::claude_session::{ClaudeSession, ClaudeSessionConfig};
use crate::connectors::codex_session::CodexSession;
use crate::domain::sessions::session::SessionConfigPatch;
use crate::infrastructure::persistence::{
    load_latest_codex_turn_context_settings_from_transcript_path, load_session_permission_mode,
    PersistCommand,
};
use crate::runtime::restored_sessions::load_prepared_resume_session;
use crate::runtime::session_commands::{PersistOp, SessionCommand, SubscribeResult};
use crate::runtime::session_lifecycle_policy::{plan_takeover_config, TakeoverConfigInputs};
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_runtime_helpers::{
    claim_codex_thread_for_direct_session, direct_mode_activation_changes,
};
use crate::support::session_modes::is_takeover_eligible_passive_session;
use crate::support::session_paths::resolve_claude_resume_cwd;
use crate::support::snapshot_compaction::prepare_snapshot_for_transport;
use crate::transport::websocket::{
    send_json, send_replay_or_snapshot_fallback, spawn_broadcast_forwarder, OutboundMessage,
};

fn stored_codex_control_plane(
    snap: &crate::domain::sessions::session::SessionSnapshot,
) -> orbitdock_connector_codex::CodexControlPlane {
    orbitdock_connector_codex::CodexControlPlane {
        collaboration_mode: snap.collaboration_mode.clone(),
        multi_agent: snap.multi_agent,
        personality: snap.personality.clone(),
        service_tier: snap.service_tier.clone(),
        developer_instructions: snap.developer_instructions.clone(),
    }
}

pub(crate) async fn handle(
    msg: ClientMessage,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<SessionRegistry>,
    conn_id: u64,
) {
    match msg {
        ClientMessage::ResumeSession { session_id } => {
            info!(
                component = "session",
                event = "session.resume.requested",
                connection_id = conn_id,
                session_id = %session_id,
                "Resume session requested"
            );

            // Block only if the session has a running connector (still active).
            // Ended sessions stay in runtime state for the list view but should
            // be resumable — remove the stale handle so we can recreate it below.
            if let Some(handle) = state.get_session(&session_id) {
                let snap = handle.snapshot();
                if snap.status == orbitdock_protocol::SessionStatus::Active {
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "already_active".into(),
                            message: format!("Session {} is already active", session_id),
                            session_id: Some(session_id),
                        },
                    )
                    .await;
                    return;
                }
                // Ended session — remove stale handle so we can re-register
                state.remove_session(&session_id);
            }

            let prepared = match load_prepared_resume_session(&session_id).await {
                Ok(Some(prepared)) => prepared,
                Ok(None) => {
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "not_found".into(),
                            message: format!("Session {} not found in database", session_id),
                            session_id: Some(session_id),
                        },
                    )
                    .await;
                    return;
                }
                Err(e) => {
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "db_error".into(),
                            message: e.to_string(),
                            session_id: Some(session_id),
                        },
                    )
                    .await;
                    return;
                }
            };

            let is_claude = prepared.provider == orbitdock_protocol::Provider::Claude;

            if prepared.transcript_loaded {
                info!(
                    component = "session",
                    event = "session.resume.transcript_loaded",
                    session_id = %session_id,
                    row_count = prepared.row_count,
                    "Loaded messages from transcript for resume"
                );
            }

            let msg_count = prepared.row_count;
            let restored_model = prepared.model.clone();
            let restored_transcript_path = prepared.transcript_path.clone();
            let restored_project_path = prepared.project_path.clone();
            let restored_claude_sdk_session_id = prepared.claude_sdk_session_id.clone();
            let restored_approval_policy = prepared.approval_policy.clone();
            let restored_sandbox_mode = prepared.sandbox_mode.clone();
            let mut handle = prepared.handle;

            // Subscribe the requesting client
            let rx = handle.subscribe();
            spawn_broadcast_forwarder(rx, client_tx.clone(), Some(session_id.clone()));

            // Send the retained session snapshot immediately so the client shows Direct/Active
            // before the connector finishes connecting.
            let snapshot = handle.retained_state();
            send_json(
                client_tx,
                ServerMessage::ConversationBootstrap {
                    session: snapshot,
                    conversation: RowPageSummary {
                        rows: vec![],
                        total_row_count: 0,
                        has_more_before: false,
                        oldest_sequence: None,
                        newest_sequence: None,
                    },
                },
            )
            .await;

            // Broadcast updated summary to session list
            state.broadcast_to_list(ServerMessage::SessionListItemUpdated {
                session: SessionListItem::from_summary(&handle.summary()),
            });

            // Reactivate in DB
            let persist_tx = state.persist().clone();
            let _ = persist_tx
                .send(PersistCommand::ReactivateSession {
                    id: session_id.clone(),
                })
                .await;

            if is_claude {
                // Resolve the correct cwd for --resume
                let project = if let Some(ref tp) = restored_transcript_path {
                    resolve_claude_resume_cwd(&restored_project_path, tp)
                } else {
                    restored_project_path.clone()
                };

                let sid = session_id.clone();
                // Validate through ProviderSessionId — refuse to resume with an OrbitDock ID
                let provider_resume_id = restored_claude_sdk_session_id
                    .clone()
                    .and_then(orbitdock_protocol::ProviderSessionId::new);

                if provider_resume_id.is_none() {
                    warn!(
                        component = "session",
                        event = "session.resume.no_sdk_id",
                        session_id = %session_id,
                        "Cannot resume Claude session — no valid Claude SDK session ID was saved"
                    );
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "resume_failed".into(),
                            message: "Cannot resume this session — no valid Claude SDK session ID was saved. The session may have been interrupted before the CLI initialized.".into(),
                            session_id: Some(session_id.clone()),
                        },
                    )
                    .await;
                    return;
                }
                let provider_resume_id = provider_resume_id.unwrap();

                state.register_claude_thread(&session_id, provider_resume_id.as_str());
                let m = restored_model.clone();
                let restored_permission_mode = load_session_permission_mode(&session_id)
                    .await
                    .unwrap_or(None);
                let connector_timeout = std::time::Duration::from_secs(15);
                let pm = restored_permission_mode.clone();
                let resume_id = provider_resume_id.clone();

                let connector_task = tokio::spawn(async move {
                    ClaudeSession::new(
                        sid.clone(),
                        ClaudeSessionConfig {
                            cwd: &project,
                            model: m.as_deref(),
                            resume_id: Some(&resume_id),
                            permission_mode: pm.as_deref(),
                            allowed_tools: &[],
                            disallowed_tools: &[],
                            effort: None,
                            allow_bypass_permissions: false,
                        },
                    )
                    .await
                });

                match tokio::time::timeout(connector_timeout, connector_task).await {
                    Ok(Ok(Ok(claude_session))) => {
                        state.register_claude_thread(&session_id, provider_resume_id.as_str());

                        handle.set_list_tx(state.list_tx());

                        let (actor_handle, action_tx) =
                            crate::connectors::claude_session::start_event_loop(
                                claude_session,
                                handle,
                                persist_tx.clone(),
                                state.list_tx(),
                                state.clone(),
                            );
                        state.add_session_actor(actor_handle);
                        state.set_claude_action_tx(&session_id, action_tx);

                        if let Some(ref mode) = restored_permission_mode {
                            if let Some(actor) = state.get_session(&session_id) {
                                actor
                                    .send(SessionCommand::ApplyDelta {
                                        changes: StateChanges {
                                            permission_mode: Some(Some(mode.clone())),
                                            ..Default::default()
                                        },
                                        persist_op: None,
                                    })
                                    .await;
                            }
                        }

                        let _ = persist_tx
                            .send(PersistCommand::SetIntegrationMode {
                                session_id: session_id.clone(),
                                codex_mode: None,
                                claude_mode: Some("direct".into()),
                            })
                            .await;

                        info!(
                            component = "session",
                            event = "session.resume.claude_connected",
                            connection_id = conn_id,
                            session_id = %session_id,
                            messages = msg_count,
                            "Resumed Claude session with live connector"
                        );

                        // Send a delta to confirm direct mode to the client.
                        // --resume replays conversation history which can overflow
                        // the broadcast channel — the client may miss state updates.
                        send_json(
                            client_tx,
                            ServerMessage::SessionDelta {
                                session_id: session_id.clone(),
                                changes: StateChanges {
                                    claude_integration_mode: Some(Some(
                                        ClaudeIntegrationMode::Direct,
                                    )),
                                    status: Some(SessionStatus::Active),
                                    work_status: Some(WorkStatus::Waiting),
                                    ..Default::default()
                                },
                            },
                        )
                        .await;
                    }
                    Ok(Ok(Err(e))) => {
                        state.add_session(handle);
                        error!(
                            component = "session",
                            event = "session.resume.connector_failed",
                            connection_id = conn_id,
                            session_id = %session_id,
                            error = %e,
                            "Failed to start Claude connector for resumed session"
                        );
                        send_json(
                            client_tx,
                            ServerMessage::Error {
                                code: "claude_error".into(),
                                message: e.to_string(),
                                session_id: Some(session_id.clone()),
                            },
                        )
                        .await;
                    }
                    Ok(Err(e)) => {
                        state.add_session(handle);
                        error!(
                            component = "session",
                            event = "session.resume.connector_failed",
                            connection_id = conn_id,
                            session_id = %session_id,
                            error = %e,
                            "Claude connector task panicked"
                        );
                    }
                    Err(_) => {
                        state.add_session(handle);
                        error!(
                            component = "session",
                            event = "session.resume.connector_timeout",
                            connection_id = conn_id,
                            session_id = %session_id,
                            "Claude connector timed out"
                        );
                        send_json(
                            client_tx,
                            ServerMessage::Error {
                                code: "timeout".into(),
                                message: "Claude CLI failed to start within 15 seconds".into(),
                                session_id: Some(session_id.clone()),
                            },
                        )
                        .await;
                    }
                }
            } else {
                // Codex connector
                let connector_timeout = std::time::Duration::from_secs(15);
                let task_session_id = session_id.clone();
                let task_project_path = restored_project_path.clone();
                let task_model = restored_model.clone();
                let task_approval = restored_approval_policy.clone();
                let task_sandbox = restored_sandbox_mode.clone();

                let mut connector_task = tokio::spawn(async move {
                    CodexSession::new(
                        task_session_id,
                        &task_project_path,
                        task_model.as_deref(),
                        task_approval.as_deref(),
                        task_sandbox.as_deref(),
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
                        let new_thread_id = codex_session.thread_id().to_string();
                        claim_codex_thread_for_direct_session(
                            state,
                            &persist_tx,
                            &session_id,
                            &new_thread_id,
                            "legacy_codex_thread_row_cleanup",
                        )
                        .await;

                        handle.set_list_tx(state.list_tx());
                        let (actor_handle, action_tx) =
                            crate::connectors::codex_session::start_event_loop(
                                codex_session,
                                handle,
                                persist_tx,
                                state.clone(),
                            );
                        state.add_session_actor(actor_handle);
                        state.set_codex_action_tx(&session_id, action_tx);
                        info!(
                            component = "session",
                            event = "session.resume.connector_started",
                            connection_id = conn_id,
                            session_id = %session_id,
                            thread_id = %new_thread_id,
                            messages = msg_count,
                            "Resumed Codex session with live connector"
                        );
                    }
                    Err(error_message) => {
                        // No connector; add as passive actor
                        state.add_session(handle);
                        error!(
                            component = "session",
                            event = "session.resume.connector_failed",
                            connection_id = conn_id,
                            session_id = %session_id,
                            error = %error_message,
                            "Failed to start Codex connector for resumed session"
                        );
                        send_json(
                            client_tx,
                            ServerMessage::Error {
                                code: "codex_error".into(),
                                message: error_message,
                                session_id: Some(session_id.clone()),
                            },
                        )
                        .await;
                    }
                }
            }
        }

        ClientMessage::TakeoverSession {
            session_id,
            model,
            approval_policy,
            sandbox_mode,
            permission_mode,
            allowed_tools,
            disallowed_tools,
            ..
        } => {
            info!(
                component = "session",
                event = "session.takeover.requested",
                connection_id = conn_id,
                session_id = %session_id,
                "Takeover session requested"
            );

            let actor = match state.get_session(&session_id) {
                Some(a) => a,
                None => {
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "not_found".into(),
                            message: format!("Session {} not found", session_id),
                            session_id: Some(session_id),
                        },
                    )
                    .await;
                    return;
                }
            };

            let snap = actor.snapshot();

            // Validate: must be passive (not already direct).
            // Hook-created Claude sessions have None integration mode — treat as passive.
            let is_passive = is_takeover_eligible_passive_session(
                snap.provider,
                snap.codex_integration_mode,
                snap.claude_integration_mode,
                snap.transcript_path.is_some(),
            );

            if !is_passive {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "not_passive".into(),
                        message: format!(
                            "Session {} is not a passive session — cannot take over",
                            session_id
                        ),
                        session_id: Some(session_id),
                    },
                )
                .await;
                return;
            }

            // Take the handle from the passive actor
            let (take_tx, take_rx) = oneshot::channel();
            actor
                .send(SessionCommand::TakeHandle { reply: take_tx })
                .await;

            let mut handle = match take_rx.await {
                Ok(h) => h,
                Err(_) => {
                    warn!(
                        component = "session",
                        event = "session.takeover.take_failed",
                        session_id = %session_id,
                        "Failed to take handle from passive actor"
                    );
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "take_failed".into(),
                            message: "Failed to take handle from passive session actor".into(),
                            session_id: Some(session_id),
                        },
                    )
                    .await;
                    return;
                }
            };

            handle.set_list_tx(state.list_tx());

            // If the passive handle has no rows, load from transcript file.
            if handle.rows().is_empty() {
                if let Some(ref tp) = snap.transcript_path {
                    if let Ok(rows) =
                        crate::infrastructure::persistence::load_messages_from_transcript_path(
                            tp,
                            &session_id,
                        )
                        .await
                    {
                        if !rows.is_empty() {
                            info!(
                                component = "session",
                                event = "session.takeover.transcript_loaded",
                                session_id = %session_id,
                                row_count = rows.len(),
                                "Loaded rows from transcript for takeover"
                            );
                            for row in rows {
                                handle.add_row(row);
                            }
                        }
                    }
                }
            }

            // Reactivate if ended
            if snap.status == orbitdock_protocol::SessionStatus::Ended {
                let _ = state
                    .persist()
                    .send(PersistCommand::ReactivateSession {
                        id: session_id.clone(),
                    })
                    .await;
            }

            let persist_tx = state.persist().clone();
            let (turn_context_model, turn_context_effort) = if snap.provider == Provider::Codex {
                if let Some(ref transcript_path) = snap.transcript_path {
                    load_latest_codex_turn_context_settings_from_transcript_path(transcript_path)
                        .await
                        .unwrap_or((None, None))
                } else {
                    (None, None)
                }
            } else {
                (None, None)
            };
            let requested_permission_mode = permission_mode.clone();
            let stored_permission_mode =
                if snap.provider == Provider::Claude && requested_permission_mode.is_none() {
                    load_session_permission_mode(&session_id)
                        .await
                        .unwrap_or(None)
                } else {
                    None
                };
            let takeover_plan = plan_takeover_config(TakeoverConfigInputs {
                provider: snap.provider,
                session_model: snap.model.clone(),
                session_effort: snap.effort.clone(),
                session_approval_policy: snap.approval_policy.clone(),
                session_sandbox_mode: snap.sandbox_mode.clone(),
                requested_model: model,
                requested_approval_policy: approval_policy,
                requested_sandbox_mode: sandbox_mode,
                requested_permission_mode,
                turn_context_model,
                turn_context_effort,
                stored_permission_mode,
            });
            let effective_model = takeover_plan.effective_model.clone();
            let effective_effort = takeover_plan.effective_effort.clone();
            let effective_approval = takeover_plan.effective_approval_policy.clone();
            let effective_sandbox = takeover_plan.effective_sandbox_mode.clone();
            let requested_permission_mode = takeover_plan.requested_permission_mode.clone();
            let effective_permission = takeover_plan.effective_permission_mode.clone();
            let connector_timeout = std::time::Duration::from_secs(15);

            let connector_ok = if snap.provider == Provider::Codex {
                let control_plane = stored_codex_control_plane(&snap);
                // Flip integration mode
                handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
                if let Some(ref m) = effective_model {
                    handle.set_model(Some(m.clone()));
                }
                handle.set_config(SessionConfigPatch {
                    approval_policy: effective_approval.clone(),
                    approval_policy_details: None,
                    sandbox_mode: effective_sandbox.clone(),
                    collaboration_mode: control_plane.collaboration_mode.clone(),
                    multi_agent: control_plane.multi_agent,
                    personality: control_plane.personality.clone(),
                    service_tier: control_plane.service_tier.clone(),
                    developer_instructions: control_plane.developer_instructions.clone(),
                    codex_config_mode: None,
                    codex_config_profile: None,
                    codex_model_provider: None,
                    model: effective_model.clone(),
                    effort: effective_effort.clone(),
                    codex_config_source: None,
                    codex_config_overrides: None,
                });

                let thread_id = state.codex_thread_for_session(&session_id);
                let sid = session_id.clone();
                let project = snap.project_path.clone();
                let m = effective_model.clone();
                let ap = effective_approval.clone();
                let sb = effective_sandbox.clone();
                let resume_control_plane = control_plane.clone();
                let new_control_plane = control_plane;

                let mut connector_task = tokio::spawn(async move {
                    if let Some(ref tid) = thread_id {
                        match CodexSession::resume_with_control_plane(
                            sid.clone(),
                            &project,
                            tid,
                            m.as_deref(),
                            ap.as_deref(),
                            sb.as_deref(),
                            resume_control_plane,
                        )
                        .await
                        {
                            Ok(codex) => Ok(codex),
                            Err(_) => {
                                CodexSession::new_with_control_plane(
                                    sid.clone(),
                                    &project,
                                    m.as_deref(),
                                    ap.as_deref(),
                                    sb.as_deref(),
                                    new_control_plane,
                                )
                                .await
                            }
                        }
                    } else {
                        CodexSession::new_with_control_plane(
                            sid.clone(),
                            &project,
                            m.as_deref(),
                            ap.as_deref(),
                            sb.as_deref(),
                            new_control_plane,
                        )
                        .await
                    }
                });

                match tokio::time::timeout(connector_timeout, &mut connector_task).await {
                    Ok(Ok(Ok(codex))) => {
                        let new_thread_id = codex.thread_id().to_string();
                        claim_codex_thread_for_direct_session(
                            state,
                            &persist_tx,
                            &session_id,
                            &new_thread_id,
                            "takeover_thread_cleanup",
                        )
                        .await;

                        let (actor_handle, action_tx) =
                            crate::connectors::codex_session::start_event_loop(
                                codex,
                                handle,
                                persist_tx.clone(),
                                state.clone(),
                            );
                        state.add_session_actor(actor_handle);
                        state.set_codex_action_tx(&session_id, action_tx);

                        if let Some(ref model_name) = effective_model {
                            let _ = persist_tx
                                .send(PersistCommand::ModelUpdate {
                                    session_id: session_id.clone(),
                                    model: model_name.clone(),
                                })
                                .await;
                        }
                        if let Some(ref effort_name) = effective_effort {
                            let _ = persist_tx
                                .send(PersistCommand::EffortUpdate {
                                    session_id: session_id.clone(),
                                    effort: Some(effort_name.clone()),
                                })
                                .await;
                        }

                        // Mark runtime state as active direct mode so clients don't
                        // issue a second resume after takeover.
                        if let Some(actor) = state.get_session(&session_id) {
                            let mut changes = direct_mode_activation_changes(Provider::Codex);
                            if let Some(ref effort_name) = effective_effort {
                                changes.effort = Some(Some(effort_name.clone()));
                            }
                            actor
                                .send(SessionCommand::ApplyDelta {
                                    changes,
                                    persist_op: None,
                                })
                                .await;
                        }

                        let _ = persist_tx
                            .send(PersistCommand::SetIntegrationMode {
                                session_id: session_id.clone(),
                                codex_mode: Some("direct".into()),
                                claude_mode: None,
                            })
                            .await;

                        info!(
                            component = "session",
                            event = "session.takeover.codex_connected",
                            session_id = %session_id,
                            "Codex takeover connector started"
                        );
                        true
                    }
                    Ok(Ok(Err(e))) => {
                        warn!(
                            component = "session",
                            event = "session.takeover.codex_failed",
                            session_id = %session_id,
                            error = %e,
                            "Codex takeover failed, re-registering as passive"
                        );
                        handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
                        state.add_session(handle);
                        send_json(
                            client_tx,
                            ServerMessage::Error {
                                code: "codex_error".into(),
                                message: e.to_string(),
                                session_id: Some(session_id.clone()),
                            },
                        )
                        .await;
                        false
                    }
                    Ok(Err(join_err)) => {
                        warn!(
                            component = "session",
                            event = "session.takeover.codex_panicked",
                            session_id = %session_id,
                            error = %join_err,
                            "Codex takeover connector panicked"
                        );
                        handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
                        state.add_session(handle);
                        send_json(
                            client_tx,
                            ServerMessage::Error {
                                code: "codex_error".into(),
                                message: "Connector task panicked".into(),
                                session_id: Some(session_id.clone()),
                            },
                        )
                        .await;
                        false
                    }
                    Err(_) => {
                        connector_task.abort();
                        warn!(
                            component = "session",
                            event = "session.takeover.codex_timeout",
                            session_id = %session_id,
                            "Codex takeover connector timed out"
                        );
                        handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
                        state.add_session(handle);
                        send_json(
                            client_tx,
                            ServerMessage::Error {
                                code: "codex_error".into(),
                                message: "Connector creation timed out".into(),
                                session_id: Some(session_id.clone()),
                            },
                        )
                        .await;
                        false
                    }
                }
            } else {
                // Claude takeover: resume with --resume flag
                handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Direct));
                if let Some(ref m) = effective_model {
                    handle.set_model(Some(m.clone()));
                }

                let sid = session_id.clone();
                // Claude scopes --resume to ~/.claude/projects/<hash-of-cwd>/,
                // so we must launch from the same cwd where the session was
                // originally started. The DB project_path may be a subdirectory.
                let project = if let Some(ref tp) = snap.transcript_path {
                    resolve_claude_resume_cwd(&snap.project_path, tp)
                } else {
                    snap.project_path.clone()
                };
                let m = effective_model.clone();
                let pm = effective_permission.clone();
                let at = allowed_tools.clone();
                let dt = disallowed_tools.clone();

                // Look up real Claude SDK session ID — don't pass OrbitDock ID as resume
                let takeover_sdk_id = state
                    .claude_sdk_id_for_session(&session_id)
                    .and_then(orbitdock_protocol::ProviderSessionId::new);
                if takeover_sdk_id.is_none() {
                    info!(
                        component = "session",
                        event = "session.takeover.no_sdk_id",
                        session_id = %session_id,
                        "No Claude SDK session ID for takeover — starting fresh session"
                    );
                }

                let takeover_sdk_id_for_spawn = takeover_sdk_id.clone();
                let connector_task = tokio::spawn(async move {
                    ClaudeSession::new(
                        sid.clone(),
                        ClaudeSessionConfig {
                            cwd: &project,
                            model: m.as_deref(),
                            resume_id: takeover_sdk_id_for_spawn.as_ref(),
                            permission_mode: pm.as_deref(),
                            allowed_tools: &at,
                            disallowed_tools: &dt,
                            effort: None,
                            allow_bypass_permissions: false,
                        },
                    )
                    .await
                });

                match tokio::time::timeout(connector_timeout, connector_task).await {
                    Ok(Ok(Ok(claude_session))) => {
                        // Only register thread if we have a real SDK ID
                        if let Some(ref sdk_id) = takeover_sdk_id {
                            state.register_claude_thread(&session_id, sdk_id.as_str());
                        }

                        let (actor_handle, action_tx) =
                            crate::connectors::claude_session::start_event_loop(
                                claude_session,
                                handle,
                                persist_tx.clone(),
                                state.list_tx(),
                                state.clone(),
                            );
                        state.add_session_actor(actor_handle);
                        state.set_claude_action_tx(&session_id, action_tx);

                        if let Some(ref mode) = effective_permission {
                            if let Some(actor) = state.get_session(&session_id) {
                                actor
                                    .send(SessionCommand::ApplyDelta {
                                        changes: orbitdock_protocol::StateChanges {
                                            permission_mode: Some(Some(mode.clone())),
                                            ..Default::default()
                                        },
                                        persist_op: if requested_permission_mode.is_some() {
                                            Some(PersistOp::SetSessionConfig {
                                                session_id: session_id.clone(),
                                                approval_policy: None,
                                                sandbox_mode: None,
                                                permission_mode: Some(Some(mode.clone())),
                                                collaboration_mode: None,
                                                multi_agent: None,
                                                personality: None,
                                                service_tier: None,
                                                developer_instructions: None,
                                                model: None,
                                                effort: None,
                                                codex_config_mode: None,
                                                codex_config_profile: None,
                                                codex_model_provider: None,
                                                codex_config_source: None,
                                                codex_config_overrides_json: None,
                                            })
                                        } else {
                                            None
                                        },
                                    })
                                    .await;
                            }
                        }

                        // Mark runtime state as active direct mode so clients don't
                        // issue a second resume after takeover.
                        if let Some(actor) = state.get_session(&session_id) {
                            actor
                                .send(SessionCommand::ApplyDelta {
                                    changes: direct_mode_activation_changes(Provider::Claude),
                                    persist_op: None,
                                })
                                .await;
                        }

                        let _ = persist_tx
                            .send(PersistCommand::SetIntegrationMode {
                                session_id: session_id.clone(),
                                codex_mode: None,
                                claude_mode: Some("direct".into()),
                            })
                            .await;

                        info!(
                            component = "session",
                            event = "session.takeover.claude_connected",
                            session_id = %session_id,
                            "Claude takeover connector started"
                        );
                        true
                    }
                    Ok(Ok(Err(e))) => {
                        warn!(
                            component = "session",
                            event = "session.takeover.claude_failed",
                            session_id = %session_id,
                            error = %e,
                            "Claude takeover failed, re-registering as passive"
                        );
                        handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Passive));
                        state.add_session(handle);
                        send_json(
                            client_tx,
                            ServerMessage::Error {
                                code: "claude_error".into(),
                                message: e.to_string(),
                                session_id: Some(session_id.clone()),
                            },
                        )
                        .await;
                        false
                    }
                    Ok(Err(join_err)) => {
                        warn!(
                            component = "session",
                            event = "session.takeover.claude_panicked",
                            session_id = %session_id,
                            error = %join_err,
                            "Claude takeover connector panicked"
                        );
                        handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Passive));
                        state.add_session(handle);
                        send_json(
                            client_tx,
                            ServerMessage::Error {
                                code: "claude_error".into(),
                                message: "Connector task panicked".into(),
                                session_id: Some(session_id.clone()),
                            },
                        )
                        .await;
                        false
                    }
                    Err(_) => {
                        warn!(
                            component = "session",
                            event = "session.takeover.claude_timeout",
                            session_id = %session_id,
                            "Claude takeover connector timed out"
                        );
                        handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Passive));
                        state.add_session(handle);
                        send_json(
                            client_tx,
                            ServerMessage::Error {
                                code: "claude_error".into(),
                                message: "Connector creation timed out".into(),
                                session_id: Some(session_id.clone()),
                            },
                        )
                        .await;
                        false
                    }
                }
            };

            if connector_ok {
                // Subscribe the requester to the now-direct session
                if let Some(new_actor) = state.get_session(&session_id) {
                    let (sub_tx, sub_rx) = oneshot::channel();
                    new_actor
                        .send(SessionCommand::Subscribe {
                            since_revision: None,
                            reply: sub_tx,
                        })
                        .await;

                    if let Ok(result) = sub_rx.await {
                        match result {
                            SubscribeResult::Snapshot {
                                state: snapshot,
                                rx,
                            } => {
                                spawn_broadcast_forwarder(
                                    rx,
                                    client_tx.clone(),
                                    Some(session_id.clone()),
                                );
                                send_json(
                                    client_tx,
                                    ServerMessage::ConversationBootstrap {
                                        session: prepare_snapshot_for_transport(*snapshot),
                                        conversation: RowPageSummary {
                                            rows: vec![],
                                            total_row_count: 0,
                                            has_more_before: false,
                                            oldest_sequence: None,
                                            newest_sequence: None,
                                        },
                                    },
                                )
                                .await;
                            }
                            SubscribeResult::Replay { events, rx } => {
                                spawn_broadcast_forwarder(
                                    rx,
                                    client_tx.clone(),
                                    Some(session_id.clone()),
                                );
                                send_replay_or_snapshot_fallback(
                                    client_tx,
                                    &session_id,
                                    events,
                                    conn_id,
                                )
                                .await;
                            }
                        }
                    }

                    // Broadcast updated summary to list subscribers
                    if let Ok(summary) = new_actor.summary().await {
                        state.broadcast_to_list(ServerMessage::SessionListItemUpdated {
                            session: SessionListItem::from_summary(&summary),
                        });
                    }
                }
            }
        }

        _ => {
            warn!(
                component = "session_lifecycle",
                event = "unhandled_message",
                connection_id = conn_id,
                "Received unhandled message variant in session_lifecycle handler"
            );
        }
    }
}
