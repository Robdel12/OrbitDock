use super::runtime::EnvironmentTracker;
use orbitdock_connector_core::{
  ConnectorOutput, ConnectorRuntimeDirective, ConnectorStateEvent, ConnectorTransportEffect,
};
use orbitdock_protocol::conversation_contracts::{
  compute_tool_display, extract_compact_result_text, CommandExecutionAction, ConversationRow,
  ConversationRowEntry, ToolDisplayInput, ToolRow,
};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Instant;

pub(super) mod approvals;
pub(super) mod capabilities;
pub(super) mod collab;
pub(super) mod guardian;
pub(super) mod lifecycle;
pub(super) mod messages;
pub(super) mod runtime_signals;
pub(super) mod streaming;
pub(super) mod tools;

/// Keep a large rolling preview so expanded command cards do not clip typical
/// build/test output while still bounding websocket row updates.
const OUTPUT_PREVIEW_CHAR_LIMIT: usize = 64 * 1024;

#[derive(Debug)]
pub(super) struct OutputBufferState {
  pub(super) command: String,
  pub(super) cwd: String,
  pub(super) process_id: Option<String>,
  pub(super) command_actions: Vec<CommandExecutionAction>,
  pub(super) full_output: String,
  pub(super) preview_output: String,
  pub(super) last_broadcast: Instant,
}

impl Default for OutputBufferState {
  fn default() -> Self {
    Self {
      command: String::new(),
      cwd: String::new(),
      process_id: None,
      command_actions: Vec::new(),
      full_output: String::new(),
      preview_output: String::new(),
      last_broadcast: Instant::now(),
    }
  }
}

impl OutputBufferState {
  pub(super) fn append(&mut self, chunk: &str) {
    self.full_output.push_str(chunk);
    self.preview_output.push_str(chunk);
    trim_front_to_char_limit(&mut self.preview_output, OUTPUT_PREVIEW_CHAR_LIMIT);
  }

  pub(super) fn preview(&self) -> Option<String> {
    (!self.preview_output.is_empty()).then(|| self.preview_output.clone())
  }
}

fn trim_front_to_char_limit(value: &mut String, limit: usize) {
  if value.len() <= limit {
    return;
  }

  let mut split_at = value.len().saturating_sub(limit);
  while split_at < value.len() && !value.is_char_boundary(split_at) {
    split_at += 1;
  }
  value.drain(..split_at);
}

pub(super) type SharedOutputBuffers = Arc<tokio::sync::Mutex<HashMap<String, OutputBufferState>>>;
pub(super) type SharedEnvironmentTracker = Arc<tokio::sync::Mutex<EnvironmentTracker>>;
pub(super) type SharedPatchContexts = Arc<tokio::sync::Mutex<HashMap<String, serde_json::Value>>>;
pub(super) type ConnectorOutputs = Vec<ConnectorOutput>;

pub(super) fn state_output(event: ConnectorStateEvent) -> ConnectorOutput {
  event.into()
}

pub(super) fn runtime_output(event: ConnectorRuntimeDirective) -> ConnectorOutput {
  event.into()
}

pub(super) fn transport_output(event: ConnectorTransportEffect) -> ConnectorOutput {
  event.into()
}

pub(super) fn row_created_output(entry: ConversationRowEntry) -> ConnectorOutput {
  state_output(ConnectorStateEvent::ConversationRowCreated(entry))
}

pub(super) fn row_updated_output(row_id: String, entry: ConversationRowEntry) -> ConnectorOutput {
  state_output(ConnectorStateEvent::ConversationRowUpdated { row_id, entry })
}

pub(super) fn with_tool_display(mut row: ToolRow) -> ToolRow {
  let invocation_ref = row.invocation.is_object().then_some(&row.invocation);
  let result_str = extract_compact_result_text(row.result.as_ref());
  row.tool_display = Some(compute_tool_display(ToolDisplayInput {
    kind: row.kind,
    family: row.family,
    status: row.status,
    title: &row.title,
    subtitle: row.subtitle.as_deref(),
    summary: row.summary.as_deref(),
    duration_ms: row.duration_ms,
    invocation_input: invocation_ref,
    result_output: result_str.as_deref(),
  }));
  row
}

pub(super) fn tool_row_entry(row: ToolRow) -> ConversationRowEntry {
  crate::runtime::row_entry(ConversationRow::Tool(with_tool_display(row)))
}

#[cfg(test)]
mod tests {
  use super::{OutputBufferState, OUTPUT_PREVIEW_CHAR_LIMIT};

  #[test]
  fn output_buffer_keeps_full_output_but_trims_preview_tail() {
    let mut state = OutputBufferState::default();
    state.append(&"a".repeat(9000));
    state.append("tail");

    assert_eq!(state.full_output.len(), 9004);
    let preview = state.preview().expect("preview output");
    assert!(preview.len() <= OUTPUT_PREVIEW_CHAR_LIMIT);
    assert!(preview.ends_with("tail"));
  }
}
