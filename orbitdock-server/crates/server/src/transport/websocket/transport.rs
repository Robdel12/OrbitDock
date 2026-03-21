use bytes::Bytes;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::{info, warn};

use orbitdock_protocol::conversation_contracts::RowPageSummary;
use orbitdock_protocol::{ServerMessage, SessionState};

use crate::support::snapshot_compaction::{
    prepare_snapshot_for_transport, replay_has_oversize_event, sanitize_replay_event_for_transport,
    WS_MAX_TEXT_MESSAGE_BYTES,
};

/// Messages that can be sent through the WebSocket.
#[allow(clippy::large_enum_variant)]
#[derive(Debug)]
pub(crate) enum OutboundMessage {
    Json(ServerMessage),
    Raw(String),
    Pong(Bytes),
}

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

pub(crate) async fn send_replay_or_snapshot_fallback(
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
            "Replay payload exceeded transport limit, requesting client re-bootstrap"
        );
        send_json(
            tx,
            ServerMessage::Error {
                code: "replay_oversized".to_string(),
                message: "Replay payload exceeded transport limit; re-bootstrap the conversation"
                    .to_string(),
                session_id: Some(session_id.to_string()),
            },
        )
        .await;
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
            ServerMessage::ConversationBootstrap {
                session: prepare_snapshot_for_transport(snapshot),
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

pub(crate) async fn send_raw(tx: &mpsc::Sender<OutboundMessage>, json: String) {
    let _ = tx.send(OutboundMessage::Raw(json)).await;
}

/// Spawn a task that drains a broadcast receiver and forwards messages to an outbound channel.
/// When the outbound channel closes (client disconnects), the task exits and the
/// broadcast::Receiver is dropped — automatic cleanup, no manual unsubscribe needed.
///
/// If `session_id` is provided and the subscriber lags behind the broadcast buffer,
/// a `lagged` error is sent to the client so it can re-bootstrap the conversation.
pub(crate) fn spawn_broadcast_forwarder(
    mut rx: tokio::sync::broadcast::Receiver<ServerMessage>,
    outbound_tx: mpsc::Sender<OutboundMessage>,
    session_id: Option<String>,
) -> JoinHandle<()> {
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
    })
}
