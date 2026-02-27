use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::sync::mpsc;
use tracing::info;

use orbitdock_protocol::{
    new_id, ClientMessage, MessageType, ServerMessage, ShellExecutionOutcome,
};

use crate::session_command::SessionCommand;
use crate::session_utils::iso_timestamp;
use crate::state::SessionRegistry;
use crate::websocket::{send_json, OutboundMessage};

pub(crate) async fn handle(
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
