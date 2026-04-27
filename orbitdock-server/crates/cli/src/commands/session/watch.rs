use std::collections::HashSet;
use std::time::Duration;

use orbitdock_protocol::{ServerMessage, SessionSurface};

use crate::client::config::ClientConfig;
use crate::error::{CliError, EXIT_CONNECTION_ERROR, EXIT_SUCCESS};
use crate::output::{truncate, Output};

use super::bootstrap::ws_connect;
use super::presentation::{
  format_row_type_summary, print_conversation_snapshot_rows, provider_str, work_status_str,
};

pub(crate) fn stream_turn_should_exit(
  status: &orbitdock_protocol::WorkStatus,
  saw_turn_activity: bool,
) -> bool {
  match status {
    orbitdock_protocol::WorkStatus::Working => false,
    orbitdock_protocol::WorkStatus::Waiting => saw_turn_activity,
    _ => true,
  }
}

pub(crate) async fn watch(
  rest: &crate::client::rest::RestClient,
  config: &ClientConfig,
  output: &Output,
  session_id: &str,
  filter: &[String],
  timeout_secs: Option<u64>,
) -> i32 {
  let detail = match rest
    .get::<orbitdock_protocol::SessionDetailSnapshot>(&format!("/api/sessions/{session_id}/detail"))
    .await
    .into_result()
  {
    Ok(snapshot) => snapshot,
    Err((code, err)) => {
      output.print_error(&err);
      return code;
    }
  };
  let conversation = match rest
    .get::<orbitdock_protocol::ConversationSnapshotPage>(&format!(
      "/api/sessions/{session_id}/conversation?limit=200"
    ))
    .await
    .into_result()
  {
    Ok(snapshot) => snapshot,
    Err((code, err)) => {
      output.print_error(&err);
      return code;
    }
  };

  let Some(mut ws) = ws_connect(config, output).await else {
    return EXIT_CONNECTION_ERROR;
  };

  if let Err(e) = ws
    .subscribe_session_surface(session_id, SessionSurface::Detail, Some(detail.revision))
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }
  if let Err(e) = ws
    .subscribe_session_surface(
      session_id,
      SessionSurface::Conversation,
      Some(conversation.replay_cursor),
    )
    .await
  {
    output.print_error(&CliError::connection(e.to_string()));
    return EXIT_CONNECTION_ERROR;
  }

  if output.json {
    output.print_json(&serde_json::json!({
        "type": "bootstrap_detail",
        "snapshot": detail,
    }));
    output.print_json(&serde_json::json!({
        "type": "bootstrap_conversation",
        "snapshot": conversation,
    }));
  } else {
    let bold = console::Style::new().bold();
    println!(
      "{} {} ({} / {})",
      bold.apply_to("Watching:"),
      session_id,
      provider_str(&detail.session.provider),
      work_status_str(&detail.session.work_status)
    );
    let mut seen_row_ids = HashSet::new();
    print_conversation_snapshot_rows(&conversation, &mut seen_row_ids);
    println!("Press Ctrl+C to stop.\n");
  }

  let timeout = timeout_secs
    .map(Duration::from_secs)
    .unwrap_or(Duration::from_secs(u64::MAX / 2));

  loop {
    match ws.recv_timeout(timeout).await {
      Ok(Some(ref msg)) => {
        if !filter.is_empty() {
          let event_type = event_type_name(msg);
          if !filter.iter().any(|f| event_type.contains(f.as_str())) {
            continue;
          }
        }

        if output.json {
          output.print_json(msg);
        } else {
          print_watch_event(msg);
        }

        if matches!(msg, ServerMessage::SessionEnded { .. }) {
          return EXIT_SUCCESS;
        }
      }
      Ok(None) => {
        if !output.json {
          println!("\nConnection closed.");
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

fn event_type_name(msg: &ServerMessage) -> &'static str {
  match msg {
    ServerMessage::Hello { .. } => "hello",
    ServerMessage::SessionsSummaryInvalidated { .. } => "sessions_summary_invalidated",
    ServerMessage::SessionDelta { .. } => "session_delta",
    ServerMessage::SessionSurfaceInvalidated { .. } => "session_surface_invalidated",
    ServerMessage::ConversationRowsChanged { .. } => "conversation_rows_changed",
    ServerMessage::ApprovalRequested { .. } => "approval_requested",
    ServerMessage::ApprovalDecisionResult { .. } => "approval_decision_result",
    ServerMessage::TokensUpdated { .. } => "tokens_updated",
    ServerMessage::SessionEnded { .. } => "session_ended",
    ServerMessage::SessionForked { .. } => "session_forked",
    ServerMessage::ContextCompacted { .. } => "context_compacted",
    ServerMessage::UndoStarted { .. } => "undo_started",
    ServerMessage::UndoCompleted { .. } => "undo_completed",
    ServerMessage::ThreadRolledBack { .. } => "thread_rolled_back",
    ServerMessage::ShellStarted { .. } => "shell_started",
    ServerMessage::ShellOutput { .. } => "shell_output",
    ServerMessage::TurnDiffSnapshot { .. } => "turn_diff_snapshot",
    ServerMessage::RateLimitEvent { .. } => "rate_limit_event",
    ServerMessage::PromptSuggestion { .. } => "prompt_suggestion",
    ServerMessage::Error { .. } => "error",
    ServerMessage::ServerInfo { .. } => "server_info",
    ServerMessage::ModelsList { .. } => "models_list",
    ServerMessage::ReviewCommentCreated { .. } => "review_comment_created",
    ServerMessage::ReviewCommentUpdated { .. } => "review_comment_updated",
    ServerMessage::ReviewCommentDeleted { .. } => "review_comment_deleted",
    ServerMessage::ReviewCommentsList { .. } => "review_comments_list",
    ServerMessage::WorktreeCreated { .. } => "worktree_created",
    ServerMessage::WorktreeRemoved { .. } => "worktree_removed",
    ServerMessage::WorktreeStatusChanged { .. } => "worktree_status_changed",
    ServerMessage::WorktreeError { .. } => "worktree_error",
    ServerMessage::WorktreesList { .. } => "worktrees_list",
    ServerMessage::CodexAccountStatus { .. } => "codex_account_status",
    ServerMessage::CodexAccountUpdated { .. } => "codex_account_updated",
    ServerMessage::CodexLoginChatgptStarted { .. } => "codex_login_started",
    ServerMessage::CodexLoginChatgptCompleted { .. } => "codex_login_completed",
    ServerMessage::CodexLoginChatgptCanceled { .. } => "codex_login_canceled",
    ServerMessage::ClaudeCapabilities { .. } => "claude_capabilities",
    ServerMessage::FilesPersisted { .. } => "files_persisted",
    ServerMessage::McpToolsList { .. } => "mcp_tools_list",
    ServerMessage::McpStartupUpdate { .. } => "mcp_startup_update",
    ServerMessage::McpStartupComplete { .. } => "mcp_startup_complete",
    ServerMessage::SkillsList { .. } => "skills_list",
    ServerMessage::SkillsUpdateAvailable { .. } => "skills_update_available",
    ServerMessage::ActiveSessionsInvalidated { .. } => "active_sessions_invalidated",
    ServerMessage::ArchivedSessionsInvalidated { .. } => "archived_sessions_invalidated",
    ServerMessage::MissionsInvalidated { .. } => "missions_invalidated",
    ServerMessage::MissionHeartbeat { .. } => "mission_heartbeat",
    ServerMessage::MissionInvalidated { .. } => "mission_invalidated",
    ServerMessage::SteerOutcome { .. } => "steer_outcome",
    ServerMessage::UpdateAvailable { .. } => "update_available",
    ServerMessage::TerminalCreated { .. } => "terminal_created",
    ServerMessage::TerminalExited { .. } => "terminal_exited",
    ServerMessage::ToolPtyAttached { .. } => "tool_pty_attached",
    ServerMessage::ToolPtyDetached { .. } => "tool_pty_detached",
    ServerMessage::ToolPtyExited { .. } => "tool_pty_exited",
  }
}

fn print_watch_event(msg: &ServerMessage) {
  let dim = console::Style::new().dim();
  let bold = console::Style::new().bold();

  match msg {
    ServerMessage::Hello { hello } => {
      println!(
        "{} version {} (min client {})",
        dim.apply_to("hello"),
        hello.server_version,
        hello.minimum_client_version
      );
    }
    ServerMessage::SessionDelta { changes, .. } => {
      if let Some(status) = &changes.work_status {
        println!(
          "{} work_status -> {}",
          dim.apply_to("delta"),
          work_status_str(status)
        );
      }
      if let Some(Some(name)) = &changes.custom_name {
        println!("{} name -> {name}", dim.apply_to("delta"));
      }
      if let Some(Some(summary)) = &changes.summary {
        println!("{} summary -> {summary}", dim.apply_to("delta"));
      }
    }
    ServerMessage::ConversationRowsChanged { upserted, .. } => {
      for entry in upserted {
        let role = format_row_type_summary(&entry.row);
        let content = truncate(
          &orbitdock_protocol::conversation_contracts::extract_row_content_str_summary(&entry.row),
          120,
        );
        println!("{} [{role}] {content}", bold.apply_to("+row"));
      }
    }
    ServerMessage::ApprovalRequested { request, .. } => {
      let coral = console::Style::new().red().bold();
      println!(
        "{} {} — {}",
        coral.apply_to("approval"),
        request.tool_name.as_deref().unwrap_or("unknown"),
        request.id
      );
    }
    ServerMessage::ApprovalDecisionResult {
      outcome,
      request_id,
      ..
    } => {
      println!("{} {outcome} ({request_id})", dim.apply_to("decision"));
    }
    ServerMessage::TokensUpdated { usage, .. } => {
      let fill = usage.context_fill_percent();
      println!(
        "{} {fill:.0}% ({} in / {} out)",
        dim.apply_to("tokens"),
        usage.input_tokens,
        usage.output_tokens
      );
    }
    ServerMessage::SessionEnded { reason, .. } => {
      println!("{} {reason}", bold.apply_to("ended"));
    }
    ServerMessage::ContextCompacted { .. } => {
      println!("{}", dim.apply_to("context compacted"));
    }
    ServerMessage::UndoCompleted { success, .. } => {
      println!("{} success={success}", dim.apply_to("undo"));
    }
    ServerMessage::ShellStarted { command, .. } => {
      println!("{} {command}", bold.apply_to("shell"));
    }
    ServerMessage::ShellOutput {
      stdout,
      stderr,
      exit_code,
      ..
    } => {
      if !stdout.is_empty() {
        print!("{stdout}");
      }
      if !stderr.is_empty() {
        eprint!("{stderr}");
      }
      if let Some(code) = exit_code {
        println!("{} exit {code}", dim.apply_to("shell"));
      }
    }
    ServerMessage::Error { code, message, .. } => {
      let red = console::Style::new().red();
      println!("{} [{code}] {message}", red.apply_to("error"));
    }
    _ => {
      println!("{} {}", dim.apply_to("event"), event_type_name(msg));
    }
  }
}
