//! WebSocket handler for tool PTY subscriptions.
//!
//! Allows clients to subscribe to live streaming output from running bash commands.
//! Uses the same binary frame protocol as interactive terminals.

use std::sync::Arc;
use std::sync::OnceLock;

use base64::Engine;
use dashmap::DashMap;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::{debug, info, warn};

use orbitdock_protocol::{ClientMessage, ServerMessage};

use crate::infrastructure::terminal::build_output_frame;
use crate::infrastructure::tool_pty::{ToolPtyEvent, ToolPtyStatus};
use crate::runtime::session_registry::SessionRegistry;
use crate::transport::websocket::{send_json, OutboundMessage};

type ToolPtyForwarderKey = (u64, String);

fn tool_pty_forwarders() -> &'static DashMap<ToolPtyForwarderKey, JoinHandle<()>> {
  static TOOL_PTY_FORWARDERS: OnceLock<DashMap<ToolPtyForwarderKey, JoinHandle<()>>> =
    OnceLock::new();
  TOOL_PTY_FORWARDERS.get_or_init(DashMap::new)
}

fn abort_tool_pty_forwarder(conn_id: u64, tool_id: &str) {
  if let Some((_, handle)) = tool_pty_forwarders().remove(&(conn_id, tool_id.to_string())) {
    handle.abort();
  }
}

pub(crate) fn abort_tool_pty_forwarders_for_connection(conn_id: u64) {
  let keys: Vec<ToolPtyForwarderKey> = tool_pty_forwarders()
    .iter()
    .filter_map(|entry| (entry.key().0 == conn_id).then(|| entry.key().clone()))
    .collect();

  for (_, tool_id) in keys {
    abort_tool_pty_forwarder(conn_id, &tool_id);
  }
}

pub(crate) async fn handle(
  msg: ClientMessage,
  client_tx: &mpsc::Sender<OutboundMessage>,
  state: &Arc<SessionRegistry>,
  conn_id: u64,
) {
  match msg {
    ClientMessage::SubscribeToolPty {
      tool_id,
      session_id,
    } => {
      info!(
        component = "tool_pty",
        event = "tool_pty.subscribe.requested",
        connection_id = conn_id,
        tool_id = %tool_id,
        session_id = %session_id,
        "Tool PTY subscription requested"
      );

      let tool_pty_service = state.tool_pty_service();

      // Try to subscribe to the tool's output stream
      let subscription = tool_pty_service.subscribe(&session_id, &tool_id);

      match subscription {
        Some((replay_buffer, status, mut output_rx)) => {
          abort_tool_pty_forwarder(conn_id, &tool_id);

          // Send attachment confirmation with replay buffer
          let buffered_output = if replay_buffer.is_empty() {
            None
          } else {
            Some(base64::engine::general_purpose::STANDARD.encode(&replay_buffer))
          };

          send_json(
            client_tx,
            ServerMessage::ToolPtyAttached {
              tool_id: tool_id.clone(),
              buffered_output,
            },
          )
          .await;

          // Check if already exited
          if let ToolPtyStatus::Exited { exit_code } = status {
            send_json(
              client_tx,
              ServerMessage::ToolPtyExited {
                tool_id: tool_id.clone(),
                exit_code,
              },
            )
            .await;
            // Don't spawn forwarder for already-exited tools
            return;
          }

          // Spawn forwarder: tool PTY output → binary WebSocket frames
          // Uses the same frame format as interactive terminals
          let forwarder_tx = client_tx.clone();
          let tid = tool_id.clone();
          let forwarder_key = (conn_id, tool_id.clone());

          let removal_key = forwarder_key.clone();
          let handle = tokio::spawn(async move {
            loop {
              match output_rx.recv().await {
                Ok(ToolPtyEvent::Output(chunk)) => {
                  let frame = build_output_frame(&tid, &chunk);
                  if forwarder_tx
                    .send(OutboundMessage::Binary(frame))
                    .await
                    .is_err()
                  {
                    debug!(
                      component = "tool_pty",
                      event = "tool_pty.forwarder.client_disconnected",
                      tool_id = %tid,
                      "Client disconnected, stopping forwarder"
                    );
                    break;
                  }
                }
                Ok(ToolPtyEvent::Exited { exit_code }) => {
                  let _ = forwarder_tx
                    .send(OutboundMessage::Json(Box::new(
                      ServerMessage::ToolPtyExited {
                        tool_id: tid.clone(),
                        exit_code,
                      },
                    )))
                    .await;
                  break;
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                  warn!(
                    component = "tool_pty",
                    event = "tool_pty.forwarder.lagged",
                    tool_id = %tid,
                    dropped = n,
                    "Tool PTY forwarder lagged, dropped {} messages",
                    n
                  );
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                  break;
                }
              }
            }

            debug!(
              component = "tool_pty",
              event = "tool_pty.forwarder.stopped",
              tool_id = %tid,
              "Tool PTY forwarder stopped"
            );

            tool_pty_forwarders().remove(&removal_key);
          });

          tool_pty_forwarders().insert(forwarder_key, handle);
        }
        None => {
          // Tool doesn't exist or already cleaned up
          debug!(
            component = "tool_pty",
            event = "tool_pty.subscribe.not_found",
            connection_id = conn_id,
            tool_id = %tool_id,
            "Tool PTY session not found"
          );

          send_json(
            client_tx,
            ServerMessage::Error {
              code: "tool_pty_not_found".to_string(),
              message: format!("Tool PTY session '{}' not found", tool_id),
              session_id: Some(session_id),
            },
          )
          .await;
        }
      }
    }

    ClientMessage::UnsubscribeToolPty { tool_id } => {
      info!(
        component = "tool_pty",
        event = "tool_pty.unsubscribe.requested",
        connection_id = conn_id,
        tool_id = %tool_id,
        "Tool PTY unsubscription requested"
      );

      abort_tool_pty_forwarder(conn_id, &tool_id);
      send_json(
        client_tx,
        ServerMessage::ToolPtyDetached {
          tool_id: tool_id.clone(),
        },
      )
      .await;
    }

    _ => {}
  }
}
