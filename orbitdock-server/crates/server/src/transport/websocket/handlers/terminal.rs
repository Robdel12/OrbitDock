//! WebSocket handler for interactive terminal sessions.

use std::sync::Arc;

use base64::Engine;
use tokio::sync::mpsc;
use tracing::{info, warn};

use orbitdock_protocol::{ClientMessage, ServerMessage};

use crate::infrastructure::terminal::{build_exit_frame, build_output_frame};
use crate::runtime::session_registry::SessionRegistry;
use crate::transport::websocket::{send_json, OutboundMessage};

pub(crate) async fn handle(
  msg: ClientMessage,
  client_tx: &mpsc::Sender<OutboundMessage>,
  state: &Arc<SessionRegistry>,
  conn_id: u64,
) {
  match msg {
    ClientMessage::CreateTerminal {
      terminal_id,
      cwd,
      shell,
      cols,
      rows,
      session_id,
    } => {
      info!(
        component = "terminal",
        event = "terminal.create.requested",
        connection_id = conn_id,
        terminal_id = %terminal_id,
        cwd = %cwd,
        cols,
        rows,
        "Terminal creation requested"
      );

      let terminal_service = state.terminal_service();
      let mut output_rx = match terminal_service.create(terminal_id.clone(), cwd, shell, cols, rows)
      {
        Ok(rx) => rx,
        Err(e) => {
          let message = match e {
            crate::infrastructure::terminal::TerminalCreateError::DuplicateId => {
              format!("Terminal {terminal_id} already exists")
            }
            crate::infrastructure::terminal::TerminalCreateError::PtyFailed => {
              "Failed to allocate PTY".to_string()
            }
            crate::infrastructure::terminal::TerminalCreateError::ForkFailed => {
              "Failed to fork child process".to_string()
            }
          };
          send_json(
            client_tx,
            ServerMessage::Error {
              code: "terminal_create_failed".to_string(),
              message,
              session_id: None,
            },
          )
          .await;
          return;
        }
      };

      // Confirm creation.
      send_json(
        client_tx,
        ServerMessage::TerminalCreated {
          terminal_id: terminal_id.clone(),
          session_id,
        },
      )
      .await;

      // Spawn forwarder: PTY output broadcast → binary WebSocket frames.
      let forwarder_tx = client_tx.clone();
      let tid = terminal_id.clone();
      let ts = terminal_service.clone();
      tokio::spawn(async move {
        loop {
          match output_rx.recv().await {
            Ok(chunk) => {
              let frame = build_output_frame(&tid, &chunk);
              if forwarder_tx
                .send(OutboundMessage::Binary(frame))
                .await
                .is_err()
              {
                // Client disconnected.
                break;
              }
            }
            Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
              warn!(
                component = "terminal",
                event = "terminal.output.lagged",
                terminal_id = %tid,
                skipped = n,
                "Terminal output subscriber lagged, skipped {n} chunks"
              );
            }
            Err(tokio::sync::broadcast::error::RecvError::Closed) => {
              // PTY closed — send exit frame.
              // We don't have the exit code here; the service cleanup handles that.
              let frame = build_exit_frame(&tid, None);
              let _ = forwarder_tx.send(OutboundMessage::Binary(frame)).await;

              // Also send a typed JSON message for clients that prefer it.
              let _ = forwarder_tx
                .send(OutboundMessage::Json(Box::new(
                  ServerMessage::TerminalExited {
                    terminal_id: tid.clone(),
                    exit_code: None,
                  },
                )))
                .await;
              break;
            }
          }
        }

        // If the terminal still exists when the client disconnects, leave it running
        // (another client could subscribe). The client can explicitly DestroyTerminal.
        let _ = ts; // keep service alive for the duration
      });
    }

    ClientMessage::TerminalInput { terminal_id, data } => {
      let decoded = match base64::engine::general_purpose::STANDARD.decode(&data) {
        Ok(bytes) => bytes,
        Err(e) => {
          warn!(
            component = "terminal",
            event = "terminal.input.decode_failed",
            connection_id = conn_id,
            terminal_id = %terminal_id,
            error = %e,
            "Failed to decode base64 terminal input"
          );
          return;
        }
      };

      let terminal_service = state.terminal_service();
      if terminal_service
        .write_input(&terminal_id, &decoded)
        .is_err()
      {
        send_json(
          client_tx,
          ServerMessage::Error {
            code: "terminal_not_found".to_string(),
            message: format!("Terminal {terminal_id} not found"),
            session_id: None,
          },
        )
        .await;
      }
    }

    ClientMessage::TerminalResize {
      terminal_id,
      cols,
      rows,
    } => {
      let terminal_service = state.terminal_service();
      if terminal_service.resize(&terminal_id, cols, rows).is_err() {
        send_json(
          client_tx,
          ServerMessage::Error {
            code: "terminal_not_found".to_string(),
            message: format!("Terminal {terminal_id} not found"),
            session_id: None,
          },
        )
        .await;
      }
    }

    ClientMessage::DestroyTerminal { terminal_id } => {
      info!(
        component = "terminal",
        event = "terminal.destroy.requested",
        connection_id = conn_id,
        terminal_id = %terminal_id,
        "Terminal destruction requested"
      );

      let terminal_service = state.terminal_service();
      if terminal_service.destroy(&terminal_id).is_err() {
        send_json(
          client_tx,
          ServerMessage::Error {
            code: "terminal_not_found".to_string(),
            message: format!("Terminal {terminal_id} not found"),
            session_id: None,
          },
        )
        .await;
      }
    }

    _ => {}
  }
}
