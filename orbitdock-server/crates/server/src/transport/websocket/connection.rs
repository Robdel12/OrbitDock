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
use orbitdock_protocol::{ClientMessage, ServerMessage};

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
  info!(
      component = "websocket",
      event = "ws.upgrade.request",
      client_version = ?headers
          .get(orbitdock_protocol::HTTP_HEADER_CLIENT_VERSION)
          .and_then(|value| value.to_str().ok()),
      has_authorization = headers.contains_key("authorization"),
      "Received WebSocket upgrade request"
  );
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
          let sanitized = sanitize_server_message_for_transport(*server_msg);
          match serde_json::to_string(&sanitized) {
            Ok(mut json) => {
              if json.len() > WS_MAX_TEXT_MESSAGE_BYTES {
                let message_type = server_message_type_for_log(&sanitized);
                error!(
                  component = "websocket",
                  event = "ws.contract_violation.oversize_payload",
                  connection_id = conn_id,
                  message_type = %message_type,
                  bytes = json.len(),
                  max_bytes = WS_MAX_TEXT_MESSAGE_BYTES,
                  "Oversized websocket payload violates transport contract (HTTP must carry heavy payloads)"
                );

                if let Some(resync_hint) = oversize_resync_hint(&sanitized) {
                  let fallback_json = serde_json::to_string(&resync_hint);
                  match fallback_json {
                    Ok(compacted) => {
                      warn!(
                        component = "websocket",
                        event = "ws.send.oversize_resync_hint",
                        connection_id = conn_id,
                        message_type = %message_type,
                        original_bytes = json.len(),
                        compacted_bytes = compacted.len(),
                        "Replacing oversized payload with explicit HTTP resync hint"
                      );
                      json = compacted;
                    }
                    Err(error) => {
                      error!(
                        component = "websocket",
                        event = "ws.contract_violation.serialize_resync_hint_failed",
                        connection_id = conn_id,
                        message_type = %message_type,
                        error = %error,
                        "Failed to serialize oversized-message resync hint"
                      );
                      continue;
                    }
                  }
                } else {
                  error!(
                    component = "websocket",
                    event = "ws.contract_violation.drop_oversize_payload",
                    connection_id = conn_id,
                    message_type = %message_type,
                    bytes = json.len(),
                    max_bytes = WS_MAX_TEXT_MESSAGE_BYTES,
                    "Dropping oversized server message; no safe compaction available"
                  );
                  continue;
                }
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

  send_json(&outbound_tx, server_hello_message()).await;
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

fn server_message_type_for_log(msg: &ServerMessage) -> String {
  serde_json::to_value(msg)
    .ok()
    .and_then(|value| {
      value
        .as_object()
        .and_then(|object| object.get("type"))
        .and_then(|entry| entry.as_str())
        .map(String::from)
    })
    .unwrap_or_else(|| "unknown".to_string())
}

fn server_message_session_id(msg: &ServerMessage) -> Option<String> {
  serde_json::to_value(msg).ok().and_then(|value| {
    value
      .as_object()
      .and_then(|object| object.get("session_id"))
      .and_then(|entry| entry.as_str())
      .map(String::from)
  })
}

fn oversize_resync_hint(msg: &ServerMessage) -> Option<ServerMessage> {
  let message_type = server_message_type_for_log(msg);

  if let Some(session_id) = server_message_session_id(msg) {
    let (code, endpoint) = if message_type == "conversation_rows_changed" {
      (
        "conversation_resync_required",
        format!("/api/sessions/{session_id}/conversation"),
      )
    } else {
      (
        "session_detail_resync_required",
        format!("/api/sessions/{session_id}/detail"),
      )
    };

    return Some(ServerMessage::Error {
      code: code.to_string(),
      message: format!(
        "Realtime payload ({message_type}) exceeded WebSocket transport budget; refetch GET {endpoint}"
      ),
      session_id: Some(session_id),
    });
  }

  if message_type.starts_with("mission_") || message_type == "missions_list" {
    return Some(ServerMessage::Error {
      code: "missions_resync_required".to_string(),
      message:
        "Realtime missions payload exceeded WebSocket transport budget; refetch GET /api/missions"
          .to_string(),
      session_id: None,
    });
  }

  Some(ServerMessage::Error {
    code: "dashboard_resync_required".to_string(),
    message: "Realtime payload exceeded WebSocket transport budget; refetch GET /api/dashboard"
      .to_string(),
    session_id: None,
  })
}
