use super::{ClaudeStatusEventPayload, ClaudeToolEventPayload, ClientMessage};
use crate::types::SessionSurface;

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
    ClientMessage::ClaudeStatusEvent(payload) => {
      let ClaudeStatusEventPayload {
        session_id,
        cwd,
        transcript_path,
        hook_event_name,
        prompt,
        ..
      } = *payload;
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
    ClientMessage::ClaudeToolEvent(payload) => {
      let ClaudeToolEventPayload {
        session_id,
        cwd,
        hook_event_name,
        tool_name,
        tool_input,
        tool_use_id,
        ..
      } = *payload;
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
