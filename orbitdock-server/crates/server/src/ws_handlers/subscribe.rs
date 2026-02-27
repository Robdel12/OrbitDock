use std::sync::Arc;
use std::time::UNIX_EPOCH;

use tokio::sync::{mpsc, oneshot};
use tracing::{error, info, warn};

use orbitdock_protocol::{
    ClaudeIntegrationMode, ClientMessage, CodexIntegrationMode, Provider, ServerMessage,
    SessionState, SessionStatus, StateChanges, TokenUsage, WorkStatus,
};

use crate::claude_session::ClaudeSession;
use crate::codex_session::CodexSession;
use crate::persistence::{
    load_messages_for_session, load_messages_from_transcript_path, load_session_by_id,
    PersistCommand,
};
use crate::session_command::{PersistOp, SessionCommand, SubscribeResult};
use crate::state::SessionRegistry;
use crate::websocket::{
    chrono_now, claim_codex_thread_for_direct_session, parse_unix_z, send_json,
    send_replay_or_snapshot_fallback, send_snapshot_if_requested, spawn_broadcast_forwarder,
    OutboundMessage,
};

pub(crate) async fn handle(
    msg: ClientMessage,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<SessionRegistry>,
    conn_id: u64,
) {
    match msg {
        ClientMessage::SubscribeList => {
            let rx = state.subscribe_list();
            spawn_broadcast_forwarder(rx, client_tx.clone(), None);

            // Send current list
            let sessions = state.get_session_summaries();
            send_json(client_tx, ServerMessage::SessionsList { sessions }).await;
        }

        ClientMessage::SubscribeSession {
            session_id,
            since_revision,
            include_snapshot,
        } => {
            if let Some(actor) = state.get_session(&session_id) {
                let snap = actor.snapshot();

                // Check for passive ended sessions that may need reactivation
                let is_passive_ended = snap.provider == Provider::Codex
                    && snap.status == SessionStatus::Ended
                    && (snap.codex_integration_mode == Some(CodexIntegrationMode::Passive)
                        || (snap.codex_integration_mode != Some(CodexIntegrationMode::Direct)
                            && snap.transcript_path.is_some()));
                if is_passive_ended {
                    let should_reactivate = snap
                        .transcript_path
                        .as_deref()
                        .and_then(|path| std::fs::metadata(path).ok())
                        .and_then(|meta| meta.modified().ok())
                        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
                        .map(|d| d.as_secs())
                        .zip(parse_unix_z(snap.last_activity_at.as_deref()))
                        .map(|(modified_at, last_activity_at)| modified_at > last_activity_at)
                        .unwrap_or(false);
                    if should_reactivate {
                        let now = chrono_now();
                        actor
                            .send(SessionCommand::ApplyDelta {
                                changes: StateChanges {
                                    status: Some(SessionStatus::Active),
                                    work_status: Some(WorkStatus::Waiting),
                                    last_activity_at: Some(now),
                                    ..Default::default()
                                },
                                persist_op: Some(PersistOp::SessionUpdate {
                                    id: session_id.clone(),
                                    status: Some(SessionStatus::Active),
                                    work_status: Some(WorkStatus::Waiting),
                                    last_activity_at: Some(chrono_now()),
                                }),
                            })
                            .await;

                        let _ = state
                            .persist()
                            .send(PersistCommand::RolloutSessionUpdate {
                                id: session_id.clone(),
                                project_path: None,
                                model: None,
                                status: Some(SessionStatus::Active),
                                work_status: Some(WorkStatus::Waiting),
                                attention_reason: Some(Some("awaitingReply".to_string())),
                                pending_tool_name: Some(None),
                                pending_tool_input: Some(None),
                                pending_question: Some(None),
                                total_tokens: None,
                                last_tool: None,
                                last_tool_at: None,
                                custom_name: None,
                            })
                            .await;

                        let (sum_tx, sum_rx) = oneshot::channel();
                        actor
                            .send(SessionCommand::GetSummary { reply: sum_tx })
                            .await;
                        if let Ok(summary) = sum_rx.await {
                            state.broadcast_to_list(ServerMessage::SessionCreated {
                                session: summary,
                            });
                        }

                        // Subscribe via actor command
                        let (sub_tx, sub_rx) = oneshot::channel();
                        actor
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
                                    send_snapshot_if_requested(
                                        client_tx,
                                        &session_id,
                                        *snapshot,
                                        include_snapshot,
                                        conn_id,
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
                                        &actor,
                                        client_tx,
                                        &session_id,
                                        events,
                                        conn_id,
                                    )
                                    .await;
                                }
                            }
                        }
                        return;
                    }
                }

                // Lazy connector creation: if the session needs a live connector
                // but doesn't have one yet, create it now on first subscribe.
                let needs_lazy_connector = {
                    let is_active_codex_direct = snap.provider == Provider::Codex
                        && snap.status == SessionStatus::Active
                        && snap.codex_integration_mode == Some(CodexIntegrationMode::Direct)
                        && !state.has_codex_connector(&session_id);
                    let is_claude_direct_needing_connector = snap.provider == Provider::Claude
                        && snap.claude_integration_mode == Some(ClaudeIntegrationMode::Direct)
                        && !state.has_claude_connector(&session_id)
                        && snap.status == SessionStatus::Active;
                    is_active_codex_direct || is_claude_direct_needing_connector
                };

                if needs_lazy_connector {
                    info!(
                        component = "session",
                        event = "session.lazy_connector.starting",
                        connection_id = conn_id,
                        session_id = %session_id,
                        provider = ?snap.provider,
                        "Creating connector lazily on first subscribe"
                    );

                    // Take the handle from the passive actor
                    let (take_tx, take_rx) = oneshot::channel();
                    actor
                        .send(SessionCommand::TakeHandle { reply: take_tx })
                        .await;

                    if let Ok(mut handle) = take_rx.await {
                        handle.set_list_tx(state.list_tx());
                        let persist_tx = state.persist().clone();

                        // Wrap connector creation in a spawned task + timeout.
                        // CodexSession::resume/new may block the executor thread
                        // (codex-core spawns processes), so we need a separate task
                        // for the timeout to actually fire.
                        let connector_timeout = std::time::Duration::from_secs(10);
                        let connector_ok = if snap.provider == Provider::Codex {
                            let thread_id = state.codex_thread_for_session(&session_id);
                            let sid = session_id.clone();
                            let project = snap.project_path.clone();
                            let model = snap.model.clone();
                            let approval = snap.approval_policy.clone();
                            let sandbox = snap.sandbox_mode.clone();

                            let mut connector_task = tokio::spawn(async move {
                                if let Some(ref tid) = thread_id {
                                    match CodexSession::resume(
                                        sid.clone(),
                                        &project,
                                        tid,
                                        model.as_deref(),
                                        approval.as_deref(),
                                        sandbox.as_deref(),
                                    )
                                    .await
                                    {
                                        Ok(codex) => Ok(codex),
                                        Err(_) => {
                                            CodexSession::new(
                                                sid.clone(),
                                                &project,
                                                model.as_deref(),
                                                approval.as_deref(),
                                                sandbox.as_deref(),
                                            )
                                            .await
                                        }
                                    }
                                } else {
                                    CodexSession::new(
                                        sid.clone(),
                                        &project,
                                        model.as_deref(),
                                        approval.as_deref(),
                                        sandbox.as_deref(),
                                    )
                                    .await
                                }
                            });
                            match tokio::time::timeout(connector_timeout, &mut connector_task).await
                            {
                                Ok(Ok(Ok(codex))) => {
                                    let new_thread_id = codex.thread_id().to_string();
                                    claim_codex_thread_for_direct_session(
                                        state,
                                        &persist_tx,
                                        &session_id,
                                        &new_thread_id,
                                        "legacy_codex_thread_row_cleanup",
                                    )
                                    .await;
                                    let (actor_handle, action_tx) =
                                        crate::codex_session::start_event_loop(
                                            codex,
                                            handle,
                                            persist_tx,
                                            state.clone(),
                                        );
                                    state.add_session_actor(actor_handle);
                                    state.set_codex_action_tx(&session_id, action_tx);
                                    info!(
                                        component = "session",
                                        event = "session.lazy_connector.codex_connected",
                                        session_id = %session_id,
                                        "Lazy Codex connector created"
                                    );
                                    true
                                }
                                Ok(Ok(Err(e))) => {
                                    warn!(
                                        component = "session",
                                        event = "session.lazy_connector.codex_failed",
                                        session_id = %session_id,
                                        error = %e,
                                        "Failed to create lazy Codex connector, re-registering passive"
                                    );
                                    state.add_session(handle);
                                    false
                                }
                                Ok(Err(join_err)) => {
                                    warn!(
                                        component = "session",
                                        event = "session.lazy_connector.codex_panicked",
                                        session_id = %session_id,
                                        error = %join_err,
                                        "Codex connector task panicked, re-registering passive"
                                    );
                                    state.add_session(handle);
                                    false
                                }
                                Err(_) => {
                                    connector_task.abort();
                                    warn!(
                                        component = "session",
                                        event = "session.lazy_connector.codex_timeout",
                                        session_id = %session_id,
                                        "Codex connector creation timed out, re-registering passive"
                                    );
                                    state.add_session(handle);
                                    false
                                }
                            }
                        } else {
                            // Claude direct session
                            let mut sdk_id = state.claude_sdk_id_for_session(&session_id);
                            if sdk_id.is_none() {
                                // Resume attempts can temporarily remove the runtime thread map.
                                // Fall back to persisted SDK session ID so lazy reconnect keeps context.
                                if let Ok(Some(restored_session)) =
                                    load_session_by_id(&session_id).await
                                {
                                    sdk_id = restored_session.claude_sdk_session_id;
                                    // Don't fall back to session_id — it's an OrbitDock ID
                                }
                            }
                            // Validate through ProviderSessionId to prevent passing od- IDs
                            let provider_id = sdk_id
                                .as_deref()
                                .and_then(orbitdock_protocol::ProviderSessionId::new);
                            if let Some(ref pid) = provider_id {
                                state.register_claude_thread(&session_id, pid.as_str());
                            }
                            let sid = session_id.clone();
                            let project = snap.project_path.clone();
                            let model = snap.model.clone();

                            let connector_task = tokio::spawn(async move {
                                ClaudeSession::new(
                                    sid,
                                    &project,
                                    model.as_deref(),
                                    provider_id.as_ref(),
                                    None,
                                    &[],
                                    &[],
                                    None, // effort
                                )
                                .await
                            });
                            match tokio::time::timeout(connector_timeout, connector_task).await {
                                Ok(Ok(Ok(claude_session))) => {
                                    let (actor_handle, action_tx) =
                                        crate::claude_session::start_event_loop(
                                            claude_session,
                                            handle,
                                            persist_tx,
                                            state.list_tx(),
                                            state.clone(),
                                        );
                                    state.add_session_actor(actor_handle);
                                    state.set_claude_action_tx(&session_id, action_tx);
                                    info!(
                                        component = "session",
                                        event = "session.lazy_connector.claude_connected",
                                        session_id = %session_id,
                                        "Lazy Claude connector created"
                                    );
                                    true
                                }
                                Ok(Ok(Err(e))) => {
                                    warn!(
                                        component = "session",
                                        event = "session.lazy_connector.claude_failed",
                                        session_id = %session_id,
                                        error = %e,
                                        "Failed to create lazy Claude connector, re-registering passive"
                                    );
                                    state.add_session(handle);
                                    false
                                }
                                Ok(Err(join_err)) => {
                                    warn!(
                                        component = "session",
                                        event = "session.lazy_connector.claude_panicked",
                                        session_id = %session_id,
                                        error = %join_err,
                                        "Claude connector task panicked, re-registering passive"
                                    );
                                    state.add_session(handle);
                                    false
                                }
                                Err(_) => {
                                    warn!(
                                        component = "session",
                                        event = "session.lazy_connector.claude_timeout",
                                        session_id = %session_id,
                                        "Claude connector creation timed out, re-registering passive"
                                    );
                                    state.add_session(handle);
                                    false
                                }
                            }
                        };

                        // Subscribe — either from new active actor or re-registered passive
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
                                        let mut snapshot = *snapshot;
                                        if snapshot.subagents.is_empty() {
                                            if let Ok(subagents) =
                                                crate::persistence::load_subagents_for_session(
                                                    &session_id,
                                                )
                                                .await
                                            {
                                                snapshot.subagents = subagents;
                                            }
                                        }
                                        spawn_broadcast_forwarder(
                                            rx,
                                            client_tx.clone(),
                                            Some(session_id.clone()),
                                        );
                                        send_snapshot_if_requested(
                                            client_tx,
                                            &session_id,
                                            snapshot,
                                            include_snapshot,
                                            conn_id,
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
                                            &new_actor,
                                            client_tx,
                                            &session_id,
                                            events,
                                            conn_id,
                                        )
                                        .await;
                                    }
                                }
                            }
                        }
                        let _ = connector_ok;
                        return;
                    }
                    // TakeHandle failed — fall through to normal subscribe
                    warn!(
                        component = "session",
                        event = "session.lazy_connector.take_failed",
                        session_id = %session_id,
                        "Failed to take handle from passive actor, falling through to normal subscribe"
                    );
                }

                // Normal subscribe flow via actor command
                let (sub_tx, sub_rx) = oneshot::channel();
                actor
                    .send(SessionCommand::Subscribe {
                        since_revision,
                        reply: sub_tx,
                    })
                    .await;

                if let Ok(result) = sub_rx.await {
                    match result {
                        SubscribeResult::Replay { events, rx } => {
                            info!(
                                component = "websocket",
                                event = "ws.subscribe.replay",
                                connection_id = conn_id,
                                session_id = %session_id,
                                replay_count = events.len(),
                                "Replaying {} events for session",
                                events.len()
                            );
                            spawn_broadcast_forwarder(
                                rx,
                                client_tx.clone(),
                                Some(session_id.clone()),
                            );
                            send_replay_or_snapshot_fallback(
                                &actor,
                                client_tx,
                                &session_id,
                                events,
                                conn_id,
                            )
                            .await;
                        }
                        SubscribeResult::Snapshot {
                            state: snapshot,
                            rx,
                        } => {
                            let mut snapshot = *snapshot;
                            // If snapshot has no messages, try loading from transcript or database
                            if snapshot.messages.is_empty() {
                                // First try transcript (for Codex sessions)
                                if let Some(path) = snapshot.transcript_path.clone() {
                                    let (reply_tx, reply_rx) = oneshot::channel();
                                    actor
                                        .send(SessionCommand::LoadTranscriptAndSync {
                                            path,
                                            session_id: session_id.clone(),
                                            reply: reply_tx,
                                        })
                                        .await;
                                    if let Ok(Some(loaded_snapshot)) = reply_rx.await {
                                        snapshot = loaded_snapshot;
                                    }
                                }
                                // If still empty, try loading from database (for Claude sessions)
                                if snapshot.messages.is_empty() {
                                    if let Ok(messages) =
                                        load_messages_for_session(&session_id).await
                                    {
                                        if !messages.is_empty() {
                                            snapshot.messages = messages;
                                        }
                                    }
                                }
                            }

                            // Enrich snapshot with subagents from DB
                            if snapshot.subagents.is_empty() {
                                if let Ok(subagents) =
                                    crate::persistence::load_subagents_for_session(&session_id)
                                        .await
                                {
                                    snapshot.subagents = subagents;
                                }
                            }

                            spawn_broadcast_forwarder(
                                rx,
                                client_tx.clone(),
                                Some(session_id.clone()),
                            );
                            send_snapshot_if_requested(
                                client_tx,
                                &session_id,
                                snapshot,
                                include_snapshot,
                                conn_id,
                            )
                            .await;
                        }
                    }
                }
            } else {
                // Session not in runtime state — try loading from database (closed session)
                match load_session_by_id(&session_id).await {
                    Ok(Some(mut restored)) => {
                        // Load messages from transcript if DB has none (passive sessions)
                        if restored.messages.is_empty() {
                            if let Some(ref tp) = restored.transcript_path {
                                if let Ok(msgs) =
                                    load_messages_from_transcript_path(tp, &session_id).await
                                {
                                    if !msgs.is_empty() {
                                        restored.messages = msgs;
                                    }
                                }
                            }
                        }

                        // Determine provider
                        let provider = if restored.provider == "claude" {
                            Provider::Claude
                        } else {
                            Provider::Codex
                        };

                        // Determine status - ended if end_reason is set
                        let (status, work_status) = if restored.end_reason.is_some() {
                            (SessionStatus::Ended, WorkStatus::Ended)
                        } else {
                            (SessionStatus::Active, WorkStatus::Waiting)
                        };

                        // Parse integration modes
                        let codex_integration_mode = restored
                            .codex_integration_mode
                            .as_deref()
                            .and_then(|s| match s {
                                "direct" => Some(CodexIntegrationMode::Direct),
                                "passive" => Some(CodexIntegrationMode::Passive),
                                _ => None,
                            });
                        let claude_integration_mode = restored
                            .claude_integration_mode
                            .as_deref()
                            .and_then(|s| match s {
                                "direct" => Some(ClaudeIntegrationMode::Direct),
                                "passive" => Some(ClaudeIntegrationMode::Passive),
                                _ => None,
                            });

                        // Build SessionState for transport
                        let state = SessionState {
                            id: restored.id,
                            provider,
                            project_path: restored.project_path,
                            transcript_path: restored.transcript_path,
                            project_name: restored.project_name,
                            model: restored.model,
                            custom_name: restored.custom_name,
                            summary: restored.summary,
                            first_prompt: restored.first_prompt,
                            last_message: restored.last_message,
                            status,
                            work_status,
                            messages: restored.messages,
                            pending_approval: None,
                            permission_mode: restored.permission_mode,
                            pending_tool_name: restored.pending_tool_name,
                            pending_tool_input: restored.pending_tool_input,
                            pending_question: restored.pending_question,
                            pending_approval_id: restored.pending_approval_id,
                            token_usage: TokenUsage {
                                input_tokens: restored.input_tokens as u64,
                                output_tokens: restored.output_tokens as u64,
                                cached_tokens: restored.cached_tokens as u64,
                                context_window: restored.context_window as u64,
                            },
                            token_usage_snapshot_kind: restored.token_usage_snapshot_kind,
                            current_diff: restored.current_diff,
                            current_plan: restored.current_plan,
                            codex_integration_mode,
                            claude_integration_mode,
                            approval_policy: restored.approval_policy,
                            sandbox_mode: restored.sandbox_mode,
                            started_at: restored.started_at,
                            last_activity_at: restored.last_activity_at,
                            forked_from_session_id: restored.forked_from_session_id,
                            revision: Some(0),
                            current_turn_id: None,
                            turn_count: 0,
                            turn_diffs: restored
                                .turn_diffs
                                .into_iter()
                                .map(|(tid, diff, inp, out, cached, ctx, snapshot_kind)| {
                                    orbitdock_protocol::TurnDiff {
                                        turn_id: tid,
                                        diff,
                                        token_usage: Some(TokenUsage {
                                            input_tokens: inp as u64,
                                            output_tokens: out as u64,
                                            cached_tokens: cached as u64,
                                            context_window: ctx as u64,
                                        }),
                                        snapshot_kind: Some(snapshot_kind),
                                    }
                                })
                                .collect(),
                            git_branch: restored.git_branch,
                            git_sha: restored.git_sha,
                            current_cwd: restored.current_cwd,
                            subagents: Vec::new(),
                            effort: restored.effort,
                            terminal_session_id: restored.terminal_session_id,
                            terminal_app: restored.terminal_app,
                            approval_version: Some(restored.approval_version),
                            repository_root: None,
                            is_worktree: false,
                            worktree_id: None,
                        };

                        send_snapshot_if_requested(
                            client_tx,
                            &session_id,
                            state,
                            include_snapshot,
                            conn_id,
                        )
                        .await;
                    }
                    Ok(None) => {
                        send_json(
                            client_tx,
                            ServerMessage::Error {
                                code: "not_found".into(),
                                message: format!("Session {} not found", session_id),
                                session_id: Some(session_id),
                            },
                        )
                        .await;
                    }
                    Err(e) => {
                        error!(
                            component = "websocket",
                            event = "session.subscribe.db_error",
                            session_id = %session_id,
                            error = %e,
                            "Failed to load session from database"
                        );
                        send_json(
                            client_tx,
                            ServerMessage::Error {
                                code: "db_error".into(),
                                message: e.to_string(),
                                session_id: Some(session_id),
                            },
                        )
                        .await;
                    }
                }
            }
        }

        ClientMessage::UnsubscribeSession { session_id: _ } => {
            // No-op: broadcast receivers clean up automatically when the
            // forwarder task exits (client disconnect drops the Receiver).
        }

        _ => {}
    }
}
