use std::sync::Arc;

use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use orbitdock_protocol::{Message, MessageType, ServerMessage, ShellExecutionOutcome};
use serde::{Deserialize, Serialize};

use crate::domain::sessions::transition::Input;
use crate::infrastructure::shell::{ShellCancelStatus, ShellOutcome, ShellResult};
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::support::session_time::iso_timestamp;

use super::{session_not_found_error, AcceptedResponse, ApiErrorResponse};

const DEFAULT_SHELL_TIMEOUT_SECS: u64 = 120;
const SHELL_STREAM_THROTTLE_MS: u128 = 120;

#[derive(Debug, Deserialize)]
pub struct ExecuteShellRequest {
    pub command: String,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub timeout_secs: Option<u64>,
}

#[derive(Debug, Serialize)]
pub struct ExecuteShellResponse {
    pub request_id: String,
    pub accepted: bool,
}

#[derive(Debug, Deserialize)]
pub struct CancelShellRequest {
    pub request_id: String,
}

fn resolve_shell_cwd(
    explicit_cwd: Option<&str>,
    current_cwd: Option<&str>,
    project_path: &str,
) -> String {
    explicit_cwd
        .map(str::to_owned)
        .or_else(|| current_cwd.map(str::to_owned))
        .unwrap_or_else(|| project_path.to_string())
}

fn build_shell_message(
    request_id: &str,
    session_id: &str,
    command: &str,
    ts_millis: u128,
) -> Message {
    Message {
        id: request_id.to_string(),
        session_id: session_id.to_string(),
        sequence: None,
        message_type: MessageType::Shell,
        content: command.to_string(),
        tool_name: None,
        tool_input: None,
        tool_output: None,
        is_error: false,
        is_in_progress: true,
        timestamp: iso_timestamp(ts_millis),
        duration_ms: None,
        images: vec![],
    }
}

fn finalize_shell_result(
    result: ShellResult,
    streamed_output: String,
) -> (String, bool, ShellExecutionOutcome, ShellResult) {
    let is_error = match result.outcome {
        ShellOutcome::Completed => result.exit_code != Some(0),
        ShellOutcome::Failed | ShellOutcome::TimedOut => true,
        ShellOutcome::Canceled => false,
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
        ShellOutcome::Completed => ShellExecutionOutcome::Completed,
        ShellOutcome::Failed => ShellExecutionOutcome::Failed,
        ShellOutcome::TimedOut => ShellExecutionOutcome::TimedOut,
        ShellOutcome::Canceled => ShellExecutionOutcome::Canceled,
    };

    (final_output, is_error, outcome, result)
}

pub async fn execute_shell_endpoint(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<ExecuteShellRequest>,
) -> Result<Json<ExecuteShellResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    let actor = state
        .get_session(&session_id)
        .ok_or_else(|| session_not_found_error(&session_id))?;
    let snapshot = actor.snapshot();
    let resolved_cwd = resolve_shell_cwd(
        body.cwd.as_deref(),
        snapshot.current_cwd.as_deref(),
        &snapshot.project_path,
    );

    let request_id = orbitdock_protocol::new_id();

    actor
        .send(SessionCommand::Broadcast {
            msg: ServerMessage::ShellStarted {
                session_id: session_id.clone(),
                request_id: request_id.clone(),
                command: body.command.clone(),
            },
        })
        .await;

    let ts_millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let shell_message = build_shell_message(&request_id, &session_id, &body.command, ts_millis);
    actor
        .send(SessionCommand::ProcessEvent {
            event: Input::MessageCreated(shell_message),
        })
        .await;

    let shell_execution = state
        .shell_service()
        .start(
            request_id.clone(),
            session_id.clone(),
            body.command,
            resolved_cwd,
            body.timeout_secs.unwrap_or(DEFAULT_SHELL_TIMEOUT_SECS),
        )
        .map_err(|_| {
            (
                StatusCode::CONFLICT,
                Json(ApiErrorResponse {
                    code: "shell_duplicate_request_id",
                    error: format!("Shell request {} is already active", request_id),
                }),
            )
        })?;

    let state_ref = state.clone();
    let sid = session_id.clone();
    let rid = request_id.clone();
    tokio::spawn(async move {
        let mut chunk_rx = shell_execution.chunk_rx;
        let completion_rx = shell_execution.completion_rx;
        let mut streamed_output = String::new();
        let mut last_stream_emit = std::time::Instant::now();

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
                        event: Input::MessageUpdated {
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
            Err(recv_err) => ShellResult {
                stdout: String::new(),
                stderr: format!("Shell execution completion channel failed: {recv_err}"),
                exit_code: None,
                duration_ms: 0,
                outcome: ShellOutcome::Failed,
            },
        };
        let (final_output, is_error, outcome, result) =
            finalize_shell_result(result, streamed_output);

        if let Some(actor) = state_ref.get_session(&sid) {
            actor
                .send(SessionCommand::ProcessEvent {
                    event: Input::MessageUpdated {
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

    Ok(Json(ExecuteShellResponse {
        request_id,
        accepted: true,
    }))
}

pub async fn cancel_shell_endpoint(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<CancelShellRequest>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    if state.get_session(&session_id).is_none() {
        return Err(session_not_found_error(&session_id));
    }

    match state.shell_service().cancel(&session_id, &body.request_id) {
        ShellCancelStatus::Canceled => Ok(Json(AcceptedResponse { accepted: true })),
        ShellCancelStatus::NotFound => Err((
            StatusCode::NOT_FOUND,
            Json(ApiErrorResponse {
                code: "shell_not_found",
                error: format!(
                    "No active shell request {} found for session {}",
                    body.request_id, session_id
                ),
            }),
        )),
    }
}

#[cfg(test)]
mod tests {
    use orbitdock_protocol::ShellExecutionOutcome;

    use super::{
        build_shell_message, finalize_shell_result, resolve_shell_cwd, DEFAULT_SHELL_TIMEOUT_SECS,
    };
    use crate::infrastructure::shell::{ShellOutcome, ShellResult};

    #[test]
    fn shell_cwd_resolution_prefers_explicit_then_runtime_then_project_path() {
        assert_eq!(
            resolve_shell_cwd(Some("/tmp/explicit"), Some("/tmp/runtime"), "/tmp/project"),
            "/tmp/explicit"
        );
        assert_eq!(
            resolve_shell_cwd(None, Some("/tmp/runtime"), "/tmp/project"),
            "/tmp/runtime"
        );
        assert_eq!(
            resolve_shell_cwd(None, None, "/tmp/project"),
            "/tmp/project"
        );
        assert_eq!(DEFAULT_SHELL_TIMEOUT_SECS, 120);
    }

    #[test]
    fn shell_result_finalization_prefers_completed_output_and_maps_outcome() {
        let result = ShellResult {
            stdout: "out".into(),
            stderr: "err".into(),
            exit_code: Some(1),
            duration_ms: 42,
            outcome: ShellOutcome::Completed,
        };

        let (final_output, is_error, outcome, result) =
            finalize_shell_result(result, "streamed".into());

        assert_eq!(final_output, "out\nerr");
        assert!(is_error);
        assert_eq!(outcome, ShellExecutionOutcome::Completed);
        assert_eq!(result.duration_ms, 42);
    }

    #[test]
    fn shell_message_builder_creates_in_progress_shell_message() {
        let message = build_shell_message("req-1", "session-1", "ls", 123);

        assert_eq!(message.id, "req-1");
        assert_eq!(message.session_id, "session-1");
        assert_eq!(message.message_type, orbitdock_protocol::MessageType::Shell);
        assert_eq!(message.content, "ls");
        assert!(message.is_in_progress);
        assert!(!message.is_error);
        assert_eq!(message.sequence, None);
    }
}
