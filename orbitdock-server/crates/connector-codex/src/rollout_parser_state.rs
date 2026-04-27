use std::collections::HashMap;

use super::{ParseState, PersistedFileState, RolloutFileProcessor};

pub(super) fn file_session_id(processor: &RolloutFileProcessor, path: &str) -> Option<String> {
  processor
    .parse_states
    .get(path)
    .and_then(|state| state.session_id.clone())
}

pub(super) fn mark_session_id(processor: &mut RolloutFileProcessor, path: &str, session_id: &str) {
  ensure_parse_state(processor, path);
  if let Some(state) = processor.parse_states.get_mut(path) {
    state.session_id = Some(session_id.to_string());
  }
}

pub(super) fn saw_agent_event(processor: &RolloutFileProcessor, path: &str) -> bool {
  processor
    .parse_states
    .get(path)
    .map(|state| state.saw_agent_event)
    .unwrap_or(false)
}

pub(super) fn ensure_parse_state(processor: &mut RolloutFileProcessor, path: &str) {
  if processor.parse_states.contains_key(path) {
    return;
  }

  let seeded = processor
    .checkpoint_seeds
    .get(path)
    .cloned()
    .unwrap_or_default();

  processor.parse_states.insert(
    path.to_string(),
    ParseState {
      session_id: seeded.session_id,
      project_path: seeded.project_path,
      model_provider: seeded.model_provider,
      pending_tool_calls: HashMap::new(),
      next_message_seq: 0,
      saw_user_event: false,
      saw_agent_event: false,
    },
  );
}

pub(super) fn reset_session_binding(processor: &mut RolloutFileProcessor, path: &str) {
  if let Some(state) = processor.parse_states.get_mut(path) {
    state.session_id = None;
    state.project_path = None;
    state.model_provider = None;
  }
}

pub(super) fn remove_path(processor: &mut RolloutFileProcessor, path: &str) {
  processor.parse_states.remove(path);
}

pub(super) fn binding_snapshot(
  processor: &RolloutFileProcessor,
  path: &str,
) -> Option<PersistedFileState> {
  processor
    .parse_states
    .get(path)
    .map(|state| PersistedFileState {
      offset: 0,
      session_id: state.session_id.clone(),
      project_path: state.project_path.clone(),
      model_provider: state.model_provider.clone(),
      ignore_existing: None,
    })
}
