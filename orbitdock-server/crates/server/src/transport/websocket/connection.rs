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
use tracing::{debug, error, warn};

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
  control_plane_forwarder: Option<JoinHandle<()>>,
  dashboard_forwarder: Option<JoinHandle<()>>,
  library_forwarder: Option<JoinHandle<()>>,
  missions_forwarder: Option<JoinHandle<()>>,
  mission_forwarders: HashMap<String, JoinHandle<()>>,
  session_surface_forwarders: HashMap<String, JoinHandle<()>>,
}

impl ConnectionSubscriptions {
  pub(crate) fn replace_control_plane_forwarder(&mut self, handle: JoinHandle<()>) {
    if let Some(existing) = self.control_plane_forwarder.replace(handle) {
      existing.abort();
    }
  }

  pub(crate) fn remove_control_plane_forwarder(&mut self) {
    if let Some(existing) = self.control_plane_forwarder.take() {
      existing.abort();
    }
  }

  pub(crate) fn replace_dashboard_forwarder(&mut self, handle: JoinHandle<()>) {
    if let Some(existing) = self.dashboard_forwarder.replace(handle) {
      existing.abort();
    }
  }

  pub(crate) fn remove_dashboard_forwarder(&mut self) {
    if let Some(existing) = self.dashboard_forwarder.take() {
      existing.abort();
    }
  }

  pub(crate) fn replace_library_forwarder(&mut self, handle: JoinHandle<()>) {
    if let Some(existing) = self.library_forwarder.replace(handle) {
      existing.abort();
    }
  }

  pub(crate) fn remove_library_forwarder(&mut self) {
    if let Some(existing) = self.library_forwarder.take() {
      existing.abort();
    }
  }

  pub(crate) fn replace_missions_forwarder(&mut self, handle: JoinHandle<()>) {
    if let Some(existing) = self.missions_forwarder.replace(handle) {
      existing.abort();
    }
  }

  pub(crate) fn remove_missions_forwarder(&mut self) {
    if let Some(existing) = self.missions_forwarder.take() {
      existing.abort();
    }
  }

  pub(crate) fn replace_mission_forwarder(&mut self, mission_id: String, handle: JoinHandle<()>) {
    if let Some(existing) = self.mission_forwarders.insert(mission_id, handle) {
      existing.abort();
    }
  }

  pub(crate) fn remove_mission_forwarder(&mut self, mission_id: &str) -> bool {
    if let Some(existing) = self.mission_forwarders.remove(mission_id) {
      existing.abort();
      return true;
    }
    false
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
    if let Some(existing) = self.control_plane_forwarder.take() {
      existing.abort();
    }
    if let Some(existing) = self.dashboard_forwarder.take() {
      existing.abort();
    }
    if let Some(existing) = self.library_forwarder.take() {
      existing.abort();
    }
    if let Some(existing) = self.missions_forwarder.take() {
      existing.abort();
    }
    for (_, handle) in self.mission_forwarders.drain() {
      handle.abort();
    }
    for (_, handle) in self.session_surface_forwarders.drain() {
      handle.abort();
    }
  }
}

/// WebSocket upgrade handler
pub async fn ws_handler(
  ws: WebSocketUpgrade,
  _headers: HeaderMap,
  State(state): State<Arc<SessionRegistry>>,
) -> impl IntoResponse {
  ws.on_upgrade(move |socket| handle_socket(socket, state))
}

/// Handle a WebSocket connection
async fn handle_socket(socket: WebSocket, state: Arc<SessionRegistry>) {
  let conn_id = NEXT_CONNECTION_ID.fetch_add(1, Ordering::Relaxed);
  state.ws_connect();

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
  if state.clear_client_primary_claim(conn_id) {
    state.broadcast_to_list(server_info_message(&state));
  }
  crate::transport::websocket::handlers::tool_pty::abort_tool_pty_forwarders_for_connection(
    conn_id,
  );
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

fn server_message_mission_id(msg: &ServerMessage) -> Option<String> {
  match msg {
    ServerMessage::MissionHeartbeat { mission_id, .. }
    | ServerMessage::MissionInvalidated { mission_id, .. } => Some(mission_id.clone()),
    _ => None,
  }
}

fn oversize_resync_hint(msg: &ServerMessage) -> Option<ServerMessage> {
  let message_type = server_message_type_for_log(msg);

  if let Some(session_id) = server_message_session_id(msg) {
    let surface = if message_type == "conversation_rows_changed" {
      SessionSurface::Conversation
    } else {
      SessionSurface::Detail
    };

    return Some(ServerMessage::SessionSurfaceInvalidated {
      session_id,
      surface,
      revision: 0,
    });
  }

  if let Some(mission_id) = server_message_mission_id(msg) {
    return Some(ServerMessage::MissionInvalidated {
      mission_id,
      revision: 0,
    });
  }

  if message_type.starts_with("mission_") {
    return Some(ServerMessage::MissionsInvalidated { revision: 0 });
  }

  if message_type.starts_with("sessions_summary_") {
    return Some(ServerMessage::SessionsSummaryInvalidated { revision: 0 });
  }

  if message_type.starts_with("archived_sessions_") {
    return Some(ServerMessage::ArchivedSessionsInvalidated { revision: 0 });
  }

  Some(ServerMessage::ActiveSessionsInvalidated { revision: 0 })
}
