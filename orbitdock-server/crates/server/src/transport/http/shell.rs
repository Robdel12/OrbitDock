use std::sync::Arc;

use axum::{
  extract::{Path, State},
  http::StatusCode,
  Json,
};
use orbitdock_protocol::conversation_contracts::{
  ConversationRow, ConversationRowEntry, RenderHints, ShellCommandRow, ShellCommandRowKind,
};
use orbitdock_protocol::{ServerMessage, ShellExecutionOutcome};
use serde::{Deserialize, Serialize};

use super::{session_not_found_error, AcceptedResponse, ApiErrorResponse};
use crate::domain::sessions::transition::Input;
use crate::infrastructure::shell::{ShellCancelStatus, ShellOutcome, ShellResult};
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::transport::shell_streaming::{ShellStreamPreviewState, SHELL_STREAM_THROTTLE_MS};

const DEFAULT_SHELL_TIMEOUT_SECS: u64 = 120;

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

fn build_shell_row_entry(
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

fn finalize_shell_result(
  result: ShellResult,
  streamed_output: Option<String>,
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
    streamed_output.unwrap_or_default()
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
  let command = body.command.clone();
  let timeout_secs = body.timeout_secs.unwrap_or(DEFAULT_SHELL_TIMEOUT_SECS);

  actor
    .send(SessionCommand::Broadcast {
      msg: ServerMessage::ShellStarted {
        session_id: session_id.clone(),
        request_id: request_id.clone(),
        command: command.clone(),
      },
    })
    .await;

  let shell_entry = build_shell_row_entry(
    &request_id,
    &session_id,
    ShellRowState {
      command: Some(command.clone()),
      stdout: None,
      stderr: None,
      exit_code: None,
      duration_ms: 0,
      cwd: Some(resolved_cwd.clone()),
    },
  );
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
      command.clone(),
      resolved_cwd.clone(),
      timeout_secs,
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
  let command_for_task = command.clone();
  let resolved_cwd_for_task = resolved_cwd.clone();
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
        let updated_entry = build_shell_row_entry(
          &rid,
          &sid,
          ShellRowState {
            command: Some(command_for_task.clone()),
            stdout: preview_state.stdout_preview(),
            stderr: preview_state.stderr_preview(),
            exit_code: None,
            duration_ms: 0,
            cwd: Some(resolved_cwd_for_task.clone()),
          },
        );
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
      finalize_shell_result(result, preview_state.combined_preview());

    if let Some(actor) = state_ref.get_session(&sid) {
      let stdout = if result.stdout.is_empty() {
        (!final_output.is_empty()).then_some(final_output.clone())
      } else {
        Some(result.stdout.clone())
      };
      let stderr = (!result.stderr.is_empty()).then_some(result.stderr.clone());
      let final_entry = build_shell_row_entry(
        &rid,
        &sid,
        ShellRowState {
          command: Some(command_for_task.clone()),
          stdout,
          stderr,
          exit_code: result.exit_code,
          duration_ms: result.duration_ms,
          cwd: Some(resolved_cwd_for_task.clone()),
        },
      );
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
