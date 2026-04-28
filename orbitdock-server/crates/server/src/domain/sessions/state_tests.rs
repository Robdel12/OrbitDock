use super::*;
use orbitdock_protocol::conversation_contracts::{ConversationRow, MessageRowContent, TurnStatus};
use orbitdock_protocol::Provider;

fn user_row(id: &str, sequence: u64) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: "session-1".to_string(),
    sequence,
    turn_id: None,
    turn_status: TurnStatus::Active,
    row: ConversationRow::User(MessageRowContent {
      id: id.to_string(),
      content: "hello".to_string(),
      turn_id: None,
      timestamp: None,
      is_streaming: false,
      images: vec![],
      memory_citation: None,
      delivery_status: None,
    }),
  }
}

#[test]
fn add_row_does_not_advance_sync_anchor_for_local_http_rows() {
  let mut state = SessionCoreState::new(
    "session-1".to_string(),
    Provider::Codex,
    "/repo".to_string(),
  );
  state.add_row(user_row("row-transcript-1", 1), false);

  state.add_row(user_row("user-http-1", 2), false);

  assert_eq!(
    state.newest_synced_row_id.as_deref(),
    Some("row-transcript-1")
  );
}

#[test]
fn apply_state_keeps_latest_transcript_anchor_when_http_row_is_newest() {
  let mut state = SessionCoreState::new(
    "session-1".to_string(),
    Provider::Codex,
    "/repo".to_string(),
  );
  state.add_row(user_row("row-transcript-1", 1), false);

  let mut transition = state.extract_state(0);
  transition.rows.push(user_row("user-http-1", 2));
  transition.total_row_count = transition.rows.len() as u64;

  state.apply_state(transition);

  assert_eq!(
    state.newest_synced_row_id.as_deref(),
    Some("row-transcript-1")
  );
}

#[test]
fn work_status_is_authoritative_for_steerable_state() {
  let mut state = SessionCoreState::new(
    "session-1".to_string(),
    Provider::Codex,
    "/repo".to_string(),
  );

  state.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
  state.set_work_status(WorkStatus::Working);
  assert!(state.retained_state(0).steerable);

  state.apply_changes(&StateChanges {
    work_status: Some(WorkStatus::Waiting),
    steerable: Some(true),
    ..Default::default()
  });

  assert_eq!(state.work_status, WorkStatus::Waiting);
  assert!(!state.retained_state(0).steerable);
}

#[test]
fn retained_rows_are_capped_to_keep_runtime_state_light() {
  let mut state = SessionCoreState::new(
    "session-1".to_string(),
    Provider::Codex,
    "/repo".to_string(),
  );

  for sequence in 0..(RETAINED_FINALIZED_ROW_LIMIT as u64 + 5) {
    state.add_row(user_row(&format!("row-{sequence}"), sequence), true);
  }

  assert_eq!(state.rows().len(), RETAINED_FINALIZED_ROW_LIMIT);
  assert_eq!(state.rows().first().map(|row| row.sequence), Some(5));
}
