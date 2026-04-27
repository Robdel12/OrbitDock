use super::ClientMessage;
use crate::types::{CodexApprovalsReviewer, SessionSurface};

#[test]
fn deserializes_claude_status_event() {
  let json = r#"{
        "type":"claude_status_event",
        "session_id":"sess-1",
        "cwd":"/tmp/project",
        "transcript_path":"/tmp/project/sess-1.jsonl",
        "hook_event_name":"UserPromptSubmit",
        "prompt":"Ship it"
      }"#;

  let parsed: ClientMessage = serde_json::from_str(json).expect("parse claude status event");
  match parsed {
    ClientMessage::ClaudeStatusEvent {
      session_id,
      cwd,
      transcript_path,
      hook_event_name,
      prompt,
      ..
    } => {
      assert_eq!(session_id, "sess-1");
      assert_eq!(cwd.as_deref(), Some("/tmp/project"));
      assert_eq!(
        transcript_path.as_deref(),
        Some("/tmp/project/sess-1.jsonl")
      );
      assert_eq!(hook_event_name, "UserPromptSubmit");
      assert_eq!(prompt.as_deref(), Some("Ship it"));
    }
    other => panic!("unexpected message variant: {:?}", other),
  }
}

#[test]
fn deserializes_claude_tool_event() {
  let json = r#"{
        "type":"claude_tool_event",
        "session_id":"sess-2",
        "cwd":"/tmp/project",
        "hook_event_name":"PreToolUse",
        "tool_name":"Bash",
        "tool_input":{"command":"echo hello"},
        "tool_use_id":"tool-1"
      }"#;

  let parsed: ClientMessage = serde_json::from_str(json).expect("parse claude tool event");
  match parsed {
    ClientMessage::ClaudeToolEvent {
      session_id,
      cwd,
      hook_event_name,
      tool_name,
      tool_input,
      tool_use_id,
      ..
    } => {
      assert_eq!(session_id, "sess-2");
      assert_eq!(cwd, "/tmp/project");
      assert_eq!(hook_event_name, "PreToolUse");
      assert_eq!(tool_name, "Bash");
      assert_eq!(tool_use_id.as_deref(), Some("tool-1"));
      let command = tool_input.and_then(|v| {
        v.get("command")
          .and_then(|v| v.as_str())
          .map(str::to_string)
      });
      assert_eq!(command.as_deref(), Some("echo hello"));
    }
    other => panic!("unexpected message variant: {:?}", other),
  }
}

#[test]
fn deserializes_codex_user_prompt_submit() {
  let json = r#"{
        "type":"codex_user_prompt_submit",
        "session_id":"codex-1",
        "cwd":"/tmp/project",
        "transcript_path":"/tmp/project/.codex/transcript.jsonl",
        "model":"gpt-5-codex",
        "turn_id":"turn-1",
        "prompt":"Ship it"
      }"#;

  let parsed: ClientMessage = serde_json::from_str(json).expect("parse codex user prompt submit");
  match parsed {
    ClientMessage::CodexUserPromptSubmit {
      session_id,
      cwd,
      transcript_path,
      model,
      turn_id,
      prompt,
    } => {
      assert_eq!(session_id, "codex-1");
      assert_eq!(cwd, "/tmp/project");
      assert_eq!(
        transcript_path.as_deref(),
        Some("/tmp/project/.codex/transcript.jsonl")
      );
      assert_eq!(model.as_deref(), Some("gpt-5-codex"));
      assert_eq!(turn_id, "turn-1");
      assert_eq!(prompt, "Ship it");
    }
    other => panic!("unexpected message variant: {:?}", other),
  }
}

#[test]
fn deserializes_codex_stop_event() {
  let json = r#"{
        "type":"codex_stop_event",
        "session_id":"codex-2",
        "cwd":"/tmp/project",
        "turn_id":"turn-9",
        "stop_hook_active":true,
        "last_assistant_message":"Done."
      }"#;

  let parsed: ClientMessage = serde_json::from_str(json).expect("parse codex stop event");
  match parsed {
    ClientMessage::CodexStopEvent {
      session_id,
      cwd,
      turn_id,
      stop_hook_active,
      last_assistant_message,
      ..
    } => {
      assert_eq!(session_id, "codex-2");
      assert_eq!(cwd, "/tmp/project");
      assert_eq!(turn_id, "turn-9");
      assert_eq!(stop_hook_active, Some(true));
      assert_eq!(last_assistant_message.as_deref(), Some("Done."));
    }
    other => panic!("unexpected message variant: {:?}", other),
  }
}

#[test]
fn deserializes_codex_tool_event() {
  let json = r#"{
        "type":"codex_tool_event",
        "session_id":"codex-3",
        "cwd":"/tmp/project",
        "hook_event_name":"PreToolUse",
        "turn_id":"turn-4",
        "tool_name":"Bash",
        "tool_use_id":"tool-9",
        "tool_input":{"command":"cargo test"}
      }"#;

  let parsed: ClientMessage = serde_json::from_str(json).expect("parse codex tool event");
  match parsed {
    ClientMessage::CodexToolEvent {
      session_id,
      cwd,
      hook_event_name,
      turn_id,
      tool_name,
      tool_use_id,
      tool_input,
      ..
    } => {
      assert_eq!(session_id, "codex-3");
      assert_eq!(cwd, "/tmp/project");
      assert_eq!(hook_event_name, "PreToolUse");
      assert_eq!(turn_id, "turn-4");
      assert_eq!(tool_name, "Bash");
      assert_eq!(tool_use_id.as_deref(), Some("tool-9"));
      let command = tool_input.and_then(|value| {
        value
          .get("command")
          .and_then(|value| value.as_str())
          .map(str::to_string)
      });
      assert_eq!(command.as_deref(), Some("cargo test"));
    }
    other => panic!("unexpected message variant: {:?}", other),
  }
}

#[test]
fn codex_hook_events_require_turn_id() {
  for json in [
    r#"{"type":"codex_user_prompt_submit","session_id":"codex-1","cwd":"/tmp/project","prompt":"Ship it"}"#,
    r#"{"type":"codex_stop_event","session_id":"codex-2","cwd":"/tmp/project"}"#,
    r#"{"type":"codex_tool_event","session_id":"codex-3","cwd":"/tmp/project","hook_event_name":"PreToolUse","tool_name":"Bash"}"#,
  ] {
    let parsed = serde_json::from_str::<ClientMessage>(json);
    assert!(parsed.is_err());
  }
}

#[test]
fn roundtrip_send_message_with_skills() {
  let json = r#"{
        "type":"send_message",
        "session_id":"sess-4",
        "content":"hello",
        "skills":[{"name":"deploy","path":"/home/.codex/skills/deploy.md"}]
      }"#;

  let parsed: ClientMessage = serde_json::from_str(json).expect("parse send_message with skills");
  match &parsed {
    ClientMessage::SendMessage {
      session_id,
      content,
      skills,
      ..
    } => {
      assert_eq!(session_id, "sess-4");
      assert_eq!(content, "hello");
      assert_eq!(skills.len(), 1);
      assert_eq!(skills[0].name, "deploy");
      assert_eq!(skills[0].path, "/home/.codex/skills/deploy.md");
    }
    other => panic!("unexpected variant: {:?}", other),
  }
}

#[test]
fn send_message_without_skills_defaults_to_empty() {
  let json = r#"{
        "type":"send_message",
        "session_id":"sess-5",
        "content":"hello"
      }"#;

  let parsed: ClientMessage =
    serde_json::from_str(json).expect("parse send_message without skills");
  match parsed {
    ClientMessage::SendMessage { skills, .. } => {
      assert!(skills.is_empty());
    }
    other => panic!("unexpected variant: {:?}", other),
  }
}

#[test]
fn roundtrip_cancel_shell() {
  let json = r#"{"type":"cancel_shell","session_id":"sess-shell","request_id":"req-shell"}"#;
  let parsed: ClientMessage = serde_json::from_str(json).expect("parse cancel_shell");
  match &parsed {
    ClientMessage::CancelShell {
      session_id,
      request_id,
    } => {
      assert_eq!(session_id, "sess-shell");
      assert_eq!(request_id, "req-shell");
    }
    other => panic!("unexpected variant: {:?}", other),
  }
  let serialized = serde_json::to_string(&parsed).expect("serialize");
  let _: ClientMessage = serde_json::from_str(&serialized).expect("roundtrip");
}

#[test]
fn roundtrip_steer_turn() {
  let json = r#"{"type":"steer_turn","session_id":"sess-s1","content":"use postgres instead"}"#;
  let parsed: ClientMessage = serde_json::from_str(json).expect("parse steer_turn");
  match &parsed {
    ClientMessage::SteerTurn {
      session_id,
      content,
      images,
      mentions,
    } => {
      assert_eq!(session_id, "sess-s1");
      assert_eq!(content, "use postgres instead");
      assert!(images.is_empty());
      assert!(mentions.is_empty());
    }
    other => panic!("unexpected variant: {:?}", other),
  }
  let serialized = serde_json::to_string(&parsed).expect("serialize");
  let _: ClientMessage = serde_json::from_str(&serialized).expect("roundtrip");
}

#[test]
fn roundtrip_steer_turn_with_mixed_inputs() {
  let json = r#"{
        "type":"steer_turn",
        "session_id":"sess-s2",
        "content":"take this into account",
        "images":[{"input_type":"url","value":"data:image/png;base64,iVBOR"}],
        "mentions":[{"name":"main.rs","path":"/project/src/main.rs"}]
      }"#;
  let parsed: ClientMessage =
    serde_json::from_str(json).expect("parse steer_turn with mixed inputs");
  match &parsed {
    ClientMessage::SteerTurn {
      session_id,
      content,
      images,
      mentions,
    } => {
      assert_eq!(session_id, "sess-s2");
      assert_eq!(content, "take this into account");
      assert_eq!(images.len(), 1);
      assert_eq!(mentions.len(), 1);
      assert_eq!(images[0].input_type, "url");
      assert_eq!(mentions[0].name, "main.rs");
    }
    other => panic!("unexpected variant: {:?}", other),
  }

  let serialized = serde_json::to_string(&parsed).expect("serialize");
  let reparsed: ClientMessage = serde_json::from_str(&serialized).expect("reparse");
  match reparsed {
    ClientMessage::SteerTurn {
      images, mentions, ..
    } => {
      assert_eq!(images.len(), 1);
      assert_eq!(mentions.len(), 1);
    }
    other => panic!("unexpected variant on roundtrip: {:?}", other),
  }
}

#[test]
fn roundtrip_compact_context() {
  let json = r#"{"type":"compact_context","session_id":"sess-c1"}"#;
  let parsed: ClientMessage = serde_json::from_str(json).expect("parse compact_context");
  match &parsed {
    ClientMessage::CompactContext { session_id } => {
      assert_eq!(session_id, "sess-c1");
    }
    other => panic!("unexpected variant: {:?}", other),
  }
  let serialized = serde_json::to_string(&parsed).expect("serialize");
  let _: ClientMessage = serde_json::from_str(&serialized).expect("roundtrip");
}

#[test]
fn roundtrip_undo_last_turn() {
  let json = r#"{"type":"undo_last_turn","session_id":"sess-u1"}"#;
  let parsed: ClientMessage = serde_json::from_str(json).expect("parse undo_last_turn");
  match &parsed {
    ClientMessage::UndoLastTurn { session_id } => {
      assert_eq!(session_id, "sess-u1");
    }
    other => panic!("unexpected variant: {:?}", other),
  }
  let serialized = serde_json::to_string(&parsed).expect("serialize");
  let _: ClientMessage = serde_json::from_str(&serialized).expect("roundtrip");
}

#[test]
fn roundtrip_rollback_turns() {
  let json = r#"{"type":"rollback_turns","session_id":"sess-r1","num_turns":3}"#;
  let parsed: ClientMessage = serde_json::from_str(json).expect("parse rollback_turns");
  match &parsed {
    ClientMessage::RollbackTurns {
      session_id,
      num_turns,
    } => {
      assert_eq!(session_id, "sess-r1");
      assert_eq!(*num_turns, 3);
    }
    other => panic!("unexpected variant: {:?}", other),
  }
  let serialized = serde_json::to_string(&parsed).expect("serialize");
  let _: ClientMessage = serde_json::from_str(&serialized).expect("roundtrip");
}

#[test]
fn roundtrip_send_message_with_image_url() {
  let json = r#"{
        "type":"send_message",
        "session_id":"sess-img1",
        "content":"check this screenshot",
        "images":[{"input_type":"url","value":"data:image/png;base64,iVBOR"}]
      }"#;

  let parsed: ClientMessage =
    serde_json::from_str(json).expect("parse send_message with image url");
  match &parsed {
    ClientMessage::SendMessage {
      session_id,
      content,
      images,
      ..
    } => {
      assert_eq!(session_id, "sess-img1");
      assert_eq!(content, "check this screenshot");
      assert_eq!(images.len(), 1);
      assert_eq!(images[0].input_type, "url");
      assert_eq!(images[0].value, "data:image/png;base64,iVBOR");
    }
    other => panic!("unexpected variant: {:?}", other),
  }

  let serialized = serde_json::to_string(&parsed).expect("serialize");
  let reparsed: ClientMessage = serde_json::from_str(&serialized).expect("reparse");
  match reparsed {
    ClientMessage::SendMessage { images, .. } => {
      assert_eq!(images.len(), 1);
      assert_eq!(images[0].input_type, "url");
    }
    other => panic!("unexpected variant on roundtrip: {:?}", other),
  }
}

#[test]
fn roundtrip_send_message_with_local_image() {
  let json = r#"{
        "type":"send_message",
        "session_id":"sess-img2",
        "content":"look at this",
        "images":[{"input_type":"path","value":"/tmp/screenshot.png"}]
      }"#;

  let parsed: ClientMessage =
    serde_json::from_str(json).expect("parse send_message with local image");
  match &parsed {
    ClientMessage::SendMessage { images, .. } => {
      assert_eq!(images.len(), 1);
      assert_eq!(images[0].input_type, "path");
      assert_eq!(images[0].value, "/tmp/screenshot.png");
    }
    other => panic!("unexpected variant: {:?}", other),
  }
}

#[test]
fn roundtrip_send_message_with_mention() {
  let json = r#"{
        "type":"send_message",
        "session_id":"sess-men1",
        "content":"update this file",
        "mentions":[{"name":"main.rs","path":"/project/src/main.rs"}]
      }"#;

  let parsed: ClientMessage = serde_json::from_str(json).expect("parse send_message with mention");
  match &parsed {
    ClientMessage::SendMessage { mentions, .. } => {
      assert_eq!(mentions.len(), 1);
      assert_eq!(mentions[0].name, "main.rs");
      assert_eq!(mentions[0].path, "/project/src/main.rs");
    }
    other => panic!("unexpected variant: {:?}", other),
  }

  let serialized = serde_json::to_string(&parsed).expect("serialize");
  let reparsed: ClientMessage = serde_json::from_str(&serialized).expect("reparse");
  match reparsed {
    ClientMessage::SendMessage { mentions, .. } => {
      assert_eq!(mentions.len(), 1);
      assert_eq!(mentions[0].name, "main.rs");
    }
    other => panic!("unexpected variant on roundtrip: {:?}", other),
  }
}

#[test]
fn roundtrip_send_message_mixed_inputs() {
  let json = r#"{
        "type":"send_message",
        "session_id":"sess-mix1",
        "content":"deploy with these files",
        "skills":[{"name":"deploy","path":"/skills/deploy.md"}],
        "images":[{"input_type":"url","value":"data:image/png;base64,abc"}],
        "mentions":[{"name":"config.toml","path":"/project/config.toml"}]
      }"#;

  let parsed: ClientMessage = serde_json::from_str(json).expect("parse mixed inputs");
  match &parsed {
    ClientMessage::SendMessage {
      skills,
      images,
      mentions,
      ..
    } => {
      assert_eq!(skills.len(), 1);
      assert_eq!(images.len(), 1);
      assert_eq!(mentions.len(), 1);
      assert_eq!(skills[0].name, "deploy");
      assert_eq!(images[0].input_type, "url");
      assert_eq!(mentions[0].name, "config.toml");
    }
    other => panic!("unexpected variant: {:?}", other),
  }

  let serialized = serde_json::to_string(&parsed).expect("serialize");
  let reparsed: ClientMessage = serde_json::from_str(&serialized).expect("reparse");
  match reparsed {
    ClientMessage::SendMessage {
      skills,
      images,
      mentions,
      ..
    } => {
      assert_eq!(skills.len(), 1);
      assert_eq!(images.len(), 1);
      assert_eq!(mentions.len(), 1);
    }
    other => panic!("unexpected variant on roundtrip: {:?}", other),
  }
}

#[test]
fn update_session_config_round_trips_model_and_effort() {
  let message = ClientMessage::UpdateSessionConfig {
    session_id: "sess-1".to_string(),
    approval_policy: Some("on-request".to_string()),
    approval_policy_details: None,
    sandbox_mode: Some("workspace-write".to_string()),
    sandbox_policy_details: None,
    approvals_reviewer: Some(CodexApprovalsReviewer::GuardianSubagent),
    permission_mode: Some("default".to_string()),
    collaboration_mode: Some("default".to_string()),
    multi_agent: Some(true),
    personality: Some("balanced".to_string()),
    service_tier: Some("priority".to_string()),
    developer_instructions: Some("Stay concise".to_string()),
    model: Some("gpt-5-codex".to_string()),
    effort: Some("high".to_string()),
  };

  let json = serde_json::to_string(&message).expect("serialize update_session_config");
  match serde_json::from_str::<ClientMessage>(&json).expect("deserialize update_session_config") {
    ClientMessage::UpdateSessionConfig {
      approvals_reviewer,
      model,
      effort,
      ..
    } => {
      assert_eq!(
        approvals_reviewer,
        Some(CodexApprovalsReviewer::GuardianSubagent)
      );
      assert_eq!(model.as_deref(), Some("gpt-5-codex"));
      assert_eq!(effort.as_deref(), Some("high"));
    }
    other => panic!("unexpected variant for update_session_config: {:?}", other),
  }
}

#[test]
fn subscribe_session_surface_round_trips_since_revision() {
  let message = ClientMessage::SubscribeSessionSurface {
    session_id: "sess-1".to_string(),
    surface: SessionSurface::Conversation,
    since_revision: Some(42),
  };

  let json = serde_json::to_string(&message).expect("serialize subscribe_session_surface");
  match serde_json::from_str::<ClientMessage>(&json).expect("deserialize subscribe_session_surface")
  {
    ClientMessage::SubscribeSessionSurface {
      session_id,
      surface,
      since_revision,
    } => {
      assert_eq!(session_id, "sess-1");
      assert_eq!(surface, SessionSurface::Conversation);
      assert_eq!(since_revision, Some(42));
    }
    other => panic!(
      "unexpected variant for subscribe_session_surface: {:?}",
      other
    ),
  }
}

#[test]
fn unsubscribe_active_sessions_round_trips() {
  let message = ClientMessage::UnsubscribeActiveSessions;

  let json = serde_json::to_string(&message).expect("serialize unsubscribe_active_sessions");
  match serde_json::from_str::<ClientMessage>(&json)
    .expect("deserialize unsubscribe_active_sessions")
  {
    ClientMessage::UnsubscribeActiveSessions => {}
    other => panic!(
      "unexpected variant for unsubscribe_active_sessions: {:?}",
      other
    ),
  }
}

#[test]
fn subscribe_archived_sessions_round_trips() {
  let message = ClientMessage::SubscribeArchivedSessions {
    since_revision: Some(17),
  };

  let json = serde_json::to_string(&message).expect("serialize subscribe_archived_sessions");
  match serde_json::from_str::<ClientMessage>(&json)
    .expect("deserialize subscribe_archived_sessions")
  {
    ClientMessage::SubscribeArchivedSessions { since_revision } => {
      assert_eq!(since_revision, Some(17));
    }
    other => panic!(
      "unexpected variant for subscribe_archived_sessions: {:?}",
      other
    ),
  }
}

#[test]
fn unsubscribe_archived_sessions_round_trips() {
  let message = ClientMessage::UnsubscribeArchivedSessions;

  let json = serde_json::to_string(&message).expect("serialize unsubscribe_archived_sessions");
  match serde_json::from_str::<ClientMessage>(&json)
    .expect("deserialize unsubscribe_archived_sessions")
  {
    ClientMessage::UnsubscribeArchivedSessions => {}
    other => panic!(
      "unexpected variant for unsubscribe_archived_sessions: {:?}",
      other
    ),
  }
}

#[test]
fn subscribe_sessions_summary_round_trips() {
  let message = ClientMessage::SubscribeSessionsSummary {
    since_revision: Some(9),
  };

  let json = serde_json::to_string(&message).expect("serialize subscribe_sessions_summary");
  match serde_json::from_str::<ClientMessage>(&json)
    .expect("deserialize subscribe_sessions_summary")
  {
    ClientMessage::SubscribeSessionsSummary { since_revision } => {
      assert_eq!(since_revision, Some(9));
    }
    other => panic!(
      "unexpected variant for subscribe_sessions_summary: {:?}",
      other
    ),
  }
}

#[test]
fn subscribe_mission_round_trips() {
  let json = r#"{"type":"subscribe_mission","mission_id":"mission-1"}"#;
  let parsed: ClientMessage = serde_json::from_str(json).expect("parse subscribe_mission");
  match &parsed {
    ClientMessage::SubscribeMission { mission_id } => {
      assert_eq!(mission_id, "mission-1");
    }
    other => panic!("unexpected variant for subscribe_mission: {:?}", other),
  }
  let serialized = serde_json::to_string(&parsed).expect("serialize");
  let _: ClientMessage = serde_json::from_str(&serialized).expect("roundtrip");
}

#[test]
fn unsubscribe_missions_round_trips() {
  let message = ClientMessage::UnsubscribeMissions;

  let json = serde_json::to_string(&message).expect("serialize unsubscribe_missions");
  match serde_json::from_str::<ClientMessage>(&json).expect("deserialize unsubscribe_missions") {
    ClientMessage::UnsubscribeMissions => {}
    other => panic!("unexpected variant for unsubscribe_missions: {:?}", other),
  }
}

#[test]
fn unsubscribe_mission_round_trips() {
  let json = r#"{"type":"unsubscribe_mission","mission_id":"mission-1"}"#;
  let parsed: ClientMessage = serde_json::from_str(json).expect("parse unsubscribe_mission");
  match &parsed {
    ClientMessage::UnsubscribeMission { mission_id } => {
      assert_eq!(mission_id, "mission-1");
    }
    other => panic!("unexpected variant for unsubscribe_mission: {:?}", other),
  }
  let serialized = serde_json::to_string(&parsed).expect("serialize");
  let _: ClientMessage = serde_json::from_str(&serialized).expect("roundtrip");
}

#[test]
fn unsubscribe_sessions_summary_round_trips() {
  let message = ClientMessage::UnsubscribeSessionsSummary;

  let json = serde_json::to_string(&message).expect("serialize unsubscribe_sessions_summary");
  match serde_json::from_str::<ClientMessage>(&json)
    .expect("deserialize unsubscribe_sessions_summary")
  {
    ClientMessage::UnsubscribeSessionsSummary => {}
    other => panic!(
      "unexpected variant for unsubscribe_sessions_summary: {:?}",
      other
    ),
  }
}
