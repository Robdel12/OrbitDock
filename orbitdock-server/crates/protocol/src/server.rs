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
    SessionForked {
        source_session_id: String,
        new_session_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        forked_from_thread_id: Option<String>,
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
    // Codex account/auth status
    CodexAccountStatus {
        status: CodexAccountStatus,
    },
    CodexLoginChatgptStarted {
        login_id: String,
        auth_url: String,
    },
    CodexLoginChatgptCompleted {
        login_id: String,
        success: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    CodexLoginChatgptCanceled {
        login_id: String,
        status: CodexLoginCancelStatus,
    },
    CodexAccountUpdated {
        status: CodexAccountStatus,
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

    // Claude capabilities (from init system message)
    ClaudeCapabilities {
        session_id: String,
        slash_commands: Vec<String>,
        skills: Vec<String>,
        tools: Vec<String>,
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

    // Turn diffs
    TurnDiffSnapshot {
        session_id: String,
        turn_id: String,
        diff: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        input_tokens: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        output_tokens: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        cached_tokens: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        context_window: Option<u64>,
    },

    // Review comments
    ReviewCommentCreated {
        session_id: String,
        comment: ReviewComment,
    },
    ReviewCommentUpdated {
        session_id: String,
        comment: ReviewComment,
    },
    ReviewCommentDeleted {
        session_id: String,
        comment_id: String,
    },
    ReviewCommentsList {
        session_id: String,
        comments: Vec<ReviewComment>,
    },

    // Subagent tools
    SubagentToolsList {
        session_id: String,
        subagent_id: String,
        tools: Vec<SubagentTool>,
    },

    // Shell execution results
    ShellStarted {
        session_id: String,
        request_id: String,
        command: String,
    },
    ShellOutput {
        session_id: String,
        request_id: String,
        stdout: String,
        stderr: String,
        exit_code: Option<i32>,
        duration_ms: u64,
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

    #[test]
    fn roundtrip_codex_account_status() {
        let msg = ServerMessage::CodexAccountStatus {
            status: CodexAccountStatus {
                auth_mode: Some(CodexAuthMode::Chatgpt),
                requires_openai_auth: true,
                account: Some(CodexAccount::Chatgpt {
                    email: Some("user@example.com".to_string()),
                    plan_type: Some("plus".to_string()),
                }),
                login_in_progress: false,
                active_login_id: None,
            },
        };

        let json = serde_json::to_string(&msg).expect("serialize");
        let reparsed: ServerMessage = serde_json::from_str(&json).expect("deserialize");
        match reparsed {
            ServerMessage::CodexAccountStatus { status } => {
                assert_eq!(status.auth_mode, Some(CodexAuthMode::Chatgpt));
                assert!(status.requires_openai_auth);
                assert!(!status.login_in_progress);
            }
            other => panic!("unexpected variant: {:?}", other),
        }
    }

    #[test]
    fn roundtrip_codex_login_chatgpt_started() {
        let msg = ServerMessage::CodexLoginChatgptStarted {
            login_id: "f4d72d8c-f4d0-4bf9-8c2f-66d6d6d6d6d6".to_string(),
            auth_url: "https://chatgpt.com/auth".to_string(),
        };

        let json = serde_json::to_string(&msg).expect("serialize");
        let reparsed: ServerMessage = serde_json::from_str(&json).expect("deserialize");
        match reparsed {
            ServerMessage::CodexLoginChatgptStarted { login_id, auth_url } => {
                assert_eq!(login_id, "f4d72d8c-f4d0-4bf9-8c2f-66d6d6d6d6d6");
                assert_eq!(auth_url, "https://chatgpt.com/auth");
            }
            other => panic!("unexpected variant: {:?}", other),
        }
    }

    #[test]
    fn roundtrip_codex_login_chatgpt_completed() {
        let msg = ServerMessage::CodexLoginChatgptCompleted {
            login_id: "f4d72d8c-f4d0-4bf9-8c2f-66d6d6d6d6d6".to_string(),
            success: false,
            error: Some("Login timed out".to_string()),
        };

        let json = serde_json::to_string(&msg).expect("serialize");
        let reparsed: ServerMessage = serde_json::from_str(&json).expect("deserialize");
        match reparsed {
            ServerMessage::CodexLoginChatgptCompleted {
                login_id,
                success,
                error,
            } => {
                assert_eq!(login_id, "f4d72d8c-f4d0-4bf9-8c2f-66d6d6d6d6d6");
                assert!(!success);
                assert_eq!(error.as_deref(), Some("Login timed out"));
            }
            other => panic!("unexpected variant: {:?}", other),
        }
    }

    #[test]
    fn roundtrip_codex_login_chatgpt_canceled() {
        let msg = ServerMessage::CodexLoginChatgptCanceled {
            login_id: "f4d72d8c-f4d0-4bf9-8c2f-66d6d6d6d6d6".to_string(),
            status: CodexLoginCancelStatus::Canceled,
        };

        let json = serde_json::to_string(&msg).expect("serialize");
        let reparsed: ServerMessage = serde_json::from_str(&json).expect("deserialize");
        match reparsed {
            ServerMessage::CodexLoginChatgptCanceled { login_id, status } => {
                assert_eq!(login_id, "f4d72d8c-f4d0-4bf9-8c2f-66d6d6d6d6d6");
                assert_eq!(status, CodexLoginCancelStatus::Canceled);
            }
            other => panic!("unexpected variant: {:?}", other),
        }
    }

    #[test]
    fn test_session_forked_roundtrip() {
        let msg = ServerMessage::SessionForked {
            source_session_id: "sess-src-1".to_string(),
            new_session_id: "sess-fork-1".to_string(),
            forked_from_thread_id: Some("thread-abc-123".to_string()),
        };

        let json = serde_json::to_string(&msg).expect("serialize");
        let reparsed: ServerMessage = serde_json::from_str(&json).expect("deserialize");
        match reparsed {
            ServerMessage::SessionForked {
                source_session_id,
                new_session_id,
                forked_from_thread_id,
            } => {
                assert_eq!(source_session_id, "sess-src-1");
                assert_eq!(new_session_id, "sess-fork-1");
                assert_eq!(forked_from_thread_id.as_deref(), Some("thread-abc-123"));
            }
            other => panic!("unexpected variant: {:?}", other),
        }
    }

    #[test]
    fn session_forked_without_thread_id() {
        let msg = ServerMessage::SessionForked {
            source_session_id: "sess-src-2".to_string(),
            new_session_id: "sess-fork-2".to_string(),
            forked_from_thread_id: None,
        };

        let json = serde_json::to_string(&msg).expect("serialize");
        // Ensure forked_from_thread_id is omitted when None
        assert!(!json.contains("forked_from_thread_id"));
        let _: ServerMessage = serde_json::from_str(&json).expect("roundtrip");
    }

    #[test]
    fn roundtrip_review_comment_created() {
        let comment = ReviewComment {
            id: "rc-abc-123".to_string(),
            session_id: "sess-1".to_string(),
            turn_id: Some("turn-1".to_string()),
            file_path: "src/main.rs".to_string(),
            line_start: 42,
            line_end: Some(45),
            body: "This function should handle errors".to_string(),
            tag: Some(ReviewCommentTag::Risk),
            status: ReviewCommentStatus::Open,
            created_at: "2024-01-15T10:30:00Z".to_string(),
            updated_at: None,
        };

        let msg = ServerMessage::ReviewCommentCreated {
            session_id: "sess-1".to_string(),
            comment,
        };

        let json = serde_json::to_string(&msg).expect("serialize");
        let reparsed: ServerMessage = serde_json::from_str(&json).expect("deserialize");
        match reparsed {
            ServerMessage::ReviewCommentCreated {
                session_id,
                comment,
            } => {
                assert_eq!(session_id, "sess-1");
                assert_eq!(comment.id, "rc-abc-123");
                assert_eq!(comment.file_path, "src/main.rs");
                assert_eq!(comment.line_start, 42);
                assert_eq!(comment.line_end, Some(45));
                assert_eq!(comment.tag, Some(ReviewCommentTag::Risk));
                assert_eq!(comment.status, ReviewCommentStatus::Open);
            }
            other => panic!("unexpected variant: {:?}", other),
        }
    }

    #[test]
    fn roundtrip_turn_diff_snapshot() {
        let msg = ServerMessage::TurnDiffSnapshot {
            session_id: "sess-1".to_string(),
            turn_id: "turn-3".to_string(),
            diff: "--- a/foo.rs\n+++ b/foo.rs\n@@ -1 +1 @@\n-old\n+new".to_string(),
            input_tokens: Some(5000),
            output_tokens: Some(1200),
            cached_tokens: Some(3000),
            context_window: Some(200000),
        };

        let json = serde_json::to_string(&msg).expect("serialize");
        let reparsed: ServerMessage = serde_json::from_str(&json).expect("deserialize");
        match reparsed {
            ServerMessage::TurnDiffSnapshot {
                session_id,
                turn_id,
                diff,
                input_tokens,
                output_tokens,
                cached_tokens,
                context_window,
            } => {
                assert_eq!(session_id, "sess-1");
                assert_eq!(turn_id, "turn-3");
                assert!(diff.contains("+new"));
                assert_eq!(input_tokens, Some(5000));
                assert_eq!(output_tokens, Some(1200));
                assert_eq!(cached_tokens, Some(3000));
                assert_eq!(context_window, Some(200000));
            }
            other => panic!("unexpected variant: {:?}", other),
        }
    }
}
