use super::*;
use orbitdock_server::ServerLogEvent;

fn sample_event(target: &str) -> ServerLogEvent {
  ServerLogEvent {
    timestamp: "2026-03-19T05:03:47.794Z".to_string(),
    level: "INFO".to_string(),
    target: target.to_string(),
    message: "sample".to_string(),
    component: None,
    event: None,
    session_id: None,
    request_id: None,
    file: None,
    line: None,
    current_span: None,
    fields: Default::default(),
  }
}

#[test]
fn classifies_codex_targets_without_component() {
  assert_eq!(
    classify_category(&sample_event("codex_otel.trace_safe")),
    Category::Codex
  );
  assert_eq!(
    classify_category(&sample_event("orbitdock_connector_codex::runtime")),
    Category::Codex
  );
}

#[test]
fn classifies_transcript_targets() {
  assert_eq!(
    classify_category(&sample_event(
      "orbitdock_server::runtime::session_runtime_helpers"
    )),
    Category::TranscriptRollout
  );
  assert_eq!(
    classify_category(&sample_event("orbitdock_connector_core::transition")),
    Category::TranscriptRollout
  );
}

#[test]
fn classifies_component_first() {
  let mut event = sample_event("orbitdock_server::app");
  event.component = Some("hook_handler".to_string());
  assert_eq!(classify_category(&event), Category::Claude);
}

#[test]
fn terminal_suspend_state_only_requests_one_suspend_until_resume() {
  let mut state = TerminalSuspendState::default();

  assert!(state.mark_suspended());
  assert!(state.is_suspended());
  assert!(!state.mark_suspended());

  state.mark_resumed();

  assert!(!state.is_suspended());
  assert!(state.mark_suspended());
}
