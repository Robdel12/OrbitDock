//! Codex session management
//!
//! Wraps the CodexConnector and handles event forwarding.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use codex_protocol::dynamic_tools::{DynamicToolCallOutputContentItem, DynamicToolResponse};
use orbitdock_connector_core::{ConnectorOutput, ConnectorRuntimeDirective, ConnectorStateEvent};
use orbitdock_protocol::Provider;
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
use crate::runtime::session_actor::SessionActorHandle;
use crate::runtime::session_command_handler::{
  abort_interrupt_watchdog, classify_connector_output, dispatch_connector_event,
  dispatch_transition_input, emit_connector_error, handle_connector_transport_effect,
  handle_session_command, is_turn_ending, restart_interrupt_watchdog, ConnectorDispatch,
};
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_runtime_helpers::{
  apply_connector_detached_directly, rebind_session_as_passive_actor, run_connector_loop_step,
  should_detach_direct_connector_after_send_error, spawn_connector_cleanup_monitor,
  ConnectorLoopControl,
};
#[path = "codex_session_dynamic_tools.rs"]
mod codex_session_dynamic_tools;
use self::codex_session_dynamic_tools::{
  apply_dynamic_tool_post_response_effects, DynamicToolExecutionResult,
  DynamicToolPostResponseContext,
};

// Re-export so existing server code doesn't break
pub use orbitdock_connector_codex::session::{
  CodexAction, CodexExecApproval, CodexPatchApproval, CodexSession,
};

struct MissionToolExecutionContext {
  tracker_kind: String,
  context: MissionToolContext,
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
    ConnectorStateEvent::DiffUpdated(merged_diff.clone()),
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

  let actor_handle = SessionActorHandle::new(id.clone(), command_tx.clone(), snapshot);

  let mut output_rx = session.connector.take_output_rx().unwrap();
  let session_id = session.session_id.clone();

  let mut session_handle = handle;
  let persist = persist_tx.clone();
  let mut dynamic_diff_tracker = DynamicWorkspaceDiffTracker::default();

  // Spawn cleanup monitor FIRST — guarantees cleanup even on panic/cancel
  let cleanup_guard = spawn_connector_cleanup_monitor(
    session_id.clone(),
    persist_tx,
    Arc::clone(&state),
    Provider::Codex,
  );

  tokio::spawn(async move {
    // Hold the guard — if we do not disarm it, fallback cleanup runs.
    let mut cleanup_guard = cleanup_guard;

    // Watchdog channel for synthetic events (interrupt timeout)
    let (watchdog_tx, mut watchdog_rx) = mpsc::channel::<ConnectorStateEvent>(4);
    let mut interrupt_watchdog: Option<JoinHandle<()>> = None;

    loop {
      tokio::select! {
          Some(output) = output_rx.recv() => {
              let control = run_connector_loop_step(
                  "codex_connector",
                  "codex.event_loop.step_panicked",
                  &session_id,
                  "output_rx",
                  async {
                      let turn_ending = matches!(
                          &output,
                          ConnectorOutput::State(event) if is_turn_ending(event.as_ref())
                      );
                      let event = match classify_connector_output(output) {
                          ConnectorDispatch::TransportEffect(effect) => {
                              handle_connector_transport_effect(effect, &state, &session_id).await;
                              return ConnectorLoopControl::Continue;
                          }
                          ConnectorDispatch::RuntimeDirective(ConnectorRuntimeDirective::DynamicToolCallRequested {
                              call_id,
                              tool_name,
                              arguments,
                          }) => {
                              handle_dynamic_tool_call(DynamicToolCallRequest {
                                  session: &mut session,
                                  session_handle: &mut session_handle,
                                  dynamic_diff_tracker: &mut dynamic_diff_tracker,
                                  state: &state,
                                  persist_tx: &persist,
                                  session_id: &session_id,
                                  call_id,
                                  tool_name,
                                  arguments,
                              })
                              .await;
                              return ConnectorLoopControl::Continue;
                          }
                          ConnectorDispatch::RuntimeDirective(ConnectorRuntimeDirective::HookSessionId(hook_sid)) => {
                              warn!(
                                  component = "codex_connector",
                                  event = "codex.directive.unexpected",
                                  session_id = %session_id,
                                  hook_session_id = %hook_sid,
                                  "Codex emitted an unexpected hook-session directive"
                              );
                              return ConnectorLoopControl::Continue;
                          }
                          ConnectorDispatch::State(event) => *event,
                      };

                      if turn_ending {
                          abort_interrupt_watchdog(&mut interrupt_watchdog);
                      }

                      if matches!(event, ConnectorStateEvent::TurnStarted) {
                          dynamic_diff_tracker.clear();
                      }
                      let clear_dynamic_diff_after_event = matches!(
                          event,
                          ConnectorStateEvent::TurnCompleted
                          | ConnectorStateEvent::TurnAborted { .. }
                          | ConnectorStateEvent::SessionEnded { .. }
                      );

                      if matches!(
                          event,
                          ConnectorStateEvent::TurnCompleted
                          | ConnectorStateEvent::TurnAborted { .. }
                          | ConnectorStateEvent::SessionEnded { .. }
                      ) {
                          flush_dynamic_workspace_diff_if_any(
                              &session_id,
                              &mut session_handle,
                              &mut dynamic_diff_tracker,
                              &persist,
                          ).await;
                      }

                      let enriched_event = match &event {
                          ConnectorStateEvent::EnvironmentChanged {
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
                                  dispatch_transition_input(
                                          &session_id, input, &mut session_handle, &persist,
                                  ).await;
                                  return ConnectorLoopControl::Continue;
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
                      ConnectorLoopControl::Continue
                  },
              ).await;
              if matches!(control, ConnectorLoopControl::Break) {
                  break;
              }
          }

          Some(event) = watchdog_rx.recv() => {
              let control = run_connector_loop_step(
                  "codex_connector",
                  "codex.event_loop.step_panicked",
                  &session_id,
                  "watchdog_rx",
                  async {
                      dispatch_connector_event(
                          &session_id, event, &mut session_handle, &persist,
                      ).await;
                      ConnectorLoopControl::Continue
                  },
              ).await;
              if matches!(control, ConnectorLoopControl::Break) {
                  break;
              }
          }

          Some(action) = action_rx.recv() => {
              let control = run_connector_loop_step(
                  "codex_connector",
                  "codex.event_loop.step_panicked",
                  &session_id,
                  "action_rx",
                  async {
                      match action {
                          CodexAction::SteerTurn {
                              content,
                              message_id,
                              images,
                              mentions,
                          } => {
                              let connector = session.connector.clone();
                              let command_tx = command_tx.clone();
                              let steer_session_id = session_id.clone();
                              tokio::spawn(async move {
                                  match connector.steer_turn(&content, &images, &mentions).await {
                                      Ok(outcome) => {
                                          let _ = command_tx
                                              .send(SessionCommand::UpdateSteerOutcome {
                                                  message_id,
                                                  outcome,
                                              })
                                              .await;
                                      }
                                      Err(e) => {
                                          error!(
                                              component = "codex_connector",
                                              event = "codex.steer.failed",
                                              session_id = %steer_session_id,
                                              error = %e,
                                              "Steer turn failed"
                                          );
                                      }
                                  }
                              });
                          }
                          CodexAction::Interrupt => {
                              match session.connector.interrupt().await {
                                  Ok(()) => {
                                      restart_interrupt_watchdog(
                                          &mut interrupt_watchdog,
                                          watchdog_tx.clone(),
                                          &session_id,
                                          "codex_connector",
                                      );
                                  }
                                  Err(e) => {
                                      error!(
                                          component = "codex_connector",
                                          event = "codex.interrupt.failed",
                                          session_id = %session_id,
                                          error = %e,
                                          "Interrupt failed, injecting error event"
                                      );
                                      emit_connector_error(
                                          &session_id,
                                          format!("Interrupt failed: {e}"),
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
                                  emit_connector_error(
                                      &session_id,
                                      format!("Action failed: {e}"),
                                      &mut session_handle,
                                      &persist,
                                  ).await;
                                  if should_detach {
                                      return ConnectorLoopControl::Break;
                                  }
                              }
                          }
                      }

                      ConnectorLoopControl::Continue
                  },
              ).await;
              if matches!(control, ConnectorLoopControl::Break) {
                  break;
              }
          }

          Some(cmd) = command_rx.recv() => {
              let control = run_connector_loop_step(
                  "codex_connector",
                  "codex.event_loop.step_panicked",
                  &session_id,
                  "command_rx",
                  async {
                      handle_session_command(cmd, &mut session_handle, &persist).await;
                      ConnectorLoopControl::Continue
                  },
              ).await;
              if matches!(control, ConnectorLoopControl::Break) {
                  break;
              }
          }

          else => break,
      }
    }

    abort_interrupt_watchdog(&mut interrupt_watchdog);

    apply_connector_detached_directly(&mut session_handle, &persist, &session_id, Provider::Codex)
      .await;
    state.remove_codex_action_tx(&session_id);
    rebind_session_as_passive_actor(&state, session_handle);
    cleanup_guard.disarm();

    info!(
        component = "codex_connector",
        event = "codex.event_loop.ended",
        session_id = %session_id,
        "Codex session event loop ended; cleanup was applied and a passive actor was rebound"
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
    post_response_effects,
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

  apply_dynamic_tool_post_response_effects(
    session_handle,
    state,
    persist_tx,
    DynamicToolPostResponseContext {
      session_id,
      call_id: &call_id,
      tool_name: tool_name.as_str(),
      output: output.as_str(),
      post_response_effects,
    },
  )
  .await;
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
#[path = "codex_session_tests.rs"]
mod tests;
