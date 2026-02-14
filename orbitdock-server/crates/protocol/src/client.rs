//! Client → Server messages

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::types::{
    ImageInput, MentionInput, Provider, ReviewCommentStatus, ReviewCommentTag, SkillInput,
};

/// Messages sent from client to server
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    // Subscriptions
    SubscribeSession {
        session_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        since_revision: Option<u64>,
    },
    UnsubscribeSession {
        session_id: String,
    },
    SubscribeList,

    // Actions
    SendMessage {
        session_id: String,
        content: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        effort: Option<String>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        skills: Vec<SkillInput>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        images: Vec<ImageInput>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        mentions: Vec<MentionInput>,
    },
    ApproveTool {
        session_id: String,
        request_id: String,
        decision: String,
    },
    AnswerQuestion {
        session_id: String,
        request_id: String,
        answer: String,
    },
    InterruptSession {
        session_id: String,
    },
    EndSession {
        session_id: String,
    },

    // Session config
    UpdateSessionConfig {
        session_id: String,
        approval_policy: Option<String>,
        sandbox_mode: Option<String>,
    },

    // Session naming
    RenameSession {
        session_id: String,
        name: Option<String>,
    },

    // Session management
    CreateSession {
        provider: Provider,
        cwd: String,
        model: Option<String>,
        approval_policy: Option<String>,
        sandbox_mode: Option<String>,
    },
    ResumeSession {
        session_id: String,
    },
    ForkSession {
        source_session_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        nth_user_message: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        approval_policy: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        sandbox_mode: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
    },

    // Approval history
    ListApprovals {
        session_id: Option<String>,
        limit: Option<u32>,
    },
    DeleteApproval {
        approval_id: i64,
    },

    // Codex models
    ListModels,

    // Skills
    ListSkills {
        session_id: String,
        #[serde(default)]
        cwds: Vec<String>,
        #[serde(default)]
        force_reload: bool,
    },
    ListRemoteSkills {
        session_id: String,
    },
    DownloadRemoteSkill {
        session_id: String,
        hazelnut_id: String,
    },

    // MCP
    ListMcpTools {
        session_id: String,
    },
    RefreshMcpServers {
        session_id: String,
    },

    // Turn steering
    SteerTurn {
        session_id: String,
        content: String,
    },

    // Context management
    CompactContext {
        session_id: String,
    },
    UndoLastTurn {
        session_id: String,
    },
    RollbackTurns {
        session_id: String,
        num_turns: u32,
    },

    // Review comments
    CreateReviewComment {
        session_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        turn_id: Option<String>,
        file_path: String,
        line_start: u32,
        #[serde(skip_serializing_if = "Option::is_none")]
        line_end: Option<u32>,
        body: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        tag: Option<ReviewCommentTag>,
    },
    UpdateReviewComment {
        comment_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        body: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        tag: Option<ReviewCommentTag>,
        #[serde(skip_serializing_if = "Option::is_none")]
        status: Option<ReviewCommentStatus>,
    },
    DeleteReviewComment {
        comment_id: String,
    },
    ListReviewComments {
        session_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        turn_id: Option<String>,
    },

    // Claude hook transport (server-owned write path)
    ClaudeSessionStart {
        session_id: String,
        cwd: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        source: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        context_label: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        transcript_path: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        permission_mode: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        agent_type: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        terminal_session_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        terminal_app: Option<String>,
    },
    ClaudeSessionEnd {
        session_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    ClaudeStatusEvent {
        session_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        transcript_path: Option<String>,
        hook_event_name: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        notification_type: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        tool_name: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        stop_hook_active: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        prompt: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        trigger: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        custom_instructions: Option<String>,
    },
    ClaudeToolEvent {
        session_id: String,
        cwd: String,
        hook_event_name: String,
        tool_name: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        tool_input: Option<Value>,
        #[serde(skip_serializing_if = "Option::is_none")]
        tool_response: Option<Value>,
        #[serde(skip_serializing_if = "Option::is_none")]
        tool_use_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        is_interrupt: Option<bool>,
    },
    ClaudeSubagentEvent {
        session_id: String,
        hook_event_name: String,
        agent_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        agent_type: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        agent_transcript_path: Option<String>,
    },
}

#[cfg(test)]
mod tests {
    use super::ClientMessage;

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
    fn roundtrip_list_skills() {
        let json = r#"{
          "type":"list_skills",
          "session_id":"sess-3",
          "cwds":["/tmp/project","/tmp/other"],
          "force_reload":true
        }"#;

        let parsed: ClientMessage = serde_json::from_str(json).expect("parse list_skills");
        match &parsed {
            ClientMessage::ListSkills {
                session_id,
                cwds,
                force_reload,
            } => {
                assert_eq!(session_id, "sess-3");
                assert_eq!(cwds, &["/tmp/project", "/tmp/other"]);
                assert!(*force_reload);
            }
            other => panic!("unexpected variant: {:?}", other),
        }

        // Roundtrip: serialize and deserialize
        let serialized = serde_json::to_string(&parsed).expect("serialize");
        let reparsed: ClientMessage = serde_json::from_str(&serialized).expect("reparse");
        match reparsed {
            ClientMessage::ListSkills {
                session_id,
                cwds,
                force_reload,
            } => {
                assert_eq!(session_id, "sess-3");
                assert_eq!(cwds.len(), 2);
                assert!(force_reload);
            }
            other => panic!("unexpected variant on roundtrip: {:?}", other),
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

        let parsed: ClientMessage =
            serde_json::from_str(json).expect("parse send_message with skills");
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
    fn roundtrip_download_remote_skill() {
        let json = r#"{
          "type":"download_remote_skill",
          "session_id":"sess-6",
          "hazelnut_id":"hz-abc-123"
        }"#;

        let parsed: ClientMessage =
            serde_json::from_str(json).expect("parse download_remote_skill");
        match &parsed {
            ClientMessage::DownloadRemoteSkill {
                session_id,
                hazelnut_id,
            } => {
                assert_eq!(session_id, "sess-6");
                assert_eq!(hazelnut_id, "hz-abc-123");
            }
            other => panic!("unexpected variant: {:?}", other),
        }

        let serialized = serde_json::to_string(&parsed).expect("serialize");
        let _: ClientMessage = serde_json::from_str(&serialized).expect("reparse");
    }

    #[test]
    fn roundtrip_list_mcp_tools() {
        let json = r#"{"type":"list_mcp_tools","session_id":"sess-m1"}"#;
        let parsed: ClientMessage = serde_json::from_str(json).expect("parse list_mcp_tools");
        match &parsed {
            ClientMessage::ListMcpTools { session_id } => {
                assert_eq!(session_id, "sess-m1");
            }
            other => panic!("unexpected variant: {:?}", other),
        }
        let serialized = serde_json::to_string(&parsed).expect("serialize");
        let _: ClientMessage = serde_json::from_str(&serialized).expect("roundtrip");
    }

    #[test]
    fn roundtrip_refresh_mcp_servers() {
        let json = r#"{"type":"refresh_mcp_servers","session_id":"sess-m2"}"#;
        let parsed: ClientMessage = serde_json::from_str(json).expect("parse refresh_mcp_servers");
        match &parsed {
            ClientMessage::RefreshMcpServers { session_id } => {
                assert_eq!(session_id, "sess-m2");
            }
            other => panic!("unexpected variant: {:?}", other),
        }
        let serialized = serde_json::to_string(&parsed).expect("serialize");
        let _: ClientMessage = serde_json::from_str(&serialized).expect("roundtrip");
    }

    #[test]
    fn roundtrip_steer_turn() {
        let json =
            r#"{"type":"steer_turn","session_id":"sess-s1","content":"use postgres instead"}"#;
        let parsed: ClientMessage = serde_json::from_str(json).expect("parse steer_turn");
        match &parsed {
            ClientMessage::SteerTurn {
                session_id,
                content,
            } => {
                assert_eq!(session_id, "sess-s1");
                assert_eq!(content, "use postgres instead");
            }
            other => panic!("unexpected variant: {:?}", other),
        }
        let serialized = serde_json::to_string(&parsed).expect("serialize");
        let _: ClientMessage = serde_json::from_str(&serialized).expect("roundtrip");
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
    fn test_fork_session_roundtrip() {
        let json = r#"{
          "type":"fork_session",
          "source_session_id":"sess-src-1",
          "nth_user_message":3,
          "model":"o3",
          "approval_policy":"on-request",
          "sandbox_mode":"read-only",
          "cwd":"/tmp/fork-target"
        }"#;

        let parsed: ClientMessage = serde_json::from_str(json).expect("parse fork_session");
        match &parsed {
            ClientMessage::ForkSession {
                source_session_id,
                nth_user_message,
                model,
                approval_policy,
                sandbox_mode,
                cwd,
            } => {
                assert_eq!(source_session_id, "sess-src-1");
                assert_eq!(*nth_user_message, Some(3));
                assert_eq!(model.as_deref(), Some("o3"));
                assert_eq!(approval_policy.as_deref(), Some("on-request"));
                assert_eq!(sandbox_mode.as_deref(), Some("read-only"));
                assert_eq!(cwd.as_deref(), Some("/tmp/fork-target"));
            }
            other => panic!("unexpected variant: {:?}", other),
        }

        let serialized = serde_json::to_string(&parsed).expect("serialize");
        let reparsed: ClientMessage = serde_json::from_str(&serialized).expect("reparse");
        match reparsed {
            ClientMessage::ForkSession {
                source_session_id,
                nth_user_message,
                ..
            } => {
                assert_eq!(source_session_id, "sess-src-1");
                assert_eq!(nth_user_message, Some(3));
            }
            other => panic!("unexpected variant on roundtrip: {:?}", other),
        }
    }

    #[test]
    fn fork_session_minimal() {
        let json = r#"{"type":"fork_session","source_session_id":"sess-src-2"}"#;
        let parsed: ClientMessage = serde_json::from_str(json).expect("parse minimal fork_session");
        match &parsed {
            ClientMessage::ForkSession {
                source_session_id,
                nth_user_message,
                model,
                ..
            } => {
                assert_eq!(source_session_id, "sess-src-2");
                assert_eq!(*nth_user_message, None);
                assert_eq!(*model, None);
            }
            other => panic!("unexpected variant: {:?}", other),
        }
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

        let parsed: ClientMessage =
            serde_json::from_str(json).expect("parse send_message with mention");
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
    fn test_subscribe_session_with_revision() {
        let json = r#"{"type":"subscribe_session","session_id":"sess-r1","since_revision":42}"#;
        let parsed: ClientMessage =
            serde_json::from_str(json).expect("parse subscribe_session with revision");
        match &parsed {
            ClientMessage::SubscribeSession {
                session_id,
                since_revision,
            } => {
                assert_eq!(session_id, "sess-r1");
                assert_eq!(*since_revision, Some(42));
            }
            other => panic!("unexpected variant: {:?}", other),
        }
        let serialized = serde_json::to_string(&parsed).expect("serialize");
        let reparsed: ClientMessage = serde_json::from_str(&serialized).expect("reparse");
        match reparsed {
            ClientMessage::SubscribeSession {
                session_id,
                since_revision,
            } => {
                assert_eq!(session_id, "sess-r1");
                assert_eq!(since_revision, Some(42));
            }
            other => panic!("unexpected variant on roundtrip: {:?}", other),
        }
    }

    #[test]
    fn test_subscribe_session_without_revision() {
        let json = r#"{"type":"subscribe_session","session_id":"sess-r2"}"#;
        let parsed: ClientMessage =
            serde_json::from_str(json).expect("parse subscribe_session without revision");
        match &parsed {
            ClientMessage::SubscribeSession {
                session_id,
                since_revision,
            } => {
                assert_eq!(session_id, "sess-r2");
                assert_eq!(*since_revision, None);
            }
            other => panic!("unexpected variant: {:?}", other),
        }
        // Verify None omits the field (backward compat)
        let serialized = serde_json::to_string(&parsed).expect("serialize");
        assert!(
            !serialized.contains("since_revision"),
            "since_revision should be omitted when None"
        );
        let reparsed: ClientMessage = serde_json::from_str(&serialized).expect("reparse");
        match reparsed {
            ClientMessage::SubscribeSession { since_revision, .. } => {
                assert_eq!(since_revision, None);
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

        // Roundtrip
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
}
