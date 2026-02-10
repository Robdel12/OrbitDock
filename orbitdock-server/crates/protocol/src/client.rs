//! Client → Server messages

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::types::Provider;

/// Messages sent from client to server
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    // Subscriptions
    SubscribeSession {
        session_id: String,
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
}
