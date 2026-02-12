//! Server → Client messages

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::types::*;

/// Messages sent from server to client
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    // Full state sync
    SessionsList {
        sessions: Vec<SessionSummary>,
    },
    SessionSnapshot {
        session: SessionState,
    },

    // Incremental updates
    SessionDelta {
        session_id: String,
        changes: StateChanges,
    },
    MessageAppended {
        session_id: String,
        message: Message,
    },
    MessageUpdated {
        session_id: String,
        message_id: String,
        changes: MessageChanges,
    },
    ApprovalRequested {
        session_id: String,
        request: ApprovalRequest,
    },
    TokensUpdated {
        session_id: String,
        usage: TokenUsage,
    },

    // Lifecycle
    SessionCreated {
        session: SessionSummary,
    },
    SessionEnded {
        session_id: String,
        reason: String,
    },

    // Approval history
    ApprovalsList {
        session_id: Option<String>,
        approvals: Vec<ApprovalHistoryItem>,
    },
    ApprovalDeleted {
        approval_id: i64,
    },

    // Codex models
    ModelsList {
        models: Vec<CodexModelOption>,
    },

    // Skills
    SkillsList {
        session_id: String,
        skills: Vec<SkillsListEntry>,
        errors: Vec<SkillErrorInfo>,
    },
    RemoteSkillsList {
        session_id: String,
        skills: Vec<RemoteSkillSummary>,
    },
    RemoteSkillDownloaded {
        session_id: String,
        id: String,
        name: String,
        path: String,
    },
    SkillsUpdateAvailable {
        session_id: String,
    },

    // MCP
    McpToolsList {
        session_id: String,
        tools: HashMap<String, McpTool>,
        resources: HashMap<String, Vec<McpResource>>,
        resource_templates: HashMap<String, Vec<McpResourceTemplate>>,
        auth_statuses: HashMap<String, McpAuthStatus>,
    },
    McpStartupUpdate {
        session_id: String,
        server: String,
        status: McpStartupStatus,
    },
    McpStartupComplete {
        session_id: String,
        ready: Vec<String>,
        failed: Vec<McpStartupFailure>,
        cancelled: Vec<String>,
    },

    // Context management
    ContextCompacted {
        session_id: String,
    },
    UndoStarted {
        session_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    UndoCompleted {
        session_id: String,
        success: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    ThreadRolledBack {
        session_id: String,
        num_turns: u32,
    },

    // Errors
    Error {
        code: String,
        message: String,
        session_id: Option<String>,
    },
}

#[cfg(test)]
mod tests {
    use super::ServerMessage;
    use crate::types::*;
    use std::collections::HashMap;

    #[test]
    fn roundtrip_mcp_tools_list() {
        let mut tools = HashMap::new();
        tools.insert(
            "server__tool".to_string(),
            McpTool {
                name: "tool".to_string(),
                title: Some("My Tool".to_string()),
                description: Some("Does stuff".to_string()),
                input_schema: serde_json::json!({"type": "object"}),
                output_schema: None,
                annotations: None,
            },
        );

        let mut resources = HashMap::new();
        resources.insert(
            "server".to_string(),
            vec![McpResource {
                name: "res".to_string(),
                uri: "file:///tmp".to_string(),
                description: None,
                mime_type: Some("text/plain".to_string()),
                title: None,
                size: Some(42),
                annotations: None,
            }],
        );

        let mut auth_statuses = HashMap::new();
        auth_statuses.insert("server".to_string(), McpAuthStatus::Unsupported);

        let msg = ServerMessage::McpToolsList {
            session_id: "sess-1".to_string(),
            tools,
            resources,
            resource_templates: HashMap::new(),
            auth_statuses,
        };

        let json = serde_json::to_string(&msg).expect("serialize");
        let reparsed: ServerMessage = serde_json::from_str(&json).expect("deserialize");
        match reparsed {
            ServerMessage::McpToolsList {
                session_id,
                tools,
                auth_statuses,
                ..
            } => {
                assert_eq!(session_id, "sess-1");
                assert_eq!(tools.len(), 1);
                assert!(tools.contains_key("server__tool"));
                assert_eq!(
                    auth_statuses.get("server"),
                    Some(&McpAuthStatus::Unsupported)
                );
            }
            other => panic!("unexpected variant: {:?}", other),
        }
    }

    #[test]
    fn roundtrip_mcp_startup_update() {
        let msg = ServerMessage::McpStartupUpdate {
            session_id: "sess-2".to_string(),
            server: "my-server".to_string(),
            status: McpStartupStatus::Failed {
                error: "connection refused".to_string(),
            },
        };

        let json = serde_json::to_string(&msg).expect("serialize");
        let reparsed: ServerMessage = serde_json::from_str(&json).expect("deserialize");
        match reparsed {
            ServerMessage::McpStartupUpdate {
                session_id,
                server,
                status,
            } => {
                assert_eq!(session_id, "sess-2");
                assert_eq!(server, "my-server");
                match status {
                    McpStartupStatus::Failed { error } => {
                        assert_eq!(error, "connection refused");
                    }
                    other => panic!("expected Failed, got {:?}", other),
                }
            }
            other => panic!("unexpected variant: {:?}", other),
        }
    }

    #[test]
    fn roundtrip_mcp_startup_complete() {
        let msg = ServerMessage::McpStartupComplete {
            session_id: "sess-3".to_string(),
            ready: vec!["server-a".to_string()],
            failed: vec![McpStartupFailure {
                server: "server-b".to_string(),
                error: "timeout".to_string(),
            }],
            cancelled: vec!["server-c".to_string()],
        };

        let json = serde_json::to_string(&msg).expect("serialize");
        let reparsed: ServerMessage = serde_json::from_str(&json).expect("deserialize");
        match reparsed {
            ServerMessage::McpStartupComplete {
                session_id,
                ready,
                failed,
                cancelled,
            } => {
                assert_eq!(session_id, "sess-3");
                assert_eq!(ready, vec!["server-a"]);
                assert_eq!(failed.len(), 1);
                assert_eq!(failed[0].server, "server-b");
                assert_eq!(failed[0].error, "timeout");
                assert_eq!(cancelled, vec!["server-c"]);
            }
            other => panic!("unexpected variant: {:?}", other),
        }
    }
}
