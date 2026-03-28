use bytes::Bytes;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::warn;

use orbitdock_protocol::{ServerMessage, WorkStatus};

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

fn normalize_transport_message(msg: &mut ServerMessage) {
  if let ServerMessage::SessionDelta { changes, .. } = msg {
    if changes.steerable.is_none() {
      if let Some(work_status) = changes.work_status {
        changes.steerable = Some(work_status == WorkStatus::Working);
      }
    }
  }
}

pub(crate) async fn send_json(tx: &mpsc::Sender<OutboundMessage>, mut msg: ServerMessage) {
  normalize_transport_message(&mut msg);
  let _ = tx.send(OutboundMessage::Json(Box::new(msg))).await;
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

/// Spawn a task that drains a broadcast receiver and forwards messages to an outbound channel.
/// When the outbound channel closes (client disconnects), the task exits and the
/// broadcast::Receiver is dropped — automatic cleanup, no manual unsubscribe needed.
///
/// If `session_id` is provided and the subscriber lags behind the broadcast buffer,
/// a `lagged` error is sent to the client so it can re-bootstrap the conversation.
pub(crate) fn spawn_broadcast_forwarder(
  rx: tokio::sync::broadcast::Receiver<ServerMessage>,
  outbound_tx: mpsc::Sender<OutboundMessage>,
  session_id: Option<String>,
) -> JoinHandle<()> {
  spawn_filtered_broadcast_forwarder(rx, outbound_tx, session_id, |_| true)
}

pub(crate) fn spawn_filtered_broadcast_forwarder<F>(
  mut rx: tokio::sync::broadcast::Receiver<ServerMessage>,
  outbound_tx: mpsc::Sender<OutboundMessage>,
  session_id: Option<String>,
  filter: F,
) -> JoinHandle<()>
where
  F: Fn(&ServerMessage) -> bool + Send + 'static,
{
  tokio::spawn(async move {
    loop {
      match rx.recv().await {
        Ok(mut msg) => {
          if !filter(&msg) {
            continue;
          }
          normalize_transport_message(&mut msg);
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

#[cfg(test)]
mod tests {
  use super::normalize_transport_message;
  use orbitdock_protocol::{ServerMessage, StateChanges, WorkStatus};

  #[test]
  fn session_delta_working_sets_steerable_when_missing() {
    let mut message = ServerMessage::SessionDelta {
      session_id: "session-1".to_string(),
      changes: Box::new(StateChanges {
        work_status: Some(WorkStatus::Working),
        ..Default::default()
      }),
    };

    normalize_transport_message(&mut message);

    let ServerMessage::SessionDelta { changes, .. } = message else {
      panic!("expected session delta");
    };
    assert_eq!(changes.steerable, Some(true));
  }

  #[test]
  fn session_delta_waiting_sets_steerable_false_when_missing() {
    let mut message = ServerMessage::SessionDelta {
      session_id: "session-1".to_string(),
      changes: Box::new(StateChanges {
        work_status: Some(WorkStatus::Waiting),
        ..Default::default()
      }),
    };

    normalize_transport_message(&mut message);

    let ServerMessage::SessionDelta { changes, .. } = message else {
      panic!("expected session delta");
    };
    assert_eq!(changes.steerable, Some(false));
  }

  #[test]
  fn session_delta_keeps_explicit_steerable_value() {
    let mut message = ServerMessage::SessionDelta {
      session_id: "session-1".to_string(),
      changes: Box::new(StateChanges {
        work_status: Some(WorkStatus::Waiting),
        steerable: Some(true),
        ..Default::default()
      }),
    };

    normalize_transport_message(&mut message);

    let ServerMessage::SessionDelta { changes, .. } = message else {
      panic!("expected session delta");
    };
    assert_eq!(changes.steerable, Some(true));
  }
}
