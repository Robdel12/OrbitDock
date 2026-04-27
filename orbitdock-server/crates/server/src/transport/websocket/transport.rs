use bytes::Bytes;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::warn;

use orbitdock_protocol::ServerMessage;

use crate::support::snapshot_compaction::{
  replay_has_oversize_event, sanitize_replay_event_for_transport, WS_MAX_TEXT_MESSAGE_BYTES,
};

/// Messages that can be sent through the WebSocket.
#[derive(Debug)]
pub(crate) enum OutboundMessage {
  Json(Box<ServerMessage>),
  Raw(String),
  Pong(Bytes),
  /// Raw binary frame for high-throughput data (terminal PTY output).
  Binary(Vec<u8>),
}

pub(crate) async fn send_json(tx: &mpsc::Sender<OutboundMessage>, msg: ServerMessage) {
  let _ = tx.send(OutboundMessage::Json(Box::new(msg))).await;
}

pub(crate) async fn send_replay_or_resync_fallback(
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

pub(crate) async fn send_raw(tx: &mpsc::Sender<OutboundMessage>, json: String) {
  let _ = tx.send(OutboundMessage::Raw(json)).await;
}

pub(crate) fn spawn_filtered_broadcast_forwarder<F>(
  mut rx: tokio::sync::broadcast::Receiver<ServerMessage>,
  outbound_tx: mpsc::Sender<OutboundMessage>,
  session_id: Option<String>,
  should_forward: F,
) -> JoinHandle<()>
where
  F: Fn(&ServerMessage) -> bool + Send + 'static,
{
  tokio::spawn(async move {
    loop {
      match rx.recv().await {
        Ok(msg) => {
          if !should_forward(&msg) {
            continue;
          }
          if outbound_tx
            .send(OutboundMessage::Json(Box::new(msg)))
            .await
            .is_err()
          {
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
            .send(OutboundMessage::Json(Box::new(ServerMessage::Error {
              code: "lagged".to_string(),
              message: format!("Subscriber lagged, skipped {n} messages"),
              session_id: session_id.clone(),
            })))
            .await;
        }
        Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
      }
    }
  })
}
