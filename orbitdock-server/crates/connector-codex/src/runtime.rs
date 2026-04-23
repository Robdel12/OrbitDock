use super::workers::iso_now;
use super::CodexConnector;
use crate::row_mapping::{row_created_output, row_updated_output};
use codex_protocol::openai_models::ReasoningEffort;
use orbitdock_connector_core::{ConnectorError, ConnectorOutput};
use orbitdock_protocol::conversation_contracts::{
  ConversationRow, ConversationRowEntry, MessageRowContent,
};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::mpsc;

/// Tracks an in-progress assistant message being streamed via app-server deltas.
pub(crate) struct StreamingMessage {
  pub(crate) message_id: String,
  pub(crate) content: String,
  pub(crate) last_broadcast: std::time::Instant,
}

/// Minimum interval between streaming content broadcasts (ms)
pub(super) const STREAM_THROTTLE_MS: u128 = 50;

impl CodexConnector {
  pub(crate) async fn from_app_server_thread(
    app_server: Arc<crate::app_server::CodexAppServer>,
    thread_id: String,
    codex_home: PathBuf,
    cwd: &str,
    model: Option<String>,
    reasoning_effort: Option<ReasoningEffort>,
  ) -> Result<Self, ConnectorError> {
    let (output_tx, output_rx) = mpsc::channel(256);

    let current_model = Arc::new(tokio::sync::Mutex::new(model));
    let current_reasoning_effort = Arc::new(tokio::sync::Mutex::new(reasoning_effort));
    let current_cwd = Arc::new(tokio::sync::Mutex::new(cwd.to_string()));
    let active_turn_id = Arc::new(tokio::sync::Mutex::new(None));
    let pending_app_server_requests = Arc::new(tokio::sync::Mutex::new(HashMap::new()));
    let pending_turn_context = Arc::new(tokio::sync::Mutex::new(Default::default()));

    app_server
      .register_session(
        thread_id.clone(),
        crate::app_server::AppServerSessionRoute::new(
          output_tx.clone(),
          Arc::clone(&active_turn_id),
          Arc::clone(&pending_app_server_requests),
        ),
      )
      .await;

    Ok(Self {
      app_server: Some(app_server),
      pending_app_server_requests,
      pending_turn_context,
      active_turn_id,
      codex_home,
      output_tx,
      output_rx: Some(output_rx),
      thread_id,
      current_cwd,
      current_model,
      current_reasoning_effort,
    })
  }
}

/// Helper to build a ConversationRowEntry with empty session_id and zero sequence.
pub(crate) fn row_entry(row: ConversationRow) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: String::new(),
    sequence: 0,
    turn_id: None,
    turn_status: Default::default(),
    row,
  }
}

/// Build a thinking row and wrap it for delta streaming.
pub(crate) fn thinking_row_entry(id: String, content: String) -> ConversationRowEntry {
  row_entry(ConversationRow::Thinking(MessageRowContent {
    id,
    content,
    turn_id: None,
    timestamp: Some(iso_now()),
    is_streaming: true,
    images: vec![],
    memory_citation: None,
    delivery_status: None,
  }))
}

/// Build a finalized thinking row (not streaming).
pub(crate) fn finalized_thinking_row_entry(id: String, content: String) -> ConversationRowEntry {
  row_entry(ConversationRow::Thinking(MessageRowContent {
    id,
    content,
    turn_id: None,
    timestamp: Some(iso_now()),
    is_streaming: false,
    images: vec![],
    memory_citation: None,
    delivery_status: None,
  }))
}

pub(crate) async fn apply_delta_thinking(
  delta_buffers: &Arc<tokio::sync::Mutex<HashMap<String, String>>>,
  message_id: String,
  delta: String,
) -> Vec<ConnectorOutput> {
  let (is_new, content) = {
    let mut buffers = delta_buffers.lock().await;
    match buffers.get_mut(&message_id) {
      Some(existing) => {
        existing.push_str(&delta);
        (false, existing.clone())
      }
      None => {
        buffers.insert(message_id.clone(), delta.clone());
        (true, delta)
      }
    }
  };

  let entry = thinking_row_entry(message_id.clone(), content);

  if is_new {
    vec![row_created_output(entry)]
  } else {
    vec![row_updated_output(message_id, entry)]
  }
}
