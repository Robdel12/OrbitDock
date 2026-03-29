use super::runtime::EnvironmentTracker;
use orbitdock_protocol::conversation_contracts::CommandExecutionAction;
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

const OUTPUT_PREVIEW_CHAR_LIMIT: usize = 8 * 1024;

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

#[cfg(test)]
mod tests {
  use super::OutputBufferState;

  #[test]
  fn output_buffer_keeps_full_output_but_trims_preview_tail() {
    let mut state = OutputBufferState::default();
    state.append(&"a".repeat(9000));
    state.append("tail");

    assert_eq!(state.full_output.len(), 9004);
    let preview = state.preview().expect("preview output");
    assert!(preview.len() <= 8 * 1024);
    assert!(preview.ends_with("tail"));
  }
}
