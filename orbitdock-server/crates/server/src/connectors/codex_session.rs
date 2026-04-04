//! Codex session management
//!
//! Wraps the CodexConnector and handles event forwarding.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use codex_protocol::dynamic_tools::{DynamicToolCallOutputContentItem, DynamicToolResponse};
use serde_json::Value;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::{error, info, warn};

use crate::domain::codex_tools::{
  execute_codex_workspace_tool, CodexWorkspaceToolContext, CodexWorkspaceToolResult,
};
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

struct DynamicToolExecutionResult {
  success: bool,
  output: String,
  blocked: bool,
  completed_state: Option<String>,
  pr_url: Option<String>,
  has_mission_side_effects: bool,
}

impl DynamicToolExecutionResult {
  fn workspace(success: bool, output: String) -> Self {
    Self {
      success,
      output,
      blocked: false,
      completed_state: None,
      pr_url: None,
      has_mission_side_effects: false,
    }
  }

  fn mission(result: crate::domain::mission_control::executor::MissionToolResult) -> Self {
    Self {
      success: result.success,
      output: result.output,
      blocked: result.blocked,
      completed_state: result.completed_state,
      pr_url: result.pr_url,
      has_mission_side_effects: true,
    }
  }

  fn failure_json(message: String) -> Self {
    Self::workspace(false, serde_json::json!({ "error": message }).to_string())
  }
}

#[derive(Default)]
struct DynamicWorkspaceDiffTracker {
  baseline_files: BTreeMap<PathBuf, Option<String>>,
  last_emitted_diff: Option<String>,
}

impl DynamicWorkspaceDiffTracker {
  fn clear(&mut self) {
    self.baseline_files.clear();
    self.last_emitted_diff = None;
  }

  fn capture_baseline_if_workspace_file_tool(
    &mut self,
    workspace_ctx: &CodexWorkspaceToolContext,
    tool_name: &str,
    arguments: &Value,
  ) {
    if !is_dynamic_workspace_file_change_tool(tool_name) {
      return;
    }
    let Some(path) = resolve_dynamic_tool_path(workspace_ctx, arguments) else {
      return;
    };
    if self.baseline_files.contains_key(&path) {
      return;
    }
    self
      .baseline_files
      .insert(path.clone(), read_text_file_lossy(&path));
  }

  fn render_unified_diff(&self, workspace_ctx: &CodexWorkspaceToolContext) -> Option<String> {
    if self.baseline_files.is_empty() {
      return None;
    }
    let project_root = fs::canonicalize(&workspace_ctx.project_path).ok();
    let mut sections: Vec<String> = Vec::new();

    for (path, baseline_text) in &self.baseline_files {
      let current_text = read_text_file_lossy(path);
      if current_text == *baseline_text {
        continue;
      }

      let rel = relative_display_path(path, project_root.as_deref());
      let old_header = if baseline_text.is_some() {
        format!("a/{rel}")
      } else {
        "/dev/null".to_string()
      };
      let new_header = if current_text.is_some() {
        format!("b/{rel}")
      } else {
        "/dev/null".to_string()
      };
      let before = baseline_text.as_deref().unwrap_or("");
      let after = current_text.as_deref().unwrap_or("");

      let unified = similar::TextDiff::from_lines(before, after)
        .unified_diff()
        .context_radius(3)
        .header(&old_header, &new_header)
        .to_string();

      if unified.trim().is_empty() {
        continue;
      }

      sections.push(format!("diff --git a/{rel} b/{rel}\n{unified}"));
    }

    if sections.is_empty() {
      return None;
    }

    Some(sections.join("\n"))
  }

  fn merge_with_current_turn_diff(&self, current_diff: Option<&str>, dynamic_diff: &str) -> String {
    let Some(current_diff) = current_diff
      .map(str::trim)
      .filter(|value| !value.is_empty())
    else {
      return dynamic_diff.to_string();
    };

    // If the session's current diff already came from this tracker, replace it
    // with the latest recomputed dynamic diff to avoid duplicate hunk growth.
    if self.last_emitted_diff.as_deref() == Some(current_diff) {
      return dynamic_diff.to_string();
    }

    let existing = orbitdock_protocol::TurnDiff {
      turn_id: "dynamic-existing".to_string(),
      diff: current_diff.to_string(),
      token_usage: None,
      snapshot_kind: None,
    };
    orbitdock_protocol::diff_merge::compute_cumulative_diff(&[existing], Some(dynamic_diff))
      .unwrap_or_else(|| dynamic_diff.to_string())
  }

  fn mark_emitted(&mut self, diff: String) {
    self.last_emitted_diff = Some(diff);
  }
}

async fn flush_dynamic_workspace_diff_if_any(
  session_id: &str,
  session_handle: &mut SessionHandle,
  tracker: &mut DynamicWorkspaceDiffTracker,
  persist: &mpsc::Sender<PersistCommand>,
) {
  let workspace_ctx = workspace_tool_context(session_handle);
  let Some(diff) = tracker.render_unified_diff(&workspace_ctx) else {
    return;
  };

  let current_diff = session_handle.retained_state().current_diff;
  let merged_diff = tracker.merge_with_current_turn_diff(current_diff.as_deref(), &diff);
  dispatch_connector_event(
    session_id,
    orbitdock_connector_core::ConnectorEvent::DiffUpdated(merged_diff.clone()),
    session_handle,
    persist,
  )
  .await;
  tracker.mark_emitted(merged_diff);
}

fn is_dynamic_workspace_file_change_tool(tool_name: &str) -> bool {
  matches!(tool_name, "file_write" | "file_edit")
}

fn workspace_tool_context(handle: &SessionHandle) -> CodexWorkspaceToolContext {
  let snapshot = handle.retained_state();
  CodexWorkspaceToolContext {
    project_path: snapshot.project_path,
    current_cwd: snapshot.current_cwd,
  }
}

fn resolve_dynamic_tool_path(
  workspace_ctx: &CodexWorkspaceToolContext,
  arguments: &Value,
) -> Option<PathBuf> {
  let raw_path = arguments.get("path").and_then(Value::as_str)?.trim();
  if raw_path.is_empty() {
    return None;
  }

  let candidate = PathBuf::from(raw_path);
  let mut resolved = if candidate.is_absolute() {
    candidate
  } else {
    let base = workspace_ctx
      .current_cwd
      .as_deref()
      .unwrap_or(workspace_ctx.project_path.as_str());
    Path::new(base).join(candidate)
  };

  if resolved.exists() {
    if let Ok(canonical) = fs::canonicalize(&resolved) {
      resolved = canonical;
    }
  } else if let Some(parent) = resolved.parent() {
    if let Ok(canonical_parent) = fs::canonicalize(parent) {
      if let Some(file_name) = resolved.file_name() {
        resolved = canonical_parent.join(file_name);
      }
    }
  }

  let project_root = fs::canonicalize(&workspace_ctx.project_path).ok();
  if let Some(root) = project_root {
    if !resolved.starts_with(&root) {
      return None;
    }
  }

  Some(resolved)
}

fn read_text_file_lossy(path: &Path) -> Option<String> {
  if !path.exists() || !path.is_file() {
    return None;
  }
  fs::read(path)
    .ok()
    .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
}

fn relative_display_path(path: &Path, project_root: Option<&Path>) -> String {
  let shown = project_root
    .and_then(|root| path.strip_prefix(root).ok())
    .unwrap_or(path)
    .display()
    .to_string();
  shown.replace('\\', "/")
}

struct DynamicToolCallRequest<'a> {
  session: &'a mut CodexSession,
  session_handle: &'a mut SessionHandle,
  dynamic_diff_tracker: &'a mut DynamicWorkspaceDiffTracker,
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
  let mut dynamic_diff_tracker = DynamicWorkspaceDiffTracker::default();

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
              if matches!(event, orbitdock_connector_core::ConnectorEvent::TurnStarted) {
                  dynamic_diff_tracker.clear();
              }
              let clear_dynamic_diff_after_event = matches!(
                  event,
                  orbitdock_connector_core::ConnectorEvent::TurnCompleted
                  | orbitdock_connector_core::ConnectorEvent::TurnAborted { .. }
                  | orbitdock_connector_core::ConnectorEvent::SessionEnded { .. }
              );

              if matches!(
                  event,
                  orbitdock_connector_core::ConnectorEvent::TurnCompleted
                  | orbitdock_connector_core::ConnectorEvent::TurnAborted { .. }
                  | orbitdock_connector_core::ConnectorEvent::SessionEnded { .. }
              ) {
                  flush_dynamic_workspace_diff_if_any(
                      &session_id,
                      &mut session_handle,
                      &mut dynamic_diff_tracker,
                      &persist,
                  ).await;
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
                      session_handle: &mut session_handle,
                      dynamic_diff_tracker: &mut dynamic_diff_tracker,
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
              if clear_dynamic_diff_after_event {
                  dynamic_diff_tracker.clear();
              }
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
    // Apply detach state directly on the handle we own — the actor command
    // channel is part of THIS task's select loop which has already broken, so
    // sending via `actor.send()` would buffer the command but never process it.
    crate::runtime::session_runtime_helpers::apply_connector_detached_directly(
      &mut session_handle,
      &persist,
      &state,
      &session_id,
      orbitdock_protocol::Provider::Codex,
    )
    .await;
    state.remove_codex_action_tx(&session_id);

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
    session_handle,
    dynamic_diff_tracker,
    state,
    persist_tx,
    session_id,
    call_id,
    tool_name,
    arguments,
  } = request;

  let workspace_ctx = workspace_tool_context(session_handle);
  dynamic_diff_tracker.capture_baseline_if_workspace_file_tool(
    &workspace_ctx,
    &tool_name,
    &arguments,
  );

  let result = execute_dynamic_tool(session_handle, state, &tool_name, arguments.clone()).await;
  let DynamicToolExecutionResult {
    success,
    output,
    blocked,
    completed_state,
    pr_url,
    has_mission_side_effects,
  } = result;

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

  if !has_mission_side_effects {
    return;
  }

  let mission_context = match load_mission_tool_execution_context(session_handle, state).await {
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

async fn execute_dynamic_tool(
  handle: &SessionHandle,
  state: &Arc<SessionRegistry>,
  tool_name: &str,
  arguments: Value,
) -> DynamicToolExecutionResult {
  if tool_name.starts_with("mission_") {
    return match execute_dynamic_mission_tool(handle, state, tool_name, arguments).await {
      Ok(result) => DynamicToolExecutionResult::mission(result),
      Err(error) => DynamicToolExecutionResult::failure_json(error),
    };
  }

  let snapshot = handle.retained_state();
  let workspace_ctx = CodexWorkspaceToolContext {
    project_path: snapshot.project_path,
    current_cwd: snapshot.current_cwd,
  };
  match execute_codex_workspace_tool(&workspace_ctx, tool_name, arguments) {
    Some(CodexWorkspaceToolResult { success, output }) => {
      DynamicToolExecutionResult::workspace(success, output)
    }
    None => DynamicToolExecutionResult::failure_json(format!("Unknown dynamic tool: {tool_name}")),
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

#[cfg(test)]
mod tests {
  use super::*;
  use serde_json::json;

  #[test]
  fn dynamic_workspace_tracker_renders_diff_for_existing_file_write() {
    let temp = tempfile::tempdir().expect("tempdir");
    let root = temp.path();
    let target = root.join("note.txt");
    fs::write(&target, "before\n").expect("seed file");

    let ctx = CodexWorkspaceToolContext {
      project_path: root.to_string_lossy().to_string(),
      current_cwd: None,
    };
    let mut tracker = DynamicWorkspaceDiffTracker::default();
    tracker.capture_baseline_if_workspace_file_tool(
      &ctx,
      "file_write",
      &json!({
        "path": "note.txt",
        "content": "after\n",
      }),
    );

    fs::write(&target, "after\n").expect("update file");

    let diff = tracker.render_unified_diff(&ctx).expect("diff");
    assert!(diff.contains("diff --git a/note.txt b/note.txt"));
    assert!(diff.contains("-before"));
    assert!(diff.contains("+after"));
  }

  #[test]
  fn dynamic_workspace_tracker_renders_addition_for_new_file() {
    let temp = tempfile::tempdir().expect("tempdir");
    let root = temp.path();
    let target = root.join("new.txt");

    let ctx = CodexWorkspaceToolContext {
      project_path: root.to_string_lossy().to_string(),
      current_cwd: None,
    };
    let mut tracker = DynamicWorkspaceDiffTracker::default();
    tracker.capture_baseline_if_workspace_file_tool(
      &ctx,
      "file_write",
      &json!({
        "path": "new.txt",
        "content": "hello\n",
      }),
    );

    fs::write(&target, "hello\n").expect("write file");

    let diff = tracker.render_unified_diff(&ctx).expect("diff");
    assert!(diff.contains("diff --git a/new.txt b/new.txt"));
    assert!(diff.contains("--- /dev/null"));
    assert!(diff.contains("+++ b/new.txt"));
    assert!(diff.contains("+hello"));
  }

  #[test]
  fn resolve_dynamic_tool_path_rejects_project_escape() {
    let temp = tempfile::tempdir().expect("tempdir");
    let root = temp.path();
    let ctx = CodexWorkspaceToolContext {
      project_path: root.to_string_lossy().to_string(),
      current_cwd: None,
    };

    let resolved = resolve_dynamic_tool_path(&ctx, &json!({ "path": "../outside.txt" }));
    assert!(resolved.is_none());
  }

  #[test]
  fn dynamic_workspace_tracker_keeps_full_diff_content() {
    let temp = tempfile::tempdir().expect("tempdir");
    let root = temp.path();
    let target = root.join("big.txt");
    let before = "a\n".repeat(5_000);
    let after = "b\n".repeat(5_000);
    fs::write(&target, &before).expect("seed file");

    let ctx = CodexWorkspaceToolContext {
      project_path: root.to_string_lossy().to_string(),
      current_cwd: None,
    };
    let mut tracker = DynamicWorkspaceDiffTracker::default();
    tracker.capture_baseline_if_workspace_file_tool(
      &ctx,
      "file_write",
      &json!({
        "path": "big.txt",
        "content": after,
      }),
    );

    fs::write(&target, &after).expect("update file");
    let diff = tracker.render_unified_diff(&ctx).expect("diff");
    assert!(!diff.contains("dynamic turn diff truncated"));
    assert!(diff.contains("diff --git a/big.txt b/big.txt"));
  }
}
