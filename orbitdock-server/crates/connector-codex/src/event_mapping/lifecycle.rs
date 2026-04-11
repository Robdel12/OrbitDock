use super::{row_updated_output, state_output, ConnectorOutputs};
use crate::runtime::{thinking_row_entry, EnvironmentTracker, ReasoningEventTracker};
use codex_protocol::openai_models::ReasoningEffort;
use codex_protocol::protocol::{SessionConfiguredEvent, TurnAbortedEvent};
use orbitdock_connector_core::ConnectorStateEvent;
use std::collections::HashMap;
use std::sync::Arc;

async fn take_pending_deltas(
  delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
) -> Vec<(String, String)> {
  let mut buffers = delta_buffers.lock().await;
  let deltas = buffers
    .iter()
    .map(|(k, v)| (k.clone(), v.clone()))
    .collect();
  buffers.clear();
  deltas
}

async fn reset_reasoning_tracker(
  reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
) {
  let mut tracker = reasoning_tracker.lock().await;
  tracker.reset_for_turn();
}

fn pending_delta_outputs(pending_deltas: Vec<(String, String)>) -> ConnectorOutputs {
  pending_deltas
    .into_iter()
    .map(|(row_id, content)| {
      let entry = thinking_row_entry(row_id.clone(), content);
      row_updated_output(row_id, entry)
    })
    .collect()
}

pub(crate) async fn handle_turn_started(
  delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
  reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
) -> ConnectorOutputs {
  {
    let mut buffers = delta_buffers.lock().await;
    buffers.clear();
  }
  {
    let mut tracker = reasoning_tracker.lock().await;
    tracker.reset_for_turn();
  }
  vec![state_output(ConnectorStateEvent::TurnStarted)]
}

pub(crate) async fn handle_turn_complete(
  delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
  reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
) -> ConnectorOutputs {
  let pending_deltas = take_pending_deltas(delta_buffers).await;
  reset_reasoning_tracker(reasoning_tracker).await;
  let mut events = vec![state_output(ConnectorStateEvent::TurnCompleted)];
  events.extend(pending_delta_outputs(pending_deltas));
  events
}

pub(crate) async fn handle_turn_aborted(
  event: TurnAbortedEvent,
  delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
  reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
) -> ConnectorOutputs {
  let pending_deltas = take_pending_deltas(delta_buffers).await;
  reset_reasoning_tracker(reasoning_tracker).await;
  let mut events = vec![state_output(ConnectorStateEvent::TurnAborted {
    reason: format!("{:?}", event.reason),
  })];
  events.extend(pending_delta_outputs(pending_deltas));
  events
}

pub(crate) async fn handle_session_configured(
  event: SessionConfiguredEvent,
  env_tracker: &Arc<tokio::sync::Mutex<EnvironmentTracker>>,
  current_model: &Arc<tokio::sync::Mutex<Option<String>>>,
  current_reasoning_effort: &Arc<tokio::sync::Mutex<Option<ReasoningEffort>>>,
) -> ConnectorOutputs {
  let cwd_str = event.cwd.to_string_lossy().to_string();
  {
    let mut model = current_model.lock().await;
    *model = Some(event.model.clone());
  }
  {
    let mut effort = current_reasoning_effort.lock().await;
    *effort = event.reasoning_effort;
  }

  let git_info = codex_git_utils::collect_git_info(&event.cwd).await;
  let (branch, sha) = match git_info {
    Some(info) => (info.branch, info.commit_hash.map(|s| s.0)),
    None => (None, None),
  };

  {
    let mut tracker = env_tracker.lock().await;
    tracker.cwd = Some(cwd_str.clone());
    tracker.branch = branch.clone();
    tracker.sha = sha.clone();
  }

  vec![state_output(ConnectorStateEvent::EnvironmentChanged {
    cwd: Some(cwd_str),
    git_branch: branch,
    git_sha: sha,
  })]
}
