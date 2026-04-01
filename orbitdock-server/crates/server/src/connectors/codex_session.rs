//! Codex session management
//!
//! Wraps the CodexConnector and handles event forwarding.

use std::sync::Arc;

use codex_protocol::dynamic_tools::{DynamicToolCallOutputContentItem, DynamicToolResponse};
use serde_json::Value;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::{error, info, warn};

use crate::domain::mission_control::executor::execute_mission_tool;
use crate::domain::mission_control::tools::MissionToolContext;
use crate::domain::sessions::session::SessionHandle;
use crate::infrastructure::persistence::{load_mission_by_id, load_mission_issues, PersistCommand};
use crate::runtime::mission_orchestrator::broadcast_mission_delta_by_id;
use crate::runtime::session_actor::SessionActorHandle;
use crate::runtime::session_command_handler::{
  dispatch_connector_event, dispatch_transition_input, handle_session_command, is_turn_ending,
  spawn_interrupt_watchdog,
};
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_runtime_helpers::should_detach_direct_connector_after_send_error;

// Re-export so existing server code doesn't break
pub use orbitdock_connector_codex::session::{
  CodexAction, CodexExecApproval, CodexPatchApproval, CodexSession,
};

struct MissionToolExecutionContext {
  tracker_kind: String,
  context: MissionToolContext,
}

struct DynamicToolCallRequest<'a> {
  session: &'a mut CodexSession,
  handle: &'a SessionHandle,
  state: &'a Arc<SessionRegistry>,
  persist_tx: &'a mpsc::Sender<PersistCommand>,
  session_id: &'a str,
  call_id: String,
  tool_name: String,
  arguments: Value,
}

/// Start the Codex session event forwarding loop.
///
/// The actor owns the `SessionHandle` directly -- no `Arc<Mutex>`.
/// Returns `(SessionActorHandle, mpsc::Sender<CodexAction>)`.
pub fn start_event_loop(
  mut session: CodexSession,
  handle: SessionHandle,
  persist_tx: mpsc::Sender<PersistCommand>,
  state: Arc<SessionRegistry>,
) -> (SessionActorHandle, mpsc::Sender<CodexAction>) {
  let (action_tx, mut action_rx) = mpsc::channel::<CodexAction>(100);
  let (command_tx, mut command_rx) = mpsc::channel::<SessionCommand>(256);

  let snapshot = handle.snapshot_arc();
  let id = handle.id().to_string();
  handle.refresh_snapshot();

  let actor_handle = SessionActorHandle::new(id.clone(), command_tx, snapshot);

  let mut event_rx = session.connector.take_event_rx().unwrap();
  let session_id = session.session_id.clone();

  let mut session_handle = handle;
  let persist = persist_tx.clone();

  tokio::spawn(async move {
    // Watchdog channel for synthetic events (interrupt timeout)
    let (watchdog_tx, mut watchdog_rx) = mpsc::channel(4);
    let mut interrupt_watchdog: Option<JoinHandle<()>> = None;

    'session_loop: loop {
      tokio::select! {
          Some(event) = event_rx.recv() => {
              if is_turn_ending(&event) {
                  if let Some(h) = interrupt_watchdog.take() { h.abort(); }
              }

              if let orbitdock_connector_core::ConnectorEvent::SubagentsUpdated { subagents } = &event {
                  for info in subagents.clone() {
                      let _ = persist
                          .send(PersistCommand::UpsertSubagent {
                              session_id: session_id.clone(),
                              info,
                          })
                          .await;
                  }

                  handle_session_command(
                      SessionCommand::SetSubagents {
                          subagents: subagents.clone(),
                      },
                      &mut session_handle,
                      &persist,
                  )
                  .await;
                  continue;
              }

              if let orbitdock_connector_core::ConnectorEvent::DynamicToolCallRequested {
                  call_id,
                  tool_name,
                  arguments,
              } = &event
              {
                  handle_dynamic_tool_call(DynamicToolCallRequest {
                      session: &mut session,
                      handle: &session_handle,
                      state: &state,
                      persist_tx: &persist,
                      session_id: &session_id,
                      call_id: call_id.clone(),
                      tool_name: tool_name.clone(),
                      arguments: arguments.clone(),
                  })
                  .await;
                  continue;
              }

              // Enrich EnvironmentChanged events with worktree info
              let enriched_event = match &event {
                  orbitdock_connector_core::ConnectorEvent::EnvironmentChanged {
                      cwd: Some(cwd), ..
                  } => {
                      let git_info = crate::domain::git::repo::resolve_git_info(cwd).await;
                      if let Some(ref info) = git_info {
                          let mut input = crate::domain::sessions::transition::Input::from(event);
                          if let crate::domain::sessions::transition::Input::EnvironmentChanged {
                              ref mut repository_root,
                              ref mut is_worktree,
                              ..
                          } = input
                          {
                              *repository_root = Some(info.common_dir_root.clone());
                              *is_worktree = Some(info.is_worktree);
                          }
                          // Dispatch enriched input directly
                          dispatch_transition_input(
                              &session_id, input, &mut session_handle, &persist,
                          ).await;
                          continue;
                      }
                      event
                  }
                  _ => event,
              };

              dispatch_connector_event(
                  &session_id, enriched_event, &mut session_handle, &persist,
              ).await;
          }

          Some(event) = watchdog_rx.recv() => {
              dispatch_connector_event(
                  &session_id, event, &mut session_handle, &persist,
              ).await;
          }

          Some(action) = action_rx.recv() => {
              match action {
                  CodexAction::SteerTurn {
                      content,
                      message_id,
                      images,
                      mentions,
                  } => {
                      match session.connector.steer_turn(&content, &images, &mentions).await {
                          Ok(outcome) => {
                              handle_session_command(
                                  SessionCommand::UpdateSteerOutcome {
                                      message_id: message_id.clone(),
                                      outcome,
                                  },
                                  &mut session_handle,
                                  &persist,
                              ).await;
                              session_handle.broadcast(
                                  orbitdock_protocol::ServerMessage::SteerOutcome {
                                      session_id: session_id.clone(),
                                      message_id,
                                      outcome,
                                  },
                              );
                          }
                          Err(e) => {
                              let should_detach =
                                  should_detach_direct_connector_after_send_error(&e.to_string());
                              if should_detach {
                                  warn!(
                                      component = "codex_connector",
                                      event = "codex.connector.detached_after_fatal_send_error",
                                      session_id = %session_id,
                                      error = %e,
                                      "Detaching direct connector after fatal steer error"
                                  );
                              } else {
                                  error!(
                                      component = "codex_connector",
                                      event = "codex.steer.failed",
                                      session_id = %session_id,
                                      error = %e,
                                      "Steer turn failed"
                                  );
                              }
                              dispatch_connector_event(
                                  &session_id,
                                  orbitdock_connector_core::ConnectorEvent::Error(
                                      format!("Steer failed: {e}"),
                                  ),
                                  &mut session_handle,
                                  &persist,
                              ).await;
                              if should_detach {
                                  break 'session_loop;
                              }
                          }
                      }
                  }
                  CodexAction::Interrupt => {
                      match session.connector.interrupt().await {
                          Ok(()) => {
                              if let Some(h) = interrupt_watchdog.take() { h.abort(); }
                              interrupt_watchdog = Some(spawn_interrupt_watchdog(
                                  watchdog_tx.clone(),
                                  session_id.clone(),
                                  "codex_connector",
                              ));
                          }
                          Err(e) => {
                              error!(
                                  component = "codex_connector",
                                  event = "codex.interrupt.failed",
                                  session_id = %session_id,
                                  error = %e,
                                  "Interrupt failed, injecting error event"
                              );
                              dispatch_connector_event(
                                  &session_id,
                                  orbitdock_connector_core::ConnectorEvent::Error(
                                      format!("Interrupt failed: {e}"),
                                  ),
                                  &mut session_handle,
                                  &persist,
                              ).await;
                          }
                      }
                  }
                  other => {
                      let is_send_action = matches!(&other, CodexAction::SendMessage { .. });
                      if let Err(e) = CodexSession::handle_action(&mut session.connector, other).await {
                          let should_detach = is_send_action
                              && should_detach_direct_connector_after_send_error(&e.to_string());
                          if should_detach {
                              warn!(
                                  component = "codex_connector",
                                  event = "codex.connector.detached_after_fatal_send_error",
                                  session_id = %session_id,
                                  error = %e,
                                  "Detaching direct connector after fatal send error"
                              );
                          } else {
                              error!(
                                  component = "codex_connector",
                                  event = "codex.action.failed",
                                  session_id = %session_id,
                                  error = %e,
                                  "Failed to handle codex action"
                              );
                          }
                          dispatch_connector_event(
                              &session_id,
                              orbitdock_connector_core::ConnectorEvent::Error(
                                  format!("Action failed: {e}"),
                              ),
                              &mut session_handle,
                              &persist,
                          ).await;
                          if should_detach {
                              break 'session_loop;
                          }
                      }
                  }
              }
          }

          Some(cmd) = command_rx.recv() => {
              handle_session_command(cmd, &mut session_handle, &persist).await;
          }

          else => break,
      }
    }

    if let Some(h) = interrupt_watchdog.take() {
      h.abort();
    }
    state.remove_codex_action_tx(&session_id);
    crate::runtime::session_runtime_helpers::mark_direct_session_connector_detached(
      &state,
      &session_id,
      orbitdock_protocol::Provider::Codex,
    )
    .await;

    info!(
        component = "codex_connector",
        event = "codex.event_loop.ended",
        session_id = %session_id,
        "Codex session event loop ended"
    );
  });

  (actor_handle, action_tx)
}

async fn handle_dynamic_tool_call(request: DynamicToolCallRequest<'_>) {
  let DynamicToolCallRequest {
    session,
    handle,
    state,
    persist_tx,
    session_id,
    call_id,
    tool_name,
    arguments,
  } = request;

  let result = execute_dynamic_mission_tool(handle, state, &tool_name, arguments).await;

  let (success, output, blocked, completed_state, pr_url) = match result {
    Ok(result) => (
      result.success,
      result.output,
      result.blocked,
      result.completed_state,
      result.pr_url,
    ),
    Err(error) => (
      false,
      serde_json::json!({ "error": error }).to_string(),
      false,
      None,
      None,
    ),
  };

  if let Err(error) = session
    .connector
    .submit_dynamic_tool_response(
      call_id.clone(),
      DynamicToolResponse {
        content_items: vec![DynamicToolCallOutputContentItem::InputText {
          text: output.clone(),
        }],
        success,
      },
    )
    .await
  {
    error!(
        component = "codex_connector",
        event = "codex.dynamic_tool.response_failed",
        session_id = %session_id,
        call_id = %call_id,
        tool_name = %tool_name,
        error = %error,
        "Failed to submit dynamic tool response"
    );
    return;
  }

  let mission_context = match load_mission_tool_execution_context(handle, state).await {
    Ok(Some(context)) => context,
    Ok(None) => return,
    Err(error) => {
      warn!(
          component = "codex_connector",
          event = "codex.dynamic_tool.side_effect_context_failed",
          session_id = %session_id,
          call_id = %call_id,
          tool_name = %tool_name,
          error = %error,
          "Failed to load mission context for dynamic tool side effects"
      );
      return;
    }
  };

  if let Some(pr_url) = pr_url {
    let _ = persist_tx
      .send(PersistCommand::MissionIssueSetPrUrl {
        mission_id: mission_context.context.mission_id.clone(),
        issue_id: mission_context.context.issue_id.clone(),
        pr_url,
      })
      .await;
    broadcast_mission_delta_by_id(state, &mission_context.context.mission_id).await;
  }

  if blocked {
    let now = chrono::Utc::now().to_rfc3339();
    let _ = persist_tx
      .send(PersistCommand::MissionIssueUpdateState {
        mission_id: mission_context.context.mission_id.clone(),
        issue_id: mission_context.context.issue_id.clone(),
        orchestration_state: "blocked".to_string(),
        session_id: None,
        workspace_id: None,
        attempt: None,
        last_error: Some(Some(output.clone())),
        retry_due_at: None,
        started_at: None,
        completed_at: Some(Some(now)),
      })
      .await;
    broadcast_mission_delta_by_id(state, &mission_context.context.mission_id).await;
  }

  if completed_state.is_some() {
    let now = chrono::Utc::now().to_rfc3339();
    let _ = persist_tx
      .send(PersistCommand::MissionIssueUpdateState {
        mission_id: mission_context.context.mission_id.clone(),
        issue_id: mission_context.context.issue_id.clone(),
        orchestration_state: "completed".to_string(),
        session_id: None,
        workspace_id: None,
        attempt: None,
        last_error: Some(None),
        retry_due_at: Some(None),
        started_at: None,
        completed_at: Some(Some(now)),
      })
      .await;

    crate::runtime::session_mutations::end_session(state, session_id).await;
    broadcast_mission_delta_by_id(state, &mission_context.context.mission_id).await;
  }
}

async fn execute_dynamic_mission_tool(
  handle: &SessionHandle,
  state: &Arc<SessionRegistry>,
  tool_name: &str,
  arguments: Value,
) -> Result<crate::domain::mission_control::executor::MissionToolResult, String> {
  let Some(mission_context) = load_mission_tool_execution_context(handle, state)
    .await
    .map_err(|error| error.to_string())?
  else {
    return Err("Dynamic mission tools require an attached mission context".to_string());
  };

  let tracker = crate::support::api_keys::build_tracker_for_mission(
    &mission_context.context.mission_id,
    &mission_context.tracker_kind,
  )
  .map_err(|error| error.to_string())?;

  Ok(
    execute_mission_tool(
      tracker.as_ref(),
      &mission_context.context,
      tool_name,
      arguments,
    )
    .await,
  )
}

async fn load_mission_tool_execution_context(
  handle: &SessionHandle,
  state: &Arc<SessionRegistry>,
) -> anyhow::Result<Option<MissionToolExecutionContext>> {
  let snapshot = handle.retained_state();
  let Some(mission_id) = snapshot.mission_id else {
    return Ok(None);
  };
  let Some(issue_identifier) = snapshot.issue_identifier else {
    return Ok(None);
  };

  let session_id = handle.id().to_string();
  let db_path = state.db_path().clone();

  tokio::task::spawn_blocking(
    move || -> anyhow::Result<Option<MissionToolExecutionContext>> {
      let conn = rusqlite::Connection::open(db_path)?;
      let Some(mission) = load_mission_by_id(&conn, &mission_id)? else {
        return Ok(None);
      };

      let issues = load_mission_issues(&conn, &mission_id)?;
      let issue = issues
        .into_iter()
        .find(|issue| issue.session_id.as_deref() == Some(session_id.as_str()))
        .or_else(|| {
          load_mission_issues(&conn, &mission_id)
            .ok()
            .and_then(|issues| {
              issues
                .into_iter()
                .find(|issue| issue.issue_identifier == issue_identifier)
            })
        });

      Ok(issue.map(|issue| MissionToolExecutionContext {
        tracker_kind: mission.tracker_kind,
        context: MissionToolContext {
          issue_id: issue.issue_id,
          issue_identifier: issue.issue_identifier,
          mission_id,
        },
      }))
    },
  )
  .await?
}
