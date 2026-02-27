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
    new_id, ClaudeIntegrationMode, ClientMessage, CodexIntegrationMode, MessageChanges,
    MessageType, Provider, ServerMessage, SessionState, SessionStatus, ShellExecutionOutcome,
    StateChanges, TokenUsage, TokenUsageSnapshotKind, WorkStatus,
};

use crate::claude_session::{ClaudeAction, ClaudeSession};
use crate::codex_session::{CodexAction, CodexSession};
use crate::persistence::{
    load_latest_codex_turn_context_settings_from_transcript_path, load_messages_for_session,
    load_messages_from_transcript_path, load_session_by_id, load_session_permission_mode,
    load_token_usage_from_transcript_path, PersistCommand,
};
use crate::session::SessionHandle;
use crate::session_actor::SessionActorHandle;
use crate::session_command::{PersistOp, SessionCommand, SubscribeResult};
use crate::session_naming::name_from_first_prompt;
use crate::state::SessionRegistry;

static NEXT_CONNECTION_ID: AtomicU64 = AtomicU64::new(1);

fn normalize_non_empty(value: Option<String>) -> Option<String> {
    value
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(str::to_string)
}

fn is_provider_placeholder_model(model: &str) -> bool {
    matches!(
        model.trim().to_ascii_lowercase().as_str(),
        "openai" | "anthropic"
    )
}

fn normalize_model_override(value: Option<String>) -> Option<String> {
    normalize_non_empty(value).filter(|model| !is_provider_placeholder_model(model))
}

fn normalize_question_answers(
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

fn select_primary_answer(
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

fn work_status_for_approval_decision(decision: &str) -> orbitdock_protocol::WorkStatus {
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

const CLAUDE_EMPTY_SHELL_TTL_SECS: u64 = 5 * 60;
const SNAPSHOT_MAX_MESSAGES: usize = 200;
const SNAPSHOT_MAX_CONTENT_CHARS: usize = 16_000;
const SNAPSHOT_MIN_CONTENT_CHARS: usize = 250;
const SNAPSHOT_MAX_TURN_DIFFS: usize = 80;
// Keep outbound frames within common client defaults (Apple URLSession WS default is 1 MiB).
const WS_MAX_TEXT_MESSAGE_BYTES: usize = 1024 * 1024;
// Snapshots should stay much smaller than the hard transport ceiling to avoid reconnect churn.
const SNAPSHOT_TARGET_TEXT_MESSAGE_BYTES: usize = 256 * 1024;

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
async fn send_json(tx: &mpsc::Sender<OutboundMessage>, msg: ServerMessage) {
    let _ = tx.send(OutboundMessage::Json(msg)).await;
}

async fn send_rest_only_error(
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

fn server_info_message(state: &SessionRegistry) -> ServerMessage {
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

async fn send_snapshot_from_actor(
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

async fn send_replay_or_snapshot_fallback(
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

async fn send_snapshot_if_requested(
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

pub(crate) fn chrono_now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    format!("{}Z", secs)
}

async fn mark_session_working_after_send(state: &Arc<SessionRegistry>, session_id: &str) {
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

async fn claim_codex_thread_for_direct_session(
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

fn direct_mode_activation_changes(provider: Provider) -> StateChanges {
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

fn parse_unix_z(value: Option<&str>) -> Option<u64> {
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

fn compact_snapshot_for_transport(snapshot: SessionState) -> SessionState {
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

/// Handle a client message
/// Dispatch a single client WebSocket message.
///
/// The body is wrapped in `Box::pin(async move { … })` so the enormous async
/// state machine (70+ match arms, each with `.await` points) lives on the heap.
/// Without this, debug-mode builds overflow the default 2 MiB thread stack —
/// both in tests and (occasionally) in production under deep call chains.
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
                            && snap.status == orbitdock_protocol::SessionStatus::Active
                            && snap.codex_integration_mode == Some(CodexIntegrationMode::Direct)
                            && !state.has_codex_connector(&session_id);
                        let is_claude_direct_needing_connector = snap.provider == Provider::Claude
                            && snap.claude_integration_mode == Some(ClaudeIntegrationMode::Direct)
                            && !state.has_claude_connector(&session_id)
                            && snap.status == orbitdock_protocol::SessionStatus::Active;
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
                                match tokio::time::timeout(connector_timeout, &mut connector_task)
                                    .await
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
                                match tokio::time::timeout(connector_timeout, connector_task).await
                                {
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

                let mut handle =
                    crate::session::SessionHandle::new(id.clone(), provider, cwd.clone());
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
                            Ok(Err(join_err)) => {
                                Err(format!("Connector task panicked: {}", join_err))
                            }
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

                    let action_model = normalize_model_override(model.clone());
                    let action_effort = normalize_non_empty(effort.clone());

                    // Persist model override and broadcast delta only when explicitly provided.
                    if let Some(actor) = state.get_session(&session_id) {
                        if let Some(ref model_name) = action_model {
                            let _ = state
                                .persist()
                                .send(PersistCommand::ModelUpdate {
                                    session_id: session_id.clone(),
                                    model: model_name.clone(),
                                })
                                .await;
                            let changes = orbitdock_protocol::StateChanges {
                                model: Some(Some(model_name.clone())),
                                ..Default::default()
                            };
                            let _ = actor
                                .send(SessionCommand::ApplyDelta {
                                    changes,
                                    persist_op: None,
                                })
                                .await;
                        }
                    }

                    // Persist effort override and broadcast delta only when explicitly provided.
                    if let Some(actor) = state.get_session(&session_id) {
                        if let Some(ref effort_name) = action_effort {
                            let _ = state
                                .persist()
                                .send(PersistCommand::EffortUpdate {
                                    session_id: session_id.clone(),
                                    effort: Some(effort_name.clone()),
                                })
                                .await;
                            let changes = orbitdock_protocol::StateChanges {
                                effort: Some(Some(effort_name.clone())),
                                ..Default::default()
                            };
                            let _ = actor
                                .send(SessionCommand::ApplyDelta {
                                    changes,
                                    persist_op: None,
                                })
                                .await;
                        }
                    }

                    // Persist user message immediately
                    let ts_millis = SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis();
                    let msg_id = format!("user-ws-{}-{}", ts_millis, conn_id);
                    // Keep client message payload portable; only connector dispatch needs path images.
                    let connector_images =
                        crate::images::extract_images_to_disk(&images, &session_id, &msg_id);
                    let user_msg = orbitdock_protocol::Message {
                        id: msg_id,
                        session_id: session_id.clone(),
                        message_type: orbitdock_protocol::MessageType::User,
                        content: content.clone(),
                        tool_name: None,
                        tool_input: None,
                        tool_output: None,
                        is_error: false,
                        is_in_progress: false,
                        timestamp: iso_timestamp(ts_millis),
                        duration_ms: None,
                        images: images.clone(),
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
                        if tx
                            .send(CodexAction::SendMessage {
                                content,
                                model: action_model,
                                effort: action_effort,
                                skills,
                                images: connector_images.clone(),
                                mentions,
                            })
                            .await
                            .is_ok()
                        {
                            mark_session_working_after_send(state, &session_id).await;
                        } else {
                            warn!(
                                component = "session",
                                event = "session.message.action_channel_closed",
                                connection_id = conn_id,
                                session_id = %session_id,
                                provider = "codex",
                                "Codex action channel closed while sending message"
                            );
                        }
                    } else if let Some(tx) = claude_tx {
                        if tx
                            .send(ClaudeAction::SendMessage {
                                content,
                                model: action_model,
                                effort: action_effort,
                                images: connector_images,
                            })
                            .await
                            .is_ok()
                        {
                            mark_session_working_after_send(state, &session_id).await;
                        } else {
                            warn!(
                                component = "session",
                                event = "session.message.action_channel_closed",
                                connection_id = conn_id,
                                session_id = %session_id,
                                provider = "claude",
                                "Claude action channel closed while sending message"
                            );
                        }
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
                images,
                mentions,
            } => {
                info!(
                    component = "session",
                    event = "session.steer.requested",
                    connection_id = conn_id,
                    session_id = %session_id,
                    content_chars = content.chars().count(),
                    images_count = images.len(),
                    mentions_count = mentions.len(),
                    "Steering active turn"
                );

                // Try Codex action channel first, then Claude
                let codex_tx = state.get_codex_action_tx(&session_id);
                let claude_tx = state.get_claude_action_tx(&session_id);

                if codex_tx.is_some() || claude_tx.is_some() {
                    // Persist steer message so it appears in conversation
                    let ts_millis = SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis();
                    let steer_msg_id = format!("steer-ws-{}-{}", ts_millis, conn_id);
                    let connector_images =
                        crate::images::extract_images_to_disk(&images, &session_id, &steer_msg_id);
                    let steer_msg = orbitdock_protocol::Message {
                        id: steer_msg_id.clone(),
                        session_id: session_id.clone(),
                        message_type: orbitdock_protocol::MessageType::Steer,
                        content: content.clone(),
                        tool_name: None,
                        tool_input: None,
                        tool_output: None,
                        is_error: false,
                        is_in_progress: false,
                        timestamp: iso_timestamp(ts_millis),
                        duration_ms: None,
                        images: images.clone(),
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

                    if let Some(tx) = codex_tx {
                        let _ = tx
                            .send(CodexAction::SteerTurn {
                                content,
                                message_id: steer_msg_id,
                                images: connector_images.clone(),
                                mentions,
                            })
                            .await;
                    } else if let Some(tx) = claude_tx {
                        let _ = tx
                            .send(ClaudeAction::SteerTurn {
                                content,
                                message_id: steer_msg_id,
                                images: connector_images,
                            })
                            .await;
                    }
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
                message,
                interrupt,
                updated_input,
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

                let fallback_work_status = work_status_for_approval_decision(&decision);
                let mut resolved_work_status = fallback_work_status;

                // Resolve pending approval server-side and promote next queued request.
                // This keeps queue ownership inside the session actor.
                let (approval_type, proposed_amendment, next_pending_request_id, approval_version) =
                    if let Some(actor) = state.get_session(&session_id) {
                        let (reply_tx, reply_rx) = oneshot::channel();
                        actor
                            .send(SessionCommand::ResolvePendingApproval {
                                request_id: request_id.clone(),
                                fallback_work_status,
                                reply: reply_tx,
                            })
                            .await;

                        if let Ok(resolution) = reply_rx.await {
                            resolved_work_status = resolution.work_status;
                            (
                                resolution.approval_type,
                                resolution.proposed_amendment,
                                resolution.next_pending_approval.map(|approval| approval.id),
                                resolution.approval_version,
                            )
                        } else {
                            (None, None, None, 0)
                        }
                    } else {
                        (None, None, None, 0)
                    };

                if state.get_session(&session_id).is_some() && approval_type.is_none() {
                    send_json(
                        client_tx,
                        ServerMessage::ApprovalDecisionResult {
                            session_id: session_id.clone(),
                            request_id: request_id.clone(),
                            outcome: "stale".to_string(),
                            active_request_id: next_pending_request_id.clone(),
                            approval_version,
                        },
                    )
                    .await;
                    return;
                }

                let request_id_for_result = request_id.clone();

                let _ = state
                    .persist()
                    .send(PersistCommand::ApprovalDecision {
                        session_id: session_id.clone(),
                        request_id: request_id.clone(),
                        decision: decision.clone(),
                    })
                    .await;

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
                            message,
                            interrupt,
                            updated_input,
                        })
                        .await;
                }

                let _ = state
                    .persist()
                    .send(PersistCommand::SessionUpdate {
                        id: session_id.clone(),
                        status: None,
                        work_status: Some(resolved_work_status),
                        last_activity_at: None,
                    })
                    .await;

                send_json(
                    client_tx,
                    ServerMessage::ApprovalDecisionResult {
                        session_id: session_id.clone(),
                        request_id: request_id_for_result,
                        outcome: "applied".to_string(),
                        active_request_id: next_pending_request_id.clone(),
                        approval_version,
                    },
                )
                .await;

                if let Some(next_pending_request_id) = next_pending_request_id {
                    info!(
                        component = "approval",
                        event = "approval.queue.promoted",
                        session_id = %session_id,
                        next_request_id = %next_pending_request_id,
                        "Promoted next queued approval"
                    );
                }
            }

            ClientMessage::ListApprovals { session_id, .. } => {
                send_rest_only_error(client_tx, "GET /api/approvals", session_id).await;
            }

            ClientMessage::DeleteApproval { .. } => {
                send_rest_only_error(client_tx, "DELETE /api/approvals/{approval_id}", None).await;
            }

            ClientMessage::ListModels => {
                send_rest_only_error(client_tx, "GET /api/models/codex", None).await;
            }

            ClientMessage::ListClaudeModels => {
                send_rest_only_error(client_tx, "GET /api/models/claude", None).await;
            }

            ClientMessage::CodexAccountRead { .. } => {
                send_rest_only_error(client_tx, "GET /api/codex/account", None).await;
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

            ClientMessage::ListSkills { session_id, .. } => {
                send_rest_only_error(
                    client_tx,
                    "GET /api/sessions/{session_id}/skills",
                    Some(session_id),
                )
                .await;
            }

            ClientMessage::ListRemoteSkills { session_id } => {
                send_rest_only_error(
                    client_tx,
                    "GET /api/sessions/{session_id}/skills/remote",
                    Some(session_id),
                )
                .await;
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
                send_rest_only_error(
                    client_tx,
                    "GET /api/sessions/{session_id}/mcp/tools",
                    Some(session_id),
                )
                .await;
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
                question_id,
                answers,
            } => {
                let mut normalized_answers = normalize_question_answers(answers);
                let trimmed_answer = answer.trim().to_string();
                if normalized_answers.is_empty() && !trimmed_answer.is_empty() {
                    let key = question_id.clone().unwrap_or_else(|| "0".to_string());
                    normalized_answers.insert(key, vec![trimmed_answer.clone()]);
                }

                info!(
                    component = "approval",
                    event = "approval.answer.submitted",
                    connection_id = conn_id,
                    session_id = %session_id,
                    request_id = %request_id,
                    answer_chars = trimmed_answer.chars().count(),
                    answer_questions = normalized_answers.len(),
                    "Answer submitted for question approval"
                );
                if normalized_answers.is_empty() {
                    warn!(
                        component = "approval",
                        event = "approval.answer.missing_payload",
                        connection_id = conn_id,
                        session_id = %session_id,
                        request_id = %request_id,
                        "Question answer request had no usable answer payload"
                    );
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "invalid_answer_payload".into(),
                            message: "Question approvals require a non-empty answer or answers map"
                                .into(),
                            session_id: Some(session_id),
                        },
                    )
                    .await;
                    return;
                }

                let fallback_work_status = WorkStatus::Working;
                let mut resolved_work_status = fallback_work_status;
                let mut resolved = false;
                let mut next_pending_request_id: Option<String> = None;
                let mut approval_version: u64 = 0;
                if let Some(actor) = state.get_session(&session_id) {
                    let (reply_tx, reply_rx) = oneshot::channel();
                    actor
                        .send(SessionCommand::ResolvePendingApproval {
                            request_id: request_id.clone(),
                            fallback_work_status,
                            reply: reply_tx,
                        })
                        .await;
                    if let Ok(resolution) = reply_rx.await {
                        resolved = resolution.approval_type.is_some();
                        resolved_work_status = resolution.work_status;
                        next_pending_request_id = resolution.next_pending_approval.map(|a| a.id);
                        approval_version = resolution.approval_version;
                    }
                }

                if state.get_session(&session_id).is_some() && !resolved {
                    send_json(
                        client_tx,
                        ServerMessage::ApprovalDecisionResult {
                            session_id: session_id.clone(),
                            request_id: request_id.clone(),
                            outcome: "stale".to_string(),
                            active_request_id: next_pending_request_id.clone(),
                            approval_version,
                        },
                    )
                    .await;
                    return;
                }

                let request_id_for_result = request_id.clone();

                let _ = state
                    .persist()
                    .send(PersistCommand::ApprovalDecision {
                        session_id: session_id.clone(),
                        request_id: request_id.clone(),
                        decision: "approved".to_string(),
                    })
                    .await;

                if let Some(tx) = state.get_codex_action_tx(&session_id) {
                    let _ = tx
                        .send(CodexAction::AnswerQuestion {
                            request_id: request_id.clone(),
                            answers: normalized_answers,
                        })
                        .await;
                } else if let Some(tx) = state.get_claude_action_tx(&session_id) {
                    let claude_answer = if trimmed_answer.is_empty() {
                        select_primary_answer(&normalized_answers, question_id.as_deref())
                            .unwrap_or_default()
                    } else {
                        trimmed_answer
                    };
                    if claude_answer.is_empty() {
                        warn!(
                            component = "approval",
                            event = "approval.answer.missing_payload",
                            connection_id = conn_id,
                            session_id = %session_id,
                            request_id = %request_id,
                            "Question answer request had no usable answer payload"
                        );
                        return;
                    }
                    let _ = tx
                        .send(ClaudeAction::AnswerQuestion {
                            request_id,
                            answer: claude_answer,
                        })
                        .await;
                }

                let _ = state
                    .persist()
                    .send(PersistCommand::SessionUpdate {
                        id: session_id.clone(),
                        status: None,
                        work_status: Some(resolved_work_status),
                        last_activity_at: None,
                    })
                    .await;

                send_json(
                    client_tx,
                    ServerMessage::ApprovalDecisionResult {
                        session_id: session_id.clone(),
                        request_id: request_id_for_result,
                        outcome: "applied".to_string(),
                        active_request_id: next_pending_request_id.clone(),
                        approval_version,
                    },
                )
                .await;

                if let Some(next_pending_request_id) = next_pending_request_id {
                    info!(
                        component = "approval",
                        event = "approval.queue.promoted",
                        session_id = %session_id,
                        next_request_id = %next_pending_request_id,
                        "Promoted next queued approval"
                    );
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

                let send_result = if let Some(tx) = state.get_codex_action_tx(&session_id) {
                    tx.send(CodexAction::Interrupt).await.map_err(|_| "codex")
                } else if let Some(tx) = state.get_claude_action_tx(&session_id) {
                    tx.send(ClaudeAction::Interrupt).await.map_err(|_| "claude")
                } else {
                    Err("none")
                };

                match send_result {
                    Ok(()) => {
                        info!(
                            component = "session",
                            event = "session.interrupt.dispatched",
                            session_id = %session_id,
                            "Interrupt dispatched to connector"
                        );
                    }
                    Err(provider) => {
                        warn!(
                            component = "session",
                            event = "session.interrupt.failed",
                            session_id = %session_id,
                            provider = %provider,
                            "Interrupt failed — no active action channel"
                        );
                        // Clean up stale channels
                        if provider == "codex" {
                            state.remove_codex_action_tx(&session_id);
                        } else if provider == "claude" {
                            state.remove_claude_action_tx(&session_id);
                        }
                        send_json(
                            client_tx,
                            ServerMessage::Error {
                                code: "interrupt_failed".into(),
                                message: format!(
                                    "Could not interrupt session {}: connector not reachable",
                                    session_id
                                ),
                                session_id: Some(session_id.clone()),
                            },
                        )
                        .await;
                    }
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
                } else if let Some(tx) = state.get_claude_action_tx(&session_id) {
                    let _ = tx.send(ClaudeAction::Undo).await;
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

            ClientMessage::SetServerRole { is_primary } => {
                info!(
                    component = "config",
                    event = "config.server_role.set",
                    connection_id = conn_id,
                    is_primary = is_primary,
                    "Server role updated via WebSocket"
                );

                let _changed = state.set_primary(is_primary);

                let role_value = if is_primary {
                    "primary".to_string()
                } else {
                    "secondary".to_string()
                };
                let _ = state
                    .persist()
                    .send(PersistCommand::SetConfig {
                        key: "server_role".into(),
                        value: role_value,
                    })
                    .await;

                let update = server_info_message(state);
                send_json(client_tx, update.clone()).await;
                state.broadcast_to_list(update);
            }

            ClientMessage::SetClientPrimaryClaim {
                client_id,
                device_name,
                is_primary,
            } => {
                info!(
                    component = "config",
                    event = "config.client_primary_claim.set",
                    connection_id = conn_id,
                    client_id = %client_id,
                    device_name = %device_name,
                    is_primary = is_primary,
                    "Client primary claim updated"
                );

                state.set_client_primary_claim(conn_id, client_id, device_name, is_primary);

                let update = server_info_message(state);
                send_json(client_tx, update.clone()).await;
                state.broadcast_to_list(update);
            }

            ClientMessage::SetOpenAiKey { key } => {
                info!(
                    component = "config",
                    event = "config.openai_key.set",
                    connection_id = conn_id,
                    "OpenAI API key set via UI"
                );

                let _ = state
                    .persist()
                    .send(PersistCommand::SetConfig {
                        key: "openai_api_key".into(),
                        value: key,
                    })
                    .await;
            }

            ClientMessage::CheckOpenAiKey { .. } => {
                send_rest_only_error(client_tx, "GET /api/server/openai-key", None).await;
            }

            ClientMessage::FetchCodexUsage { .. } => {
                send_rest_only_error(client_tx, "GET /api/usage/codex", None).await;
            }

            ClientMessage::FetchClaudeUsage { .. } => {
                send_rest_only_error(client_tx, "GET /api/usage/claude", None).await;
            }

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

                // Load session data from DB
                let mut restored = match load_session_by_id(&session_id).await {
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

                let is_claude = restored.provider == "claude";
                let provider = if is_claude {
                    orbitdock_protocol::Provider::Claude
                } else {
                    orbitdock_protocol::Provider::Codex
                };

                // If DB has no messages but we have a transcript file, load from it.
                // Passive sessions don't store full conversation in DB — the transcript
                // file has the complete history.
                if restored.messages.is_empty() {
                    if let Some(ref tp) = restored.transcript_path {
                        match crate::persistence::load_messages_from_transcript_path(
                            tp,
                            &session_id,
                        )
                        .await
                        {
                            Ok(msgs) if !msgs.is_empty() => {
                                info!(
                                    component = "session",
                                    event = "session.resume.transcript_loaded",
                                    session_id = %session_id,
                                    message_count = msgs.len(),
                                    "Loaded messages from transcript for resume"
                                );
                                restored.messages = msgs;
                            }
                            _ => {}
                        }
                    }
                }

                let msg_count = restored.messages.len();
                let mut handle = SessionHandle::restore(
                    restored.id.clone(),
                    provider,
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
                    restored.permission_mode.clone(),
                    TokenUsage {
                        input_tokens: restored.input_tokens.max(0) as u64,
                        output_tokens: restored.output_tokens.max(0) as u64,
                        cached_tokens: restored.cached_tokens.max(0) as u64,
                        context_window: restored.context_window.max(0) as u64,
                    },
                    restored.token_usage_snapshot_kind,
                    restored.started_at,
                    restored.last_activity_at,
                    restored.messages,
                    restored.current_diff,
                    restored.current_plan,
                    restored
                        .turn_diffs
                        .into_iter()
                        .map(
                            |(
                                turn_id,
                                diff,
                                input_tokens,
                                output_tokens,
                                cached_tokens,
                                context_window,
                                snapshot_kind,
                            )| {
                                let has_tokens =
                                    input_tokens > 0 || output_tokens > 0 || context_window > 0;
                                orbitdock_protocol::TurnDiff {
                                    turn_id,
                                    diff,
                                    token_usage: if has_tokens {
                                        Some(orbitdock_protocol::TokenUsage {
                                            input_tokens: input_tokens as u64,
                                            output_tokens: output_tokens as u64,
                                            cached_tokens: cached_tokens as u64,
                                            context_window: context_window as u64,
                                        })
                                    } else {
                                        None
                                    },
                                    snapshot_kind: Some(snapshot_kind),
                                }
                            },
                        )
                        .collect(),
                    restored.git_branch,
                    restored.git_sha,
                    restored.current_cwd,
                    restored.first_prompt,
                    restored.last_message,
                    restored.pending_tool_name,
                    restored.pending_tool_input,
                    restored.pending_question,
                    restored.pending_approval_id,
                    restored.effort,
                    restored.terminal_session_id,
                    restored.terminal_app,
                    restored.approval_version,
                );

                // Set integration mode to direct BEFORE snapshot so the client sees it immediately
                if is_claude {
                    handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Direct));
                } else {
                    handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
                }

                // Subscribe the requesting client
                let rx = handle.subscribe();
                spawn_broadcast_forwarder(rx, client_tx.clone(), Some(session_id.clone()));

                // Send full snapshot immediately so the client shows Direct/Active
                // before the connector finishes connecting.
                let snapshot = handle.state();
                send_json(
                    client_tx,
                    ServerMessage::SessionSnapshot { session: snapshot },
                )
                .await;

                // Broadcast updated summary to session list
                state.broadcast_to_list(ServerMessage::SessionCreated {
                    session: handle.summary(),
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
                    let project = if let Some(ref tp) = restored.transcript_path {
                        resolve_claude_resume_cwd(&restored.project_path, tp)
                    } else {
                        restored.project_path.clone()
                    };

                    let sid = session_id.clone();
                    // Validate through ProviderSessionId — refuse to resume with an OrbitDock ID
                    let provider_resume_id = restored
                        .claude_sdk_session_id
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
                    let m = restored.model.clone();
                    let restored_permission_mode = load_session_permission_mode(&session_id)
                        .await
                        .unwrap_or(None);
                    let connector_timeout = std::time::Duration::from_secs(15);
                    let pm = restored_permission_mode.clone();
                    let resume_id = provider_resume_id.clone();

                    let connector_task = tokio::spawn(async move {
                        ClaudeSession::new(
                            sid.clone(),
                            &project,
                            m.as_deref(),
                            Some(&resume_id),
                            pm.as_deref(),
                            &[],  // allowed_tools
                            &[],  // disallowed_tools
                            None, // effort
                        )
                        .await
                    });

                    match tokio::time::timeout(connector_timeout, connector_task).await {
                        Ok(Ok(Ok(claude_session))) => {
                            state.register_claude_thread(&session_id, provider_resume_id.as_str());

                            handle.set_list_tx(state.list_tx());

                            let (actor_handle, action_tx) = crate::claude_session::start_event_loop(
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
                    let task_project_path = restored.project_path.clone();
                    let task_model = restored.model.clone();
                    let task_approval = restored.approval_policy.clone();
                    let task_sandbox = restored.sandbox_mode.clone();

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
                            Ok(Err(join_err)) => {
                                Err(format!("Connector task panicked: {}", join_err))
                            }
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
                let is_passive = match snap.provider {
                    Provider::Codex => {
                        snap.codex_integration_mode == Some(CodexIntegrationMode::Passive)
                            || (snap.codex_integration_mode.is_none()
                                && snap.transcript_path.is_some())
                    }
                    Provider::Claude => {
                        snap.claude_integration_mode != Some(ClaudeIntegrationMode::Direct)
                    }
                };

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

                // If the passive handle has no messages, load from transcript file.
                if handle.messages().is_empty() {
                    if let Some(ref tp) = snap.transcript_path {
                        if let Ok(msgs) =
                            crate::persistence::load_messages_from_transcript_path(tp, &session_id)
                                .await
                        {
                            if !msgs.is_empty() {
                                info!(
                                    component = "session",
                                    event = "session.takeover.transcript_loaded",
                                    session_id = %session_id,
                                    message_count = msgs.len(),
                                    "Loaded messages from transcript for takeover"
                                );
                                for msg in msgs {
                                    handle.add_message(msg);
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
                let (turn_context_model, turn_context_effort) = if snap.provider == Provider::Codex
                {
                    if let Some(ref transcript_path) = snap.transcript_path {
                        load_latest_codex_turn_context_settings_from_transcript_path(
                            transcript_path,
                        )
                        .await
                        .unwrap_or((None, None))
                    } else {
                        (None, None)
                    }
                } else {
                    (None, None)
                };
                let effective_model = model.or(turn_context_model).or_else(|| snap.model.clone());
                let effective_effort = snap.effort.clone().or(turn_context_effort);
                let effective_approval = approval_policy.or(snap.approval_policy.clone());
                let effective_sandbox = sandbox_mode.or(snap.sandbox_mode.clone());
                let requested_permission_mode = permission_mode.clone();
                let stored_permission_mode =
                    if snap.provider == Provider::Claude && requested_permission_mode.is_none() {
                        load_session_permission_mode(&session_id)
                            .await
                            .unwrap_or(None)
                    } else {
                        None
                    };
                let effective_permission =
                    requested_permission_mode.clone().or(stored_permission_mode);
                let connector_timeout = std::time::Duration::from_secs(15);

                let connector_ok = if snap.provider == Provider::Codex {
                    // Flip integration mode
                    handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
                    if let Some(ref m) = effective_model {
                        handle.set_model(Some(m.clone()));
                    }
                    handle.set_config(effective_approval.clone(), effective_sandbox.clone());

                    let thread_id = state.codex_thread_for_session(&session_id);
                    let sid = session_id.clone();
                    let project = snap.project_path.clone();
                    let m = effective_model.clone();
                    let ap = effective_approval.clone();
                    let sb = effective_sandbox.clone();

                    let mut connector_task = tokio::spawn(async move {
                        if let Some(ref tid) = thread_id {
                            match CodexSession::resume(
                                sid.clone(),
                                &project,
                                tid,
                                m.as_deref(),
                                ap.as_deref(),
                                sb.as_deref(),
                            )
                            .await
                            {
                                Ok(codex) => Ok(codex),
                                Err(_) => {
                                    CodexSession::new(
                                        sid.clone(),
                                        &project,
                                        m.as_deref(),
                                        ap.as_deref(),
                                        sb.as_deref(),
                                    )
                                    .await
                                }
                            }
                        } else {
                            CodexSession::new(
                                sid.clone(),
                                &project,
                                m.as_deref(),
                                ap.as_deref(),
                                sb.as_deref(),
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

                            let (actor_handle, action_tx) = crate::codex_session::start_event_loop(
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
                            &project,
                            m.as_deref(),
                            takeover_sdk_id_for_spawn.as_ref(),
                            pm.as_deref(),
                            &at,
                            &dt,
                            None, // effort
                        )
                        .await
                    });

                    match tokio::time::timeout(connector_timeout, connector_task).await {
                        Ok(Ok(Ok(claude_session))) => {
                            // Only register thread if we have a real SDK ID
                            if let Some(ref sdk_id) = takeover_sdk_id {
                                state.register_claude_thread(&session_id, sdk_id.as_str());
                            }

                            let (actor_handle, action_tx) = crate::claude_session::start_event_loop(
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
                                                    permission_mode: Some(mode.clone()),
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
                            handle
                                .set_claude_integration_mode(Some(ClaudeIntegrationMode::Passive));
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
                            handle
                                .set_claude_integration_mode(Some(ClaudeIntegrationMode::Passive));
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
                            handle
                                .set_claude_integration_mode(Some(ClaudeIntegrationMode::Passive));
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

                        // Broadcast updated summary to list subscribers
                        let (sum_tx, sum_rx) = oneshot::channel();
                        new_actor
                            .send(SessionCommand::GetSummary { reply: sum_tx })
                            .await;
                        if let Ok(summary) = sum_rx.await {
                            state.broadcast_to_list(ServerMessage::SessionCreated {
                                session: summary,
                            });
                        }
                    }
                }
            }

            ClientMessage::ClaudeSessionStart { .. }
            | ClientMessage::ClaudeSessionEnd { .. }
            | ClientMessage::ClaudeStatusEvent { .. }
            | ClientMessage::ClaudeToolEvent { .. }
            | ClientMessage::ClaudeSubagentEvent { .. } => {
                // Keep hook processing future on the heap to avoid debug-stack blowups
                // when this large async match is exercised directly by tests.
                Box::pin(crate::hook_handler::handle_hook_message(msg, state)).await;
            }

            ClientMessage::GetSubagentTools {
                session_id,
                subagent_id,
            } => {
                let _ = subagent_id;
                send_rest_only_error(
                    client_tx,
                    "GET /api/sessions/{session_id}/subagents/{subagent_id}/tools",
                    Some(session_id),
                )
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
                                handle.set_claude_integration_mode(Some(
                                    ClaudeIntegrationMode::Direct,
                                ));
                                handle.set_forked_from(source_session_id.clone());
                                if let Some(ref m) = source_model {
                                    handle.set_model(Some(m.clone()));
                                }

                                let rx = handle.subscribe();
                                spawn_broadcast_forwarder(
                                    rx,
                                    client_tx.clone(),
                                    Some(new_id.clone()),
                                );

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
                                let (actor_handle, action_tx) =
                                    crate::claude_session::start_event_loop(
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

                        let forked_messages = if let Some(rollout_path) =
                            new_connector.rollout_path().await
                        {
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

            ClientMessage::ListReviewComments { session_id, .. } => {
                send_rest_only_error(
                    client_tx,
                    "GET /api/sessions/{session_id}/review-comments",
                    Some(session_id),
                )
                .await;
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

            // Shell execution — dispatched to a separate async fn to reduce
            // the parent future's stack frame size.
            ClientMessage::ExecuteShell { .. } | ClientMessage::CancelShell { .. } => {
                handle_shell_message(msg, client_tx, state, conn_id).await;
            }

            ClientMessage::BrowseDirectory { .. } => {
                send_rest_only_error(client_tx, "GET /api/fs/browse", None).await;
            }

            ClientMessage::ListRecentProjects { .. } => {
                send_rest_only_error(client_tx, "GET /api/fs/recent-projects", None).await;
            }

            // Worktree management — dispatched to a separate async fn to reduce
            // the parent future's stack frame size (prevents debug-mode overflow).
            ClientMessage::ListWorktrees { .. }
            | ClientMessage::CreateWorktree { .. }
            | ClientMessage::RemoveWorktree { .. }
            | ClientMessage::DiscoverWorktrees { .. } => {
                handle_worktree_message(msg, client_tx).await;
            }
        }
    })
}

/// Handle worktree management messages in a separate async function.
///
/// Extracted from `handle_client_message` to keep its future size small enough
/// for the default 2MB thread stack in debug builds. Each async fn gets its own
/// independently-sized future, so splitting large match arms out prevents the
/// compiler from unioning all arms' locals into one oversized frame.
async fn handle_shell_message(
    msg: ClientMessage,
    client_tx: &mpsc::Sender<OutboundMessage>,
    state: &Arc<SessionRegistry>,
    conn_id: u64,
) {
    match msg {
        ClientMessage::ExecuteShell {
            session_id,
            command,
            cwd,
            timeout_secs,
        } => {
            info!(
                component = "shell",
                event = "shell.execute.requested",
                connection_id = conn_id,
                session_id = %session_id,
                command = %command,
                "Shell execution requested"
            );

            let resolved_cwd = if let Some(ref explicit) = cwd {
                explicit.clone()
            } else if let Some(actor) = state.get_session(&session_id) {
                let snap = actor.snapshot();
                snap.current_cwd
                    .clone()
                    .unwrap_or_else(|| snap.project_path.clone())
            } else {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "not_found".to_string(),
                        message: format!("Session {session_id} not found"),
                        session_id: Some(session_id),
                    },
                )
                .await;
                return;
            };

            let request_id = new_id();
            let sid = session_id.clone();
            let rid = request_id.clone();
            let cmd_clone = command.clone();

            let actor = match state.get_session(&sid) {
                Some(a) => a,
                None => return,
            };

            actor
                .send(SessionCommand::Broadcast {
                    msg: ServerMessage::ShellStarted {
                        session_id: sid.clone(),
                        request_id: rid.clone(),
                        command: cmd_clone.clone(),
                    },
                })
                .await;

            let shell_msg = orbitdock_protocol::Message {
                id: rid.clone(),
                session_id: sid.clone(),
                message_type: MessageType::Shell,
                content: cmd_clone.clone(),
                tool_name: None,
                tool_input: None,
                tool_output: None,
                is_error: false,
                is_in_progress: true,
                timestamp: iso_timestamp(
                    SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis(),
                ),
                duration_ms: None,
                images: vec![],
            };

            actor
                .send(SessionCommand::ProcessEvent {
                    event: crate::transition::Input::MessageCreated(shell_msg),
                })
                .await;

            let shell_execution = match state.shell_service().start(
                rid.clone(),
                sid.clone(),
                cmd_clone.clone(),
                resolved_cwd.clone(),
                timeout_secs,
            ) {
                Ok(execution) => execution,
                Err(crate::shell::ShellStartError::DuplicateRequestId) => {
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "shell_duplicate_request_id".to_string(),
                            message: format!("Shell request {rid} is already active"),
                            session_id: Some(sid.clone()),
                        },
                    )
                    .await;
                    return;
                }
            };

            let state_ref = state.clone();
            tokio::spawn(async move {
                let mut chunk_rx = shell_execution.chunk_rx;
                let completion_rx = shell_execution.completion_rx;

                let mut streamed_output = String::new();
                let mut last_stream_emit = std::time::Instant::now();
                const SHELL_STREAM_THROTTLE_MS: u128 = 120;

                while let Some(chunk) = chunk_rx.recv().await {
                    if !chunk.stdout.is_empty() {
                        streamed_output.push_str(&chunk.stdout);
                    }
                    if !chunk.stderr.is_empty() {
                        streamed_output.push_str(&chunk.stderr);
                    }

                    let now = std::time::Instant::now();
                    if now.duration_since(last_stream_emit).as_millis() < SHELL_STREAM_THROTTLE_MS {
                        continue;
                    }
                    last_stream_emit = now;

                    if let Some(actor) = state_ref.get_session(&sid) {
                        actor
                            .send(SessionCommand::ProcessEvent {
                                event: crate::transition::Input::MessageUpdated {
                                    message_id: rid.clone(),
                                    content: None,
                                    tool_output: Some(streamed_output.clone()),
                                    is_error: None,
                                    is_in_progress: Some(true),
                                    duration_ms: None,
                                },
                            })
                            .await;
                    }
                }

                let result = match completion_rx.await {
                    Ok(result) => result,
                    Err(recv_err) => crate::shell::ShellResult {
                        stdout: String::new(),
                        stderr: format!("Shell execution completion channel failed: {recv_err}"),
                        exit_code: None,
                        duration_ms: 0,
                        outcome: crate::shell::ShellOutcome::Failed,
                    },
                };

                let is_error = match result.outcome {
                    crate::shell::ShellOutcome::Completed => result.exit_code != Some(0),
                    crate::shell::ShellOutcome::Failed | crate::shell::ShellOutcome::TimedOut => {
                        true
                    }
                    crate::shell::ShellOutcome::Canceled => false,
                };
                let combined_output = if result.stderr.is_empty() {
                    result.stdout.clone()
                } else if result.stdout.is_empty() {
                    result.stderr.clone()
                } else {
                    format!("{}\n{}", result.stdout, result.stderr)
                };
                let final_output = if combined_output.is_empty() {
                    streamed_output
                } else {
                    combined_output
                };
                let outcome = match result.outcome {
                    crate::shell::ShellOutcome::Completed => ShellExecutionOutcome::Completed,
                    crate::shell::ShellOutcome::Failed => ShellExecutionOutcome::Failed,
                    crate::shell::ShellOutcome::TimedOut => ShellExecutionOutcome::TimedOut,
                    crate::shell::ShellOutcome::Canceled => ShellExecutionOutcome::Canceled,
                };

                if let Some(actor) = state_ref.get_session(&sid) {
                    actor
                        .send(SessionCommand::ProcessEvent {
                            event: crate::transition::Input::MessageUpdated {
                                message_id: rid.clone(),
                                content: None,
                                tool_output: Some(final_output),
                                is_error: Some(is_error),
                                is_in_progress: Some(false),
                                duration_ms: Some(result.duration_ms),
                            },
                        })
                        .await;

                    actor
                        .send(SessionCommand::Broadcast {
                            msg: ServerMessage::ShellOutput {
                                session_id: sid,
                                request_id: rid,
                                stdout: result.stdout,
                                stderr: result.stderr,
                                exit_code: result.exit_code,
                                duration_ms: result.duration_ms,
                                outcome,
                            },
                        })
                        .await;
                }
            });
        }

        ClientMessage::CancelShell {
            session_id,
            request_id,
        } => {
            info!(
                component = "shell",
                event = "shell.cancel.requested",
                connection_id = conn_id,
                session_id = %session_id,
                request_id = %request_id,
                "Shell cancel requested"
            );

            if state.get_session(&session_id).is_none() {
                send_json(
                    client_tx,
                    ServerMessage::Error {
                        code: "not_found".to_string(),
                        message: format!("Session {session_id} not found"),
                        session_id: Some(session_id),
                    },
                )
                .await;
                return;
            }

            match state.shell_service().cancel(&session_id, &request_id) {
                crate::shell::ShellCancelStatus::Canceled => {
                    info!(
                        component = "shell",
                        event = "shell.cancel.accepted",
                        connection_id = conn_id,
                        session_id = %session_id,
                        request_id = %request_id,
                        "Shell cancel accepted"
                    );
                }
                crate::shell::ShellCancelStatus::NotFound => {
                    send_json(
                        client_tx,
                        ServerMessage::Error {
                            code: "shell_not_found".to_string(),
                            message: format!(
                                "No active shell request {request_id} found for session {session_id}"
                            ),
                            session_id: Some(session_id),
                        },
                    )
                    .await;
                }
            }
        }

        _ => {}
    }
}

/// Handle worktree management messages in a separate async function (same reason).
async fn handle_worktree_message(msg: ClientMessage, client_tx: &mpsc::Sender<OutboundMessage>) {
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

/// Resolve the correct cwd for `claude --resume` by matching the transcript
/// path's project hash against the session's project_path (and its parents).
///
/// Claude stores transcripts at `~/.claude/projects/<hash>/<session>.jsonl`
/// where `<hash>` encodes the cwd with `/` and `.` replaced by `-`.
/// The DB's `project_path` may be a subdirectory, so we walk up until
/// we find a path whose hash matches the transcript's project directory.
fn resolve_claude_resume_cwd(project_path: &str, transcript_path: &str) -> String {
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
