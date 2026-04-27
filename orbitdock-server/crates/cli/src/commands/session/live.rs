use std::time::Duration;

use orbitdock_protocol::{
  ClientMessage, ServerMessage, SessionStatus, ToolApprovalDecision, WorkStatus,
};

use crate::cli::{ApprovalDecision, Effort};
use crate::client::config::ClientConfig;
use crate::client::ws::WsClient;
use crate::error::{
  CliError, EXIT_CLIENT_ERROR, EXIT_CONNECTION_ERROR, EXIT_SERVER_ERROR, EXIT_SUCCESS,
};
use crate::output::{truncate, Output};

use super::bootstrap::{bootstrap_session_subscription, fetch_conversation_snapshot, ws_connect};
use super::presentation::{pending_request_id, work_status_str};

pub(crate) async fn send_message(
  config: &ClientConfig,
  output: &Output,
  session_id: &str,
  content: &str,
  model: Option<&str>,
  effort: Option<&Effort>,
  no_wait: bool,
) -> i32 {
  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  if let Err(err) = bootstrap_session_subscription(config, &mut ws, session_id).await {
    output.print_error(&err);
    return EXIT_SERVER_ERROR;
  }

  let replay_cursor = match fetch_conversation_snapshot(config, session_id, 50).await {
    Ok(snapshot) => snapshot.replay_cursor,
    Err(err) => {
      output.print_error(&err);
      return EXIT_SERVER_ERROR;
    }
  };

  if let Err(err) = super::bootstrap::subscribe_session_surface(
    &mut ws,
    session_id,
    orbitdock_protocol::SessionSurface::Conversation,
    Some(replay_cursor),
  )
  .await
  {
    output.print_error(&err);
    return EXIT_CONNECTION_ERROR;
  }

  if let Err(e) = ws
    .send(&ClientMessage::SendMessage {
      session_id: session_id.to_string(),
      content: content.to_string(),
      model: model.map(str::to_string),
      effort: effort.map(|e| e.as_str().to_string()),
      skills: vec![],
      images: vec![],
      mentions: vec![],
    })
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

  if no_wait {
    if output.json {
      output.print_json(&serde_json::json!({"sent": true, "session_id": session_id}));
    } else {
      println!("Message sent.");
    }
    return EXIT_SUCCESS;
  }

  stream_turn_events(&mut ws, output).await
}

pub(crate) async fn approve_tool(
  config: &ClientConfig,
  output: &Output,
  session_id: &str,
  decision: &ApprovalDecision,
  message: Option<&str>,
  request_id: Option<&str>,
) -> i32 {
  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  let session = match bootstrap_session_subscription(config, &mut ws, session_id).await {
    Ok(session) => session,
    Err(err) => {
      output.print_error(&err);
      return EXIT_SERVER_ERROR;
    }
  };

  let resolved_id = match request_id {
    Some(id) => id.to_string(),
    None => match pending_request_id(&session) {
      Some(id) => id.to_string(),
      None => {
        output.print_error(&CliError::new(
          "no_pending_approval",
          "No pending approval. Use --request-id to specify one.",
        ));
        return EXIT_CLIENT_ERROR;
      }
    },
  };

  if let Err(e) = ws
    .send(&ClientMessage::ApproveTool {
      session_id: session_id.to_string(),
      request_id: resolved_id.clone(),
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
    })
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

  loop {
    match ws.recv_timeout(Duration::from_secs(10)).await {
      Ok(Some(ServerMessage::ApprovalDecisionResult {
        ref request_id,
        ref outcome,
        ..
      }))
        if *request_id == resolved_id =>
      {
        if output.json {
          output.print_json(&serde_json::json!({
              "request_id": request_id,
              "outcome": outcome,
          }));
        } else {
          let bold = console::Style::new().bold();
          println!(
            "{} {} ({})",
            bold.apply_to("Approval:"),
            outcome,
            request_id
          );
        }
        return EXIT_SUCCESS;
      }
      Ok(Some(ServerMessage::Error { code, message, .. })) => {
        output.print_error(&CliError::new(code, message));
        return EXIT_SERVER_ERROR;
      }
      Ok(Some(_)) => continue,
      Ok(None) => {
        output.print_error(&CliError::connection(
          "Timed out waiting for approval result",
        ));
        return EXIT_CONNECTION_ERROR;
      }
      Err(e) => {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

pub(crate) async fn answer_question(
  config: &ClientConfig,
  output: &Output,
  session_id: &str,
  answer: &str,
  request_id: Option<&str>,
) -> i32 {
  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  let session = match bootstrap_session_subscription(config, &mut ws, session_id).await {
    Ok(session) => session,
    Err(err) => {
      output.print_error(&err);
      return EXIT_SERVER_ERROR;
    }
  };

  let resolved_id = match request_id {
    Some(id) => id.to_string(),
    None => match pending_request_id(&session) {
      Some(id) => id.to_string(),
      None => {
        output.print_error(&CliError::new(
          "no_pending_question",
          "No pending question. Use --request-id to specify one.",
        ));
        return EXIT_CLIENT_ERROR;
      }
    },
  };

  if let Err(e) = ws
    .send(&ClientMessage::AnswerQuestion {
      session_id: session_id.to_string(),
      request_id: resolved_id.clone(),
      answer: answer.to_string(),
      question_id: None,
      answers: None,
    })
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

  loop {
    match ws.recv_timeout(Duration::from_secs(10)).await {
      Ok(Some(ServerMessage::ApprovalDecisionResult {
        ref request_id,
        ref outcome,
        ..
      }))
        if *request_id == resolved_id =>
      {
        if output.json {
          output.print_json(&serde_json::json!({
              "request_id": request_id,
              "outcome": outcome,
          }));
        } else {
          println!("Answer submitted ({outcome})");
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
      Err(e) => {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

pub(crate) async fn interrupt(config: &ClientConfig, output: &Output, session_id: &str) -> i32 {
  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  if let Err(err) = bootstrap_session_subscription(config, &mut ws, session_id).await {
    output.print_error(&err);
    return EXIT_SERVER_ERROR;
  }

  if let Err(e) = ws
    .send(&ClientMessage::InterruptSession {
      session_id: session_id.to_string(),
    })
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

  loop {
    match ws.recv_timeout(Duration::from_secs(5)).await {
      Ok(Some(ServerMessage::SessionDelta { changes, .. })) => {
        if let Some(status) = changes.work_status.as_ref() {
          if *status != WorkStatus::Working {
            if output.json {
              output.print_json(
                &serde_json::json!({"interrupted": true, "work_status": work_status_str(status)}),
              );
            } else {
              println!("Session interrupted. Status: {}", work_status_str(status));
            }
            return EXIT_SUCCESS;
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
      Err(e) => {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

pub(crate) async fn end_session(config: &ClientConfig, output: &Output, session_id: &str) -> i32 {
  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  if let Err(err) = bootstrap_session_subscription(config, &mut ws, session_id).await {
    output.print_error(&err);
    return EXIT_SERVER_ERROR;
  }

  if let Err(e) = ws
    .send(&ClientMessage::EndSession {
      session_id: session_id.to_string(),
    })
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

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
      Err(e) => {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

pub(crate) async fn steer(
  config: &ClientConfig,
  output: &Output,
  session_id: &str,
  content: &str,
) -> i32 {
  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  if let Err(err) = bootstrap_session_subscription(config, &mut ws, session_id).await {
    output.print_error(&err);
    return EXIT_SERVER_ERROR;
  }

  if let Err(e) = ws
    .send(&ClientMessage::SteerTurn {
      session_id: session_id.to_string(),
      content: content.to_string(),
      images: vec![],
      mentions: vec![],
    })
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

  if output.json {
    output.print_json(&serde_json::json!({"steered": true, "session_id": session_id}));
  } else {
    println!("Guidance injected.");
  }
  EXIT_SUCCESS
}

pub(crate) async fn compact(config: &ClientConfig, output: &Output, session_id: &str) -> i32 {
  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  if let Err(err) = bootstrap_session_subscription(config, &mut ws, session_id).await {
    output.print_error(&err);
    return EXIT_SERVER_ERROR;
  }

  if let Err(e) = ws
    .send(&ClientMessage::CompactContext {
      session_id: session_id.to_string(),
    })
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

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
      Err(e) => {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

pub(crate) async fn undo(config: &ClientConfig, output: &Output, session_id: &str) -> i32 {
  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  if let Err(err) = bootstrap_session_subscription(config, &mut ws, session_id).await {
    output.print_error(&err);
    return EXIT_SERVER_ERROR;
  }

  if let Err(e) = ws
    .send(&ClientMessage::UndoLastTurn {
      session_id: session_id.to_string(),
    })
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

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
            message.map(|m| format!(" {m}")).unwrap_or_default()
          );
        } else {
          eprintln!(
            "Undo failed.{}",
            message.map(|m| format!(" {m}")).unwrap_or_default()
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
      Err(e) => {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

pub(crate) async fn rollback(
  config: &ClientConfig,
  output: &Output,
  session_id: &str,
  turns: u32,
) -> i32 {
  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  if let Err(err) = bootstrap_session_subscription(config, &mut ws, session_id).await {
    output.print_error(&err);
    return EXIT_SERVER_ERROR;
  }

  if let Err(e) = ws
    .send(&ClientMessage::RollbackTurns {
      session_id: session_id.to_string(),
      num_turns: turns,
    })
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

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
      Err(e) => {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}

pub(crate) async fn rename(
  config: &ClientConfig,
  output: &Output,
  session_id: &str,
  name: &str,
) -> i32 {
  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  if let Err(e) = ws
    .send(&ClientMessage::RenameSession {
      session_id: session_id.to_string(),
      name: Some(name.to_string()),
    })
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

  match ws.recv_timeout(Duration::from_secs(5)).await {
    Ok(Some(ServerMessage::Error { code, message, .. })) => {
      output.print_error(&CliError::new(code, message));
      return EXIT_SERVER_ERROR;
    }
    Err(e) => {
      output.print_error(&CliError::connection(e.to_string()));
      return EXIT_CONNECTION_ERROR;
    }
    _ => {}
  }

  if output.json {
    output.print_json(&serde_json::json!({"renamed": true, "name": name}));
  } else {
    println!("Session renamed to: {name}");
  }
  EXIT_SUCCESS
}

async fn stream_turn_events(ws: &mut WsClient, output: &Output) -> i32 {
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
                let role = super::presentation::format_row_type_summary(&entry.row);
                let content = truncate(
                  &orbitdock_protocol::conversation_contracts::extract_row_content_str_summary(
                    &entry.row,
                  ),
                  120,
                );
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
      Err(e) => {
        output.print_error(&CliError::connection(e.to_string()));
        return EXIT_CONNECTION_ERROR;
      }
    }
  }
}
