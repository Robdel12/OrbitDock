use std::sync::Arc;
use tokio::sync::mpsc;

use orbitdock_protocol::conversation_contracts::{
  ConversationRow, ConversationRowEntry, RenderHints, ShellCommandRow, ShellCommandRowKind,
};
use orbitdock_protocol::{new_id, ClientMessage, ServerMessage, ShellExecutionOutcome};

use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::transport::shell_streaming::{ShellStreamPreviewState, SHELL_STREAM_THROTTLE_MS};
use crate::transport::websocket::{send_json, OutboundMessage};

fn shell_render_hints() -> RenderHints {
  RenderHints {
    can_expand: true,
    default_expanded: false,
    emphasized: false,
    monospace_summary: true,
    accent_tone: Some("shell".to_string()),
  }
}

fn shell_summary(exit_code: Option<i32>, duration_ms: u64) -> Option<String> {
  let mut parts: Vec<String> = Vec::new();
  if let Some(exit_code) = exit_code {
    parts.push(format!("Exit {exit_code}"));
  }
  if duration_ms > 0 {
    parts.push(format!("{:.2}s", duration_ms as f64 / 1000.0));
  }
  (!parts.is_empty()).then(|| parts.join(" • "))
}

struct ShellRowState {
  command: Option<String>,
  stdout: Option<String>,
  stderr: Option<String>,
  exit_code: Option<i32>,
  duration_ms: u64,
  cwd: Option<String>,
}

fn shell_row_entry(
  request_id: &str,
  session_id: &str,
  state: ShellRowState,
) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: session_id.to_string(),
    sequence: 0,
    turn_id: None,
    turn_status: Default::default(),
    row: ConversationRow::ShellCommand(ShellCommandRow {
      id: request_id.to_string(),
      kind: ShellCommandRowKind::UserShellCommand,
      title: state
        .command
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("Shell command")
        .to_string(),
      summary: shell_summary(state.exit_code, state.duration_ms),
      command: state.command,
      args: vec![],
      stdout: state.stdout,
      stderr: state.stderr,
      exit_code: state.exit_code,
      duration_seconds: (state.duration_ms > 0).then_some(state.duration_ms as f64 / 1000.0),
      cwd: state.cwd,
      render_hints: shell_render_hints(),
    }),
  }
}

pub(crate) async fn handle(
  msg: ClientMessage,
  client_tx: &mpsc::Sender<OutboundMessage>,
  state: &Arc<SessionRegistry>,
  _conn_id: u64,
) {
  match msg {
    ClientMessage::ExecuteShell {
      session_id,
      command,
      cwd,
      timeout_secs,
    } => {
      let resolved_cwd = if let Some(ref explicit) = cwd {
        explicit.clone()
      } else if let Some(actor) = state.get_session(&session_id) {
        let snap = actor.snapshot();
        snap
          .current_cwd
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

      let shell_entry = shell_row_entry(
        &rid,
        &sid,
        ShellRowState {
          command: Some(cmd_clone.clone()),
          stdout: None,
          stderr: None,
          exit_code: None,
          duration_ms: 0,
          cwd: Some(resolved_cwd.clone()),
        },
      );

      actor
        .send(SessionCommand::ProcessEvent {
          event: crate::domain::sessions::transition::Input::RowCreated(shell_entry),
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
        Err(crate::infrastructure::shell::ShellStartError::DuplicateRequestId) => {
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

        let mut preview_state = ShellStreamPreviewState::default();
        let mut last_stream_emit = std::time::Instant::now();

        while let Some(chunk) = chunk_rx.recv().await {
          if !chunk.stdout.is_empty() {
            preview_state.append_stdout(&chunk.stdout);
          }
          if !chunk.stderr.is_empty() {
            preview_state.append_stderr(&chunk.stderr);
          }

          let now = std::time::Instant::now();
          if now.duration_since(last_stream_emit).as_millis() < SHELL_STREAM_THROTTLE_MS {
            continue;
          }
          last_stream_emit = now;

          if let Some(actor) = state_ref.get_session(&sid) {
            let updated_entry = shell_row_entry(
              &rid,
              &sid,
              ShellRowState {
                command: Some(cmd_clone.clone()),
                stdout: preview_state.stdout_preview(),
                stderr: preview_state.stderr_preview(),
                exit_code: None,
                duration_ms: 0,
                cwd: Some(resolved_cwd.clone()),
              },
            );
            actor
              .send(SessionCommand::ProcessEvent {
                event: crate::domain::sessions::transition::Input::RowUpdated {
                  row_id: rid.clone(),
                  entry: updated_entry,
                },
              })
              .await;
          }
        }

        let result = match completion_rx.await {
          Ok(result) => result,
          Err(recv_err) => crate::infrastructure::shell::ShellResult {
            stdout: String::new(),
            stderr: format!("Shell execution completion channel failed: {recv_err}"),
            exit_code: None,
            duration_ms: 0,
            outcome: crate::infrastructure::shell::ShellOutcome::Failed,
          },
        };

        let is_error = match result.outcome {
          crate::infrastructure::shell::ShellOutcome::Completed => result.exit_code != Some(0),
          crate::infrastructure::shell::ShellOutcome::Failed
          | crate::infrastructure::shell::ShellOutcome::TimedOut => true,
          crate::infrastructure::shell::ShellOutcome::Canceled => false,
        };
        let _ = is_error; // preserved for future use
        let combined_output = if result.stderr.is_empty() {
          result.stdout.clone()
        } else if result.stdout.is_empty() {
          result.stderr.clone()
        } else {
          format!("{}\n{}", result.stdout, result.stderr)
        };
        let final_output = if combined_output.is_empty() {
          preview_state.combined_preview().unwrap_or_default()
        } else {
          combined_output
        };
        let outcome = match result.outcome {
          crate::infrastructure::shell::ShellOutcome::Completed => ShellExecutionOutcome::Completed,
          crate::infrastructure::shell::ShellOutcome::Failed => ShellExecutionOutcome::Failed,
          crate::infrastructure::shell::ShellOutcome::TimedOut => ShellExecutionOutcome::TimedOut,
          crate::infrastructure::shell::ShellOutcome::Canceled => ShellExecutionOutcome::Canceled,
        };

        if let Some(actor) = state_ref.get_session(&sid) {
          let stdout = if result.stdout.is_empty() {
            (!final_output.is_empty()).then_some(final_output.clone())
          } else {
            Some(result.stdout.clone())
          };
          let stderr = (!result.stderr.is_empty()).then_some(result.stderr.clone());
          let final_entry = shell_row_entry(
            &rid,
            &sid,
            ShellRowState {
              command: Some(cmd_clone.clone()),
              stdout,
              stderr,
              exit_code: result.exit_code,
              duration_ms: result.duration_ms,
              cwd: Some(resolved_cwd.clone()),
            },
          );
          actor
            .send(SessionCommand::ProcessEvent {
              event: crate::domain::sessions::transition::Input::RowUpdated {
                row_id: rid.clone(),
                entry: final_entry,
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
        crate::infrastructure::shell::ShellCancelStatus::Canceled => {}
        crate::infrastructure::shell::ShellCancelStatus::NotFound => {
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
