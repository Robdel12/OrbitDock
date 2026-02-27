//! WebSocket handling

use std::collections::{HashMap, HashSet};
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
use tokio::sync::{mpsc, oneshot};
use tracing::{debug, error, info, warn};

use orbitdock_protocol::{
    ClaudeIntegrationMode, ClientMessage, CodexIntegrationMode, MessageChanges, Provider,
    ServerMessage, SessionState, SessionStatus, StateChanges, TokenUsageSnapshotKind, WorkStatus,
};

use crate::persistence::{
    load_messages_from_transcript_path, load_token_usage_from_transcript_path, PersistCommand,
};
use crate::session_actor::SessionActorHandle;
use crate::session_command::{PersistOp, SessionCommand};
use crate::state::SessionRegistry;

static NEXT_CONNECTION_ID: AtomicU64 = AtomicU64::new(1);

pub(crate) fn normalize_non_empty(value: Option<String>) -> Option<String> {
    value
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(str::to_string)
}

pub(crate) fn is_provider_placeholder_model(model: &str) -> bool {
    matches!(
        model.trim().to_ascii_lowercase().as_str(),
        "openai" | "anthropic"
    )
}

pub(crate) fn normalize_model_override(value: Option<String>) -> Option<String> {
    normalize_non_empty(value).filter(|model| !is_provider_placeholder_model(model))
}

pub(crate) fn normalize_question_answers(
    raw_answers: Option<HashMap<String, Vec<String>>>,
) -> HashMap<String, Vec<String>> {
    let Some(raw_answers) = raw_answers else {
        return HashMap::new();
    };

    let mut normalized = HashMap::new();
    for (raw_question_id, raw_values) in raw_answers {
        let question_id = raw_question_id.trim();
        if question_id.is_empty() {
            continue;
        }

        let values: Vec<String> = raw_values
            .into_iter()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
            .collect();
        if values.is_empty() {
            continue;
        }

        normalized.insert(question_id.to_string(), values);
    }

    normalized
}

pub(crate) fn select_primary_answer(
    answers: &HashMap<String, Vec<String>>,
    preferred_question_id: Option<&str>,
) -> Option<String> {
    if let Some(question_id) = preferred_question_id {
        if let Some(values) = answers.get(question_id) {
            if let Some(first) = values.first() {
                return Some(first.clone());
            }
        }
    }

    answers.values().find_map(|values| values.first().cloned())
}

pub(crate) fn work_status_for_approval_decision(decision: &str) -> orbitdock_protocol::WorkStatus {
    let normalized = decision.trim().to_lowercase();
    if matches!(
        normalized.as_str(),
        "approved" | "approved_for_session" | "approved_always" | "denied" | "deny"
    ) {
        orbitdock_protocol::WorkStatus::Working
    } else {
        orbitdock_protocol::WorkStatus::Waiting
    }
}

pub(crate) const CLAUDE_EMPTY_SHELL_TTL_SECS: u64 = 5 * 60;
pub(crate) const SNAPSHOT_MAX_MESSAGES: usize = 200;
pub(crate) const SNAPSHOT_MAX_CONTENT_CHARS: usize = 16_000;
const SNAPSHOT_MIN_CONTENT_CHARS: usize = 250;
const SNAPSHOT_MAX_TURN_DIFFS: usize = 80;
// Keep outbound frames within common client defaults (Apple URLSession WS default is 1 MiB).
pub(crate) const WS_MAX_TEXT_MESSAGE_BYTES: usize = 1024 * 1024;
// Snapshots should stay much smaller than the hard transport ceiling to avoid reconnect churn.
pub(crate) const SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES: usize = 256 * 1024;

/// Messages that can be sent through the WebSocket
#[allow(clippy::large_enum_variant)]
pub(crate) enum OutboundMessage {
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
    state.ws_connect();
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
                OutboundMessage::Json(server_msg) => {
                    let compacted = sanitize_server_message_for_transport(server_msg);
                    match serde_json::to_string(&compacted) {
                        Ok(json) => {
                            if json.len() > WS_MAX_TEXT_MESSAGE_BYTES {
                                warn!(
                                    component = "websocket",
                                    event = "ws.send.message_dropped_oversize",
                                    connection_id = conn_id,
                                    bytes = json.len(),
                                    max_bytes = WS_MAX_TEXT_MESSAGE_BYTES,
                                    "Dropped oversized server message after compaction"
                                );
                                continue;
                            }
                            ws_tx.send(Message::Text(json.into())).await
                        }
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
                    }
                }
                OutboundMessage::Raw(json) => {
                    if json.len() > WS_MAX_TEXT_MESSAGE_BYTES {
                        warn!(
                            component = "websocket",
                            event = "ws.send.raw_dropped_oversize",
                            connection_id = conn_id,
                            bytes = json.len(),
                            max_bytes = WS_MAX_TEXT_MESSAGE_BYTES,
                            "Dropped oversized replay payload"
                        );
                        continue;
                    }
                    ws_tx.send(Message::Text(json.into())).await
                }
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

    // Announce server role immediately so clients can derive control-plane routing.
    send_json(&outbound_tx, server_info_message(&state)).await;

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

        handle_client_message(client_msg, &client_tx, &state, conn_id).await;
    }

    state.ws_disconnect();
    info!(
        component = "websocket",
        event = "ws.connection.closed",
        connection_id = conn_id,
        "WebSocket connection closed"
    );
    if state.clear_client_primary_claim(conn_id) {
        state.broadcast_to_list(server_info_message(&state));
    }
    send_task.abort();
}

fn truncate_for_log(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

/// Send a ServerMessage through the outbound channel
pub(crate) async fn send_json(tx: &mpsc::Sender<OutboundMessage>, msg: ServerMessage) {
    let _ = tx.send(OutboundMessage::Json(msg)).await;
}

pub(crate) async fn send_rest_only_error(
    tx: &mpsc::Sender<OutboundMessage>,
    endpoint: &str,
    session_id: Option<String>,
) {
    send_json(
        tx,
        ServerMessage::Error {
            code: "http_only_endpoint".into(),
            message: format!("Use REST endpoint {endpoint} for this request"),
            session_id,
        },
    )
    .await;
}

pub(crate) fn server_info_message(state: &SessionRegistry) -> ServerMessage {
    ServerMessage::ServerInfo {
        is_primary: state.is_primary(),
        client_primary_claims: state.active_client_primary_claims(),
    }
}

fn replay_has_oversize_event(events: &[String]) -> Option<usize> {
    events
        .iter()
        .map(String::len)
        .max()
        .filter(|size| *size > WS_MAX_TEXT_MESSAGE_BYTES)
}

pub(crate) async fn send_snapshot_from_actor(
    actor: &SessionActorHandle,
    tx: &mpsc::Sender<OutboundMessage>,
    session_id: &str,
) {
    let (state_tx, state_rx) = oneshot::channel();
    actor
        .send(SessionCommand::GetState { reply: state_tx })
        .await;
    match state_rx.await {
        Ok(snapshot) => {
            send_json(tx, ServerMessage::SessionSnapshot { session: snapshot }).await;
        }
        Err(err) => {
            warn!(
                component = "websocket",
                event = "ws.subscribe.snapshot_fallback_failed",
                session_id = %session_id,
                error = %err,
                "Failed to fetch fallback snapshot after replay overflow"
            );
            send_json(
                tx,
                ServerMessage::Error {
                    code: "snapshot_unavailable".to_string(),
                    message: "Session snapshot unavailable".to_string(),
                    session_id: Some(session_id.to_string()),
                },
            )
            .await;
        }
    }
}

pub(crate) async fn send_replay_or_snapshot_fallback(
    actor: &SessionActorHandle,
    tx: &mpsc::Sender<OutboundMessage>,
    session_id: &str,
    events: Vec<String>,
    conn_id: u64,
) {
    let sanitized_events: Vec<String> = events
        .into_iter()
        .map(|event| {
            sanitize_replay_event_for_transport(&event).unwrap_or_else(|| {
                warn!(
                    component = "websocket",
                    event = "ws.subscribe.replay_sanitize_failed",
                    connection_id = conn_id,
                    session_id = %session_id,
                    "Failed to sanitize replay event, using original payload"
                );
                event
            })
        })
        .collect();

    if let Some(max_bytes) = replay_has_oversize_event(&sanitized_events) {
        warn!(
            component = "websocket",
            event = "ws.subscribe.replay_fallback_snapshot",
            connection_id = conn_id,
            session_id = %session_id,
            replay_count = sanitized_events.len(),
            largest_event_bytes = max_bytes,
            max_bytes = WS_MAX_TEXT_MESSAGE_BYTES,
            "Replay payload exceeded transport limit, falling back to compact snapshot"
        );
        send_snapshot_from_actor(actor, tx, session_id).await;
        return;
    }

    for json in sanitized_events {
        send_raw(tx, json).await;
    }
}

pub(crate) async fn send_snapshot_if_requested(
    tx: &mpsc::Sender<OutboundMessage>,
    session_id: &str,
    snapshot: SessionState,
    include_snapshot: bool,
    conn_id: u64,
) {
    if include_snapshot {
        send_json(
            tx,
            ServerMessage::SessionSnapshot {
                session: compact_snapshot_for_transport(snapshot),
            },
        )
        .await;
        return;
    }

    info!(
        component = "websocket",
        event = "ws.subscribe.snapshot_suppressed",
        connection_id = conn_id,
        session_id = %session_id,
        "Session snapshot suppressed (client requested replay-only subscribe)"
    );
}

/// Send a pre-serialized JSON string through the outbound channel (for replay)
pub(crate) async fn send_raw(tx: &mpsc::Sender<OutboundMessage>, json: String) {
    let _ = tx.send(OutboundMessage::Raw(json)).await;
}

/// Spawn a task that drains a broadcast receiver and forwards messages to an outbound channel.
/// When the outbound channel closes (client disconnects), the task exits and the
/// broadcast::Receiver is dropped — automatic cleanup, no manual unsubscribe needed.
///
/// If `session_id` is provided and the subscriber lags behind the broadcast buffer,
/// a `lagged` error is sent to the client so it can re-subscribe for a fresh snapshot.
pub(crate) fn spawn_broadcast_forwarder(
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

pub(crate) fn chrono_now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    format!("{}Z", secs)
}

pub(crate) async fn mark_session_working_after_send(
    state: &Arc<SessionRegistry>,
    session_id: &str,
) {
    let Some(actor) = state.get_session(session_id) else {
        return;
    };

    let now = chrono_now();
    actor
        .send(SessionCommand::ApplyDelta {
            changes: StateChanges {
                work_status: Some(WorkStatus::Working),
                last_activity_at: Some(now.clone()),
                ..Default::default()
            },
            persist_op: Some(PersistOp::SessionUpdate {
                id: session_id.to_string(),
                status: None,
                work_status: Some(WorkStatus::Working),
                last_activity_at: Some(now),
            }),
        })
        .await;
}

pub(crate) async fn claim_codex_thread_for_direct_session(
    state: &Arc<SessionRegistry>,
    persist_tx: &mpsc::Sender<PersistCommand>,
    session_id: &str,
    thread_id: &str,
    cleanup_reason: &str,
) {
    let _ = persist_tx
        .send(PersistCommand::SetThreadId {
            session_id: session_id.to_string(),
            thread_id: thread_id.to_string(),
        })
        .await;
    state.register_codex_thread(session_id, thread_id);

    if thread_id != session_id && state.remove_session(thread_id).is_some() {
        state.broadcast_to_list(ServerMessage::SessionEnded {
            session_id: thread_id.to_string(),
            reason: "direct_session_thread_claimed".into(),
        });
    }

    let _ = persist_tx
        .send(PersistCommand::CleanupThreadShadowSession {
            thread_id: thread_id.to_string(),
            reason: cleanup_reason.to_string(),
        })
        .await;
}

pub(crate) fn direct_mode_activation_changes(provider: Provider) -> StateChanges {
    let mut changes = StateChanges {
        status: Some(SessionStatus::Active),
        work_status: Some(WorkStatus::Waiting),
        ..Default::default()
    };

    match provider {
        Provider::Codex => {
            changes.codex_integration_mode = Some(Some(CodexIntegrationMode::Direct));
        }
        Provider::Claude => {
            changes.claude_integration_mode = Some(Some(ClaudeIntegrationMode::Direct));
        }
    }

    changes
}

pub(crate) fn parse_unix_z(value: Option<&str>) -> Option<u64> {
    let raw = value?;
    let stripped = raw.strip_suffix('Z').unwrap_or(raw);
    stripped.parse::<u64>().ok()
}

pub(crate) fn is_stale_empty_claude_shell(
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

pub(crate) fn project_name_from_cwd(cwd: &str) -> Option<String> {
    std::path::Path::new(cwd)
        .file_name()
        .and_then(|s| s.to_str())
        .map(|s| s.to_string())
}

pub(crate) fn claude_transcript_path_from_cwd(cwd: &str, session_id: &str) -> Option<String> {
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

fn truncate_string_in_place(value: &mut String, max_chars: usize) {
    if value.chars().count() <= max_chars {
        return;
    }
    let truncated = truncate_text(value, max_chars);
    *value = truncated;
}

fn truncate_option_string_in_place(value: &mut Option<String>, max_chars: usize) {
    if let Some(content) = value.as_mut() {
        truncate_string_in_place(content, max_chars);
    }
}

fn compact_approval_preview_for_transport(
    preview: &mut orbitdock_protocol::ApprovalPreview,
    max_chars: usize,
) {
    truncate_string_in_place(&mut preview.value, max_chars);
    truncate_option_string_in_place(&mut preview.compact, max_chars);
    truncate_option_string_in_place(&mut preview.decision_scope, max_chars);
    truncate_option_string_in_place(&mut preview.manifest, max_chars.saturating_mul(2));
    for finding in &mut preview.risk_findings {
        truncate_string_in_place(finding, max_chars);
    }
    for segment in &mut preview.shell_segments {
        truncate_string_in_place(&mut segment.command, max_chars);
        truncate_option_string_in_place(&mut segment.leading_operator, 8);
    }
}

fn compact_approval_for_transport(
    approval: &mut orbitdock_protocol::ApprovalRequest,
    max_chars: usize,
) {
    truncate_option_string_in_place(&mut approval.tool_input, max_chars);
    truncate_option_string_in_place(&mut approval.command, max_chars);
    truncate_option_string_in_place(&mut approval.file_path, max_chars);
    truncate_option_string_in_place(&mut approval.question, max_chars);
    truncate_option_string_in_place(&mut approval.diff, max_chars.saturating_mul(2));
    for prompt in &mut approval.question_prompts {
        truncate_string_in_place(&mut prompt.id, max_chars);
        truncate_option_string_in_place(&mut prompt.header, max_chars);
        truncate_string_in_place(&mut prompt.question, max_chars);
        for option in &mut prompt.options {
            truncate_string_in_place(&mut option.label, max_chars);
            truncate_option_string_in_place(&mut option.description, max_chars);
        }
    }
    if let Some(preview) = approval.preview.as_mut() {
        compact_approval_preview_for_transport(preview, max_chars);
    }

    if let Some(amendment) = approval.proposed_amendment.as_mut() {
        for line in amendment {
            truncate_string_in_place(line, max_chars);
        }
    }
}

fn compact_message_for_transport(message: &mut orbitdock_protocol::Message, max_chars: usize) {
    message.images = crate::images::normalize_images_for_transport(&message.images);
    truncate_string_in_place(&mut message.content, max_chars);
    truncate_option_string_in_place(&mut message.tool_input, max_chars);
    truncate_option_string_in_place(&mut message.tool_output, max_chars);
}

fn compact_message_changes_for_transport(changes: &mut MessageChanges, max_chars: usize) {
    truncate_option_string_in_place(&mut changes.content, max_chars);
    truncate_option_string_in_place(&mut changes.tool_output, max_chars);
}

fn compact_state_changes_for_transport(changes: &mut StateChanges, max_chars: usize) {
    if let Some(diff) = changes.current_diff.as_mut().and_then(Option::as_mut) {
        truncate_string_in_place(diff, max_chars.saturating_mul(2));
    }
    if let Some(plan) = changes.current_plan.as_mut().and_then(Option::as_mut) {
        truncate_string_in_place(plan, max_chars.saturating_mul(2));
    }
    if let Some(approval) = changes.pending_approval.as_mut().and_then(Option::as_mut) {
        compact_approval_for_transport(approval, max_chars);
    }
}

fn dedupe_turn_diffs_keep_latest(turn_diffs: &mut Vec<orbitdock_protocol::TurnDiff>) {
    if turn_diffs.len() < 2 {
        return;
    }

    let mut seen = HashSet::new();
    let mut deduped_reversed = Vec::with_capacity(turn_diffs.len());
    for turn in turn_diffs.iter().rev() {
        if seen.insert(turn.turn_id.clone()) {
            deduped_reversed.push(turn.clone());
        }
    }

    deduped_reversed.reverse();
    *turn_diffs = deduped_reversed;
}

fn compact_snapshot_for_transport_with_limits(
    mut snapshot: SessionState,
    max_messages: usize,
    max_content_chars: usize,
) -> SessionState {
    let max_messages = max_messages.min(SNAPSHOT_MAX_MESSAGES);
    let max_content_chars =
        max_content_chars.clamp(SNAPSHOT_MIN_CONTENT_CHARS, SNAPSHOT_MAX_CONTENT_CHARS);

    if max_messages == 0 {
        snapshot.messages.clear();
    } else if snapshot.messages.len() > max_messages {
        let keep_from = snapshot.messages.len() - max_messages;
        snapshot.messages = snapshot.messages.split_off(keep_from);
    }

    for message in &mut snapshot.messages {
        compact_message_for_transport(message, max_content_chars);
    }

    // Avoid huge payload spikes from active turn context fields.
    truncate_option_string_in_place(
        &mut snapshot.current_diff,
        max_content_chars.saturating_mul(2),
    );
    truncate_option_string_in_place(
        &mut snapshot.current_plan,
        max_content_chars.saturating_mul(2),
    );
    truncate_option_string_in_place(&mut snapshot.pending_tool_input, max_content_chars);
    truncate_option_string_in_place(&mut snapshot.pending_question, max_content_chars);
    if let Some(approval) = snapshot.pending_approval.as_mut() {
        compact_approval_for_transport(approval, max_content_chars);
    }

    dedupe_turn_diffs_keep_latest(&mut snapshot.turn_diffs);

    let max_turn_diffs = if max_messages == 0 {
        0
    } else {
        SNAPSHOT_MAX_TURN_DIFFS.min(max_messages.saturating_mul(2))
    };
    if max_turn_diffs == 0 {
        snapshot.turn_diffs.clear();
    } else if snapshot.turn_diffs.len() > max_turn_diffs {
        let keep_from = snapshot.turn_diffs.len() - max_turn_diffs;
        snapshot.turn_diffs = snapshot.turn_diffs.split_off(keep_from);
    }
    for turn in &mut snapshot.turn_diffs {
        truncate_string_in_place(&mut turn.diff, max_content_chars.saturating_mul(2));
    }

    snapshot
}

fn snapshot_transport_size_bytes(snapshot: &SessionState) -> Option<usize> {
    serde_json::to_vec(&ServerMessage::SessionSnapshot {
        session: snapshot.clone(),
    })
    .ok()
    .map(|bytes| bytes.len())
}

fn trim_snapshot_images_to_transport_limit(snapshot: &mut SessionState, limit_bytes: usize) {
    let mut size = snapshot_transport_size_bytes(snapshot).unwrap_or(usize::MAX);
    if size <= limit_bytes {
        return;
    }

    loop {
        let mut removed = false;
        for message in &mut snapshot.messages {
            if message.images.is_empty() {
                continue;
            }
            message.images.pop();
            removed = true;
            break;
        }

        if !removed {
            break;
        }

        size = snapshot_transport_size_bytes(snapshot).unwrap_or(usize::MAX);
        if size <= limit_bytes {
            break;
        }
    }
}

fn compact_snapshot_to_transport_limit(snapshot: SessionState) -> SessionState {
    let mut portable_snapshot = snapshot;
    for message in &mut portable_snapshot.messages {
        message.images = crate::images::normalize_images_for_transport(&message.images);
    }

    let default_compacted = compact_snapshot_for_transport_with_limits(
        portable_snapshot.clone(),
        SNAPSHOT_MAX_MESSAGES,
        SNAPSHOT_MAX_CONTENT_CHARS,
    );
    let mut default_compacted = default_compacted;
    trim_snapshot_images_to_transport_limit(
        &mut default_compacted,
        SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES,
    );

    if snapshot_transport_size_bytes(&default_compacted)
        .is_some_and(|size| size <= SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES)
    {
        return default_compacted;
    }

    let message_caps = [160, 120, 96, 72, 48, 32, 24, 16, 8, 4, 2, 1, 0];
    let content_caps = [
        12_000,
        8_000,
        4_000,
        2_000,
        1_000,
        500,
        SNAPSHOT_MIN_CONTENT_CHARS,
    ];
    let mut smallest = default_compacted;
    let mut smallest_size = snapshot_transport_size_bytes(&smallest).unwrap_or(usize::MAX);

    for max_messages in message_caps {
        for max_content_chars in content_caps {
            let mut candidate = compact_snapshot_for_transport_with_limits(
                portable_snapshot.clone(),
                max_messages,
                max_content_chars,
            );
            trim_snapshot_images_to_transport_limit(
                &mut candidate,
                SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES,
            );
            let Some(size) = snapshot_transport_size_bytes(&candidate) else {
                continue;
            };
            if size < smallest_size {
                smallest_size = size;
                smallest = candidate.clone();
            }
            if size <= SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES {
                return candidate;
            }
        }
    }

    if smallest_size > WS_MAX_TEXT_MESSAGE_BYTES {
        trim_snapshot_images_to_transport_limit(&mut smallest, WS_MAX_TEXT_MESSAGE_BYTES);
    }

    smallest
}

pub(crate) fn compact_snapshot_for_transport(snapshot: SessionState) -> SessionState {
    compact_snapshot_for_transport_with_limits(
        snapshot,
        SNAPSHOT_MAX_MESSAGES,
        SNAPSHOT_MAX_CONTENT_CHARS,
    )
}

fn message_appended_transport_size_bytes(
    session_id: &str,
    message: &orbitdock_protocol::Message,
) -> Option<usize> {
    serde_json::to_vec(&ServerMessage::MessageAppended {
        session_id: session_id.to_string(),
        message: message.clone(),
    })
    .ok()
    .map(|bytes| bytes.len())
}

fn trim_message_images_to_transport_limit(
    session_id: &str,
    message: &mut orbitdock_protocol::Message,
) {
    let mut size = message_appended_transport_size_bytes(session_id, message).unwrap_or(usize::MAX);
    if size <= WS_MAX_TEXT_MESSAGE_BYTES {
        return;
    }

    while !message.images.is_empty() && size > WS_MAX_TEXT_MESSAGE_BYTES {
        message.images.pop();
        size = message_appended_transport_size_bytes(session_id, message).unwrap_or(usize::MAX);
    }
}

fn sanitize_server_message_for_transport(msg: ServerMessage) -> ServerMessage {
    match msg {
        ServerMessage::SessionSnapshot { session } => {
            let before = snapshot_transport_size_bytes(&session);
            let compacted = compact_snapshot_to_transport_limit(session);
            let after = snapshot_transport_size_bytes(&compacted);

            if let (Some(before), Some(after)) = (before, after) {
                if before > SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES && after < before {
                    warn!(
                        component = "websocket",
                        event = "ws.transport.snapshot_compacted",
                        session_id = %compacted.id,
                        before_bytes = before,
                        after_bytes = after,
                        target_bytes = SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES,
                        max_bytes = WS_MAX_TEXT_MESSAGE_BYTES,
                        "Compacted session snapshot to fit outbound payload target"
                    );
                }
            }

            ServerMessage::SessionSnapshot { session: compacted }
        }
        ServerMessage::MessageAppended {
            session_id,
            mut message,
        } => {
            compact_message_for_transport(&mut message, SNAPSHOT_MAX_CONTENT_CHARS);
            trim_message_images_to_transport_limit(&session_id, &mut message);
            ServerMessage::MessageAppended {
                session_id,
                message,
            }
        }
        ServerMessage::MessageUpdated {
            session_id,
            message_id,
            mut changes,
        } => {
            compact_message_changes_for_transport(&mut changes, SNAPSHOT_MAX_CONTENT_CHARS);
            ServerMessage::MessageUpdated {
                session_id,
                message_id,
                changes,
            }
        }
        ServerMessage::SessionDelta {
            session_id,
            mut changes,
        } => {
            compact_state_changes_for_transport(&mut changes, SNAPSHOT_MAX_CONTENT_CHARS);
            ServerMessage::SessionDelta {
                session_id,
                changes,
            }
        }
        other => other,
    }
}

fn sanitize_replay_event_for_transport(event_json: &str) -> Option<String> {
    let mut value: serde_json::Value = serde_json::from_str(event_json).ok()?;
    let revision = value
        .as_object()
        .and_then(|object| object.get("revision").cloned());

    if let Some(object) = value.as_object_mut() {
        object.remove("revision");
    }

    let message: ServerMessage = serde_json::from_value(value).ok()?;
    let sanitized = sanitize_server_message_for_transport(message);
    let mut sanitized_value = serde_json::to_value(sanitized).ok()?;
    if let Some(revision) = revision {
        if let Some(object) = sanitized_value.as_object_mut() {
            object.insert("revision".to_string(), revision);
        }
    }

    serde_json::to_string(&sanitized_value).ok()
}

/// Dispatch a single client WebSocket message.
///
/// Each handler group lives in its own module under , so each
/// `.await` site produces an independently-sized future. This keeps the
/// parent future small enough for the default 2 MiB thread stack in debug
/// builds.
fn handle_client_message<'a>(
    msg: ClientMessage,
    client_tx: &'a mpsc::Sender<OutboundMessage>,
    state: &'a Arc<SessionRegistry>,
    conn_id: u64,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + 'a>> {
    Box::pin(async move {
        debug!(
            component = "websocket",
            event = "ws.message.received",
            connection_id = conn_id,
            message = ?msg,
            "Received client message"
        );

        match msg {
            // ── Subscribe ────────────────────────────────────────────
            ClientMessage::SubscribeList
            | ClientMessage::SubscribeSession { .. }
            | ClientMessage::UnsubscribeSession { .. } => {
                crate::ws_handlers::subscribe::handle(msg, client_tx, state, conn_id).await;
            }

            // ── Session CRUD ─────────────────────────────────────────
            ClientMessage::CreateSession { .. }
            | ClientMessage::EndSession { .. }
            | ClientMessage::RenameSession { .. }
            | ClientMessage::UpdateSessionConfig { .. }
            | ClientMessage::ForkSession { .. } => {
                crate::ws_handlers::session_crud::handle(msg, client_tx, state, conn_id).await;
            }

            // ── Session lifecycle (resume / takeover) ────────────────
            ClientMessage::ResumeSession { .. } | ClientMessage::TakeoverSession { .. } => {
                crate::ws_handlers::session_lifecycle::handle(msg, client_tx, state, conn_id).await;
            }

            // ── Messaging ────────────────────────────────────────────
            ClientMessage::SendMessage { .. }
            | ClientMessage::SteerTurn { .. }
            | ClientMessage::AnswerQuestion { .. }
            | ClientMessage::InterruptSession { .. }
            | ClientMessage::CompactContext { .. }
            | ClientMessage::UndoLastTurn { .. }
            | ClientMessage::RollbackTurns { .. } => {
                crate::ws_handlers::messaging::handle(msg, client_tx, state, conn_id).await;
            }

            // ── Approvals ────────────────────────────────────────────
            ClientMessage::ApproveTool { .. }
            | ClientMessage::ListApprovals { .. }
            | ClientMessage::DeleteApproval { .. } => {
                crate::ws_handlers::approvals::handle(msg, client_tx, state, conn_id).await;
            }

            // ── Config ───────────────────────────────────────────────
            ClientMessage::SetServerRole { .. }
            | ClientMessage::SetClientPrimaryClaim { .. }
            | ClientMessage::SetOpenAiKey { .. }
            | ClientMessage::ListModels
            | ClientMessage::ListClaudeModels => {
                crate::ws_handlers::config::handle(msg, client_tx, state, conn_id).await;
            }

            // ── Codex account ────────────────────────────────────────
            ClientMessage::CodexAccountRead { .. }
            | ClientMessage::CodexLoginChatgptStart
            | ClientMessage::CodexLoginChatgptCancel { .. }
            | ClientMessage::CodexAccountLogout => {
                crate::ws_handlers::codex_account::handle(msg, client_tx, state).await;
            }

            // ── Skills / MCP ─────────────────────────────────────────
            ClientMessage::ListSkills { .. }
            | ClientMessage::ListRemoteSkills { .. }
            | ClientMessage::DownloadRemoteSkill { .. }
            | ClientMessage::ListMcpTools { .. }
            | ClientMessage::RefreshMcpServers { .. } => {
                crate::ws_handlers::skills::handle(msg, client_tx, state).await;
            }

            // ── Claude hooks ─────────────────────────────────────────
            ClientMessage::ClaudeSessionStart { .. }
            | ClientMessage::ClaudeSessionEnd { .. }
            | ClientMessage::ClaudeStatusEvent { .. }
            | ClientMessage::ClaudeToolEvent { .. }
            | ClientMessage::ClaudeSubagentEvent { .. }
            | ClientMessage::GetSubagentTools { .. } => {
                crate::ws_handlers::claude_hooks::handle(msg, client_tx, state).await;
            }

            // ── Review comments ──────────────────────────────────────
            ClientMessage::CreateReviewComment { .. }
            | ClientMessage::UpdateReviewComment { .. }
            | ClientMessage::DeleteReviewComment { .. }
            | ClientMessage::ListReviewComments { .. } => {
                crate::ws_handlers::review_comments::handle(msg, client_tx, state, conn_id).await;
            }

            // ── Shell execution ──────────────────────────────────────
            ClientMessage::ExecuteShell { .. } | ClientMessage::CancelShell { .. } => {
                crate::ws_handlers::shell::handle(msg, client_tx, state, conn_id).await;
            }

            // ── Worktree management ──────────────────────────────────
            ClientMessage::ListWorktrees { .. }
            | ClientMessage::CreateWorktree { .. }
            | ClientMessage::RemoveWorktree { .. }
            | ClientMessage::DiscoverWorktrees { .. } => {
                crate::ws_handlers::worktree::handle(msg, client_tx).await;
            }

            // ── REST-only stubs ──────────────────────────────────────
            ClientMessage::BrowseDirectory { .. }
            | ClientMessage::ListRecentProjects { .. }
            | ClientMessage::CheckOpenAiKey { .. }
            | ClientMessage::FetchCodexUsage { .. }
            | ClientMessage::FetchClaudeUsage { .. } => {
                crate::ws_handlers::rest_only::handle(msg, client_tx).await;
            }
        }
    })
}

/// Re-read a session's transcript and broadcast any new messages to subscribers.
/// Works for any hook-triggered session (Claude CLI, future Codex CLI hooks).
pub(crate) async fn sync_transcript_messages(
    actor: &SessionActorHandle,
    persist_tx: &tokio::sync::mpsc::Sender<crate::persistence::PersistCommand>,
) {
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
                    event: crate::transition::Input::TokensUpdated {
                        usage,
                        snapshot_kind: match snap.provider {
                            Provider::Codex => TokenUsageSnapshotKind::ContextTurn,
                            Provider::Claude => TokenUsageSnapshotKind::MixedLegacy,
                        },
                    },
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
        let _ = persist_tx
            .send(crate::persistence::PersistCommand::MessageAppend {
                session_id: session_id.clone(),
                message: msg.clone(),
            })
            .await;
        actor
            .send(SessionCommand::AddMessageAndBroadcast { message: msg })
            .await;
    }
}

/// Format millis-since-epoch as ISO 8601 timestamp
pub(crate) fn iso_timestamp(millis: u128) -> String {
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

/// Resolve the correct cwd for `claude --resume` by matching the transcript
/// path's project hash against the session's project_path (and its parents).
///
/// Claude stores transcripts at `~/.claude/projects/<hash>/<session>.jsonl`
/// where `<hash>` encodes the cwd with `/` and `.` replaced by `-`.
/// The DB's `project_path` may be a subdirectory, so we walk up until
/// we find a path whose hash matches the transcript's project directory.
pub(crate) fn resolve_claude_resume_cwd(project_path: &str, transcript_path: &str) -> String {
    let expected_hash = std::path::Path::new(transcript_path)
        .parent()
        .and_then(|p| p.file_name())
        .and_then(|n| n.to_str());

    let Some(expected) = expected_hash else {
        return project_path.to_string();
    };

    let mut candidate = std::path::PathBuf::from(project_path);
    for _ in 0..5 {
        let hash = candidate.to_string_lossy().replace(['/', '.'], "-");
        if hash == expected {
            return candidate.to_string_lossy().to_string();
        }
        if !candidate.pop() {
            break;
        }
    }

    // Fallback: use project_path as-is
    project_path.to_string()
}

#[cfg(test)]
mod tests {
    use super::{
        claim_codex_thread_for_direct_session, claude_transcript_path_from_cwd,
        compact_message_for_transport, compact_snapshot_to_transport_limit,
        direct_mode_activation_changes, handle_client_message, replay_has_oversize_event,
        sanitize_replay_event_for_transport, sanitize_server_message_for_transport,
        snapshot_transport_size_bytes, work_status_for_approval_decision, OutboundMessage,
        SNAPSHOT_MAX_CONTENT_CHARS, SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES, WS_MAX_TEXT_MESSAGE_BYTES,
    };
    use crate::claude_session::ClaudeAction;
    use crate::codex_session::CodexAction;
    use crate::persistence::PersistCommand;
    use crate::session::SessionHandle;
    use crate::session_command::SessionCommand;
    use crate::session_naming::name_from_first_prompt;
    use crate::state::SessionRegistry;
    use crate::transition::Input;
    use orbitdock_protocol::{
        new_id, ApprovalType, ClaudeIntegrationMode, ClientMessage, CodexIntegrationMode,
        ImageInput, MentionInput, Message, MessageType, Provider, ServerMessage, SessionStatus,
        TurnDiff, WorkStatus,
    };
    use std::sync::{Arc, Once};
    use tokio::sync::mpsc;

    static INIT_TEST_DATA_DIR: Once = Once::new();

    fn ensure_test_data_dir() {
        INIT_TEST_DATA_DIR.call_once(|| {
            let dir = std::env::temp_dir().join("orbitdock-websocket-tests");
            crate::paths::init_data_dir(Some(&dir));
        });
    }

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
        assert_eq!(
            work_status_for_approval_decision("denied"),
            WorkStatus::Working
        );
        assert_eq!(
            work_status_for_approval_decision("deny"),
            WorkStatus::Working
        );
    }

    #[test]
    fn approval_decisions_that_stop_return_to_waiting() {
        assert_eq!(
            work_status_for_approval_decision("abort"),
            WorkStatus::Waiting
        );
        assert_eq!(
            work_status_for_approval_decision("unknown_value"),
            WorkStatus::Waiting
        );
    }

    async fn queue_codex_exec_approval(
        state: &Arc<SessionRegistry>,
        session_id: &str,
        request_id: &str,
    ) {
        let actor = state
            .get_session(session_id)
            .expect("session should exist to queue approval");
        actor
            .send(SessionCommand::ProcessEvent {
                event: Input::ApprovalRequested {
                    request_id: request_id.to_string(),
                    approval_type: ApprovalType::Exec,
                    tool_name: Some("Bash".to_string()),
                    tool_input: Some(r#"{"command":"echo test"}"#.to_string()),
                    command: Some("echo test".to_string()),
                    file_path: None,
                    diff: None,
                    question: None,
                    proposed_amendment: None,
                },
            })
            .await;
        tokio::task::yield_now().await;
    }

    #[tokio::test]
    async fn approve_tool_promotes_next_queued_request_from_server_state() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "approve-tool-queue-promote".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/Users/tester/repo".to_string(),
        ));
        state.set_codex_action_tx(&session_id, action_tx);

        queue_codex_exec_approval(&state, &session_id, "req-1").await;
        queue_codex_exec_approval(&state, &session_id, "req-2").await;

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        assert_eq!(
            actor.snapshot().pending_approval_id.as_deref(),
            Some("req-1")
        );

        handle_client_message(
            ClientMessage::ApproveTool {
                session_id: session_id.clone(),
                request_id: "req-1".to_string(),
                decision: "approved".to_string(),
                message: None,
                interrupt: None,
                updated_input: None,
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match action_rx
            .recv()
            .await
            .expect("expected codex approval action")
        {
            CodexAction::ApproveExec { request_id, .. } => {
                assert_eq!(request_id, "req-1");
            }
            other => panic!("expected ApproveExec action, got {:?}", other),
        }

        tokio::task::yield_now().await;

        let snapshot = actor.snapshot();
        assert_eq!(snapshot.pending_approval_id.as_deref(), Some("req-2"));
        assert_eq!(snapshot.work_status, WorkStatus::Permission);

        // The server now sends an ApprovalDecisionResult on success
        match recv_json(&mut client_rx).await {
            ServerMessage::ApprovalDecisionResult {
                outcome,
                request_id,
                ..
            } => {
                assert_eq!(outcome, "applied");
                assert_eq!(request_id, "req-1");
            }
            other => panic!("expected ApprovalDecisionResult, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn approve_tool_denied_keeps_session_working_until_turn_finishes() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "approve-tool-denied-working".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/Users/tester/repo".to_string(),
        ));
        state.set_codex_action_tx(&session_id, action_tx);

        queue_codex_exec_approval(&state, &session_id, "req-1").await;

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        assert_eq!(
            actor.snapshot().pending_approval_id.as_deref(),
            Some("req-1")
        );

        handle_client_message(
            ClientMessage::ApproveTool {
                session_id: session_id.clone(),
                request_id: "req-1".to_string(),
                decision: "denied".to_string(),
                message: None,
                interrupt: None,
                updated_input: None,
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match action_rx
            .recv()
            .await
            .expect("expected codex approval action")
        {
            CodexAction::ApproveExec {
                request_id,
                decision,
                ..
            } => {
                assert_eq!(request_id, "req-1");
                assert_eq!(decision, "denied");
            }
            other => panic!("expected ApproveExec action, got {:?}", other),
        }

        tokio::task::yield_now().await;

        let snapshot = actor.snapshot();
        assert_eq!(
            snapshot.pending_approval_id, None,
            "pending approval should be cleared after decision"
        );
        assert_eq!(
            snapshot.work_status,
            WorkStatus::Working,
            "denied decisions should stay working until connector emits turn completion/abort"
        );

        match recv_json(&mut client_rx).await {
            ServerMessage::ApprovalDecisionResult {
                outcome,
                request_id,
                ..
            } => {
                assert_eq!(outcome, "applied");
                assert_eq!(request_id, "req-1");
            }
            other => panic!("expected ApprovalDecisionResult, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn approve_tool_rejects_out_of_order_request_ids() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "approve-tool-queue-stale".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/Users/tester/repo".to_string(),
        ));
        state.set_codex_action_tx(&session_id, action_tx);

        queue_codex_exec_approval(&state, &session_id, "req-1").await;
        queue_codex_exec_approval(&state, &session_id, "req-2").await;

        handle_client_message(
            ClientMessage::ApproveTool {
                session_id: session_id.clone(),
                request_id: "req-2".to_string(),
                decision: "approved".to_string(),
                message: None,
                interrupt: None,
                updated_input: None,
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::ApprovalDecisionResult {
                session_id: result_session_id,
                request_id,
                outcome,
                active_request_id,
                ..
            } => {
                assert_eq!(result_session_id, session_id);
                assert_eq!(request_id, "req-2");
                assert_eq!(outcome, "stale");
                assert_eq!(
                    active_request_id.as_deref(),
                    Some("req-1"),
                    "stale result should include the active request id"
                );
            }
            other => panic!(
                "expected ApprovalDecisionResult with stale outcome, got {:?}",
                other
            ),
        }

        assert!(
            action_rx.try_recv().is_err(),
            "stale approvals must not dispatch connector approval actions"
        );

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        assert_eq!(
            actor.snapshot().pending_approval_id.as_deref(),
            Some("req-1")
        );
    }

    #[test]
    fn direct_mode_activation_changes_sets_active_waiting_for_codex() {
        let changes = direct_mode_activation_changes(Provider::Codex);
        assert_eq!(changes.status, Some(SessionStatus::Active));
        assert_eq!(changes.work_status, Some(WorkStatus::Waiting));
        assert_eq!(
            changes.codex_integration_mode,
            Some(Some(CodexIntegrationMode::Direct))
        );
        assert_eq!(changes.claude_integration_mode, None);
    }

    #[test]
    fn direct_mode_activation_changes_sets_active_waiting_for_claude() {
        let changes = direct_mode_activation_changes(Provider::Claude);
        assert_eq!(changes.status, Some(SessionStatus::Active));
        assert_eq!(changes.work_status, Some(WorkStatus::Waiting));
        assert_eq!(
            changes.claude_integration_mode,
            Some(Some(ClaudeIntegrationMode::Direct))
        );
        assert_eq!(changes.codex_integration_mode, None);
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

    #[test]
    fn snapshot_compaction_fits_websocket_transport_limit() {
        let mut snapshot = SessionHandle::new(
            "oversized".to_string(),
            Provider::Codex,
            "/tmp/oversized".into(),
        )
        .state();

        snapshot.messages = (0..80)
            .map(|index| Message {
                id: format!("m-{index}"),
                session_id: snapshot.id.clone(),
                message_type: MessageType::Assistant,
                content: "A".repeat(60_000),
                tool_name: Some("bash".to_string()),
                tool_input: Some("B".repeat(20_000)),
                tool_output: Some("C".repeat(20_000)),
                is_error: false,
                is_in_progress: false,
                timestamp: "2026-01-01T00:00:00Z".to_string(),
                duration_ms: Some(123),
                images: vec![],
            })
            .collect();

        snapshot.current_diff = Some("D".repeat(120_000));
        snapshot.current_plan = Some("E".repeat(120_000));
        snapshot.pending_tool_input = Some("F".repeat(120_000));
        snapshot.pending_question = Some("G".repeat(120_000));
        snapshot.turn_diffs = (0..120)
            .map(|idx| TurnDiff {
                turn_id: format!("turn-{idx}"),
                diff: "H".repeat(120_000),
                token_usage: None,
                snapshot_kind: None,
            })
            .collect();

        let compacted = compact_snapshot_to_transport_limit(snapshot);
        let compacted_size =
            snapshot_transport_size_bytes(&compacted).expect("compacted snapshot serialized");

        assert!(
            compacted_size <= WS_MAX_TEXT_MESSAGE_BYTES,
            "expected compacted snapshot <= {} bytes, got {}",
            WS_MAX_TEXT_MESSAGE_BYTES,
            compacted_size
        );
        assert!(
            compacted_size <= SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES,
            "expected compacted snapshot <= {} bytes target, got {}",
            SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES,
            compacted_size
        );
    }

    #[test]
    fn detects_oversized_replay_payloads() {
        let small = vec!["{}".to_string(), "{\"type\":\"ping\"}".to_string()];
        assert_eq!(replay_has_oversize_event(&small), None);

        let large = vec!["{}".to_string(), "X".repeat(WS_MAX_TEXT_MESSAGE_BYTES + 1)];
        assert_eq!(
            replay_has_oversize_event(&large),
            Some(WS_MAX_TEXT_MESSAGE_BYTES + 1)
        );
    }

    #[test]
    fn snapshot_compaction_dedupes_duplicate_turn_ids() {
        let mut snapshot = SessionHandle::new(
            "dupe-turns".to_string(),
            Provider::Codex,
            "/tmp/dupe-turns".into(),
        )
        .state();
        snapshot.turn_diffs = vec![
            TurnDiff {
                turn_id: "turn-20".to_string(),
                diff: "old".to_string(),
                token_usage: None,
                snapshot_kind: None,
            },
            TurnDiff {
                turn_id: "turn-21".to_string(),
                diff: "next".to_string(),
                token_usage: None,
                snapshot_kind: None,
            },
            TurnDiff {
                turn_id: "turn-20".to_string(),
                diff: "new".to_string(),
                token_usage: None,
                snapshot_kind: None,
            },
        ];

        let compacted = compact_snapshot_to_transport_limit(snapshot);
        assert_eq!(compacted.turn_diffs.len(), 2);
        assert_eq!(compacted.turn_diffs[0].turn_id, "turn-21");
        assert_eq!(compacted.turn_diffs[1].turn_id, "turn-20");
        assert_eq!(compacted.turn_diffs[1].diff, "new");
    }

    #[test]
    fn compact_message_transport_preserves_data_uri_images() {
        let mut message = Message {
            id: "m-image".to_string(),
            session_id: "s".to_string(),
            message_type: MessageType::User,
            content: "send this".to_string(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: false,
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            duration_ms: None,
            images: vec![ImageInput {
                input_type: "url".to_string(),
                value: format!("data:image/png;base64,{}", "A".repeat(5_000)),
            }],
        };

        compact_message_for_transport(&mut message, SNAPSHOT_MAX_CONTENT_CHARS);

        assert_eq!(message.images.len(), 1);
        assert_eq!(message.images[0].input_type, "url");
        assert!(message.images[0]
            .value
            .starts_with("data:image/png;base64,"));
    }

    #[test]
    fn compact_message_transport_converts_path_images_to_data_uri() {
        let image_path = std::env::temp_dir().join(format!("orbitdock-image-{}.png", new_id()));
        std::fs::write(&image_path, b"hello-image").expect("write test image");

        let mut message = Message {
            id: "m-path".to_string(),
            session_id: "s".to_string(),
            message_type: MessageType::User,
            content: "send path".to_string(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: false,
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            duration_ms: None,
            images: vec![ImageInput {
                input_type: "path".to_string(),
                value: image_path.to_string_lossy().to_string(),
            }],
        };

        compact_message_for_transport(&mut message, SNAPSHOT_MAX_CONTENT_CHARS);
        let _ = std::fs::remove_file(image_path);

        assert_eq!(message.images.len(), 1);
        assert_eq!(message.images[0].input_type, "url");
        assert_eq!(
            message.images[0].value,
            "data:image/png;base64,aGVsbG8taW1hZ2U="
        );
    }

    #[test]
    fn sanitize_message_appended_trims_oversized_images_instead_of_dropping_message() {
        let oversized_image = ImageInput {
            input_type: "url".to_string(),
            value: format!(
                "data:image/png;base64,{}",
                "A".repeat(WS_MAX_TEXT_MESSAGE_BYTES + 512)
            ),
        };

        let message = Message {
            id: "m-large".to_string(),
            session_id: "s".to_string(),
            message_type: MessageType::User,
            content: "large image".to_string(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: false,
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            duration_ms: None,
            images: vec![oversized_image],
        };

        let sanitized = sanitize_server_message_for_transport(ServerMessage::MessageAppended {
            session_id: "s".to_string(),
            message,
        });

        let json = serde_json::to_string(&sanitized).expect("serialize sanitized message");
        assert!(
            json.len() <= WS_MAX_TEXT_MESSAGE_BYTES,
            "expected sanitized message <= {} bytes, got {}",
            WS_MAX_TEXT_MESSAGE_BYTES,
            json.len()
        );

        match sanitized {
            ServerMessage::MessageAppended { message, .. } => {
                assert!(
                    message.images.is_empty(),
                    "oversized image should be trimmed from outbound transport"
                );
            }
            other => panic!("expected MessageAppended, got {:?}", other),
        }
    }

    #[test]
    fn replay_sanitize_preserves_revision_and_normalizes_path_images() {
        let image_path =
            std::env::temp_dir().join(format!("orbitdock-replay-image-{}.png", new_id()));
        std::fs::write(&image_path, b"replay-image").expect("write test image");

        let replay_json = serde_json::json!({
            "type": "message_appended",
            "revision": 42,
            "session_id": "s",
            "message": {
                "id": "m",
                "session_id": "s",
                "message_type": "user",
                "content": "hello",
                "is_error": false,
                "timestamp": "2026-01-01T00:00:00Z",
                "images": [{
                    "input_type": "path",
                    "value": image_path.to_string_lossy().to_string(),
                }]
            }
        });

        let sanitized = sanitize_replay_event_for_transport(&replay_json.to_string())
            .expect("sanitize replay payload");
        let _ = std::fs::remove_file(image_path);

        let decoded: serde_json::Value =
            serde_json::from_str(&sanitized).expect("decode sanitized replay");
        assert_eq!(
            decoded.get("revision").and_then(|value| value.as_u64()),
            Some(42)
        );
        assert_eq!(
            decoded
                .get("message")
                .and_then(|value| value.get("images"))
                .and_then(|value| value.as_array())
                .and_then(|images| images.first())
                .and_then(|image| image.get("input_type"))
                .and_then(|value| value.as_str()),
            Some("url")
        );
    }

    fn new_test_state() -> Arc<SessionRegistry> {
        ensure_test_data_dir();
        let (persist_tx, _persist_rx) = mpsc::channel(128);
        Arc::new(SessionRegistry::new(persist_tx))
    }

    #[tokio::test]
    async fn claim_codex_thread_ends_shadow_runtime_session_and_persists_cleanup() {
        ensure_test_data_dir();
        let (persist_tx, mut persist_rx) = mpsc::channel(16);
        let state = Arc::new(SessionRegistry::new(persist_tx.clone()));
        let mut list_rx = state.subscribe_list();
        let direct_session_id = "od-direct-session".to_string();
        let shadow_thread_id = "019-shadow-thread".to_string();

        let mut direct = SessionHandle::new(
            direct_session_id.clone(),
            Provider::Codex,
            "/tmp/project".to_string(),
        );
        direct.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
        state.add_session(direct);

        let mut shadow = SessionHandle::new(
            shadow_thread_id.clone(),
            Provider::Codex,
            "/tmp/project".to_string(),
        );
        shadow.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
        state.add_session(shadow);

        claim_codex_thread_for_direct_session(
            &state,
            &persist_tx,
            &direct_session_id,
            &shadow_thread_id,
            "test_shadow_cleanup",
        )
        .await;

        assert_eq!(
            state.codex_thread_for_session(&direct_session_id),
            Some(shadow_thread_id.clone())
        );
        assert!(
            state.get_session(&shadow_thread_id).is_none(),
            "shadow runtime session should be removed"
        );

        match list_rx.recv().await.expect("expected list broadcast") {
            ServerMessage::SessionEnded { session_id, reason } => {
                assert_eq!(session_id, shadow_thread_id);
                assert_eq!(reason, "direct_session_thread_claimed");
            }
            other => panic!("expected SessionEnded broadcast, got {:?}", other),
        }

        match persist_rx
            .recv()
            .await
            .expect("expected SetThreadId command")
        {
            PersistCommand::SetThreadId {
                session_id,
                thread_id,
            } => {
                assert_eq!(session_id, direct_session_id);
                assert_eq!(thread_id, "019-shadow-thread");
            }
            other => panic!("expected SetThreadId command, got {:?}", other),
        }
        match persist_rx
            .recv()
            .await
            .expect("expected CleanupThreadShadowSession command")
        {
            PersistCommand::CleanupThreadShadowSession { thread_id, reason } => {
                assert_eq!(thread_id, "019-shadow-thread");
                assert_eq!(reason, "test_shadow_cleanup");
            }
            other => panic!("expected CleanupThreadShadowSession, got {:?}", other),
        }
    }

    async fn recv_json(client_rx: &mut mpsc::Receiver<OutboundMessage>) -> ServerMessage {
        match client_rx.recv().await.expect("expected outbound message") {
            OutboundMessage::Json(msg) => msg,
            OutboundMessage::Raw(_) => panic!("expected JSON message, got raw payload"),
            OutboundMessage::Pong(_) => panic!("expected JSON message, got pong"),
        }
    }

    #[tokio::test]
    async fn subscribe_session_can_stream_without_initial_snapshot() {
        let state = new_test_state();
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let handle = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/project".to_string(),
        );
        state.add_session(handle);

        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);
        handle_client_message(
            ClientMessage::SubscribeSession {
                session_id: session_id.clone(),
                since_revision: None,
                include_snapshot: false,
            },
            &client_tx,
            &state,
            1001,
        )
        .await;

        let actor = state
            .get_session(&session_id)
            .expect("session should be available after subscribe");
        let message = Message {
            id: orbitdock_protocol::new_id(),
            session_id: session_id.clone(),
            message_type: MessageType::Assistant,
            content: "streamed update".to_string(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: false,
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            duration_ms: None,
            images: vec![],
        };

        actor
            .send(SessionCommand::AddMessageAndBroadcast { message })
            .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::MessageAppended {
                session_id: sid,
                message,
            } => {
                assert_eq!(sid, session_id);
                assert_eq!(message.content, "streamed update");
            }
            other => panic!(
                "expected first streamed event to be MessageAppended, got {:?}",
                other
            ),
        }
    }

    #[tokio::test]
    async fn check_open_ai_key_over_websocket_returns_rest_only_error() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);

        handle_client_message(
            ClientMessage::CheckOpenAiKey {
                request_id: "req-check-key".to_string(),
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::Error {
                code,
                message,
                session_id,
            } => {
                assert_eq!(code, "http_only_endpoint");
                assert!(message.contains("GET /api/server/openai-key"));
                assert_eq!(session_id, None);
            }
            other => panic!("expected http_only_endpoint error, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn list_recent_projects_over_websocket_returns_rest_only_error() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);

        handle_client_message(
            ClientMessage::ListRecentProjects {
                request_id: "req-recent-projects".to_string(),
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::Error {
                code,
                message,
                session_id,
            } => {
                assert_eq!(code, "http_only_endpoint");
                assert!(message.contains("GET /api/fs/recent-projects"));
                assert_eq!(session_id, None);
            }
            other => panic!("expected http_only_endpoint error, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn browse_directory_over_websocket_returns_rest_only_error() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);

        handle_client_message(
            ClientMessage::BrowseDirectory {
                path: Some("/tmp".to_string()),
                request_id: "req-browse-dir".to_string(),
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::Error {
                code,
                message,
                session_id,
            } => {
                assert_eq!(code, "http_only_endpoint");
                assert!(message.contains("GET /api/fs/browse"));
                assert_eq!(session_id, None);
            }
            other => panic!("expected http_only_endpoint error, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn browse_directory_missing_path_over_websocket_still_returns_rest_only_error() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);

        handle_client_message(
            ClientMessage::BrowseDirectory {
                path: Some("/definitely/missing/path".to_string()),
                request_id: "req-browse-missing".to_string(),
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::Error {
                code,
                message,
                session_id,
            } => {
                assert_eq!(code, "http_only_endpoint");
                assert!(message.contains("GET /api/fs/browse"));
                assert_eq!(session_id, None);
            }
            other => panic!("expected http_only_endpoint error, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn set_open_ai_key_does_not_emit_unsolicited_status() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);

        handle_client_message(
            ClientMessage::SetOpenAiKey {
                key: "sk-test".to_string(),
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        assert!(
            client_rx.try_recv().is_err(),
            "set_open_ai_key should not emit websocket messages"
        );
    }

    #[tokio::test]
    async fn set_server_role_updates_state_and_emits_server_info() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);
        assert!(state.is_primary());

        handle_client_message(
            ClientMessage::SetServerRole { is_primary: false },
            &client_tx,
            &state,
            1,
        )
        .await;

        assert!(!state.is_primary());
        match recv_json(&mut client_rx).await {
            ServerMessage::ServerInfo {
                is_primary,
                client_primary_claims,
            } => {
                assert!(!is_primary);
                assert!(client_primary_claims.is_empty());
            }
            other => panic!("expected ServerInfo, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn set_client_primary_claim_updates_server_info() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);

        handle_client_message(
            ClientMessage::SetClientPrimaryClaim {
                client_id: "device-1".to_string(),
                device_name: "Robert's iPhone".to_string(),
                is_primary: true,
            },
            &client_tx,
            &state,
            7,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::ServerInfo {
                is_primary,
                client_primary_claims,
            } => {
                assert!(is_primary);
                assert_eq!(client_primary_claims.len(), 1);
                assert_eq!(client_primary_claims[0].client_id, "device-1");
                assert_eq!(client_primary_claims[0].device_name, "Robert's iPhone");
            }
            other => panic!("expected ServerInfo, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn codex_usage_over_websocket_returns_rest_only_error() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);

        handle_client_message(
            ClientMessage::FetchCodexUsage {
                request_id: "req-codex".to_string(),
            },
            &client_tx,
            &state,
            11,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::Error {
                code,
                message,
                session_id,
            } => {
                assert_eq!(code, "http_only_endpoint");
                assert!(message.contains("GET /api/usage/codex"));
                assert_eq!(session_id, None);
            }
            other => panic!("expected http_only_endpoint error, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn claude_usage_over_websocket_returns_rest_only_error() {
        let state = new_test_state();
        let (client_tx, mut client_rx) = mpsc::channel::<OutboundMessage>(16);

        handle_client_message(
            ClientMessage::FetchClaudeUsage {
                request_id: "req-claude".to_string(),
            },
            &client_tx,
            &state,
            15,
        )
        .await;

        match recv_json(&mut client_rx).await {
            ServerMessage::Error {
                code,
                message,
                session_id,
            } => {
                assert_eq!(code, "http_only_endpoint");
                assert!(message.contains("GET /api/usage/claude"));
                assert_eq!(session_id, None);
            }
            other => panic!("expected http_only_endpoint error, got {:?}", other),
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

    #[tokio::test(flavor = "current_thread")]
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
                permission_mode: None,
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
                permission_mode: None,
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
        assert_eq!(snapshot.work_status, WorkStatus::Working);
    }

    #[tokio::test]
    async fn send_message_does_not_mark_working_when_action_channel_is_closed() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "send-message-closed-channel".to_string();
        let (action_tx, action_rx) = mpsc::channel(1);

        drop(action_rx);

        {
            state.add_session(SessionHandle::new(
                session_id.clone(),
                Provider::Codex,
                "/Users/tester/repo".to_string(),
            ));
            state.set_codex_action_tx(&session_id, action_tx);
        }

        handle_client_message(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "ping".to_string(),
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

        tokio::task::yield_now().await;

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        let snapshot = actor.snapshot();
        assert_eq!(snapshot.work_status, WorkStatus::Waiting);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn send_message_dispatches_extracted_images_to_codex_connector() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "send-message-images-codex".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        {
            state.add_session(SessionHandle::new(
                session_id.clone(),
                Provider::Codex,
                "/Users/tester/repo".to_string(),
            ));
            state.set_codex_action_tx(&session_id, action_tx);
        }

        handle_client_message(
            ClientMessage::SendMessage {
                session_id,
                content: "ping".to_string(),
                model: None,
                effort: None,
                skills: vec![],
                images: vec![ImageInput {
                    input_type: "url".to_string(),
                    value: "data:image/png;base64,aGVsbG8=".to_string(),
                }],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        let action = action_rx.recv().await.expect("expected codex action");
        match action {
            CodexAction::SendMessage { images, .. } => {
                assert_eq!(images.len(), 1);
                assert_eq!(images[0].input_type, "path");
                assert!(images[0].value.ends_with(".png"));
            }
            other => panic!("expected SendMessage action, got {:?}", other),
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn send_message_dispatches_extracted_images_to_claude_connector() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "send-message-images-claude".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        {
            state.add_session(SessionHandle::new(
                session_id.clone(),
                Provider::Claude,
                "/Users/tester/repo".to_string(),
            ));
            state.set_claude_action_tx(&session_id, action_tx);
        }

        handle_client_message(
            ClientMessage::SendMessage {
                session_id,
                content: "ping".to_string(),
                model: None,
                effort: None,
                skills: vec![],
                images: vec![ImageInput {
                    input_type: "url".to_string(),
                    value: "data:image/png;base64,aGVsbG8=".to_string(),
                }],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        let action = action_rx.recv().await.expect("expected claude action");
        match action {
            ClaudeAction::SendMessage { images, .. } => {
                assert_eq!(images.len(), 1);
                assert_eq!(images[0].input_type, "path");
                assert!(images[0].value.ends_with(".png"));
            }
            other => panic!("expected SendMessage action, got {:?}", other),
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn steer_turn_dispatches_extracted_images_and_mentions_to_codex_connector() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "steer-turn-images-codex".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        {
            state.add_session(SessionHandle::new(
                session_id.clone(),
                Provider::Codex,
                "/Users/tester/repo".to_string(),
            ));
            state.set_codex_action_tx(&session_id, action_tx);
        }

        handle_client_message(
            ClientMessage::SteerTurn {
                session_id,
                content: "consider this".to_string(),
                images: vec![ImageInput {
                    input_type: "url".to_string(),
                    value: "data:image/png;base64,aGVsbG8=".to_string(),
                }],
                mentions: vec![MentionInput {
                    name: "main.rs".to_string(),
                    path: "/project/src/main.rs".to_string(),
                }],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        let action = action_rx.recv().await.expect("expected codex action");
        match action {
            CodexAction::SteerTurn {
                images, mentions, ..
            } => {
                assert_eq!(images.len(), 1);
                assert_eq!(images[0].input_type, "path");
                assert!(images[0].value.ends_with(".png"));
                assert_eq!(mentions.len(), 1);
                assert_eq!(mentions[0].name, "main.rs");
                assert_eq!(mentions[0].path, "/project/src/main.rs");
            }
            other => panic!("expected SteerTurn action, got {:?}", other),
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn steer_turn_dispatches_extracted_images_to_claude_connector() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "steer-turn-images-claude".to_string();
        let (action_tx, mut action_rx) = mpsc::channel(8);

        {
            state.add_session(SessionHandle::new(
                session_id.clone(),
                Provider::Claude,
                "/Users/tester/repo".to_string(),
            ));
            state.set_claude_action_tx(&session_id, action_tx);
        }

        handle_client_message(
            ClientMessage::SteerTurn {
                session_id,
                content: "consider this".to_string(),
                images: vec![ImageInput {
                    input_type: "url".to_string(),
                    value: "data:image/png;base64,aGVsbG8=".to_string(),
                }],
                mentions: vec![],
            },
            &client_tx,
            &state,
            1,
        )
        .await;

        let action = action_rx.recv().await.expect("expected claude action");
        match action {
            ClaudeAction::SteerTurn { images, .. } => {
                assert_eq!(images.len(), 1);
                assert_eq!(images[0].input_type, "path");
                assert!(images[0].value.ends_with(".png"));
            }
            other => panic!("expected SteerTurn action, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn send_message_without_effort_preserves_existing_effort() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "send-message-effort-preserve".to_string();
        let (action_tx, _action_rx) = mpsc::channel(8);

        {
            let mut handle = SessionHandle::new(
                session_id.clone(),
                Provider::Codex,
                "/Users/tester/repo".to_string(),
            );
            handle.apply_changes(&orbitdock_protocol::StateChanges {
                effort: Some(Some("xhigh".to_string())),
                ..Default::default()
            });
            state.add_session(handle);
            state.set_codex_action_tx(&session_id, action_tx);
        }

        handle_client_message(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "<environment_context>...</environment_context>".to_string(),
                model: Some("gpt-5.3-codex".to_string()),
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

        tokio::task::yield_now().await;

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        let snapshot = actor.snapshot();
        assert_eq!(snapshot.effort.as_deref(), Some("xhigh"));
    }

    #[tokio::test]
    async fn send_message_with_model_override_updates_session_model() {
        let state = new_test_state();
        let (client_tx, _client_rx) = mpsc::channel::<OutboundMessage>(16);
        let session_id = "send-message-model-override".to_string();
        let (action_tx, _action_rx) = mpsc::channel(8);

        {
            let mut handle = SessionHandle::new(
                session_id.clone(),
                Provider::Codex,
                "/Users/tester/repo".to_string(),
            );
            handle.set_model(Some("openai".to_string()));
            state.add_session(handle);
            state.set_codex_action_tx(&session_id, action_tx);
        }

        handle_client_message(
            ClientMessage::SendMessage {
                session_id: session_id.clone(),
                content: "<environment_context>...</environment_context>".to_string(),
                model: Some("gpt-5.3-codex".to_string()),
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

        tokio::task::yield_now().await;
        tokio::task::yield_now().await;

        let actor = state
            .get_session(&session_id)
            .expect("session should exist");
        let snapshot = actor.snapshot();
        assert_eq!(snapshot.model.as_deref(), Some("gpt-5.3-codex"));
    }
}
