use super::*;

#[test]
fn binding_snapshot_reflects_current_parse_state() {
  let path = "/tmp/rollout.jsonl";
  let mut processor = RolloutFileProcessor::new(HashMap::new());
  processor.parse_states.insert(
    path.to_string(),
    ParseState {
      session_id: Some("session-1".to_string()),
      project_path: Some("/tmp/repo".to_string()),
      model_provider: Some("gpt-5".to_string()),
      pending_tool_calls: HashMap::new(),
      next_message_seq: 7,
      saw_user_event: true,
      saw_agent_event: true,
    },
  );

  let snapshot = processor.binding_snapshot(path).expect("binding snapshot");

  assert_eq!(snapshot.offset, 0);
  assert_eq!(snapshot.session_id.as_deref(), Some("session-1"));
  assert_eq!(snapshot.project_path.as_deref(), Some("/tmp/repo"));
  assert_eq!(snapshot.model_provider.as_deref(), Some("gpt-5"));
  assert_eq!(snapshot.ignore_existing, None);
}

#[test]
fn mark_session_id_initializes_seeded_parse_state() {
  let path = "/tmp/rollout.jsonl";
  let mut processor = RolloutFileProcessor::new(HashMap::from([(
    path.to_string(),
    PersistedFileState {
      offset: 128,
      session_id: Some("session-2".to_string()),
      project_path: Some("/tmp/project".to_string()),
      model_provider: Some("codex".to_string()),
      ignore_existing: Some(false),
    },
  )]));

  processor.mark_session_id(path, "session-3");

  let state = processor.parse_states.get(path).expect("parse state");
  assert_eq!(state.session_id.as_deref(), Some("session-3"));
  assert_eq!(state.project_path.as_deref(), Some("/tmp/project"));
  assert_eq!(state.model_provider.as_deref(), Some("codex"));
}

#[test]
fn extract_images_from_content_preserves_image_detail() {
  let images = extract_images_from_content(&[ContentItem::InputImage {
    image_url: "data:image/png;base64,aGVsbG8=".to_string(),
    detail: Some(ImageDetail::Original),
  }]);

  assert_eq!(images.len(), 1);
  assert_eq!(images[0].input_type, "url");
  assert_eq!(images[0].value, "data:image/png;base64,aGVsbG8=");
  assert_eq!(images[0].detail.as_deref(), Some("original"));
}
