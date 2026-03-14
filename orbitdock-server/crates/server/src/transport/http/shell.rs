use std::sync::Arc;

use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use orbitdock_protocol::conversation_contracts::{
    ConversationRow, ConversationRowEntry, SystemRow,
};
use orbitdock_protocol::{ServerMessage, ShellExecutionOutcome};
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

fn build_shell_row_entry(
    request_id: &str,
    session_id: &str,
    command: &str,
    ts_millis: u128,
    sequence: u64,
) -> ConversationRowEntry {
    ConversationRowEntry {
        session_id: session_id.to_string(),
        sequence,
        turn_id: None,
        row: ConversationRow::System(SystemRow {
            id: request_id.to_string(),
            content: command.to_string(),
            turn_id: None,
            timestamp: Some(iso_timestamp(ts_millis)),
            is_streaming: false,
            images: vec![],
        }),
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
    let shell_entry = build_shell_row_entry(&request_id, &session_id, &body.command, ts_millis, 0);
    actor
        .send(SessionCommand::ProcessEvent {
            event: Input::RowCreated(shell_entry),
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
                let updated_entry = ConversationRowEntry {
                    session_id: sid.clone(),
                    sequence: 0,
                    turn_id: None,
                    row: ConversationRow::System(SystemRow {
                        id: rid.clone(),
                        content: streamed_output.clone(),
                        turn_id: None,
                        timestamp: None,
                        is_streaming: false,
                        images: vec![],
                    }),
                };
                actor
                    .send(SessionCommand::ProcessEvent {
                        event: Input::RowUpdated {
                            row_id: rid.clone(),
                            entry: updated_entry,
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
        let (final_output, _is_error, outcome, result) =
            finalize_shell_result(result, streamed_output);

        if let Some(actor) = state_ref.get_session(&sid) {
            let final_entry = ConversationRowEntry {
                session_id: sid.clone(),
                sequence: 0,
                turn_id: None,
                row: ConversationRow::System(SystemRow {
                    id: rid.clone(),
                    content: final_output,
                    turn_id: None,
                    timestamp: None,
                    is_streaming: false,
                    images: vec![],
                }),
            };
            actor
                .send(SessionCommand::ProcessEvent {
                    event: Input::RowUpdated {
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
