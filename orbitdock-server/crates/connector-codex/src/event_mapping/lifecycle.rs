use crate::runtime::{thinking_row_entry, EnvironmentTracker, ReasoningEventTracker};
use codex_protocol::openai_models::ReasoningEffort;
use codex_protocol::protocol::{SessionConfiguredEvent, TurnAbortedEvent};
use orbitdock_connector_core::ConnectorEvent;
use std::collections::HashMap;
use std::sync::Arc;

pub(crate) async fn handle_turn_started(
    delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
    reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
) -> Vec<ConnectorEvent> {
    {
        let mut buffers = delta_buffers.lock().await;
        buffers.clear();
    }
    {
        let mut tracker = reasoning_tracker.lock().await;
        tracker.reset_for_turn();
    }
    vec![ConnectorEvent::TurnStarted]
}

pub(crate) async fn handle_turn_complete(
    delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
    reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
) -> Vec<ConnectorEvent> {
    let pending_deltas = {
        let mut buffers = delta_buffers.lock().await;
        let deltas: Vec<(String, String)> = buffers
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        buffers.clear();
        deltas
    };
    {
        let mut tracker = reasoning_tracker.lock().await;
        tracker.reset_for_turn();
    }
    let mut events = vec![ConnectorEvent::TurnCompleted];
    for (row_id, content) in pending_deltas {
        let entry = thinking_row_entry(row_id.clone(), content);
        events.push(ConnectorEvent::ConversationRowUpdated { row_id, entry });
    }
    events
}

pub(crate) async fn handle_turn_aborted(
    event: TurnAbortedEvent,
    delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
    reasoning_tracker: &Arc<tokio::sync::Mutex<ReasoningEventTracker>>,
) -> Vec<ConnectorEvent> {
    let pending_deltas = {
        let mut buffers = delta_buffers.lock().await;
        let deltas: Vec<(String, String)> = buffers
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        buffers.clear();
        deltas
    };
    {
        let mut tracker = reasoning_tracker.lock().await;
        tracker.reset_for_turn();
    }
    let mut events = vec![ConnectorEvent::TurnAborted {
        reason: format!("{:?}", event.reason),
    }];
    for (row_id, content) in pending_deltas {
        let entry = thinking_row_entry(row_id.clone(), content);
        events.push(ConnectorEvent::ConversationRowUpdated { row_id, entry });
    }
    events
}

pub(crate) async fn handle_session_configured(
    event: SessionConfiguredEvent,
    env_tracker: &Arc<tokio::sync::Mutex<EnvironmentTracker>>,
    current_model: &Arc<tokio::sync::Mutex<Option<String>>>,
    current_reasoning_effort: &Arc<tokio::sync::Mutex<Option<ReasoningEffort>>>,
) -> Vec<ConnectorEvent> {
    let cwd_str = event.cwd.to_string_lossy().to_string();
    {
        let mut model = current_model.lock().await;
        *model = Some(event.model.clone());
    }
    {
        let mut effort = current_reasoning_effort.lock().await;
        *effort = event.reasoning_effort;
    }

    let git_info = codex_core::git_info::collect_git_info(&event.cwd).await;
    let (branch, sha) = match git_info {
        Some(info) => (info.branch, info.commit_hash),
        None => (None, None),
    };

    {
        let mut tracker = env_tracker.lock().await;
        tracker.cwd = Some(cwd_str.clone());
        tracker.branch = branch.clone();
        tracker.sha = sha.clone();
    }

    vec![ConnectorEvent::EnvironmentChanged {
        cwd: Some(cwd_str),
        git_branch: branch,
        git_sha: sha,
    }]
}
