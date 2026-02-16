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
use tokio::sync::{mpsc, oneshot};
use tracing::{debug, error, info, warn};

use orbitdock_connectors::discover_models;
use orbitdock_protocol::{
    ClaudeIntegrationMode, ClientMessage, CodexIntegrationMode, Provider, ServerMessage,
    SessionState, TokenUsage,
};

use crate::claude_session::{ClaudeAction, ClaudeSession};
use crate::codex_session::{CodexAction, CodexSession};
use crate::persistence::{
    delete_approval, list_approvals, list_review_comments, load_messages_from_transcript_path,
    load_session_by_id, load_token_usage_from_transcript_path, PersistCommand,
};
use crate::session::SessionHandle;
use crate::session_actor::SessionActorHandle;
use crate::session_command::{PersistOp, SessionCommand, SubscribeResult};
use crate::session_naming::name_from_first_prompt;
use crate::state::SessionRegistry;

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
    /// Pre-serialized JSON string (for replay)
    Raw(String),
    /// Raw pong response
    Pong(Bytes),
}

/// WebSocket upgrade handler
pub async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<Arc<SessionRegistry>>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

/// Handle a WebSocket connection
async fn handle_socket(socket: WebSocket, state: Arc<SessionRegistry>) {
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
                OutboundMessage::Raw(json) => ws_tx.send(Message::Text(json.into())).await,
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

/// Send a pre-serialized JSON string through the outbound channel (for replay)
async fn send_raw(tx: &mpsc::Sender<OutboundMessage>, json: String) {
    let _ = tx.send(OutboundMessage::Raw(json)).await;
}

/// Spawn a task that drains a broadcast receiver and forwards messages to an outbound channel.
/// When the outbound channel closes (client disconnects), the task exits and the
/// broadcast::Receiver is dropped — automatic cleanup, no manual unsubscribe needed.
///
/// If `session_id` is provided and the subscriber lags behind the broadcast buffer,
/// a `lagged` error is sent to the client so it can re-subscribe for a fresh snapshot.
fn spawn_broadcast_forwarder(
    mut rx: tokio::sync::broadcast::Receiver<ServerMessage>,
    outbound_tx: mpsc::Sender<OutboundMessage>,
    session_id: Option<String>,
) {
    tokio::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(msg) => {
                    if outbound_tx.send(OutboundMessage::Json(msg)).await.is_err() {
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    warn!(
                        component = "websocket",
                        event = "ws.broadcast.lagged",
                        session_id = ?session_id,
                        skipped = n,
                        "Broadcast subscriber lagged, skipped {n} messages"
                    );
                    // Notify the client so it can re-subscribe for a fresh snapshot.
                    let _ = outbound_tx
                        .send(OutboundMessage::Json(ServerMessage::Error {
                            code: "lagged".to_string(),
                            message: format!("Subscriber lagged, skipped {n} messages"),
                            session_id: session_id.clone(),
                        }))
                        .await;
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });
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
    state: &Arc<SessionRegistry>,
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
            let rx = state.subscribe_list();
            spawn_broadcast_forwarder(rx, client_tx.clone(), None);

            // Send current list
            let sessions = state.get_session_summaries();
            send_json(client_tx, ServerMessage::SessionsList { sessions }).await;
        }

        ClientMessage::SubscribeSession {
            session_id,
            since_revision,
        } => {
            if let Some(actor) = state.get_session(&session_id) {
                let snap = actor.snapshot();

                // Check for passive ended sessions that may need reactivation
                let is_passive_ended = snap.provider == Provider::Codex
                    && snap.status == orbitdock_protocol::SessionStatus::Ended
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
                                changes: orbitdock_protocol::StateChanges {
                                    status: Some(orbitdock_protocol::SessionStatus::Active),
                                    work_status: Some(orbitdock_protocol::WorkStatus::Waiting),
                                    last_activity_at: Some(now),
                                    ..Default::default()
                                },
                                persist_op: Some(PersistOp::SessionUpdate {
                                    id: session_id.clone(),
                                    status: Some(orbitdock_protocol::SessionStatus::Active),
                                    work_status: Some(orbitdock_protocol::WorkStatus::Waiting),
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
                                    send_json(
                                        client_tx,
                                        ServerMessage::SessionSnapshot {
                                            session: compact_snapshot_for_transport(*snapshot),
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
                                    for json in events {
                                        send_raw(client_tx, json).await;
                                    }
                                }
                            }
                        }
                        return;
                    }
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
                            for json in events {
                                send_raw(client_tx, json).await;
                            }
                        }
                        SubscribeResult::Snapshot {
                            state: snapshot,
                            rx,
                        } => {
                            let mut snapshot = *snapshot;
                            // If snapshot has no messages, try loading from transcript
                            snapshot = if snapshot.messages.is_empty() {
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
                                        loaded_snapshot
                                    } else {
                                        snapshot
                                    }
                                } else {
                                    snapshot
                                }
                            } else {
                                snapshot
                            };

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
                            send_json(
                                client_tx,
                                ServerMessage::SessionSnapshot {
                                    session: compact_snapshot_for_transport(snapshot),
                                },
                            )
                            .await;
                        }
                    }
                }
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

        ClientMessage::UnsubscribeSession { session_id: _ } => {
            // No-op: broadcast receivers clean up automatically when the
            // forwarder task exits (client disconnect drops the Receiver).
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
            let git_branch = crate::git::resolve_git_branch(&cwd).await;

            let mut handle = crate::session::SessionHandle::new(id.clone(), provider, cwd.clone());
            handle.set_git_branch(git_branch.clone());

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
                        let thread_id = codex_session.thread_id().to_string();
                        let _ = persist_tx
                            .send(PersistCommand::SetThreadId {
                                session_id: session_id.clone(),
                                thread_id: thread_id.clone(),
                            })
                            .await;
                        state.register_codex_thread(&session_id, codex_session.thread_id());

                        if state.remove_session(&thread_id).is_some() {
                            state.broadcast_to_list(ServerMessage::SessionEnded {
                                session_id: thread_id.clone(),
                                reason: "direct_session_thread_claimed".into(),
                            });
                        }
                        let _ = persist_tx
                            .send(PersistCommand::CleanupThreadShadowSession {
                                thread_id,
                                reason: "legacy_codex_thread_row_cleanup".into(),
                            })
                            .await;

                        handle.set_list_tx(state.list_tx());
                        let (actor_handle, action_tx) =
                            codex_session.start_event_loop(handle, persist_tx);
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
                    Err(e) => {
                        // No Codex connector; add as passive actor
                        state.add_session(handle);
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
            } else if provider == Provider::Claude {
                // Claude direct session
                let session_id = id.clone();
                let cwd_clone = cwd.clone();
                let model_clone = model.clone();

                match ClaudeSession::new(
                    session_id.clone(),
                    &cwd_clone,
                    model_clone.as_deref(),
                    None,
                )
                .await
                {
                    Ok(claude_session) => {
                        handle.set_list_tx(state.list_tx());
                        let (actor_handle, action_tx) =
                            claude_session.start_event_loop(handle, persist_tx, state.list_tx(), state.clone());
                        state.add_session_actor(actor_handle);
                        state.set_claude_action_tx(&session_id, action_tx);
                        info!(
                            component = "session",
                            event = "session.create.claude_connector_started",
                            connection_id = conn_id,
                            session_id = %session_id,
                            "Claude connector started"
                        );
                    }
                    Err(e) => {
                        state.add_session(handle);
                        error!(
                            component = "session",
                            event = "session.create.claude_connector_failed",
                            connection_id = conn_id,
                            session_id = %session_id,
                            error = %e,
                            "Failed to start Claude session"
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

        ClientMessage::SendMessage {
            session_id,
            content,
            model,
            effort,
            skills,
            images,
            mentions,
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
                images_count = images.len(),
                mentions_count = mentions.len(),
                "Sending message to session"
            );

            // Try Codex action channel first, then Claude
            let codex_tx = state.get_codex_action_tx(&session_id);
            let claude_tx = state.get_claude_action_tx(&session_id);

            if codex_tx.is_some() || claude_tx.is_some() {
                let first_prompt = name_from_first_prompt(&content);

                let _ = state
                    .persist()
                    .send(PersistCommand::CodexPromptIncrement {
                        id: session_id.clone(),
                        first_prompt: first_prompt.clone(),
                    })
                    .await;

                // Broadcast first_prompt delta and trigger AI naming
                if let Some(prompt) = first_prompt {
                    if let Some(actor) = state.get_session(&session_id) {
                        let changes = orbitdock_protocol::StateChanges {
                            first_prompt: Some(Some(prompt.clone())),
                            ..Default::default()
                        };
                        let _ = actor
                            .send(SessionCommand::ApplyDelta {
                                changes,
                                persist_op: None,
                            })
                            .await;

                        // Trigger AI naming (fire-and-forget, deduped)
                        if state.naming_guard().try_claim(&session_id) {
                            crate::ai_naming::spawn_naming_task(
                                session_id.clone(),
                                prompt,
                                actor,
                                state.persist().clone(),
                                state.list_tx(),
                            );
                        }
                    }
                }

                // Persist user message immediately
                let ts_millis = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis();
                let user_msg = orbitdock_protocol::Message {
                    id: format!("user-ws-{}-{}", ts_millis, conn_id),
                    session_id: session_id.clone(),
                    message_type: orbitdock_protocol::MessageType::User,
                    content: content.clone(),
                    tool_name: None,
                    tool_input: None,
                    tool_output: None,
                    is_error: false,
                    timestamp: iso_timestamp(ts_millis),
                    duration_ms: None,
                };

                if let Some(actor) = state.get_session(&session_id) {
                    let _ = state
                        .persist()
                        .send(PersistCommand::MessageAppend {
                            session_id: session_id.clone(),
                            message: user_msg.clone(),
                        })
                        .await;
                    actor
                        .send(SessionCommand::AddMessageAndBroadcast { message: user_msg })
                        .await;
                }

                if let Some(tx) = codex_tx {
                    let _ = tx
                        .send(CodexAction::SendMessage {
                            content,
                            model,
                            effort,
                            skills,
                            images,
                            mentions,
                        })
                        .await;
                } else if let Some(tx) = claude_tx {
                    let _ = tx
                        .send(ClaudeAction::SendMessage {
                            content,
                            model,
                            effort,
                        })
                        .await;
                }
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

        ClientMessage::SteerTurn {
            session_id,
            content,
        } => {
            info!(
                component = "session",
                event = "session.steer.requested",
                connection_id = conn_id,
                session_id = %session_id,
                content_chars = content.chars().count(),
                "Steering active turn"
            );

            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                // Persist steer message so it appears in conversation
                let ts_millis = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis();
                let steer_msg_id = format!("steer-ws-{}-{}", ts_millis, conn_id);
                let steer_msg = orbitdock_protocol::Message {
                    id: steer_msg_id.clone(),
                    session_id: session_id.clone(),
                    message_type: orbitdock_protocol::MessageType::Steer,
                    content: content.clone(),
                    tool_name: None,
                    tool_input: None,
                    tool_output: None,
                    is_error: false,
                    timestamp: iso_timestamp(ts_millis),
                    duration_ms: None,
                };

                if let Some(actor) = state.get_session(&session_id) {
                    let _ = state
                        .persist()
                        .send(PersistCommand::MessageAppend {
                            session_id: session_id.clone(),
                            message: steer_msg.clone(),
                        })
                        .await;
                    actor
                        .send(SessionCommand::AddMessageAndBroadcast { message: steer_msg })
                        .await;
                }

                let _ = tx
                    .send(CodexAction::SteerTurn {
                        content,
                        message_id: steer_msg_id,
                    })
                    .await;
            } else {
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
                if let Some(actor) = state.get_session(&session_id) {
                    let (reply_tx, reply_rx) = oneshot::channel();
                    actor
                        .send(SessionCommand::TakePendingApproval {
                            request_id: request_id.clone(),
                            reply: reply_tx,
                        })
                        .await;
                    reply_rx.await.unwrap_or((None, None))
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
            } else if let Some(tx) = state.get_claude_action_tx(&session_id) {
                let _ = tx
                    .send(ClaudeAction::ApproveTool {
                        request_id,
                        decision: decision.clone(),
                    })
                    .await;
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

            if let Some(actor) = state.get_session(&session_id) {
                actor
                    .send(SessionCommand::ApplyDelta {
                        changes: orbitdock_protocol::StateChanges {
                            work_status: Some(next_work_status),
                            pending_approval: Some(None),
                            ..Default::default()
                        },
                        persist_op: None,
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

        ClientMessage::CodexAccountRead { refresh_token } => {
            let auth = state.codex_auth();
            match auth.read_account(refresh_token).await {
                Ok(status) => {
                    send_json(client_tx, ServerMessage::CodexAccountStatus { status }).await;
                }
                Err(err) => {
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "codex_auth_error".into(),
                            message: err,
                            session_id: None,
                        },
                    )
                    .await;
                }
            }
        }

        ClientMessage::CodexLoginChatgptStart => {
            let auth = state.codex_auth();
            match auth.start_chatgpt_login().await {
                Ok((login_id, auth_url)) => {
                    send_json(
                        client_tx,
                        ServerMessage::CodexLoginChatgptStarted { login_id, auth_url },
                    )
                    .await;
                    if let Ok(status) = auth.read_account(false).await {
                        state.broadcast_to_list(ServerMessage::CodexAccountStatus { status });
                    }
                }
                Err(err) => {
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "codex_auth_login_start_failed".into(),
                            message: err,
                            session_id: None,
                        },
                    )
                    .await;
                }
            }
        }

        ClientMessage::CodexLoginChatgptCancel { login_id } => {
            let auth = state.codex_auth();
            let status = auth.cancel_chatgpt_login(login_id.clone()).await;
            send_json(
                client_tx,
                ServerMessage::CodexLoginChatgptCanceled { login_id, status },
            )
            .await;
            if let Ok(status) = auth.read_account(false).await {
                state.broadcast_to_list(ServerMessage::CodexAccountStatus { status });
            }
        }

        ClientMessage::CodexAccountLogout => {
            let auth = state.codex_auth();
            match auth.logout().await {
                Ok(status) => {
                    let updated = ServerMessage::CodexAccountUpdated {
                        status: status.clone(),
                    };
                    send_json(client_tx, updated.clone()).await;
                    state.broadcast_to_list(updated);
                }
                Err(err) => {
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "codex_auth_logout_failed".into(),
                            message: err,
                            session_id: None,
                        },
                    )
                    .await;
                }
            }
        }

        ClientMessage::ListSkills {
            session_id,
            cwds,
            force_reload,
        } => {
            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx
                    .send(CodexAction::ListSkills { cwds, force_reload })
                    .await;
            } else {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "session_not_found".into(),
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

        ClientMessage::ListRemoteSkills { session_id } => {
            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx.send(CodexAction::ListRemoteSkills).await;
            } else {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "session_not_found".into(),
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

        ClientMessage::DownloadRemoteSkill {
            session_id,
            hazelnut_id,
        } => {
            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx
                    .send(CodexAction::DownloadRemoteSkill { hazelnut_id })
                    .await;
            } else {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "session_not_found".into(),
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

        ClientMessage::ListMcpTools { session_id } => {
            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx.send(CodexAction::ListMcpTools).await;
            } else {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "session_not_found".into(),
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

        ClientMessage::RefreshMcpServers { session_id } => {
            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx.send(CodexAction::RefreshMcpServers).await;
            } else {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "session_not_found".into(),
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

            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let mut answers = std::collections::HashMap::new();
                answers.insert("0".to_string(), answer);
                let _ = tx
                    .send(CodexAction::AnswerQuestion {
                        request_id,
                        answers,
                    })
                    .await;
            } else if let Some(tx) = state.get_claude_action_tx(&session_id) {
                let _ = tx
                    .send(ClaudeAction::AnswerQuestion { request_id, answer })
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

            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx.send(CodexAction::Interrupt).await;
            } else if let Some(tx) = state.get_claude_action_tx(&session_id) {
                let _ = tx.send(ClaudeAction::Interrupt).await;
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

            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx.send(CodexAction::Compact).await;
            } else if let Some(tx) = state.get_claude_action_tx(&session_id) {
                let _ = tx.send(ClaudeAction::Compact).await;
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

            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx.send(CodexAction::Undo).await;
            }
        }

        ClientMessage::RollbackTurns {
            session_id,
            num_turns,
        } => {
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

            if let Some(actor) = state.get_session(&session_id) {
                actor
                    .send(SessionCommand::ApplyDelta {
                        changes: orbitdock_protocol::StateChanges {
                            approval_policy: Some(approval_policy.clone()),
                            sandbox_mode: Some(sandbox_mode.clone()),
                            ..Default::default()
                        },
                        persist_op: Some(PersistOp::SetSessionConfig {
                            session_id: session_id.clone(),
                            approval_policy: approval_policy.clone(),
                            sandbox_mode: sandbox_mode.clone(),
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

            if let Some(tx) = state.get_codex_action_tx(&session_id) {
                let _ = tx
                    .send(CodexAction::UpdateConfig {
                        approval_policy,
                        sandbox_mode,
                    })
                    .await;
            }
        }

        ClientMessage::SetOpenAiKey { key } => {
            info!(
                component = "config",
                event = "config.openai_key.set",
                connection_id = conn_id,
                "OpenAI API key set via UI"
            );

            // Persist to macOS Keychain (picked up on next server restart)
            let key_for_keychain = key;
            tokio::task::spawn_blocking(move || {
                let result = std::process::Command::new("security")
                    .args([
                        "add-generic-password",
                        "-s",
                        "com.orbitdock.openai-api-key",
                        "-a",
                        "orbitdock",
                        "-w",
                        &key_for_keychain,
                        "-U", // Update if exists
                    ])
                    .output();
                match result {
                    Ok(output) if output.status.success() => {
                        info!(
                            event = "config.openai_key.keychain_saved",
                            "API key saved to Keychain"
                        );
                    }
                    Ok(output) => {
                        warn!(
                            event = "config.openai_key.keychain_failed",
                            stderr = %String::from_utf8_lossy(&output.stderr),
                            "Failed to save API key to Keychain"
                        );
                    }
                    Err(e) => {
                        warn!(
                            event = "config.openai_key.keychain_error",
                            error = %e,
                            "Keychain command failed"
                        );
                    }
                }
            });
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
            if state.get_session(&session_id).is_some() {
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
            let mut handle = SessionHandle::restore(
                restored.id.clone(),
                orbitdock_protocol::Provider::Codex,
                restored.project_path.clone(),
                restored.transcript_path.clone(),
                restored.project_name,
                restored.model.clone(),
                restored.custom_name,
                restored.summary,
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
                restored.current_diff,
                restored.current_plan,
                restored
                    .turn_diffs
                    .into_iter()
                    .map(|(turn_id, diff)| orbitdock_protocol::TurnDiff { turn_id, diff })
                    .collect(),
                restored.git_branch,
                restored.git_sha,
                restored.current_cwd,
                restored.first_prompt,
                restored.last_message,
            );

            // Subscribe the requesting client
            let rx = handle.subscribe();
            spawn_broadcast_forwarder(rx, client_tx.clone(), Some(session_id.clone()));

            let summary = handle.summary();
            let snapshot = handle.state();

            // Reactivate in DB
            let persist_tx = state.persist().clone();
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
                    state.register_codex_thread(&session_id, &new_thread_id);
                    if state.remove_session(&new_thread_id).is_some() {
                        state.broadcast_to_list(ServerMessage::SessionEnded {
                            session_id: new_thread_id.clone(),
                            reason: "direct_session_thread_claimed".into(),
                        });
                    }
                    let _ = persist_tx
                        .send(PersistCommand::CleanupThreadShadowSession {
                            thread_id: new_thread_id.clone(),
                            reason: "legacy_codex_thread_row_cleanup".into(),
                        })
                        .await;

                    handle.set_list_tx(state.list_tx());
                    let (actor_handle, action_tx) =
                        codex_session.start_event_loop(handle, persist_tx);
                    state.add_session_actor(actor_handle);
                    state.set_codex_action_tx(&session_id, action_tx);
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
                    // No connector; add as passive actor
                    state.add_session(handle);
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
            state.broadcast_to_list(ServerMessage::SessionCreated { session: summary });
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

            // Skip if this session ID belongs to a managed Claude direct session
            if state.is_managed_claude_thread(&session_id) {
                return;
            }

            let persist_tx = state.persist().clone();
            let now_secs = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();

            // Prune stale empty Claude shells in the same project so they do not
            // linger as ghost active sessions.
            let stale_shell_ids: Vec<String> = state
                .get_session_summaries()
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
                    state.broadcast_to_list(ServerMessage::SessionEnded {
                        session_id: stale_id,
                        reason: "stale_empty_shell".to_string(),
                    });
                }
            }

            // Resolve git branch from cwd
            let git_branch = crate::git::resolve_git_branch(&cwd).await;

            let mut created = false;
            let actor = if let Some(existing) = state.get_session(&session_id) {
                let snap = existing.snapshot();
                if snap.provider == Provider::Codex {
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

            actor
                .send(SessionCommand::SetModel {
                    model: model.clone(),
                })
                .await;
            if transcript_path.is_some() {
                actor
                    .send(SessionCommand::SetTranscriptPath {
                        path: transcript_path.clone(),
                    })
                    .await;
            }
            actor
                .send(SessionCommand::ApplyDelta {
                    changes: orbitdock_protocol::StateChanges {
                        work_status: Some(orbitdock_protocol::WorkStatus::Waiting),
                        git_branch: git_branch.as_ref().map(|b| Some(b.clone())),
                        last_activity_at: Some(chrono_now()),
                        ..Default::default()
                    },
                    persist_op: None,
                })
                .await;

            if created {
                let (sum_tx, sum_rx) = oneshot::channel();
                actor
                    .send(SessionCommand::GetSummary { reply: sum_tx })
                    .await;
                if let Ok(summary) = sum_rx.await {
                    state.broadcast_to_list(ServerMessage::SessionCreated { session: summary });
                }
            }

            let _ = persist_tx
                .send(PersistCommand::ClaudeSessionUpsert {
                    id: session_id,
                    project_path: cwd.clone(),
                    project_name: project_name_from_cwd(&cwd),
                    branch: git_branch,
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
            // Skip if this session ID belongs to a managed Claude direct session
            if state.is_managed_claude_thread(&session_id) {
                return;
            }

            let persist_tx = state.persist().clone();

            if let Some(existing) = state.get_session(&session_id) {
                if existing.snapshot().provider == Provider::Codex {
                    return;
                }

                // Extract AI-generated summary from transcript before ending
                if let Some(transcript_path) = &existing.snapshot().transcript_path {
                    if let Some(summary) =
                        crate::persistence::extract_summary_from_transcript_path(transcript_path)
                            .await
                    {
                        let _ = persist_tx
                            .send(PersistCommand::SetSummary {
                                session_id: session_id.clone(),
                                summary,
                            })
                            .await;
                    }
                }
            }

            let _ = persist_tx
                .send(PersistCommand::ClaudeSessionEnd {
                    id: session_id.clone(),
                    reason: reason.clone(),
                })
                .await;

            if state.remove_session(&session_id).is_some() {
                state.broadcast_to_list(ServerMessage::SessionEnded {
                    session_id,
                    reason: reason.unwrap_or_else(|| "hook_session_end".to_string()),
                });
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
            // If this hook is from a managed Claude direct session, route
            // supplementary data (summary, compact_count, last_tool) to the
            // owning session instead of creating/updating a passive session.
            if state.is_managed_claude_thread(&session_id) {
                if let Some(owning_id) = state.resolve_claude_thread(&session_id) {
                    if let Some(actor) = state.get_session(&owning_id) {
                        let persist_tx = state.persist().clone();

                        // Route summary extraction on Stop
                        if hook_event_name == "Stop" {
                            let snap = actor.snapshot();
                            if snap.summary.is_none() {
                                let derived = cwd.as_deref().and_then(|p| {
                                    claude_transcript_path_from_cwd(p, &session_id)
                                });
                                let tp = snap
                                    .transcript_path
                                    .clone()
                                    .or_else(|| transcript_path.clone())
                                    .or(derived);
                                if let Some(path) = tp {
                                    if let Some(summary) =
                                        crate::persistence::extract_summary_from_transcript_path(
                                            &path,
                                        )
                                        .await
                                    {
                                        actor
                                            .send(SessionCommand::ApplyDelta {
                                                changes: orbitdock_protocol::StateChanges {
                                                    summary: Some(Some(summary.clone())),
                                                    ..Default::default()
                                                },
                                                persist_op: None,
                                            })
                                            .await;
                                        let _ = persist_tx
                                            .send(PersistCommand::SetSummary {
                                                session_id: owning_id.clone(),
                                                summary,
                                            })
                                            .await;
                                    }
                                }
                            }
                        }

                        // Route compact_count increment on PreCompact
                        if hook_event_name == "PreCompact" {
                            let _ = persist_tx
                                .send(PersistCommand::ClaudeSessionUpdate {
                                    id: owning_id.clone(),
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

                        // Route last_tool tracking
                        if let Some(ref tool_name) = tool_name {
                            actor
                                .send(SessionCommand::SetLastTool {
                                    tool: Some(tool_name.clone()),
                                })
                                .await;
                        }
                    }
                }
                return;
            }

            let persist_tx = state.persist().clone();
            let derived_transcript_path = cwd
                .as_deref()
                .and_then(|path| claude_transcript_path_from_cwd(path, &session_id));

            // Resolve git branch from cwd if available
            let git_branch = match cwd.as_deref() {
                Some(path) => crate::git::resolve_git_branch(path).await,
                None => None,
            };

            let actor = if let Some(existing) = state.get_session(&session_id) {
                if existing.snapshot().provider == Provider::Codex {
                    return;
                }
                // Update branch if we have one and it's missing
                if git_branch.is_some() && existing.snapshot().git_branch.is_none() {
                    existing
                        .send(SessionCommand::ApplyDelta {
                            changes: orbitdock_protocol::StateChanges {
                                git_branch: git_branch.as_ref().map(|b| Some(b.clone())),
                                ..Default::default()
                            },
                            persist_op: None,
                        })
                        .await;
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
                let actor = state.add_session(handle);

                // Set branch via delta for new sessions
                if git_branch.is_some() {
                    actor
                        .send(SessionCommand::ApplyDelta {
                            changes: orbitdock_protocol::StateChanges {
                                git_branch: git_branch.as_ref().map(|b| Some(b.clone())),
                                ..Default::default()
                            },
                            persist_op: None,
                        })
                        .await;
                }

                let (sum_tx, sum_rx) = oneshot::channel();
                actor
                    .send(SessionCommand::GetSummary { reply: sum_tx })
                    .await;
                if let Ok(summary) = sum_rx.await {
                    state.broadcast_to_list(ServerMessage::SessionCreated { session: summary });
                }
                actor
            };

            if transcript_path.is_some() || derived_transcript_path.is_some() {
                actor
                    .send(SessionCommand::SetTranscriptPath {
                        path: transcript_path
                            .clone()
                            .or_else(|| derived_transcript_path.clone()),
                    })
                    .await;
            }

            if let Some(cwd) = cwd.clone() {
                let _ = persist_tx
                    .send(PersistCommand::ClaudeSessionUpsert {
                        id: session_id.clone(),
                        project_path: cwd.clone(),
                        project_name: project_name_from_cwd(&cwd),
                        branch: git_branch.clone(),
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
                        let (lt_tx, lt_rx) = oneshot::channel();
                        actor
                            .send(SessionCommand::GetLastTool { reply: lt_tx })
                            .await;
                        lt_rx.await.ok().flatten().as_deref() == Some("AskUserQuestion")
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
                            let (lt_tx, lt_rx) = oneshot::channel();
                            actor
                                .send(SessionCommand::GetLastTool { reply: lt_tx })
                                .await;
                            lt_rx.await.ok().flatten().as_deref() == Some("AskUserQuestion")
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

                // Broadcast first_prompt delta and trigger AI naming
                if let Some(ref prompt_text) = prompt {
                    let changes = orbitdock_protocol::StateChanges {
                        first_prompt: Some(Some(prompt_text.clone())),
                        ..Default::default()
                    };
                    let _ = actor
                        .send(SessionCommand::ApplyDelta {
                            changes,
                            persist_op: None,
                        })
                        .await;

                    if state.naming_guard().try_claim(&session_id) {
                        crate::ai_naming::spawn_naming_task(
                            session_id.clone(),
                            prompt_text.clone(),
                            actor.clone(),
                            persist_tx.clone(),
                            state.list_tx(),
                        );
                    }
                }
            }

            // On Stop events, try to extract AI-generated summary from transcript.
            // Claude writes {"type":"summary","summary":"..."} at end of turns/sessions.
            if hook_event_name == "Stop" {
                let snap = actor.snapshot();
                if snap.summary.is_none() {
                    let tp = snap
                        .transcript_path
                        .clone()
                        .or_else(|| transcript_path.clone())
                        .or_else(|| derived_transcript_path.clone());
                    if let Some(path) = tp {
                        if let Some(extracted_summary) =
                            crate::persistence::extract_summary_from_transcript_path(&path).await
                        {
                            // Apply to in-memory session state
                            actor
                                .send(SessionCommand::ApplyDelta {
                                    changes: orbitdock_protocol::StateChanges {
                                        summary: Some(Some(extracted_summary.clone())),
                                        ..Default::default()
                                    },
                                    persist_op: None,
                                })
                                .await;
                            // Persist to DB
                            let _ = persist_tx
                                .send(PersistCommand::SetSummary {
                                    session_id: session_id.clone(),
                                    summary: extracted_summary,
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
                actor
                    .send(SessionCommand::SetLastTool {
                        tool: Some(tool_name),
                    })
                    .await;
            }

            if let Some(work_status) = next_work_status {
                actor
                    .send(SessionCommand::ApplyDelta {
                        changes: orbitdock_protocol::StateChanges {
                            work_status: Some(work_status),
                            last_activity_at: Some(chrono_now()),
                            ..Default::default()
                        },
                        persist_op: None,
                    })
                    .await;

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
            sync_transcript_messages(&actor).await;
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
            // If this hook is from a managed Claude direct session, route
            // supplementary data (tool_count, last_tool) to the owning session.
            if state.is_managed_claude_thread(&session_id) {
                if let Some(owning_id) = state.resolve_claude_thread(&session_id) {
                    let persist_tx = state.persist().clone();

                    match hook_event_name.as_str() {
                        "PreToolUse" => {
                            // Route last_tool tracking
                            let _ = persist_tx
                                .send(PersistCommand::ClaudeSessionUpdate {
                                    id: owning_id.clone(),
                                    work_status: None,
                                    attention_reason: None,
                                    last_tool: Some(Some(tool_name.clone())),
                                    last_tool_at: Some(Some(chrono_now())),
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

                            if let Some(actor) = state.get_session(&owning_id) {
                                actor
                                    .send(SessionCommand::SetLastTool {
                                        tool: Some(tool_name.clone()),
                                    })
                                    .await;
                            }
                        }
                        "PostToolUse" | "PostToolUseFailure" => {
                            // Route tool_count increment
                            let _ = persist_tx
                                .send(PersistCommand::ClaudeToolIncrement {
                                    id: owning_id.clone(),
                                })
                                .await;
                        }
                        _ => {}
                    }
                }
                return;
            }

            let persist_tx = state.persist().clone();
            let derived_transcript_path = claude_transcript_path_from_cwd(&cwd, &session_id);

            // Resolve git branch from cwd
            let git_branch = crate::git::resolve_git_branch(&cwd).await;

            let actor = if let Some(existing) = state.get_session(&session_id) {
                if existing.snapshot().provider == Provider::Codex {
                    return;
                }
                // Update branch if missing
                if git_branch.is_some() && existing.snapshot().git_branch.is_none() {
                    existing
                        .send(SessionCommand::ApplyDelta {
                            changes: orbitdock_protocol::StateChanges {
                                git_branch: git_branch.as_ref().map(|b| Some(b.clone())),
                                ..Default::default()
                            },
                            persist_op: None,
                        })
                        .await;
                }
                existing
            } else {
                let mut handle =
                    SessionHandle::new(session_id.clone(), Provider::Claude, cwd.clone());
                handle.set_project_name(project_name_from_cwd(handle.project_path()));
                handle.set_transcript_path(derived_transcript_path.clone());
                let actor = state.add_session(handle);

                if git_branch.is_some() {
                    actor
                        .send(SessionCommand::ApplyDelta {
                            changes: orbitdock_protocol::StateChanges {
                                git_branch: git_branch.as_ref().map(|b| Some(b.clone())),
                                ..Default::default()
                            },
                            persist_op: None,
                        })
                        .await;
                }

                let (sum_tx, sum_rx) = oneshot::channel();
                actor
                    .send(SessionCommand::GetSummary { reply: sum_tx })
                    .await;
                if let Ok(summary) = sum_rx.await {
                    state.broadcast_to_list(ServerMessage::SessionCreated { session: summary });
                }
                actor
            };

            let _ = persist_tx
                .send(PersistCommand::ClaudeSessionUpsert {
                    id: session_id.clone(),
                    project_path: cwd.clone(),
                    project_name: project_name_from_cwd(&cwd),
                    branch: git_branch,
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
                    let was_permission =
                        actor.snapshot().work_status == orbitdock_protocol::WorkStatus::Permission;
                    let question = tool_input
                        .as_ref()
                        .and_then(|value| value.get("question"))
                        .and_then(Value::as_str)
                        .map(|s| s.to_string());
                    let serialized_input =
                        tool_input.and_then(|value| serde_json::to_string(&value).ok());

                    actor
                        .send(SessionCommand::SetLastTool {
                            tool: Some(tool_name.clone()),
                        })
                        .await;
                    actor
                        .send(SessionCommand::ApplyDelta {
                            changes: orbitdock_protocol::StateChanges {
                                work_status: Some(orbitdock_protocol::WorkStatus::Working),
                                last_activity_at: Some(chrono_now()),
                                ..Default::default()
                            },
                            persist_op: None,
                        })
                        .await;

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

                    actor
                        .send(SessionCommand::ApplyDelta {
                            changes: orbitdock_protocol::StateChanges {
                                work_status: Some(orbitdock_protocol::WorkStatus::Working),
                                last_activity_at: Some(chrono_now()),
                                ..Default::default()
                            },
                            persist_op: None,
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

                    actor
                        .send(SessionCommand::ApplyDelta {
                            changes: orbitdock_protocol::StateChanges {
                                work_status: Some(orbitdock_protocol::WorkStatus::Waiting),
                                last_activity_at: Some(chrono_now()),
                                ..Default::default()
                            },
                            persist_op: None,
                        })
                        .await;
                }
                _ => {}
            }

            // Sync new messages from transcript
            sync_transcript_messages(&actor).await;
        }

        ClientMessage::GetSubagentTools {
            session_id,
            subagent_id,
        } => {
            debug!(
                component = "websocket",
                event = "ws.get_subagent_tools",
                connection_id = conn_id,
                session_id = %session_id,
                subagent_id = %subagent_id,
                "GetSubagentTools request"
            );

            let subagent_id_clone = subagent_id.clone();
            let session_id_clone = session_id.clone();
            let client_tx = client_tx.clone();

            tokio::spawn(async move {
                match crate::persistence::load_subagent_transcript_path(&subagent_id_clone).await {
                    Ok(Some(path)) => {
                        let tools = tokio::task::spawn_blocking(move || {
                            crate::subagent_parser::parse_tools(std::path::Path::new(&path))
                        })
                        .await
                        .unwrap_or_default();

                        let _ = client_tx
                            .send(OutboundMessage::Json(ServerMessage::SubagentToolsList {
                                session_id: session_id_clone,
                                subagent_id: subagent_id_clone,
                                tools,
                            }))
                            .await;
                    }
                    Ok(None) => {
                        let _ = client_tx
                            .send(OutboundMessage::Json(ServerMessage::SubagentToolsList {
                                session_id: session_id_clone,
                                subagent_id: subagent_id_clone,
                                tools: Vec::new(),
                            }))
                            .await;
                    }
                    Err(e) => {
                        warn!(
                            component = "websocket",
                            event = "ws.get_subagent_tools.error",
                            error = %e,
                            "Failed to load subagent transcript path"
                        );
                        let _ = client_tx
                            .send(OutboundMessage::Json(ServerMessage::SubagentToolsList {
                                session_id: session_id_clone,
                                subagent_id: subagent_id_clone,
                                tools: Vec::new(),
                            }))
                            .await;
                    }
                }
            });
        }

        ClientMessage::ClaudeSubagentEvent {
            session_id,
            hook_event_name,
            agent_id,
            agent_type,
            agent_transcript_path,
        } => {
            // If this hook is from a managed Claude direct session, route
            // subagent tracking to the owning session.
            if state.is_managed_claude_thread(&session_id) {
                if let Some(owning_id) = state.resolve_claude_thread(&session_id) {
                    let persist_tx = state.persist().clone();

                    match hook_event_name.as_str() {
                        "SubagentStart" => {
                            let normalized_type =
                                agent_type.clone().unwrap_or_else(|| "unknown".to_string());
                            let _ = persist_tx
                                .send(PersistCommand::ClaudeSubagentStart {
                                    id: agent_id.clone(),
                                    session_id: owning_id.clone(),
                                    agent_type: normalized_type.clone(),
                                })
                                .await;
                            let _ = persist_tx
                                .send(PersistCommand::ClaudeSessionUpdate {
                                    id: owning_id,
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
                                    id: owning_id,
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
                return;
            }

            let persist_tx = state.persist().clone();
            if let Some(existing) = state.get_session(&session_id) {
                if existing.snapshot().provider == Provider::Codex {
                    return;
                }
            }

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

            // Verify source session exists and has an active connector
            let source_action_tx = match state.get_codex_action_tx(&source_session_id) {
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
            let source_cwd = state
                .get_session(&source_session_id)
                .map(|s| s.snapshot().project_path.clone());

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

            let fork_branch = crate::git::resolve_git_branch(&fork_cwd).await;
            let mut handle = SessionHandle::new(new_id.clone(), Provider::Codex, fork_cwd.clone());
            handle.set_git_branch(fork_branch.clone());
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
            let rx = handle.subscribe();
            spawn_broadcast_forwarder(rx, client_tx.clone(), Some(new_id.clone()));

            let summary = handle.summary();
            let snapshot = handle.state();

            let persist_tx = state.persist().clone();

            // Persist new session
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

            // Register thread ID
            let _ = persist_tx
                .send(PersistCommand::SetThreadId {
                    session_id: new_id.clone(),
                    thread_id: new_thread_id.clone(),
                })
                .await;
            state.register_codex_thread(&new_id, &new_thread_id);

            // Clean up any shadow session from rollout watcher
            if state.remove_session(&new_thread_id).is_some() {
                state.broadcast_to_list(ServerMessage::SessionEnded {
                    session_id: new_thread_id.clone(),
                    reason: "direct_session_thread_claimed".into(),
                });
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
            handle.set_list_tx(state.list_tx());
            let (actor_handle, action_tx) = codex_session.start_event_loop(handle, persist_tx);
            state.add_session_actor(actor_handle);
            state.set_codex_action_tx(&new_id, action_tx);

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
            state.broadcast_to_list(ServerMessage::SessionCreated { session: summary });

            info!(
                component = "session",
                event = "session.fork.completed",
                connection_id = conn_id,
                source_session_id = %source_session_id,
                new_session_id = %new_id,
                "Session forked successfully"
            );
        }

        ClientMessage::CreateReviewComment {
            session_id,
            turn_id,
            file_path,
            line_start,
            line_end,
            body,
            tag,
        } => {
            let comment_id = format!(
                "rc-{}-{}",
                &session_id[..8.min(session_id.len())],
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis()
            );

            let tag_str = tag.map(|t| {
                match t {
                    orbitdock_protocol::ReviewCommentTag::Clarity => "clarity",
                    orbitdock_protocol::ReviewCommentTag::Scope => "scope",
                    orbitdock_protocol::ReviewCommentTag::Risk => "risk",
                    orbitdock_protocol::ReviewCommentTag::Nit => "nit",
                }
                .to_string()
            });

            let now = {
                let secs = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs();
                format!("{}Z", secs)
            };

            let comment = orbitdock_protocol::ReviewComment {
                id: comment_id.clone(),
                session_id: session_id.clone(),
                turn_id: turn_id.clone(),
                file_path: file_path.clone(),
                line_start,
                line_end,
                body: body.clone(),
                tag,
                status: orbitdock_protocol::ReviewCommentStatus::Open,
                created_at: now,
                updated_at: None,
            };

            let _ = state
                .persist()
                .send(PersistCommand::ReviewCommentCreate {
                    id: comment_id,
                    session_id: session_id.clone(),
                    turn_id,
                    file_path,
                    line_start,
                    line_end,
                    body,
                    tag: tag_str,
                })
                .await;

            // Broadcast to session subscribers
            if let Some(actor) = state.get_session(&session_id) {
                actor
                    .send(crate::session_command::SessionCommand::Broadcast {
                        msg: ServerMessage::ReviewCommentCreated {
                            session_id,
                            comment,
                        },
                    })
                    .await;
            }
        }

        ClientMessage::UpdateReviewComment {
            comment_id,
            body,
            tag,
            status,
        } => {
            let tag_str = tag.map(|t| match t {
                orbitdock_protocol::ReviewCommentTag::Clarity => "clarity".to_string(),
                orbitdock_protocol::ReviewCommentTag::Scope => "scope".to_string(),
                orbitdock_protocol::ReviewCommentTag::Risk => "risk".to_string(),
                orbitdock_protocol::ReviewCommentTag::Nit => "nit".to_string(),
            });
            let status_str = status.map(|s| match s {
                orbitdock_protocol::ReviewCommentStatus::Open => "open".to_string(),
                orbitdock_protocol::ReviewCommentStatus::Resolved => "resolved".to_string(),
            });

            let _ = state
                .persist()
                .send(PersistCommand::ReviewCommentUpdate {
                    id: comment_id.clone(),
                    body: body.clone(),
                    tag: tag_str,
                    status: status_str,
                })
                .await;

            // TODO: broadcast ReviewCommentUpdated once we can read back the full comment
            // For now, the client can optimistically update its local state
        }

        ClientMessage::DeleteReviewComment { comment_id } => {
            let _ = state
                .persist()
                .send(PersistCommand::ReviewCommentDelete {
                    id: comment_id.clone(),
                })
                .await;

            // We don't know the session_id here, so we can't target a broadcast.
            // The client should optimistically remove the comment locally.
        }

        ClientMessage::ListReviewComments {
            session_id,
            turn_id,
        } => match list_review_comments(&session_id, turn_id.as_deref()).await {
            Ok(comments) => {
                send_json(
                    client_tx,
                    ServerMessage::ReviewCommentsList {
                        session_id,
                        comments,
                    },
                )
                .await;
            }
            Err(e) => {
                warn!(
                    component = "websocket",
                    event = "review_comments.list.failed",
                    error = %e,
                    "Failed to list review comments"
                );
                send_json(
                    client_tx,
                    ServerMessage::ReviewCommentsList {
                        session_id,
                        comments: Vec::new(),
                    },
                )
                .await;
            }
        },

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
    }
}

/// Re-read a session's transcript and broadcast any new messages to subscribers.
/// Works for any hook-triggered session (Claude CLI, future Codex CLI hooks).
async fn sync_transcript_messages(actor: &SessionActorHandle) {
    let snap = actor.snapshot();
    let transcript_path = match snap.transcript_path.as_deref() {
        Some(p) => p.to_string(),
        None => return,
    };
    let session_id = snap.id.clone();
    let existing_count = snap.message_count;

    let all_messages = match load_messages_from_transcript_path(&transcript_path, &session_id).await
    {
        Ok(msgs) => msgs,
        Err(_) => return,
    };

    if let Ok(Some(usage)) = load_token_usage_from_transcript_path(&transcript_path).await {
        let current_usage = &snap.token_usage;
        if usage.input_tokens != current_usage.input_tokens
            || usage.output_tokens != current_usage.output_tokens
            || usage.cached_tokens != current_usage.cached_tokens
            || usage.context_window != current_usage.context_window
        {
            actor
                .send(SessionCommand::ProcessEvent {
                    event: crate::transition::Input::TokensUpdated(usage),
                })
                .await;
        }
    }

    if all_messages.len() <= existing_count {
        return;
    }

    let new_messages = all_messages[existing_count..].to_vec();

    // Double-check count hasn't changed while we were reading
    let (count_tx, count_rx) = oneshot::channel();
    actor
        .send(SessionCommand::GetMessageCount { reply: count_tx })
        .await;
    if let Ok(current_count) = count_rx.await {
        if current_count != existing_count {
            return;
        }
    }

    for msg in new_messages {
        actor
            .send(SessionCommand::AddMessageAndBroadcast { message: msg })
            .await;
    }
}

/// Format millis-since-epoch as ISO 8601 timestamp
fn iso_timestamp(millis: u128) -> String {
    let total_secs = millis / 1000;
    let secs = total_secs % 60;
    let total_mins = total_secs / 60;
    let mins = total_mins % 60;
    let total_hours = total_mins / 60;
    let hours = total_hours % 24;
    let days_since_epoch = total_hours / 24;

    // Simplified date calc (good enough for timestamps)
    let mut y = 1970i64;
    let mut remaining_days = days_since_epoch as i64;
    loop {
        let days_in_year = if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 {
            366
        } else {
            365
        };
        if remaining_days < days_in_year {
            break;
        }
        remaining_days -= days_in_year;
        y += 1;
    }
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let month_days = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    let mut m = 0usize;
    for &md in &month_days {
        if remaining_days < md {
            break;
        }
        remaining_days -= md;
        m += 1;
    }
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        y,
        m + 1,
        remaining_days + 1,
        hours,
        mins,
        secs
    )
}

#[cfg(test)]
mod tests {
    use super::{
        claude_transcript_path_from_cwd, handle_client_message, work_status_for_approval_decision,
        OutboundMessage,
    };
    use crate::session::SessionHandle;
    use crate::session_naming::name_from_first_prompt;
    use crate::state::SessionRegistry;
    use orbitdock_protocol::{
        ClientMessage, CodexIntegrationMode, Provider, ServerMessage, SessionStatus, WorkStatus,
    };
    use std::sync::Arc;
    use tokio::sync::mpsc;

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

    fn new_test_state() -> Arc<SessionRegistry> {
        let (persist_tx, _persist_rx) = mpsc::channel(128);
        Arc::new(SessionRegistry::new(persist_tx))
    }

    async fn recv_server_message(rx: &mut mpsc::Receiver<OutboundMessage>) -> ServerMessage {
        match rx.recv().await.expect("expected outbound server message") {
            OutboundMessage::Json(message) => message,
            OutboundMessage::Raw(_) => panic!("expected JSON server message, got raw replay"),
            OutboundMessage::Pong(_) => panic!("expected JSON server message, got pong"),
        }
    }

    #[tokio::test]
    async fn ending_passive_session_keeps_it_available_for_reactivation() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "passive-end-keep".to_string();

        {
            let mut handle = SessionHandle::new(
                session_id.clone(),
                Provider::Codex,
                "/Users/tester/repo".to_string(),
            );
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            state.add_session(handle);
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
        // Yield so the actor processes queued commands
        tokio::task::yield_now().await;
        tokio::task::yield_now().await;

        let actor = state
            .get_session(&session_id)
            .expect("passive session should remain in app state");

        let snap = actor.snapshot();
        assert_eq!(snap.status, SessionStatus::Ended);
        assert_eq!(snap.work_status, WorkStatus::Ended);
    }

    #[tokio::test]
    async fn list_and_detail_match_after_manual_passive_close() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(32);
        let session_id = "passive-list-detail-consistency".to_string();

        {
            let mut handle = SessionHandle::new(
                session_id.clone(),
                Provider::Codex,
                "/Users/tester/repo".to_string(),
            );
            handle.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
            state.add_session(handle);
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
        // Yield so the actor processes queued commands
        tokio::task::yield_now().await;
        tokio::task::yield_now().await;

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
                since_revision: None,
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

        let actor = {
            state
                .get_session(&session_id)
                .expect("session should exist")
        };
        let snapshot = actor.snapshot();

        assert_eq!(snapshot.provider, Provider::Claude);
        assert_eq!(snapshot.work_status, WorkStatus::Working);
        let transcript_path = snapshot
            .transcript_path
            .clone()
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
    async fn claude_user_prompt_sets_first_prompt() {
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

        let actor = {
            state
                .get_session(&session_id)
                .expect("session should exist")
        };
        let snapshot = actor.snapshot();
        assert_eq!(snapshot.work_status, WorkStatus::Working);
    }

    #[tokio::test]
    async fn codex_send_message_ignores_bootstrap_prompt_for_naming() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "codex-name-on-prompt".to_string();
        let (action_tx, _action_rx) = mpsc::channel(8);

        {
            state.add_session(SessionHandle::new(
                session_id.clone(),
                Provider::Codex,
                "/Users/tester/repo".to_string(),
            ));
            state.set_codex_action_tx(&session_id, action_tx);
        }

        // Bootstrap prompt should be skipped
        handle_client_message(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "<environment_context>...</environment_context>".to_string(),
                model: None,
                effort: None,
                skills: vec![],
                images: vec![],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        // Real prompt should set first_prompt
        handle_client_message(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "Investigate flaky auth and propose a safe migration plan".to_string(),
                model: None,
                effort: None,
                skills: vec![],
                images: vec![],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        // Yield to let the actor process the ApplyDelta command
        tokio::task::yield_now().await;

        let actor = {
            state
                .get_session(&session_id)
                .expect("session should exist")
        };
        let snapshot = actor.snapshot();

        // first_prompt is set (not custom_name — AI naming sets summary asynchronously)
        assert_eq!(
            snapshot.first_prompt.as_deref(),
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

        let actor = {
            state
                .get_session(&session_id)
                .expect("session should exist")
        };
        let snapshot = actor.snapshot();
        assert_eq!(snapshot.work_status, WorkStatus::Question);
    }
}
