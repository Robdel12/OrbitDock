//! WebSocket handling

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::{
    extract::{
        ws::{Message, WebSocket},
        State, WebSocketUpgrade,
    },
    response::IntoResponse,
};
use bytes::Bytes;
use futures::{SinkExt, StreamExt};
use serde_json::Value;
use tokio::sync::{mpsc, Mutex};
use tracing::{debug, error, info, warn};

use orbitdock_connectors::discover_models;
use orbitdock_protocol::{
    ClientMessage, CodexIntegrationMode, Provider, ServerMessage, SessionState, TokenUsage,
};

use crate::codex_session::{CodexAction, CodexSession};
use crate::persistence::{
    delete_approval, list_approvals, load_messages_from_transcript_path, load_session_by_id,
    PersistCommand,
};
use crate::session::SessionHandle;
use crate::session_naming::name_from_first_prompt;
use crate::state::AppState;

static NEXT_CONNECTION_ID: AtomicU64 = AtomicU64::new(1);

fn work_status_for_approval_decision(decision: &str) -> orbitdock_protocol::WorkStatus {
    let normalized = decision.trim().to_lowercase();
    if matches!(
        normalized.as_str(),
        "approved" | "approved_for_session" | "approved_always"
    ) {
        orbitdock_protocol::WorkStatus::Working
    } else {
        orbitdock_protocol::WorkStatus::Waiting
    }
}

const CLAUDE_EMPTY_SHELL_TTL_SECS: u64 = 5 * 60;
const SNAPSHOT_MAX_MESSAGES: usize = 200;
const SNAPSHOT_MAX_CONTENT_CHARS: usize = 16_000;

/// Messages that can be sent through the WebSocket
#[allow(clippy::large_enum_variant)]
enum OutboundMessage {
    /// JSON-serialized ServerMessage
    Json(ServerMessage),
    /// Raw pong response
    Pong(Bytes),
}

/// WebSocket upgrade handler
pub async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<Arc<Mutex<AppState>>>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

/// Handle a WebSocket connection
async fn handle_socket(socket: WebSocket, state: Arc<Mutex<AppState>>) {
    let conn_id = NEXT_CONNECTION_ID.fetch_add(1, Ordering::Relaxed);
    info!(
        component = "websocket",
        event = "ws.connection.opened",
        connection_id = conn_id,
        "WebSocket connection opened"
    );

    let (mut ws_tx, mut ws_rx) = socket.split();

    // Channel for sending messages to this client (supports both JSON and raw frames)
    let (outbound_tx, mut outbound_rx) = mpsc::channel::<OutboundMessage>(100);

    // Spawn task to forward messages to WebSocket
    let send_task = tokio::spawn(async move {
        while let Some(msg) = outbound_rx.recv().await {
            let result = match msg {
                OutboundMessage::Json(server_msg) => match serde_json::to_string(&server_msg) {
                    Ok(json) => ws_tx.send(Message::Text(json.into())).await,
                    Err(e) => {
                        error!(
                            component = "websocket",
                            event = "ws.send.serialize_failed",
                            connection_id = conn_id,
                            error = %e,
                            "Failed to serialize server message"
                        );
                        continue;
                    }
                },
                OutboundMessage::Pong(data) => ws_tx.send(Message::Pong(data)).await,
            };

            if result.is_err() {
                debug!(
                    component = "websocket",
                    event = "ws.send.disconnected",
                    connection_id = conn_id,
                    "WebSocket send failed, client disconnected"
                );
                break;
            }
        }
    });

    // Wrapper to send JSON messages (used by handle_client_message)
    let client_tx = outbound_tx.clone();

    // Handle incoming messages
    while let Some(result) = ws_rx.next().await {
        let msg = match result {
            Ok(Message::Text(text)) => text,
            Ok(Message::Ping(data)) => {
                // Respond to ping with pong
                let _ = outbound_tx.send(OutboundMessage::Pong(data)).await;
                continue;
            }
            Ok(Message::Close(_)) => {
                info!(
                    component = "websocket",
                    event = "ws.connection.close_frame",
                    connection_id = conn_id,
                    "Client sent close frame"
                );
                break;
            }
            Ok(_) => continue,
            Err(e) => {
                warn!(
                    component = "websocket",
                    event = "ws.connection.error",
                    connection_id = conn_id,
                    error = %e,
                    "WebSocket error"
                );
                break;
            }
        };

        // Parse client message
        let client_msg: ClientMessage = match serde_json::from_str(&msg) {
            Ok(m) => m,
            Err(e) => {
                warn!(
                    component = "websocket",
                    event = "ws.message.parse_failed",
                    connection_id = conn_id,
                    error = %e,
                    payload_bytes = msg.len(),
                    payload_preview = %truncate_for_log(&msg, 240),
                    "Failed to parse client message"
                );
                send_json(
                    &client_tx,
                    ServerMessage::Error {
                        code: "parse_error".into(),
                        message: e.to_string(),
                        session_id: None,
                    },
                )
                .await;
                continue;
            }
        };

        // Handle the message
        handle_client_message(client_msg, &client_tx, &state, conn_id).await;
    }

    info!(
        component = "websocket",
        event = "ws.connection.closed",
        connection_id = conn_id,
        "WebSocket connection closed"
    );
    send_task.abort();
}

fn truncate_for_log(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

/// Send a ServerMessage through the outbound channel
async fn send_json(tx: &mpsc::Sender<OutboundMessage>, msg: ServerMessage) {
    let _ = tx.send(OutboundMessage::Json(msg)).await;
}

/// Create a ServerMessage sender that wraps an OutboundMessage sender
fn wrap_sender(tx: mpsc::Sender<OutboundMessage>) -> mpsc::Sender<ServerMessage> {
    let (server_tx, mut server_rx) = mpsc::channel::<ServerMessage>(100);
    tokio::spawn(async move {
        while let Some(msg) = server_rx.recv().await {
            if tx.send(OutboundMessage::Json(msg)).await.is_err() {
                break;
            }
        }
    });
    server_tx
}

fn chrono_now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    format!("{}Z", secs)
}

fn parse_unix_z(value: Option<&str>) -> Option<u64> {
    let raw = value?;
    let stripped = raw.strip_suffix('Z').unwrap_or(raw);
    stripped.parse::<u64>().ok()
}

fn is_stale_empty_claude_shell(
    summary: &orbitdock_protocol::SessionSummary,
    current_session_id: &str,
    cwd: &str,
    now_secs: u64,
) -> bool {
    if summary.id == current_session_id {
        return false;
    }
    if summary.provider != Provider::Claude {
        return false;
    }
    if summary.project_path != cwd {
        return false;
    }
    if summary.status != orbitdock_protocol::SessionStatus::Active {
        return false;
    }
    if summary.work_status != orbitdock_protocol::WorkStatus::Waiting {
        return false;
    }
    if summary.custom_name.is_some() {
        return false;
    }

    let started_at = parse_unix_z(summary.started_at.as_deref());
    let last_activity_at = parse_unix_z(summary.last_activity_at.as_deref()).or(started_at);
    let Some(last_activity_at) = last_activity_at else {
        return false;
    };

    now_secs.saturating_sub(last_activity_at) >= CLAUDE_EMPTY_SHELL_TTL_SECS
}

fn project_name_from_cwd(cwd: &str) -> Option<String> {
    std::path::Path::new(cwd)
        .file_name()
        .and_then(|s| s.to_str())
        .map(|s| s.to_string())
}

fn claude_transcript_path_from_cwd(cwd: &str, session_id: &str) -> Option<String> {
    let home = std::env::var("HOME").ok()?;
    let trimmed = cwd.trim_start_matches('/');
    if trimmed.is_empty() {
        return None;
    }
    let dir = format!("-{}", trimmed.replace('/', "-"));
    Some(format!(
        "{}/.claude/projects/{}/{}.jsonl",
        home, dir, session_id
    ))
}

fn truncate_text(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        return value.to_string();
    }
    let truncated: String = value.chars().take(max_chars).collect();
    format!("{truncated}\n\n[truncated]")
}

fn compact_snapshot_for_transport(mut snapshot: SessionState) -> SessionState {
    if snapshot.messages.len() > SNAPSHOT_MAX_MESSAGES {
        let keep_from = snapshot.messages.len() - SNAPSHOT_MAX_MESSAGES;
        snapshot.messages = snapshot.messages.split_off(keep_from);
    }

    for message in &mut snapshot.messages {
        if message.content.chars().count() > SNAPSHOT_MAX_CONTENT_CHARS {
            message.content = truncate_text(&message.content, SNAPSHOT_MAX_CONTENT_CHARS);
        }
        if let Some(tool_input) = &message.tool_input {
            if tool_input.chars().count() > SNAPSHOT_MAX_CONTENT_CHARS {
                message.tool_input = Some(truncate_text(tool_input, SNAPSHOT_MAX_CONTENT_CHARS));
            }
        }
        if let Some(tool_output) = &message.tool_output {
            if tool_output.chars().count() > SNAPSHOT_MAX_CONTENT_CHARS {
                message.tool_output = Some(truncate_text(tool_output, SNAPSHOT_MAX_CONTENT_CHARS));
            }
        }
    }

    snapshot
}

/// Handle a client message
async fn handle_client_message(
    msg: ClientMessage,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<Mutex<AppState>>,
    conn_id: u64,
) {
    debug!(
        component = "websocket",
        event = "ws.message.received",
        connection_id = conn_id,
        message = ?msg,
        "Received client message"
    );

    match msg {
        ClientMessage::SubscribeList => {
            let mut state = state.lock().await;
            state.subscribe_list(wrap_sender(client_tx.clone()));

            // Send current list
            let sessions = state.get_session_summaries().await;
            send_json(client_tx, ServerMessage::SessionsList { sessions }).await;
        }

        ClientMessage::SubscribeSession { session_id } => {
            let state = state.lock().await;
            if let Some(session_arc) = state.get_session(&session_id) {
                let mut session = session_arc.lock().await;
                let mut snapshot = session.state();
                if snapshot.messages.is_empty() {
                    if let Some(path) = snapshot.transcript_path.clone() {
                        drop(session);
                        if let Ok(messages) =
                            load_messages_from_transcript_path(&path, &session_id).await
                        {
                            let mut session_reloaded = session_arc.lock().await;
                            if !messages.is_empty() {
                                session_reloaded.replace_messages(messages);
                                snapshot = session_reloaded.state();
                                session = session_reloaded;
                            } else {
                                session = session_reloaded;
                            }
                        } else {
                            session = session_arc.lock().await;
                        }
                    }
                }
                let is_passive_ended = snapshot.provider == Provider::Codex
                    && snapshot.status == orbitdock_protocol::SessionStatus::Ended
                    && (snapshot.codex_integration_mode == Some(CodexIntegrationMode::Passive)
                        || (snapshot.codex_integration_mode != Some(CodexIntegrationMode::Direct)
                            && snapshot.transcript_path.is_some()));
                if is_passive_ended {
                    let should_reactivate = snapshot
                        .transcript_path
                        .as_deref()
                        .and_then(|path| std::fs::metadata(path).ok())
                        .and_then(|meta| meta.modified().ok())
                        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
                        .map(|d| d.as_secs())
                        .zip(parse_unix_z(snapshot.last_activity_at.as_deref()))
                        .map(|(modified_at, last_activity_at)| modified_at > last_activity_at)
                        .unwrap_or(false);
                    if should_reactivate {
                        let now = chrono_now();
                        session.set_status(orbitdock_protocol::SessionStatus::Active);
                        if session.work_status() == orbitdock_protocol::WorkStatus::Ended {
                            session.set_work_status(orbitdock_protocol::WorkStatus::Waiting);
                        }
                        session.set_last_activity_at(Some(now.clone()));
                        let summary = session.summary();
                        session
                            .broadcast(ServerMessage::SessionDelta {
                                session_id: session_id.clone(),
                                changes: orbitdock_protocol::StateChanges {
                                    status: Some(orbitdock_protocol::SessionStatus::Active),
                                    work_status: Some(orbitdock_protocol::WorkStatus::Waiting),
                                    last_activity_at: Some(now),
                                    ..Default::default()
                                },
                            })
                            .await;
                        drop(session);
                        let _ = state
                            .persist()
                            .send(PersistCommand::RolloutSessionUpdate {
                                id: session_id.clone(),
                                project_path: None,
                                model: None,
                                status: Some(orbitdock_protocol::SessionStatus::Active),
                                work_status: Some(orbitdock_protocol::WorkStatus::Waiting),
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
                        let mut state = state;
                        state
                            .broadcast_to_list(ServerMessage::SessionCreated { session: summary })
                            .await;
                        if let Some(session) = state.get_session(&session_id) {
                            let mut session = session.lock().await;
                            session.subscribe(wrap_sender(client_tx.clone()));
                            let snapshot = session.state();
                            let snapshot = compact_snapshot_for_transport(snapshot);
                            send_json(
                                client_tx,
                                ServerMessage::SessionSnapshot { session: snapshot },
                            )
                            .await;
                        }
                        return;
                    }
                }
                session.subscribe(wrap_sender(client_tx.clone()));

                // Send current state
                send_json(
                    client_tx,
                    ServerMessage::SessionSnapshot {
                        session: compact_snapshot_for_transport(snapshot),
                    },
                )
                .await;
            } else {
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
        }

        ClientMessage::UnsubscribeSession { session_id } => {
            let state = state.lock().await;
            if let Some(session) = state.get_session(&session_id) {
                let mut session = session.lock().await;
                // Note: unsubscribe won't match the wrapped sender, but that's OK
                // The session will clean up closed channels on broadcast
                session.unsubscribe_by_closed();
            }
        }

        ClientMessage::CreateSession {
            provider,
            cwd,
            model,
            approval_policy,
            sandbox_mode,
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
            let mut handle = crate::session::SessionHandle::new(id.clone(), provider, cwd.clone());
            if provider == Provider::Codex {
                handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
                handle.set_config(approval_policy.clone(), sandbox_mode.clone());
            }

            // Subscribe the creator
            handle.subscribe(wrap_sender(client_tx.clone()));

            let summary = handle.summary();
            let snapshot = handle.state();

            let mut state_guard = state.lock().await;

            // Persist session creation
            let persist_tx = state_guard.persist().clone();
            let _ = persist_tx
                .send(PersistCommand::SessionCreate {
                    id: id.clone(),
                    provider,
                    project_path: cwd.clone(),
                    project_name,
                    model: model.clone(),
                    approval_policy: approval_policy.clone(),
                    sandbox_mode: sandbox_mode.clone(),
                    forked_from_session_id: None,
                })
                .await;

            let session_arc = state_guard.add_session(handle);

            // Notify creator
            send_json(
                client_tx,
                ServerMessage::SessionSnapshot { session: snapshot },
            )
            .await;

            // Notify list subscribers
            state_guard
                .broadcast_to_list(ServerMessage::SessionCreated { session: summary })
                .await;

            // Spawn Codex connector if it's a Codex session
            if provider == Provider::Codex {
                let session_id = id.clone();
                let cwd_clone = cwd.clone();
                let model_clone = model.clone();
                let approval_clone = approval_policy.clone();
                let sandbox_clone = sandbox_mode.clone();

                match CodexSession::new(
                    session_id.clone(),
                    &cwd_clone,
                    model_clone.as_deref(),
                    approval_clone.as_deref(),
                    sandbox_clone.as_deref(),
                )
                .await
                {
                    Ok(codex_session) => {
                        // Persist the codex-core thread ID so the watcher can skip this session
                        let thread_id = codex_session.thread_id().to_string();
                        let _ = persist_tx
                            .send(PersistCommand::SetThreadId {
                                session_id: session_id.clone(),
                                thread_id,
                            })
                            .await;
                        state_guard.register_codex_thread(&session_id, codex_session.thread_id());

                        // If rollout watcher raced and created a shadow session keyed by thread id,
                        // evict it immediately so the direct session remains canonical.
                        let thread_id = codex_session.thread_id().to_string();
                        if state_guard.remove_session(&thread_id).is_some() {
                            state_guard
                                .broadcast_to_list(ServerMessage::SessionEnded {
                                    session_id: thread_id.clone(),
                                    reason: "direct_session_thread_claimed".into(),
                                })
                                .await;
                        }
                        let _ = persist_tx
                            .send(PersistCommand::CleanupThreadShadowSession {
                                thread_id,
                                reason: "legacy_codex_thread_row_cleanup".into(),
                            })
                            .await;

                        let action_tx =
                            codex_session.start_event_loop(session_arc.clone(), persist_tx);
                        state_guard.set_codex_action_tx(&session_id, action_tx);
                        info!(
                            component = "session",
                            event = "session.create.connector_started",
                            connection_id = conn_id,
                            session_id = %session_id,
                            "Codex connector started"
                        );
                    }
                    Err(e) => {
                        error!(
                            component = "session",
                            event = "session.create.connector_failed",
                            connection_id = conn_id,
                            session_id = %session_id,
                            error = %e,
                            "Failed to start Codex session"
                        );
                        send_json(
                            client_tx,
                            ServerMessage::Error {
                                code: "codex_error".into(),
                                message: e.to_string(),
                                session_id: Some(session_id),
                            },
                        )
                        .await;
                    }
                }
            }
        }

        ClientMessage::SendMessage {
            session_id,
            content,
            model,
            effort,
            skills,
        } => {
            info!(
                component = "session",
                event = "session.message.send_requested",
                connection_id = conn_id,
                session_id = %session_id,
                content_chars = content.chars().count(),
                model = ?model,
                effort = ?effort,
                skills_count = skills.len(),
                "Sending message to session"
            );

            let mut state = state.lock().await;
            if let Some(tx) = state.get_codex_action_tx(&session_id).cloned() {
                let first_prompt = name_from_first_prompt(&content);

                let _ = state
                    .persist()
                    .send(PersistCommand::CodexPromptIncrement {
                        id: session_id.clone(),
                        first_prompt: first_prompt.clone(),
                    })
                    .await;

                if let Some(derived_name) = first_prompt {
                    if let Some(session) = state.get_session(&session_id) {
                        let mut session = session.lock().await;
                        if session.custom_name().is_none() {
                            session.set_custom_name(Some(derived_name.clone()));

                            let _ = state
                                .persist()
                                .send(PersistCommand::SetCustomName {
                                    session_id: session_id.clone(),
                                    custom_name: Some(derived_name.clone()),
                                })
                                .await;

                            session
                                .broadcast(ServerMessage::SessionDelta {
                                    session_id: session_id.clone(),
                                    changes: orbitdock_protocol::StateChanges {
                                        custom_name: Some(Some(derived_name.clone())),
                                        ..Default::default()
                                    },
                                })
                                .await;

                            let summary = session.summary();
                            drop(session);
                            state
                                .broadcast_to_list(ServerMessage::SessionCreated {
                                    session: summary,
                                })
                                .await;
                        }
                    }
                }

                let _ = tx
                    .send(CodexAction::SendMessage {
                        content,
                        model,
                        effort,
                        skills,
                    })
                    .await;
            } else {
                warn!(
                    component = "session",
                    event = "session.message.missing_action_channel",
                    connection_id = conn_id,
                    session_id = %session_id,
                    "No action channel for session"
                );
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "not_found".into(),
                        message: format!(
                            "Session {} not found or has no active connector",
                            session_id
                        ),
                        session_id: Some(session_id),
                    },
                )
                .await;
            }
        }

        ClientMessage::ApproveTool {
            session_id,
            request_id,
            decision,
        } => {
            info!(
                component = "approval",
                event = "approval.decision.received",
                connection_id = conn_id,
                session_id = %session_id,
                request_id = %request_id,
                decision = %decision,
                "Approval decision received"
            );

            let state = state.lock().await;

            let _ = state
                .persist()
                .send(PersistCommand::ApprovalDecision {
                    session_id: session_id.clone(),
                    request_id: request_id.clone(),
                    decision: decision.clone(),
                })
                .await;

            // Look up approval type and proposed amendment from session state
            let (approval_type, proposed_amendment) =
                if let Some(session) = state.get_session(&session_id) {
                    let mut session = session.lock().await;
                    let atype = session.take_pending_approval(&request_id);
                    let amendment = session.take_pending_amendment(&request_id);
                    (atype, amendment)
                } else {
                    (None, None)
                };

            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let action = match approval_type {
                    Some(orbitdock_protocol::ApprovalType::Patch) => {
                        info!(
                            component = "approval",
                            event = "approval.dispatch.patch",
                            connection_id = conn_id,
                            session_id = %session_id,
                            request_id = %request_id,
                            "Dispatching patch approval"
                        );
                        CodexAction::ApprovePatch {
                            request_id,
                            decision: decision.clone(),
                        }
                    }
                    _ => {
                        // Default to exec for exec and unknown types
                        CodexAction::ApproveExec {
                            request_id,
                            decision: decision.clone(),
                            proposed_amendment,
                        }
                    }
                };
                let _ = tx.send(action).await;
            }

            // Clear pending approval and transition to an appropriate post-decision state.
            // Approved actions continue work; denied/abort returns to waiting.
            let next_work_status = work_status_for_approval_decision(&decision);

            let _ = state
                .persist()
                .send(PersistCommand::SessionUpdate {
                    id: session_id.clone(),
                    status: None,
                    work_status: Some(next_work_status),
                    last_activity_at: None,
                })
                .await;

            if let Some(session) = state.get_session(&session_id) {
                let mut session = session.lock().await;
                session.set_work_status(next_work_status);

                session
                    .broadcast(ServerMessage::SessionDelta {
                        session_id: session_id.clone(),
                        changes: orbitdock_protocol::StateChanges {
                            work_status: Some(next_work_status),
                            pending_approval: Some(None), // Explicitly clear
                            ..Default::default()
                        },
                    })
                    .await;
            }
        }

        ClientMessage::ListApprovals { session_id, limit } => {
            match list_approvals(session_id.clone(), limit).await {
                Ok(approvals) => {
                    send_json(
                        client_tx,
                        ServerMessage::ApprovalsList {
                            session_id,
                            approvals,
                        },
                    )
                    .await;
                }
                Err(e) => {
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "approval_list_failed".into(),
                            message: format!("Failed to list approvals: {}", e),
                            session_id: None,
                        },
                    )
                    .await;
                }
            }
        }

        ClientMessage::DeleteApproval { approval_id } => match delete_approval(approval_id).await {
            Ok(true) => {
                send_json(client_tx, ServerMessage::ApprovalDeleted { approval_id }).await;
            }
            Ok(false) => {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "not_found".into(),
                        message: format!("Approval {} not found", approval_id),
                        session_id: None,
                    },
                )
                .await;
            }
            Err(e) => {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "approval_delete_failed".into(),
                        message: format!("Failed to delete approval {}: {}", approval_id, e),
                        session_id: None,
                    },
                )
                .await;
            }
        },

        ClientMessage::ListModels => match discover_models().await {
            Ok(models) => {
                send_json(client_tx, ServerMessage::ModelsList { models }).await;
            }
            Err(e) => {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "model_list_failed".into(),
                        message: format!("Failed to list models: {}", e),
                        session_id: None,
                    },
                )
                .await;
            }
        },

        ClientMessage::ListSkills {
            session_id,
            cwds,
            force_reload,
        } => {
            let state = state.lock().await;
            if let Some(tx) = state.get_codex_action_tx(&session_id).cloned() {
                let _ = tx
                    .send(CodexAction::ListSkills { cwds, force_reload })
                    .await;
            } else {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "session_not_found".into(),
                        message: format!("Session {} not found or has no active connector", session_id),
                        session_id: Some(session_id),
                    },
                )
                .await;
            }
        }

        ClientMessage::ListRemoteSkills { session_id } => {
            let state = state.lock().await;
            if let Some(tx) = state.get_codex_action_tx(&session_id).cloned() {
                let _ = tx.send(CodexAction::ListRemoteSkills).await;
            } else {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "session_not_found".into(),
                        message: format!("Session {} not found or has no active connector", session_id),
                        session_id: Some(session_id),
                    },
                )
                .await;
            }
        }

        ClientMessage::DownloadRemoteSkill {
            session_id,
            hazelnut_id,
        } => {
            let state = state.lock().await;
            if let Some(tx) = state.get_codex_action_tx(&session_id).cloned() {
                let _ = tx
                    .send(CodexAction::DownloadRemoteSkill { hazelnut_id })
                    .await;
            } else {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "session_not_found".into(),
                        message: format!("Session {} not found or has no active connector", session_id),
                        session_id: Some(session_id),
                    },
                )
                .await;
            }
        }

        ClientMessage::ListMcpTools { session_id } => {
            let state = state.lock().await;
            if let Some(tx) = state.get_codex_action_tx(&session_id).cloned() {
                let _ = tx.send(CodexAction::ListMcpTools).await;
            } else {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "session_not_found".into(),
                        message: format!("Session {} not found or has no active connector", session_id),
                        session_id: Some(session_id),
                    },
                )
                .await;
            }
        }

        ClientMessage::RefreshMcpServers { session_id } => {
            let state = state.lock().await;
            if let Some(tx) = state.get_codex_action_tx(&session_id).cloned() {
                let _ = tx.send(CodexAction::RefreshMcpServers).await;
            } else {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "session_not_found".into(),
                        message: format!("Session {} not found or has no active connector", session_id),
                        session_id: Some(session_id),
                    },
                )
                .await;
            }
        }

        ClientMessage::AnswerQuestion {
            session_id,
            request_id,
            answer,
        } => {
            info!(
                component = "approval",
                event = "approval.answer.submitted",
                connection_id = conn_id,
                session_id = %session_id,
                request_id = %request_id,
                answer_chars = answer.chars().count(),
                "Answer submitted for question approval"
            );

            let state = state.lock().await;
            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let mut answers = std::collections::HashMap::new();
                answers.insert("0".to_string(), answer);
                let _ = tx
                    .send(CodexAction::AnswerQuestion {
                        request_id,
                        answers,
                    })
                    .await;
            }
        }

        ClientMessage::InterruptSession { session_id } => {
            info!(
                component = "session",
                event = "session.interrupt.requested",
                connection_id = conn_id,
                session_id = %session_id,
                "Interrupt session requested"
            );

            let state = state.lock().await;
            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx.send(CodexAction::Interrupt).await;
            }
        }

        ClientMessage::CompactContext { session_id } => {
            info!(
                component = "session",
                event = "session.compact.requested",
                connection_id = conn_id,
                session_id = %session_id,
                "Compact context requested"
            );

            let state = state.lock().await;
            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx.send(CodexAction::Compact).await;
            }
        }

        ClientMessage::UndoLastTurn { session_id } => {
            info!(
                component = "session",
                event = "session.undo.requested",
                connection_id = conn_id,
                session_id = %session_id,
                "Undo last turn requested"
            );

            let state = state.lock().await;
            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx.send(CodexAction::Undo).await;
            }
        }

        ClientMessage::RollbackTurns { session_id, num_turns } => {
            if num_turns < 1 {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "invalid_argument".into(),
                        message: "num_turns must be >= 1".into(),
                        session_id: Some(session_id),
                    },
                )
                .await;
                return;
            }

            info!(
                component = "session",
                event = "session.rollback.requested",
                connection_id = conn_id,
                session_id = %session_id,
                num_turns = num_turns,
                "Rollback turns requested"
            );

            let state = state.lock().await;
            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx.send(CodexAction::ThreadRollback { num_turns }).await;
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

            let mut state = state.lock().await;
            if let Some(session) = state.get_session(&session_id) {
                let mut session = session.lock().await;
                session.set_custom_name(name.clone());

                // Persist
                let _ = state
                    .persist()
                    .send(PersistCommand::SetCustomName {
                        session_id: session_id.clone(),
                        custom_name: name.clone(),
                    })
                    .await;

                // Broadcast delta to session subscribers
                session
                    .broadcast(ServerMessage::SessionDelta {
                        session_id: session_id.clone(),
                        changes: orbitdock_protocol::StateChanges {
                            custom_name: Some(name.clone()),
                            ..Default::default()
                        },
                    })
                    .await;

                // Update list subscribers with the new summary
                let summary = session.summary();
                drop(session);
                state
                    .broadcast_to_list(ServerMessage::SessionCreated { session: summary })
                    .await;
            }

            // Also set in codex-core if it's a Codex session
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
        } => {
            info!(
                component = "session",
                event = "session.config.update_requested",
                connection_id = conn_id,
                session_id = %session_id,
                approval_policy = ?approval_policy,
                sandbox_mode = ?sandbox_mode,
                "Session config update requested"
            );

            let mut state = state.lock().await;
            if let Some(session) = state.get_session(&session_id) {
                let mut session = session.lock().await;
                session.set_config(approval_policy.clone(), sandbox_mode.clone());
                let summary = session.summary();

                let _ = state
                    .persist()
                    .send(PersistCommand::SetSessionConfig {
                        session_id: session_id.clone(),
                        approval_policy: approval_policy.clone(),
                        sandbox_mode: sandbox_mode.clone(),
                    })
                    .await;

                session
                    .broadcast(ServerMessage::SessionDelta {
                        session_id: session_id.clone(),
                        changes: orbitdock_protocol::StateChanges {
                            approval_policy: Some(approval_policy.clone()),
                            sandbox_mode: Some(sandbox_mode.clone()),
                            ..Default::default()
                        },
                    })
                    .await;

                drop(session);
                state
                    .broadcast_to_list(ServerMessage::SessionCreated { session: summary })
                    .await;
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

        ClientMessage::ResumeSession { session_id } => {
            info!(
                component = "session",
                event = "session.resume.requested",
                connection_id = conn_id,
                session_id = %session_id,
                "Resume session requested"
            );

            // Check if session is already active in state
            {
                let state_guard = state.lock().await;
                if state_guard.get_session(&session_id).is_some() {
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
            }

            // Load session data from DB
            let restored = match load_session_by_id(&session_id).await {
                Ok(Some(rs)) => rs,
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

            let msg_count = restored.messages.len();
            let handle = SessionHandle::restore(
                restored.id.clone(),
                orbitdock_protocol::Provider::Codex,
                restored.project_path.clone(),
                restored.transcript_path.clone(),
                restored.project_name,
                restored.model.clone(),
                restored.custom_name,
                orbitdock_protocol::SessionStatus::Active,
                orbitdock_protocol::WorkStatus::Waiting,
                restored.approval_policy.clone(),
                restored.sandbox_mode.clone(),
                TokenUsage {
                    input_tokens: restored.codex_input_tokens.max(0) as u64,
                    output_tokens: restored.codex_output_tokens.max(0) as u64,
                    cached_tokens: restored.codex_cached_tokens.max(0) as u64,
                    context_window: restored.codex_context_window.max(0) as u64,
                },
                restored.started_at,
                restored.last_activity_at,
                restored.messages,
            );

            let mut state_guard = state.lock().await;

            // Subscribe the requesting client
            let mut handle = handle;
            handle.subscribe(wrap_sender(client_tx.clone()));

            let summary = handle.summary();
            let snapshot = handle.state();
            let session_arc = state_guard.add_session(handle);

            // Reactivate in DB
            let persist_tx = state_guard.persist().clone();
            let _ = persist_tx
                .send(PersistCommand::ReactivateSession {
                    id: session_id.clone(),
                })
                .await;

            // Start Codex connector
            match CodexSession::new(
                session_id.clone(),
                &restored.project_path,
                restored.model.as_deref(),
                restored.approval_policy.as_deref(),
                restored.sandbox_mode.as_deref(),
            )
            .await
            {
                Ok(codex_session) => {
                    let new_thread_id = codex_session.thread_id().to_string();
                    let _ = persist_tx
                        .send(PersistCommand::SetThreadId {
                            session_id: session_id.clone(),
                            thread_id: new_thread_id.clone(),
                        })
                        .await;
                    state_guard.register_codex_thread(&session_id, &new_thread_id);
                    if state_guard.remove_session(&new_thread_id).is_some() {
                        state_guard
                            .broadcast_to_list(ServerMessage::SessionEnded {
                                session_id: new_thread_id.clone(),
                                reason: "direct_session_thread_claimed".into(),
                            })
                            .await;
                    }
                    let _ = persist_tx
                        .send(PersistCommand::CleanupThreadShadowSession {
                            thread_id: new_thread_id.clone(),
                            reason: "legacy_codex_thread_row_cleanup".into(),
                        })
                        .await;

                    let action_tx = codex_session.start_event_loop(session_arc, persist_tx);
                    state_guard.set_codex_action_tx(&session_id, action_tx);
                    info!(
                        component = "session",
                        event = "session.resume.connector_started",
                        connection_id = conn_id,
                        session_id = %session_id,
                        thread_id = %new_thread_id,
                        messages = msg_count,
                        "Resumed session with live connector"
                    );
                }
                Err(e) => {
                    error!(
                        component = "session",
                        event = "session.resume.connector_failed",
                        connection_id = conn_id,
                        session_id = %session_id,
                        error = %e,
                        "Failed to start Codex connector for resumed session"
                    );
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "codex_error".into(),
                            message: e.to_string(),
                            session_id: Some(session_id.clone()),
                        },
                    )
                    .await;
                }
            }

            // Send snapshot to requester
            send_json(
                client_tx,
                ServerMessage::SessionSnapshot { session: snapshot },
            )
            .await;

            // Broadcast to list subscribers (session reappears in sidebar)
            state_guard
                .broadcast_to_list(ServerMessage::SessionCreated { session: summary })
                .await;
        }

        ClientMessage::ClaudeSessionStart {
            session_id,
            cwd,
            model,
            source,
            context_label,
            transcript_path,
            permission_mode,
            agent_type,
            terminal_session_id,
            terminal_app,
        } => {
            // Defensive guard: codex rollout payloads should stay on Codex path.
            if context_label.as_deref() == Some("codex_cli_rs") {
                return;
            }

            let mut state = state.lock().await;
            let persist_tx = state.persist().clone();
            let now_secs = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();

            // Prune stale empty Claude shells in the same project so they do not
            // linger as ghost active sessions.
            let stale_shell_ids: Vec<String> = state
                .get_session_summaries()
                .await
                .into_iter()
                .filter(|summary| is_stale_empty_claude_shell(summary, &session_id, &cwd, now_secs))
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
                    state
                        .broadcast_to_list(ServerMessage::SessionEnded {
                            session_id: stale_id,
                            reason: "stale_empty_shell".to_string(),
                        })
                        .await;
                }
            }

            let mut created = false;
            let session_arc = if let Some(existing) = state.get_session(&session_id) {
                let provider = {
                    let session = existing.lock().await;
                    session.provider()
                };
                if provider == Provider::Codex {
                    return;
                }
                existing
            } else {
                let mut handle =
                    SessionHandle::new(session_id.clone(), Provider::Claude, cwd.clone());
                handle.set_project_name(project_name_from_cwd(&cwd));
                handle.set_model(model.clone());
                handle.set_transcript_path(transcript_path.clone());
                handle.set_work_status(orbitdock_protocol::WorkStatus::Waiting);
                created = true;
                state.add_session(handle)
            };

            {
                let mut session = session_arc.lock().await;
                session.set_model(model.clone());
                if transcript_path.is_some() {
                    session.set_transcript_path(transcript_path.clone());
                }
                session.set_work_status(orbitdock_protocol::WorkStatus::Waiting);

                session
                    .broadcast(ServerMessage::SessionDelta {
                        session_id: session_id.clone(),
                        changes: orbitdock_protocol::StateChanges {
                            work_status: Some(orbitdock_protocol::WorkStatus::Waiting),
                            last_activity_at: Some(chrono_now()),
                            ..Default::default()
                        },
                    })
                    .await;

                if created {
                    state
                        .broadcast_to_list(ServerMessage::SessionCreated {
                            session: session.summary(),
                        })
                        .await;
                }
            }

            let _ = persist_tx
                .send(PersistCommand::ClaudeSessionUpsert {
                    id: session_id,
                    project_path: cwd.clone(),
                    project_name: project_name_from_cwd(&cwd),
                    model,
                    context_label,
                    transcript_path,
                    source,
                    agent_type,
                    permission_mode,
                    terminal_session_id,
                    terminal_app,
                })
                .await;
        }

        ClientMessage::ClaudeSessionEnd { session_id, reason } => {
            let mut state = state.lock().await;
            let persist_tx = state.persist().clone();

            if let Some(existing) = state.get_session(&session_id) {
                let provider = {
                    let session = existing.lock().await;
                    session.provider()
                };
                if provider == Provider::Codex {
                    return;
                }
            }

            let _ = persist_tx
                .send(PersistCommand::ClaudeSessionEnd {
                    id: session_id.clone(),
                    reason: reason.clone(),
                })
                .await;

            if state.remove_session(&session_id).is_some() {
                state
                    .broadcast_to_list(ServerMessage::SessionEnded {
                        session_id,
                        reason: reason.unwrap_or_else(|| "hook_session_end".to_string()),
                    })
                    .await;
            }
        }

        ClientMessage::ClaudeStatusEvent {
            session_id,
            cwd,
            transcript_path,
            hook_event_name,
            notification_type,
            tool_name,
            stop_hook_active: _,
            prompt,
            message: _,
            title: _,
            trigger: _,
            custom_instructions: _,
        } => {
            let mut state = state.lock().await;
            let persist_tx = state.persist().clone();
            let derived_transcript_path = cwd
                .as_deref()
                .and_then(|path| claude_transcript_path_from_cwd(path, &session_id));

            let session_arc = if let Some(existing) = state.get_session(&session_id) {
                let provider = {
                    let session = existing.lock().await;
                    session.provider()
                };
                if provider == Provider::Codex {
                    return;
                }
                existing
            } else {
                let fallback_cwd = cwd.clone().unwrap_or_else(|| "/unknown".to_string());
                let mut handle =
                    SessionHandle::new(session_id.clone(), Provider::Claude, fallback_cwd);
                handle.set_project_name(project_name_from_cwd(handle.project_path()));
                handle.set_transcript_path(
                    transcript_path
                        .clone()
                        .or_else(|| derived_transcript_path.clone()),
                );
                let arc = state.add_session(handle);
                {
                    let session = arc.lock().await;
                    state
                        .broadcast_to_list(ServerMessage::SessionCreated {
                            session: session.summary(),
                        })
                        .await;
                }
                arc
            };

            if transcript_path.is_some() || derived_transcript_path.is_some() {
                let mut session = session_arc.lock().await;
                session.set_transcript_path(
                    transcript_path
                        .clone()
                        .or_else(|| derived_transcript_path.clone()),
                );
            }

            if let Some(cwd) = cwd.clone() {
                let _ = persist_tx
                    .send(PersistCommand::ClaudeSessionUpsert {
                        id: session_id.clone(),
                        project_path: cwd.clone(),
                        project_name: project_name_from_cwd(&cwd),
                        model: None,
                        context_label: None,
                        transcript_path: transcript_path
                            .clone()
                            .or_else(|| derived_transcript_path.clone()),
                        source: None,
                        agent_type: None,
                        permission_mode: None,
                        terminal_session_id: None,
                        terminal_app: None,
                    })
                    .await;
            }

            let (next_work_status, persist_attention_reason) = match hook_event_name.as_str() {
                "UserPromptSubmit" => (
                    Some(orbitdock_protocol::WorkStatus::Working),
                    Some(Some("none".to_string())),
                ),
                "Stop" => {
                    let is_question = {
                        let session = session_arc.lock().await;
                        session.last_tool() == Some("AskUserQuestion")
                    };
                    if is_question {
                        (
                            Some(orbitdock_protocol::WorkStatus::Question),
                            Some(Some("awaitingQuestion".to_string())),
                        )
                    } else {
                        (
                            Some(orbitdock_protocol::WorkStatus::Waiting),
                            Some(Some("awaitingReply".to_string())),
                        )
                    }
                }
                "Notification" => match notification_type.as_deref() {
                    Some("permission_prompt") => (
                        Some(orbitdock_protocol::WorkStatus::Permission),
                        Some(Some("awaitingPermission".to_string())),
                    ),
                    Some("elicitation_dialog") => (
                        Some(orbitdock_protocol::WorkStatus::Question),
                        Some(Some("awaitingQuestion".to_string())),
                    ),
                    Some("idle_prompt") => {
                        let is_question = {
                            let session = session_arc.lock().await;
                            session.last_tool() == Some("AskUserQuestion")
                        };
                        if is_question {
                            (
                                Some(orbitdock_protocol::WorkStatus::Question),
                                Some(Some("awaitingQuestion".to_string())),
                            )
                        } else {
                            (
                                Some(orbitdock_protocol::WorkStatus::Waiting),
                                Some(Some("awaitingReply".to_string())),
                            )
                        }
                    }
                    _ => (None, None),
                },
                _ => (None, None),
            };

            if hook_event_name == "UserPromptSubmit" {
                let _ = persist_tx
                    .send(PersistCommand::ClaudePromptIncrement {
                        id: session_id.clone(),
                        first_prompt: prompt.clone(),
                    })
                    .await;

                if let Some(prompt_text) = prompt.as_deref() {
                    let derived_name = name_from_first_prompt(prompt_text);
                    if let Some(derived_name) = derived_name {
                        let mut session = session_arc.lock().await;
                        if session.custom_name().is_none() {
                            session.set_custom_name(Some(derived_name.clone()));

                            let _ = persist_tx
                                .send(PersistCommand::SetCustomName {
                                    session_id: session_id.clone(),
                                    custom_name: Some(derived_name.clone()),
                                })
                                .await;

                            session
                                .broadcast(ServerMessage::SessionDelta {
                                    session_id: session_id.clone(),
                                    changes: orbitdock_protocol::StateChanges {
                                        custom_name: Some(Some(derived_name.clone())),
                                        last_activity_at: Some(chrono_now()),
                                        ..Default::default()
                                    },
                                })
                                .await;

                            let summary = session.summary();
                            drop(session);
                            state
                                .broadcast_to_list(ServerMessage::SessionCreated {
                                    session: summary,
                                })
                                .await;
                        }
                    }
                }
            }

            if hook_event_name == "PreCompact" {
                let _ = persist_tx
                    .send(PersistCommand::ClaudeSessionUpdate {
                        id: session_id.clone(),
                        work_status: None,
                        attention_reason: None,
                        last_tool: None,
                        last_tool_at: None,
                        pending_tool_name: None,
                        pending_tool_input: None,
                        pending_question: None,
                        source: None,
                        agent_type: None,
                        permission_mode: None,
                        active_subagent_id: None,
                        active_subagent_type: None,
                        first_prompt: None,
                        compact_count_increment: true,
                    })
                    .await;
            }

            if let Some(tool_name) = tool_name {
                let mut session = session_arc.lock().await;
                session.set_last_tool(Some(tool_name));
            }

            if let Some(work_status) = next_work_status {
                {
                    let mut session = session_arc.lock().await;
                    session.set_work_status(work_status);
                    session
                        .broadcast(ServerMessage::SessionDelta {
                            session_id: session_id.clone(),
                            changes: orbitdock_protocol::StateChanges {
                                work_status: Some(work_status),
                                last_activity_at: Some(chrono_now()),
                                ..Default::default()
                            },
                        })
                        .await;
                }

                let _ = persist_tx
                    .send(PersistCommand::ClaudeSessionUpdate {
                        id: session_id.clone(),
                        work_status: Some(match work_status {
                            orbitdock_protocol::WorkStatus::Working => "working".to_string(),
                            orbitdock_protocol::WorkStatus::Waiting => "waiting".to_string(),
                            orbitdock_protocol::WorkStatus::Permission => "permission".to_string(),
                            orbitdock_protocol::WorkStatus::Question => "question".to_string(),
                            orbitdock_protocol::WorkStatus::Reply => "reply".to_string(),
                            orbitdock_protocol::WorkStatus::Ended => "ended".to_string(),
                        }),
                        attention_reason: persist_attention_reason,
                        last_tool: None,
                        last_tool_at: None,
                        pending_tool_name: None,
                        pending_tool_input: None,
                        pending_question: None,
                        source: None,
                        agent_type: None,
                        permission_mode: None,
                        active_subagent_id: None,
                        active_subagent_type: None,
                        first_prompt: None,
                        compact_count_increment: false,
                    })
                    .await;
            }

            // Sync new messages from transcript
            sync_transcript_messages(&session_arc).await;
        }

        ClientMessage::ClaudeToolEvent {
            session_id,
            cwd,
            hook_event_name,
            tool_name,
            tool_input,
            tool_response: _,
            tool_use_id: _,
            error: _,
            is_interrupt: _,
        } => {
            let mut state = state.lock().await;
            let persist_tx = state.persist().clone();
            let derived_transcript_path = claude_transcript_path_from_cwd(&cwd, &session_id);

            let session_arc = if let Some(existing) = state.get_session(&session_id) {
                let provider = {
                    let session = existing.lock().await;
                    session.provider()
                };
                if provider == Provider::Codex {
                    return;
                }
                existing
            } else {
                let mut handle =
                    SessionHandle::new(session_id.clone(), Provider::Claude, cwd.clone());
                handle.set_project_name(project_name_from_cwd(handle.project_path()));
                handle.set_transcript_path(derived_transcript_path.clone());
                let arc = state.add_session(handle);
                {
                    let session = arc.lock().await;
                    state
                        .broadcast_to_list(ServerMessage::SessionCreated {
                            session: session.summary(),
                        })
                        .await;
                }
                arc
            };

            let _ = persist_tx
                .send(PersistCommand::ClaudeSessionUpsert {
                    id: session_id.clone(),
                    project_path: cwd.clone(),
                    project_name: project_name_from_cwd(&cwd),
                    model: None,
                    context_label: None,
                    transcript_path: derived_transcript_path,
                    source: None,
                    agent_type: None,
                    permission_mode: None,
                    terminal_session_id: None,
                    terminal_app: None,
                })
                .await;

            match hook_event_name.as_str() {
                "PreToolUse" => {
                    let was_permission = {
                        let session = session_arc.lock().await;
                        session.work_status() == orbitdock_protocol::WorkStatus::Permission
                    };
                    let question = tool_input
                        .as_ref()
                        .and_then(|value| value.get("question"))
                        .and_then(Value::as_str)
                        .map(|s| s.to_string());
                    let serialized_input =
                        tool_input.and_then(|value| serde_json::to_string(&value).ok());

                    {
                        let mut session = session_arc.lock().await;
                        session.set_last_tool(Some(tool_name.clone()));
                        session.set_work_status(orbitdock_protocol::WorkStatus::Working);
                        session
                            .broadcast(ServerMessage::SessionDelta {
                                session_id: session_id.clone(),
                                changes: orbitdock_protocol::StateChanges {
                                    work_status: Some(orbitdock_protocol::WorkStatus::Working),
                                    last_activity_at: Some(chrono_now()),
                                    ..Default::default()
                                },
                            })
                            .await;
                    }

                    let _ = persist_tx
                        .send(PersistCommand::ClaudeSessionUpdate {
                            id: session_id.clone(),
                            work_status: Some("working".to_string()),
                            attention_reason: Some(Some("none".to_string())),
                            last_tool: Some(Some(tool_name.clone())),
                            last_tool_at: Some(Some(chrono_now())),
                            pending_tool_name: if was_permission {
                                None
                            } else {
                                Some(Some(tool_name.clone()))
                            },
                            pending_tool_input: if was_permission {
                                None
                            } else {
                                Some(serialized_input)
                            },
                            pending_question: if was_permission { None } else { Some(question) },
                            source: None,
                            agent_type: None,
                            permission_mode: None,
                            active_subagent_id: None,
                            active_subagent_type: None,
                            first_prompt: None,
                            compact_count_increment: false,
                        })
                        .await;
                }
                "PostToolUse" => {
                    let _ = persist_tx
                        .send(PersistCommand::ClaudeToolIncrement {
                            id: session_id.clone(),
                        })
                        .await;
                    let _ = persist_tx
                        .send(PersistCommand::ClaudeSessionUpdate {
                            id: session_id.clone(),
                            work_status: Some("working".to_string()),
                            attention_reason: Some(Some("none".to_string())),
                            last_tool: None,
                            last_tool_at: None,
                            pending_tool_name: Some(None),
                            pending_tool_input: Some(None),
                            pending_question: Some(None),
                            source: None,
                            agent_type: None,
                            permission_mode: None,
                            active_subagent_id: None,
                            active_subagent_type: None,
                            first_prompt: None,
                            compact_count_increment: false,
                        })
                        .await;

                    let mut session = session_arc.lock().await;
                    session.set_work_status(orbitdock_protocol::WorkStatus::Working);
                    session
                        .broadcast(ServerMessage::SessionDelta {
                            session_id: session_id.clone(),
                            changes: orbitdock_protocol::StateChanges {
                                work_status: Some(orbitdock_protocol::WorkStatus::Working),
                                last_activity_at: Some(chrono_now()),
                                ..Default::default()
                            },
                        })
                        .await;
                }
                "PostToolUseFailure" => {
                    let _ = persist_tx
                        .send(PersistCommand::ClaudeToolIncrement {
                            id: session_id.clone(),
                        })
                        .await;
                    let _ = persist_tx
                        .send(PersistCommand::ClaudeSessionUpdate {
                            id: session_id.clone(),
                            work_status: Some("waiting".to_string()),
                            attention_reason: Some(Some("awaitingReply".to_string())),
                            last_tool: None,
                            last_tool_at: None,
                            pending_tool_name: Some(None),
                            pending_tool_input: Some(None),
                            pending_question: Some(None),
                            source: None,
                            agent_type: None,
                            permission_mode: None,
                            active_subagent_id: None,
                            active_subagent_type: None,
                            first_prompt: None,
                            compact_count_increment: false,
                        })
                        .await;

                    let mut session = session_arc.lock().await;
                    session.set_work_status(orbitdock_protocol::WorkStatus::Waiting);
                    session
                        .broadcast(ServerMessage::SessionDelta {
                            session_id: session_id.clone(),
                            changes: orbitdock_protocol::StateChanges {
                                work_status: Some(orbitdock_protocol::WorkStatus::Waiting),
                                last_activity_at: Some(chrono_now()),
                                ..Default::default()
                            },
                        })
                        .await;
                }
                _ => {}
            }

            // Sync new messages from transcript
            sync_transcript_messages(&session_arc).await;
        }

        ClientMessage::ClaudeSubagentEvent {
            session_id,
            hook_event_name,
            agent_id,
            agent_type,
            agent_transcript_path,
        } => {
            let state = state.lock().await;
            let persist_tx = state.persist().clone();
            if let Some(existing) = state.get_session(&session_id) {
                let provider = {
                    let session = existing.lock().await;
                    session.provider()
                };
                if provider == Provider::Codex {
                    return;
                }
            }
            drop(state);

            match hook_event_name.as_str() {
                "SubagentStart" => {
                    let normalized_type =
                        agent_type.clone().unwrap_or_else(|| "unknown".to_string());
                    let _ = persist_tx
                        .send(PersistCommand::ClaudeSubagentStart {
                            id: agent_id.clone(),
                            session_id: session_id.clone(),
                            agent_type: normalized_type.clone(),
                        })
                        .await;
                    let _ = persist_tx
                        .send(PersistCommand::ClaudeSessionUpdate {
                            id: session_id,
                            work_status: None,
                            attention_reason: None,
                            last_tool: None,
                            last_tool_at: None,
                            pending_tool_name: None,
                            pending_tool_input: None,
                            pending_question: None,
                            source: None,
                            agent_type: None,
                            permission_mode: None,
                            active_subagent_id: Some(Some(agent_id)),
                            active_subagent_type: Some(Some(normalized_type)),
                            first_prompt: None,
                            compact_count_increment: false,
                        })
                        .await;
                }
                "SubagentStop" => {
                    let _ = persist_tx
                        .send(PersistCommand::ClaudeSubagentEnd {
                            id: agent_id,
                            transcript_path: agent_transcript_path,
                        })
                        .await;
                    let _ = persist_tx
                        .send(PersistCommand::ClaudeSessionUpdate {
                            id: session_id,
                            work_status: None,
                            attention_reason: None,
                            last_tool: None,
                            last_tool_at: None,
                            pending_tool_name: None,
                            pending_tool_input: None,
                            pending_question: None,
                            source: None,
                            agent_type: None,
                            permission_mode: None,
                            active_subagent_id: Some(None),
                            active_subagent_type: Some(None),
                            first_prompt: None,
                            compact_count_increment: false,
                        })
                        .await;
                }
                _ => {}
            }
        }

        ClientMessage::ForkSession {
            source_session_id,
            nth_user_message,
            model,
            approval_policy,
            sandbox_mode,
            cwd,
        } => {
            info!(
                component = "session",
                event = "session.fork.requested",
                connection_id = conn_id,
                source_session_id = %source_session_id,
                nth_user_message = ?nth_user_message,
                "Fork session requested"
            );

            let state_guard = state.lock().await;

            // Verify source session exists and has an active connector
            let source_action_tx = match state_guard.get_codex_action_tx(&source_session_id).cloned() {
                Some(tx) => tx,
                None => {
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "not_found".into(),
                            message: format!(
                                "Source session {} not found or has no active connector",
                                source_session_id
                            ),
                            session_id: Some(source_session_id),
                        },
                    )
                    .await;
                    return;
                }
            };

            // Get source session's cwd as fallback
            let source_cwd = if let Some(s) = state_guard.get_session(&source_session_id) {
                let s = s.lock().await;
                Some(s.project_path().to_string())
            } else {
                None
            };

            drop(state_guard);

            // Send fork action to source session's event loop via oneshot
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

            // Await the fork result
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

            // Create new session handle
            let new_id = orbitdock_protocol::new_id();
            let fork_cwd = effective_cwd.unwrap_or_else(|| ".".to_string());
            let project_name = fork_cwd.split('/').next_back().map(String::from);

            let mut handle = SessionHandle::new(
                new_id.clone(),
                Provider::Codex,
                fork_cwd.clone(),
            );
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
            handle.set_config(approval_policy.clone(), sandbox_mode.clone());
            handle.set_forked_from(source_session_id.clone());

            // Load forked conversation history from the new thread's rollout
            let forked_messages = if let Some(rollout_path) = new_connector.rollout_path().await {
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

            // Subscribe the requester to the new session
            handle.subscribe(wrap_sender(client_tx.clone()));

            let summary = handle.summary();
            let snapshot = handle.state();

            let mut state_guard = state.lock().await;
            let persist_tx = state_guard.persist().clone();

            // Persist new session
            let _ = persist_tx
                .send(PersistCommand::SessionCreate {
                    id: new_id.clone(),
                    provider: Provider::Codex,
                    project_path: fork_cwd,
                    project_name,
                    model,
                    approval_policy,
                    sandbox_mode,
                    forked_from_session_id: Some(source_session_id.clone()),
                })
                .await;

            // Persist forked messages so they survive server restarts
            for msg in forked_messages {
                let _ = persist_tx
                    .send(PersistCommand::MessageAppend {
                        session_id: new_id.clone(),
                        message: msg,
                    })
                    .await;
            }

            let session_arc = state_guard.add_session(handle);

            // Register thread ID
            let _ = persist_tx
                .send(PersistCommand::SetThreadId {
                    session_id: new_id.clone(),
                    thread_id: new_thread_id.clone(),
                })
                .await;
            state_guard.register_codex_thread(&new_id, &new_thread_id);

            // Clean up any shadow session from rollout watcher
            if state_guard.remove_session(&new_thread_id).is_some() {
                state_guard
                    .broadcast_to_list(ServerMessage::SessionEnded {
                        session_id: new_thread_id.clone(),
                        reason: "direct_session_thread_claimed".into(),
                    })
                    .await;
            }
            let _ = persist_tx
                .send(PersistCommand::CleanupThreadShadowSession {
                    thread_id: new_thread_id.clone(),
                    reason: "legacy_codex_thread_row_cleanup".into(),
                })
                .await;

            // Start the new connector's event loop
            let codex_session = CodexSession {
                session_id: new_id.clone(),
                connector: new_connector,
            };
            let action_tx =
                codex_session.start_event_loop(session_arc, persist_tx);
            state_guard.set_codex_action_tx(&new_id, action_tx);

            // Send snapshot to requester
            send_json(
                client_tx,
                ServerMessage::SessionSnapshot { session: snapshot },
            )
            .await;

            // Send fork confirmation
            send_json(
                client_tx,
                ServerMessage::SessionForked {
                    source_session_id: source_session_id.clone(),
                    new_session_id: new_id.clone(),
                    forked_from_thread_id: Some(new_thread_id),
                },
            )
            .await;

            // Notify list subscribers
            state_guard
                .broadcast_to_list(ServerMessage::SessionCreated { session: summary })
                .await;

            info!(
                component = "session",
                event = "session.fork.completed",
                connection_id = conn_id,
                source_session_id = %source_session_id,
                new_session_id = %new_id,
                "Session forked successfully"
            );
        }

        ClientMessage::EndSession { session_id } => {
            info!(
                component = "session",
                event = "session.end.requested",
                connection_id = conn_id,
                session_id = %session_id,
                "End session requested"
            );

            let mut state = state.lock().await;

            let session_arc = state.get_session(&session_id);
            let is_passive_rollout = if let Some(session_arc) = session_arc.as_ref() {
                let session = session_arc.lock().await;
                let state_snapshot = session.state();
                state_snapshot.provider == Provider::Codex
                    && (state_snapshot.codex_integration_mode
                        == Some(CodexIntegrationMode::Passive)
                        || (state_snapshot.codex_integration_mode
                            != Some(CodexIntegrationMode::Direct)
                            && state_snapshot.transcript_path.is_some()))
            } else {
                false
            };

            // Tell direct connectors to shutdown gracefully.
            if !is_passive_rollout {
                if let Some(tx) = state.get_codex_action_tx(&session_id) {
                    let _ = tx.send(CodexAction::EndSession).await;
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
                if let Some(session_arc) = session_arc {
                    let mut session = session_arc.lock().await;
                    let now = chrono_now();
                    session.set_status(orbitdock_protocol::SessionStatus::Ended);
                    session.set_work_status(orbitdock_protocol::WorkStatus::Ended);
                    session.set_last_activity_at(Some(now.clone()));
                    session
                        .broadcast(ServerMessage::SessionDelta {
                            session_id: session_id.clone(),
                            changes: orbitdock_protocol::StateChanges {
                                status: Some(orbitdock_protocol::SessionStatus::Ended),
                                work_status: Some(orbitdock_protocol::WorkStatus::Ended),
                                last_activity_at: Some(now),
                                ..Default::default()
                            },
                        })
                        .await;
                }
                state
                    .broadcast_to_list(ServerMessage::SessionEnded {
                        session_id,
                        reason: "user_requested".to_string(),
                    })
                    .await;
            // Direct sessions are removed from active runtime state.
            } else if state.remove_session(&session_id).is_some() {
                info!(
                    component = "session",
                    event = "session.end.direct_removed",
                    connection_id = conn_id,
                    session_id = %session_id,
                    "Removed direct session from runtime state"
                );
                state
                    .broadcast_to_list(ServerMessage::SessionEnded {
                        session_id,
                        reason: "user_requested".to_string(),
                    })
                    .await;
            }
        }
    }
}

/// Re-read a session's transcript and broadcast any new messages to subscribers.
/// Works for any hook-triggered session (Claude CLI, future Codex CLI hooks).
async fn sync_transcript_messages(
    session_arc: &Arc<Mutex<SessionHandle>>,
) {
    let (transcript_path, session_id, existing_count) = {
        let session = session_arc.lock().await;
        let path = match session.transcript_path() {
            Some(p) => p.to_string(),
            None => return,
        };
        (path, session.id().to_string(), session.message_count())
    };

    let all_messages =
        match load_messages_from_transcript_path(&transcript_path, &session_id).await {
            Ok(msgs) => msgs,
            Err(_) => return,
        };

    if all_messages.len() <= existing_count {
        return;
    }

    let new_messages = all_messages[existing_count..].to_vec();
    let mut session = session_arc.lock().await;

    // Double-check count hasn't changed while we were reading
    if session.message_count() != existing_count {
        return;
    }

    for msg in new_messages {
        session.add_message(msg.clone());
        session
            .broadcast(ServerMessage::MessageAppended {
                session_id: session_id.clone(),
                message: msg,
            })
            .await;
    }
}

#[cfg(test)]
pub(crate) async fn end_session_for_test(state: &Arc<Mutex<AppState>>, session_id: String) {
    let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
    handle_client_message(
        ClientMessage::EndSession { session_id },
        &client_tx,
        state,
        1,
    )
    .await;
}

#[cfg(test)]
mod tests {
    use super::{
        claude_transcript_path_from_cwd, handle_client_message, work_status_for_approval_decision,
        OutboundMessage,
    };
    use crate::session::SessionHandle;
    use crate::session_naming::name_from_first_prompt;
    use crate::state::AppState;
    use orbitdock_protocol::{
        ClientMessage, CodexIntegrationMode, Provider, ServerMessage, SessionStatus, WorkStatus,
    };
    use std::sync::Arc;
    use tokio::sync::{mpsc, Mutex};

    #[test]
    fn approval_decisions_that_continue_tooling_stay_working() {
        assert_eq!(
            work_status_for_approval_decision("approved"),
            WorkStatus::Working
        );
        assert_eq!(
            work_status_for_approval_decision("approved_for_session"),
            WorkStatus::Working
        );
        assert_eq!(
            work_status_for_approval_decision("approved_always"),
            WorkStatus::Working
        );
        assert_eq!(
            work_status_for_approval_decision("  approved  "),
            WorkStatus::Working
        );
    }

    #[test]
    fn approval_decisions_that_stop_or_reject_return_to_waiting() {
        assert_eq!(
            work_status_for_approval_decision("denied"),
            WorkStatus::Waiting
        );
        assert_eq!(
            work_status_for_approval_decision("abort"),
            WorkStatus::Waiting
        );
        assert_eq!(
            work_status_for_approval_decision("unknown_value"),
            WorkStatus::Waiting
        );
    }

    #[test]
    fn derives_readable_name_from_first_prompt() {
        let prompt =
            "  Please investigate auth race conditions and propose a safe migration plan.  ";
        let name = name_from_first_prompt(prompt).expect("expected name");
        assert_eq!(
            name,
            "Please investigate auth race conditions and propose a safe migration pla…"
        );
    }

    #[test]
    fn derives_transcript_path_from_cwd() {
        let path =
            claude_transcript_path_from_cwd("/Users/robertdeluca/Developer/vizzly-cli", "abc-123");
        let value = path.expect("expected transcript path");
        assert!(
            value.ends_with(
                "/.claude/projects/-Users-robertdeluca-Developer-vizzly-cli/abc-123.jsonl"
            ),
            "unexpected transcript path: {}",
            value
        );
    }

    fn new_test_state() -> Arc<Mutex<AppState>> {
        let (persist_tx, _persist_rx) = mpsc::channel(128);
        Arc::new(Mutex::new(AppState::new(persist_tx)))
    }

    async fn recv_server_message(rx: &mut mpsc::Receiver<OutboundMessage>) -> ServerMessage {
        match rx.recv().await.expect("expected outbound server message") {
            OutboundMessage::Json(message) => message,
            OutboundMessage::Pong(_) => panic!("expected JSON server message, got pong"),
        }
    }

    #[tokio::test]
    async fn ending_passive_session_keeps_it_available_for_reactivation() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "passive-end-keep".to_string();

        {
            let mut app = state.lock().await;
            let mut handle = SessionHandle::new(
                session_id.clone(),
                Provider::Codex,
                "/Users/tester/repo".to_string(),
            );
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            app.add_session(handle);
        }

        handle_client_message(
            ClientMessage::EndSession {
                session_id: session_id.clone(),
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        let session_arc = {
            let app = state.lock().await;
            app.get_session(&session_id)
        }
        .expect("passive session should remain in app state");

        let snapshot = session_arc.lock().await.state();
        assert_eq!(snapshot.status, SessionStatus::Ended);
        assert_eq!(snapshot.work_status, WorkStatus::Ended);
    }

    #[tokio::test]
    async fn list_and_detail_match_after_manual_passive_close() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(32);
        let session_id = "passive-list-detail-consistency".to_string();

        {
            let mut app = state.lock().await;
            let mut handle = SessionHandle::new(
                session_id.clone(),
                Provider::Codex,
                "/Users/tester/repo".to_string(),
            );
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            app.add_session(handle);
        }

        handle_client_message(
            ClientMessage::EndSession {
                session_id: session_id.clone(),
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        handle_client_message(ClientMessage::SubscribeList, &client_tx, &state, 1).await;
        let list_message = recv_server_message(&mut client_rx).await;
        let list_session = match list_message {
            ServerMessage::SessionsList { sessions } => sessions
                .into_iter()
                .find(|session| session.id == session_id)
                .expect("session should be present in list"),
            other => panic!("expected sessions_list, got {:?}", other),
        };

        handle_client_message(
            ClientMessage::SubscribeSession {
                session_id: session_id.clone(),
            },
            &client_tx,
            &state,
            1,
        )
        .await;
        let detail_message = recv_server_message(&mut client_rx).await;
        let detail_session = match detail_message {
            ServerMessage::SessionSnapshot { session } => session,
            other => panic!("expected session_snapshot, got {:?}", other),
        };

        assert_eq!(list_session.id, detail_session.id);
        assert_eq!(list_session.status, detail_session.status);
        assert_eq!(list_session.work_status, detail_session.work_status);
        assert_eq!(detail_session.status, SessionStatus::Ended);
        assert_eq!(detail_session.work_status, WorkStatus::Ended);
    }

    #[tokio::test]
    async fn claude_tool_event_bootstraps_session_with_transcript_path() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "claude-tool-bootstrap".to_string();
        let cwd = "/Users/tester/Developer/sample".to_string();

        handle_client_message(
            ClientMessage::ClaudeToolEvent {
                session_id: session_id.clone(),
                cwd: cwd.clone(),
                hook_event_name: "PreToolUse".to_string(),
                tool_name: "Read".to_string(),
                tool_input: None,
                tool_response: None,
                tool_use_id: None,
                error: None,
                is_interrupt: None,
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        let session_arc = {
            let state_guard = state.lock().await;
            state_guard
                .get_session(&session_id)
                .expect("session should exist")
        };
        let snapshot = session_arc.lock().await.state();

        assert_eq!(snapshot.provider, Provider::Claude);
        assert_eq!(snapshot.work_status, WorkStatus::Working);
        let transcript_path = snapshot
            .transcript_path
            .expect("transcript path should be derived");
        assert!(
            transcript_path.ends_with(
                "/.claude/projects/-Users-tester-Developer-sample/claude-tool-bootstrap.jsonl"
            ),
            "unexpected transcript path: {}",
            transcript_path
        );
    }

    #[tokio::test]
    async fn claude_user_prompt_sets_custom_name_once() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "claude-name-on-prompt".to_string();

        handle_client_message(
            ClientMessage::ClaudeStatusEvent {
                session_id: session_id.clone(),
                cwd: Some("/Users/tester/repo".to_string()),
                transcript_path: Some(
                    "/Users/tester/.claude/projects/-Users-tester-repo/claude-name-on-prompt.jsonl"
                        .to_string(),
                ),
                hook_event_name: "UserPromptSubmit".to_string(),
                notification_type: None,
                tool_name: None,
                stop_hook_active: None,
                prompt: Some(
                    "Investigate flaky auth and propose a safe migration plan".to_string(),
                ),
                message: None,
                title: None,
                trigger: None,
                custom_instructions: None,
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        handle_client_message(
            ClientMessage::ClaudeStatusEvent {
                session_id: session_id.clone(),
                cwd: Some("/Users/tester/repo".to_string()),
                transcript_path: None,
                hook_event_name: "UserPromptSubmit".to_string(),
                notification_type: None,
                tool_name: None,
                stop_hook_active: None,
                prompt: Some("Different prompt should not rename".to_string()),
                message: None,
                title: None,
                trigger: None,
                custom_instructions: None,
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        let session_arc = {
            let state_guard = state.lock().await;
            state_guard
                .get_session(&session_id)
                .expect("session should exist")
        };
        let snapshot = session_arc.lock().await.state();
        assert_eq!(snapshot.work_status, WorkStatus::Working);
        assert_eq!(
            snapshot.custom_name.as_deref(),
            Some("Investigate flaky auth and propose a safe migration plan")
        );
    }

    #[tokio::test]
    async fn codex_send_message_ignores_bootstrap_prompt_for_naming() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "codex-name-on-prompt".to_string();
        let (action_tx, _action_rx) = mpsc::channel(8);

        {
            let mut app = state.lock().await;
            app.add_session(SessionHandle::new(
                session_id.clone(),
                Provider::Codex,
                "/Users/tester/repo".to_string(),
            ));
            app.set_codex_action_tx(&session_id, action_tx);
        }

        handle_client_message(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "<environment_context>...</environment_context>".to_string(),
                model: None,
                effort: None,
                skills: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        handle_client_message(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "Investigate flaky auth and propose a safe migration plan".to_string(),
                model: None,
                effort: None,
                skills: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        let session_arc = {
            let state_guard = state.lock().await;
            state_guard
                .get_session(&session_id)
                .expect("session should exist")
        };
        let snapshot = session_arc.lock().await.state();

        assert_eq!(
            snapshot.custom_name.as_deref(),
            Some("Investigate flaky auth and propose a safe migration plan")
        );
    }

    #[tokio::test]
    async fn claude_stop_after_question_tool_sets_question_status() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "claude-question-flow".to_string();

        handle_client_message(
            ClientMessage::ClaudeToolEvent {
                session_id: session_id.clone(),
                cwd: "/Users/tester/repo".to_string(),
                hook_event_name: "PreToolUse".to_string(),
                tool_name: "AskUserQuestion".to_string(),
                tool_input: Some(serde_json::json!({"question": "Ship now?"})),
                tool_response: None,
                tool_use_id: None,
                error: None,
                is_interrupt: None,
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        handle_client_message(
            ClientMessage::ClaudeStatusEvent {
                session_id: session_id.clone(),
                cwd: Some("/Users/tester/repo".to_string()),
                transcript_path: None,
                hook_event_name: "Stop".to_string(),
                notification_type: None,
                tool_name: None,
                stop_hook_active: Some(false),
                prompt: None,
                message: None,
                title: None,
                trigger: None,
                custom_instructions: None,
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        let session_arc = {
            let state_guard = state.lock().await;
            state_guard
                .get_session(&session_id)
                .expect("session should exist")
        };
        let snapshot = session_arc.lock().await.state();
        assert_eq!(snapshot.work_status, WorkStatus::Question);
    }
}
