use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use axum::{
  extract::{
    ws::{Message, WebSocket},
    State, WebSocketUpgrade,
  },
  http::HeaderMap,
  response::IntoResponse,
};
use futures::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::{debug, error, info, warn};

use orbitdock_protocol::SessionSurface;
use orbitdock_protocol::{ClientMessage, CompatibilityStatus, ServerMessage};

use crate::infrastructure::protocol_compat::compatibility_status_from_headers;
use crate::runtime::session_registry::SessionRegistry;
use crate::support::snapshot_compaction::{
  sanitize_server_message_for_transport, WS_MAX_TEXT_MESSAGE_BYTES,
};

use super::{
  handle_client_message, send_json, server_hello_message, server_info_message, OutboundMessage,
};

static NEXT_CONNECTION_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Default)]
pub(crate) struct ConnectionSubscriptions {
  dashboard_forwarder: Option<JoinHandle<()>>,
  missions_forwarder: Option<JoinHandle<()>>,
  session_surface_forwarders: HashMap<String, JoinHandle<()>>,
}

impl ConnectionSubscriptions {
  pub(crate) fn replace_dashboard_forwarder(&mut self, handle: JoinHandle<()>) {
    if let Some(existing) = self.dashboard_forwarder.replace(handle) {
      existing.abort();
    }
  }

  pub(crate) fn replace_missions_forwarder(&mut self, handle: JoinHandle<()>) {
    if let Some(existing) = self.missions_forwarder.replace(handle) {
      existing.abort();
    }
  }

  fn surface_key(session_id: &str, surface: SessionSurface) -> String {
    format!("{session_id}:{surface:?}")
  }

  pub(crate) fn replace_session_surface_forwarder(
    &mut self,
    session_id: String,
    surface: SessionSurface,
    handle: JoinHandle<()>,
  ) {
    let key = Self::surface_key(&session_id, surface);
    if let Some(existing) = self.session_surface_forwarders.insert(key, handle) {
      existing.abort();
    }
  }

  pub(crate) fn remove_session_surface_forwarder(
    &mut self,
    session_id: &str,
    surface: SessionSurface,
  ) -> bool {
    let key = Self::surface_key(session_id, surface);
    if let Some(existing) = self.session_surface_forwarders.remove(&key) {
      existing.abort();
      return true;
    }
    false
  }

  pub(crate) fn abort_all(&mut self) {
    if let Some(existing) = self.dashboard_forwarder.take() {
      existing.abort();
    }
    if let Some(existing) = self.missions_forwarder.take() {
      existing.abort();
    }
    for (_, handle) in self.session_surface_forwarders.drain() {
      handle.abort();
    }
  }
}

/// WebSocket upgrade handler
pub async fn ws_handler(
  ws: WebSocketUpgrade,
  headers: HeaderMap,
  State(state): State<Arc<SessionRegistry>>,
) -> impl IntoResponse {
  let compatibility = compatibility_status_from_headers(&headers);
  info!(
      component = "websocket",
      event = "ws.upgrade.request",
      client_version = ?headers
          .get(orbitdock_protocol::HTTP_HEADER_CLIENT_VERSION)
          .and_then(|value| value.to_str().ok()),
      client_compatibility = ?headers
          .get(orbitdock_protocol::HTTP_HEADER_CLIENT_COMPATIBILITY)
          .and_then(|value| value.to_str().ok()),
      has_authorization = headers.contains_key("authorization"),
      compatible = compatibility.compatible,
      reason = ?compatibility.reason,
      "Received WebSocket upgrade request"
  );
  ws.on_upgrade(move |socket| handle_socket(socket, state, compatibility))
}

/// Handle a WebSocket connection
async fn handle_socket(
  socket: WebSocket,
  state: Arc<SessionRegistry>,
  compatibility: CompatibilityStatus,
) {
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
          let sanitized = sanitize_server_message_for_transport(*server_msg);
          match serde_json::to_string(&sanitized) {
            Ok(json) => {
              if json.len() > WS_MAX_TEXT_MESSAGE_BYTES {
                warn!(
                  component = "websocket",
                  event = "ws.send.oversize_message",
                  connection_id = conn_id,
                  bytes = json.len(),
                  max_bytes = WS_MAX_TEXT_MESSAGE_BYTES,
                  "Sending oversized server message (no truncation)"
                );
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
              event = "ws.send.oversize_raw",
              connection_id = conn_id,
              bytes = json.len(),
              max_bytes = WS_MAX_TEXT_MESSAGE_BYTES,
              "Sending oversized replay payload (no truncation)"
            );
          }
          ws_tx.send(Message::Text(json.into())).await
        }
        OutboundMessage::Pong(data) => ws_tx.send(Message::Pong(data)).await,
        OutboundMessage::Binary(data) => ws_tx.send(Message::Binary(data.into())).await,
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
  let mut subscriptions = ConnectionSubscriptions::default();

  send_json(&outbound_tx, server_hello_message(compatibility)).await;
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
      Ok(Message::Binary(_)) => {
        // Binary frames are reserved for future client → server terminal input.
        // Currently terminal input uses JSON ClientMessage::TerminalInput.
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

    handle_client_message(client_msg, &client_tx, &state, &mut subscriptions, conn_id).await;
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
  subscriptions.abort_all();
  send_task.abort();
}

fn truncate_for_log(value: &str, max_chars: usize) -> String {
  value.chars().take(max_chars).collect()
}
