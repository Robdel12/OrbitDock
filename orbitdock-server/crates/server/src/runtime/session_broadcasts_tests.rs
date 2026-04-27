use orbitdock_protocol::{ServerMessage, SessionSurface};

use super::invalidated_surfaces;

#[test]
fn conversation_rows_changed_do_not_emit_surface_invalidation() {
  let invalidations = invalidated_surfaces(&ServerMessage::ConversationRowsChanged {
    session_id: "session-1".to_string(),
    upserted: vec![],
    removed_row_ids: vec![],
    total_row_count: 1,
  });

  assert!(invalidations.is_empty());
}

#[test]
fn context_compacted_still_invalidates_conversation_detail_and_review() {
  let invalidations = invalidated_surfaces(&ServerMessage::ContextCompacted {
    session_id: "session-1".to_string(),
  });

  assert_eq!(
    invalidations,
    &[
      SessionSurface::Conversation,
      SessionSurface::Detail,
      SessionSurface::Review,
    ]
  );
}

#[test]
fn capabilities_domain_events_do_not_emit_extra_surface_invalidations() {
  let invalidations = invalidated_surfaces(&ServerMessage::SkillsUpdateAvailable {
    session_id: "session-1".to_string(),
  });

  assert!(invalidations.is_empty());
}
