use std::time::Duration;

use orbitdock_protocol::{
  conversation_contracts::{extract_row_content_str_summary, ConversationRowEntry},
  ImageInput, MentionInput, ServerMessage, SessionDetailSnapshot, SessionStatus, SkillInput,
  ToolApprovalDecision, WorkStatus,
};
use serde::{Deserialize, Serialize};

use crate::cli::{ApprovalDecision, Effort};
use crate::client::config::ClientConfig;
use crate::client::rest::RestClient;
use crate::client::ws::WsClient;
use crate::error::{
  CliError, EXIT_CLIENT_ERROR, EXIT_CONNECTION_ERROR, EXIT_SERVER_ERROR, EXIT_SUCCESS,
};
use crate::output::{truncate, Output};

use super::bootstrap::{subscribe_session_surface, ws_connect};
use super::presentation::{format_row_type_summary, pending_request_id, work_status_str};

#[derive(Debug, Serialize)]
struct SendSessionMessageRequest {
  content: String,
  model: Option<String>,
  effort: Option<String>,
  skills: Vec<SkillInput>,
  images: Vec<ImageInput>,
  mentions: Vec<MentionInput>,
}

#[derive(Debug, Serialize, Deserialize)]
struct SendMessageResponse {
  accepted: bool,
  row: ConversationRowEntry,
  session_detail_snapshot: Option<SessionDetailSnapshot>,
}

#[derive(Debug, Serialize)]
struct SteerTurnRequest {
  content: String,
  images: Vec<ImageInput>,
  mentions: Vec<MentionInput>,
}

#[derive(Debug, Serialize, Deserialize)]
struct SteerTurnResponse {
  accepted: bool,
  row: ConversationRowEntry,
  session_detail_snapshot: Option<SessionDetailSnapshot>,
}

#[derive(Debug, Serialize)]
struct ApproveToolRequest {
  decision: ToolApprovalDecision,
  message: Option<String>,
  interrupt: Option<bool>,
  updated_input: Option<serde_json::Value>,
}

#[derive(Debug, Serialize)]
struct AnswerQuestionRequest {
  answer: String,
  question_id: Option<String>,
  answers: std::collections::HashMap<String, Vec<String>>,
}

#[derive(Debug, Serialize, Deserialize)]
struct ApprovalDecisionResponse {
  session_id: String,
  request_id: String,
  outcome: String,
  active_request_id: Option<String>,
  approval_version: u64,
  session_detail_snapshot: Option<SessionDetailSnapshot>,
}

#[derive(Debug, Serialize, Deserialize)]
struct AcceptedResponse {
  accepted: bool,
  session_detail_snapshot: Option<SessionDetailSnapshot>,
}

#[derive(Debug, Serialize)]
struct RollbackTurnsRequest {
  num_turns: u32,
}

#[derive(Debug, Serialize)]
struct RenameSessionRequest {
  name: Option<String>,
}

pub(crate) async fn send_message(
  rest: &RestClient,
  config: &ClientConfig,
  output: &Output,
  session_id: &str,
  content: &str,
  model: Option<&str>,
  effort: Option<&Effort>,
  no_wait: bool,
) -> i32 {
  let response = match rest
    .post_json::<_, SendMessageResponse>(
      &format!("/api/sessions/{session_id}/conversation/messages"),
      &SendSessionMessageRequest {
        content: content.to_string(),
        model: model.map(str::to_string),
        effort: effort.map(|value| value.as_str().to_string()),
        skills: vec![],
        images: vec![],
        mentions: vec![],
      },
    )
    .await
    .into_result()
  {
    Ok(response) => response,
    Err((code, err)) => {
      output.print_error(&err);
      return code;
    }
  };

  if no_wait {
    if output.json {
      output.print_json(&serde_json::json!({"sent": true, "session_id": session_id}));
    } else {
      println!("Message sent.");
    }
    return EXIT_SUCCESS;
  }

  if !output.json {
    print_row_summary(&response.row);
  } else {
    output.print_json(&response);
  }

  let Some(mut ws) = subscribe_turn_followup(
    config,
    output,
    session_id,
    response
      .session_detail_snapshot
      .as_ref()
      .map(|snapshot| snapshot.revision),
  )
  .await
  else {
    return EXIT_CONNECTION_ERROR;
  };

  stream_turn_events(&mut ws, output).await
}

pub(crate) async fn approve_tool(
  rest: &RestClient,
  output: &Output,
  session_id: &str,
  decision: &ApprovalDecision,
  message: Option<&str>,
  request_id: Option<&str>,
) -> i32 {
  let resolved_id = match resolve_pending_request_id(
    rest,
    output,
    session_id,
    request_id,
    "no_pending_approval",
    "No pending approval. Use --request-id to specify one.",
  )
  .await
  {
    Ok(request_id) => request_id,
    Err(code) => return code,
  };

  let response = match rest
    .post_json::<_, ApprovalDecisionResponse>(
      &format!("/api/sessions/{session_id}/approvals/requests/{resolved_id}/decision"),
      &ApproveToolRequest {
        decision: match decision {
          ApprovalDecision::Approved => ToolApprovalDecision::Approved,
          ApprovalDecision::ApprovedForSession => ToolApprovalDecision::ApprovedForSession,
          ApprovalDecision::ApprovedAlways => ToolApprovalDecision::ApprovedAlways,
          ApprovalDecision::Denied => ToolApprovalDecision::Denied,
          ApprovalDecision::Abort => ToolApprovalDecision::Abort,
        },
        message: message.map(str::to_string),
        interrupt: None,
        updated_input: None,
      },
    )
    .await
    .into_result()
  {
    Ok(response) => response,
    Err((code, err)) => {
      output.print_error(&err);
      return code;
    }
  };

  if output.json {
    output.print_json(&serde_json::json!({
      "request_id": response.request_id,
      "outcome": response.outcome,
    }));
  } else {
    let bold = console::Style::new().bold();
    println!(
      "{} {} ({})",
      bold.apply_to("Approval:"),
      response.outcome,
      response.request_id
    );
  }

  EXIT_SUCCESS
}

pub(crate) async fn answer_question(
  rest: &RestClient,
  output: &Output,
  session_id: &str,
  answer: &str,
  request_id: Option<&str>,
) -> i32 {
  let resolved_id = match resolve_pending_request_id(
    rest,
    output,
    session_id,
    request_id,
    "no_pending_question",
    "No pending question. Use --request-id to specify one.",
  )
  .await
  {
    Ok(request_id) => request_id,
    Err(code) => return code,
  };

  let response = match rest
    .post_json::<_, ApprovalDecisionResponse>(
      &format!("/api/sessions/{session_id}/questions/requests/{resolved_id}/answer"),
      &AnswerQuestionRequest {
        answer: answer.to_string(),
        question_id: None,
        answers: std::collections::HashMap::new(),
      },
    )
    .await
    .into_result()
  {
    Ok(response) => response,
    Err((code, err)) => {
      output.print_error(&err);
      return code;
    }
  };

  if output.json {
    output.print_json(&serde_json::json!({
      "request_id": response.request_id,
      "outcome": response.outcome,
    }));
  } else {
    println!("Answer submitted ({})", response.outcome);
  }

  EXIT_SUCCESS
}

pub(crate) async fn interrupt(
  rest: &RestClient,
  config: &ClientConfig,
  output: &Output,
  session_id: &str,
) -> i32 {
  let response = match post_accepted(
    rest,
    &format!("/api/sessions/{session_id}/controls/stop-active-turn"),
  )
  .await
  {
    Ok(response) => response,
    Err((code, err)) => {
      output.print_error(&err);
      return code;
    }
  };

  if let Some(snapshot) = response.session_detail_snapshot.as_ref() {
    if snapshot.session.work_status != WorkStatus::Working {
      return print_interrupt_success(output, &snapshot.session.work_status);
    }
  }

  let Some(mut ws) = subscribe_detail_followup(
    config,
    output,
    session_id,
    response
      .session_detail_snapshot
      .as_ref()
      .map(|snapshot| snapshot.revision),
  )
  .await
  else {
    return EXIT_CONNECTION_ERROR;
  };

  loop {
    match ws.recv_timeout(Duration::from_secs(5)).await {
      Ok(Some(ServerMessage::SessionDelta { changes, .. })) => {
        if let Some(status) = changes.work_status.as_ref() {
          if *status != WorkStatus::Working {
            return print_interrupt_success(output, status);
          }
        }
      }
      Ok(Some(ServerMessage::Error { code, message, .. })) => {
        output.print_error(&CliError::new(code, message));
        return EXIT_SERVER_ERROR;
      }
      Ok(Some(_)) => continue,
      Ok(None) => {
        if output.json {
          output.print_json(&serde_json::json!({"interrupted": true}));
        } else {
          println!("Interrupt sent.");
        }
        return EXIT_SUCCESS;
      }
      Err(error) => {
        output.print_error(&CliError::connection(error.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

pub(crate) async fn end_session(
  rest: &RestClient,
  config: &ClientConfig,
  output: &Output,
  session_id: &str,
) -> i32 {
  let response =
    match post_accepted(rest, &format!("/api/sessions/{session_id}/lifecycle/end")).await {
      Ok(response) => response,
      Err((code, err)) => {
        output.print_error(&err);
        return code;
      }
    };

  if let Some(snapshot) = response.session_detail_snapshot.as_ref() {
    let ended = snapshot.session.status == SessionStatus::Ended
      || snapshot.session.work_status == WorkStatus::Ended;
    if ended {
      if output.json {
        output.print_json(&serde_json::json!({"ended": true, "reason": "user_requested"}));
      } else {
        println!("Session ended: user_requested");
      }
      return EXIT_SUCCESS;
    }
  }

  let Some(mut ws) = subscribe_detail_followup(
    config,
    output,
    session_id,
    response
      .session_detail_snapshot
      .as_ref()
      .map(|snapshot| snapshot.revision),
  )
  .await
  else {
    return EXIT_CONNECTION_ERROR;
  };

  loop {
    match ws.recv_timeout(Duration::from_secs(10)).await {
      Ok(Some(ServerMessage::SessionEnded { reason, .. })) => {
        if output.json {
          output.print_json(&serde_json::json!({"ended": true, "reason": reason}));
        } else {
          println!("Session ended: {reason}");
        }
        return EXIT_SUCCESS;
      }
      Ok(Some(ServerMessage::SessionDelta { changes, .. })) => {
        let ended = matches!(changes.status, Some(SessionStatus::Ended))
          || matches!(changes.work_status, Some(WorkStatus::Ended));
        if ended {
          if output.json {
            output.print_json(&serde_json::json!({"ended": true, "reason": "user_requested"}));
          } else {
            println!("Session ended: user_requested");
          }
          return EXIT_SUCCESS;
        }
      }
      Ok(Some(ServerMessage::Error { code, message, .. })) => {
        output.print_error(&CliError::new(code, message));
        return EXIT_SERVER_ERROR;
      }
      Ok(Some(_)) => continue,
      Ok(None) => {
        if output.json {
          output.print_json(&serde_json::json!({"ended": true}));
        } else {
          println!("End request sent.");
        }
        return EXIT_SUCCESS;
      }
      Err(error) => {
        output.print_error(&CliError::connection(error.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

pub(crate) async fn steer(
  rest: &RestClient,
  output: &Output,
  session_id: &str,
  content: &str,
) -> i32 {
  let response = match rest
    .post_json::<_, SteerTurnResponse>(
      &format!("/api/sessions/{session_id}/conversation/steer"),
      &SteerTurnRequest {
        content: content.to_string(),
        images: vec![],
        mentions: vec![],
      },
    )
    .await
    .into_result()
  {
    Ok(response) => response,
    Err((code, err)) => {
      output.print_error(&err);
      return code;
    }
  };

  let _ = response;
  if output.json {
    output.print_json(&serde_json::json!({"steered": true, "session_id": session_id}));
  } else {
    println!("Guidance injected.");
  }
  EXIT_SUCCESS
}

pub(crate) async fn compact(
  rest: &RestClient,
  config: &ClientConfig,
  output: &Output,
  session_id: &str,
) -> i32 {
  let response = match post_accepted(
    rest,
    &format!("/api/sessions/{session_id}/controls/compact-context"),
  )
  .await
  {
    Ok(response) => response,
    Err((code, err)) => {
      output.print_error(&err);
      return code;
    }
  };

  let Some(mut ws) = subscribe_detail_followup(
    config,
    output,
    session_id,
    response
      .session_detail_snapshot
      .as_ref()
      .map(|snapshot| snapshot.revision),
  )
  .await
  else {
    return EXIT_CONNECTION_ERROR;
  };

  loop {
    match ws.recv_timeout(Duration::from_secs(60)).await {
      Ok(Some(ServerMessage::ContextCompacted { .. })) => {
        if output.json {
          output.print_json(&serde_json::json!({"compacted": true}));
        } else {
          println!("Context compacted.");
        }
        return EXIT_SUCCESS;
      }
      Ok(Some(ServerMessage::Error { code, message, .. })) => {
        output.print_error(&CliError::new(code, message));
        return EXIT_SERVER_ERROR;
      }
      Ok(Some(_)) => continue,
      Ok(None) => {
        output.print_error(&CliError::connection("Timed out waiting for compaction"));
        return EXIT_CONNECTION_ERROR;
      }
      Err(error) => {
        output.print_error(&CliError::connection(error.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

pub(crate) async fn undo(
  rest: &RestClient,
  config: &ClientConfig,
  output: &Output,
  session_id: &str,
) -> i32 {
  let response = match post_accepted(
    rest,
    &format!("/api/sessions/{session_id}/controls/undo-last-turn"),
  )
  .await
  {
    Ok(response) => response,
    Err((code, err)) => {
      output.print_error(&err);
      return code;
    }
  };

  let Some(mut ws) = subscribe_detail_followup(
    config,
    output,
    session_id,
    response
      .session_detail_snapshot
      .as_ref()
      .map(|snapshot| snapshot.revision),
  )
  .await
  else {
    return EXIT_CONNECTION_ERROR;
  };

  loop {
    match ws.recv_timeout(Duration::from_secs(30)).await {
      Ok(Some(ServerMessage::UndoCompleted {
        success, message, ..
      })) => {
        if output.json {
          output.print_json(&serde_json::json!({"undone": success, "message": message}));
        } else if success {
          println!(
            "Undo complete.{}",
            message.map(|value| format!(" {value}")).unwrap_or_default()
          );
        } else {
          eprintln!(
            "Undo failed.{}",
            message.map(|value| format!(" {value}")).unwrap_or_default()
          );
        }
        return if success {
          EXIT_SUCCESS
        } else {
          EXIT_SERVER_ERROR
        };
      }
      Ok(Some(ServerMessage::UndoStarted { .. })) => continue,
      Ok(Some(ServerMessage::Error { code, message, .. })) => {
        output.print_error(&CliError::new(code, message));
        return EXIT_SERVER_ERROR;
      }
      Ok(Some(_)) => continue,
      Ok(None) => {
        output.print_error(&CliError::connection("Timed out waiting for undo"));
        return EXIT_CONNECTION_ERROR;
      }
      Err(error) => {
        output.print_error(&CliError::connection(error.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

pub(crate) async fn rollback(
  rest: &RestClient,
  config: &ClientConfig,
  output: &Output,
  session_id: &str,
  turns: u32,
) -> i32 {
  let response = match rest
    .post_json::<_, AcceptedResponse>(
      &format!("/api/sessions/{session_id}/controls/rollback-turns"),
      &RollbackTurnsRequest { num_turns: turns },
    )
    .await
    .into_result()
  {
    Ok(response) => response,
    Err((code, err)) => {
      output.print_error(&err);
      return code;
    }
  };

  let Some(mut ws) = subscribe_detail_followup(
    config,
    output,
    session_id,
    response
      .session_detail_snapshot
      .as_ref()
      .map(|snapshot| snapshot.revision),
  )
  .await
  else {
    return EXIT_CONNECTION_ERROR;
  };

  loop {
    match ws.recv_timeout(Duration::from_secs(30)).await {
      Ok(Some(ServerMessage::ThreadRolledBack { num_turns, .. })) => {
        if output.json {
          output.print_json(&serde_json::json!({"rolled_back": num_turns}));
        } else {
          println!("Rolled back {num_turns} turn(s).");
        }
        return EXIT_SUCCESS;
      }
      Ok(Some(ServerMessage::Error { code, message, .. })) => {
        output.print_error(&CliError::new(code, message));
        return EXIT_SERVER_ERROR;
      }
      Ok(Some(_)) => continue,
      Ok(None) => {
        output.print_error(&CliError::connection("Timed out"));
        return EXIT_CONNECTION_ERROR;
      }
      Err(error) => {
        output.print_error(&CliError::connection(error.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

pub(crate) async fn rename(
  rest: &RestClient,
  output: &Output,
  session_id: &str,
  name: &str,
) -> i32 {
  match rest
    .patch_json::<_, AcceptedResponse>(
      &format!("/api/sessions/{session_id}/detail/name"),
      &RenameSessionRequest {
        name: Some(name.to_string()),
      },
    )
    .await
    .into_result()
  {
    Ok(_) => {
      if output.json {
        output.print_json(&serde_json::json!({"renamed": true, "name": name}));
      } else {
        println!("Session renamed to: {name}");
      }
      EXIT_SUCCESS
    }
    Err((code, err)) => {
      output.print_error(&err);
      code
    }
  }
}

async fn resolve_pending_request_id(
  rest: &RestClient,
  output: &Output,
  session_id: &str,
  request_id: Option<&str>,
  error_code: &'static str,
  error_message: &'static str,
) -> Result<String, i32> {
  if let Some(request_id) = request_id {
    return Ok(request_id.to_string());
  }

  match rest
    .get::<SessionDetailSnapshot>(&format!("/api/sessions/{session_id}/detail"))
    .await
    .into_result()
  {
    Ok(snapshot) => match pending_request_id(&snapshot.session) {
      Some(request_id) => Ok(request_id.to_string()),
      None => {
        output.print_error(&CliError::new(error_code, error_message));
        Err(EXIT_CLIENT_ERROR)
      }
    },
    Err((code, err)) => {
      output.print_error(&err);
      Err(code)
    }
  }
}

async fn post_accepted(rest: &RestClient, path: &str) -> Result<AcceptedResponse, (i32, CliError)> {
  rest
    .post_json::<_, AcceptedResponse>(path, &serde_json::json!({}))
    .await
    .into_result()
}

async fn subscribe_detail_followup(
  config: &ClientConfig,
  output: &Output,
  session_id: &str,
  since_revision: Option<u64>,
) -> Option<WsClient> {
  let mut ws = ws_connect(config, output).await?;
  if let Err(err) = subscribe_session_surface(
    &mut ws,
    session_id,
    orbitdock_protocol::SessionSurface::Detail,
    since_revision,
  )
  .await
  {
    output.print_error(&err);
    return None;
  }
  Some(ws)
}

async fn subscribe_turn_followup(
  config: &ClientConfig,
  output: &Output,
  session_id: &str,
  since_revision: Option<u64>,
) -> Option<WsClient> {
  let mut ws = subscribe_detail_followup(config, output, session_id, since_revision).await?;
  if let Err(err) = subscribe_session_surface(
    &mut ws,
    session_id,
    orbitdock_protocol::SessionSurface::Conversation,
    since_revision,
  )
  .await
  {
    output.print_error(&err);
    return None;
  }
  Some(ws)
}

fn print_row_summary(row: &ConversationRowEntry) {
  let summary = row.to_summary();
  let role = format_row_type_summary(&summary.row);
  let content = truncate(&extract_row_content_str_summary(&summary.row), 120);
  if content.is_empty() {
    println!("Message sent.");
  } else {
    println!("[{role}] {content}");
  }
}

fn print_interrupt_success(output: &Output, status: &WorkStatus) -> i32 {
  if output.json {
    output.print_json(
      &serde_json::json!({"interrupted": true, "work_status": work_status_str(status)}),
    );
  } else {
    println!("Session interrupted. Status: {}", work_status_str(status));
  }
  EXIT_SUCCESS
}

pub(crate) async fn stream_turn_events(ws: &mut WsClient, output: &Output) -> i32 {
  let timeout = Duration::from_secs(300);
  let mut saw_turn_activity = false;

  loop {
    match ws.recv_timeout(timeout).await {
      Ok(Some(ref msg)) => {
        if output.json {
          output.print_json(msg);
        }
        match msg {
          ServerMessage::ConversationRowsChanged { upserted, .. } => {
            if !upserted.is_empty() {
              saw_turn_activity = true;
            }
            if !output.json {
              for entry in upserted {
                let role = format_row_type_summary(&entry.row);
                let content = truncate(&extract_row_content_str_summary(&entry.row), 120);
                if !content.is_empty() {
                  println!("[{role}] {content}");
                }
              }
            }
          }
          ServerMessage::SessionDelta { changes, .. } => {
            if changes.work_status.is_some() || changes.last_message.is_some() {
              saw_turn_activity = true;
            }
            if !output.json {
              let dim = console::Style::new().dim();
              if let Some(status) = &changes.work_status {
                println!(
                  "{} work_status -> {}",
                  dim.apply_to("delta"),
                  work_status_str(status)
                );
                if super::watch::stream_turn_should_exit(status, saw_turn_activity) {
                  return EXIT_SUCCESS;
                }
              }
              if let Some(Some(name)) = &changes.custom_name {
                println!("{} name -> {name}", dim.apply_to("delta"));
              }
              if let Some(Some(summary)) = &changes.summary {
                println!("{} summary -> {summary}", dim.apply_to("delta"));
              }
            } else if let Some(status) = &changes.work_status {
              if super::watch::stream_turn_should_exit(status, saw_turn_activity) {
                return EXIT_SUCCESS;
              }
            }
          }
          ServerMessage::SessionEnded { .. } => {
            if output.json {
              return EXIT_SUCCESS;
            }
          }
          ServerMessage::Error { code, message, .. } => {
            output.print_error(&CliError::new(code, message));
            return EXIT_SERVER_ERROR;
          }
          _ => {}
        }
      }
      Ok(None) => return EXIT_SUCCESS,
      Err(error) => {
        output.print_error(&CliError::connection(error.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}
