use orbitdock_protocol::ClientMessage;

use super::rest_only_policy::rest_only_route;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum MessageGroup {
    Subscribe,
    SessionCrud,
    SessionLifecycle,
    Messaging,
    Approvals,
    Config,
    ClaudeHooks,
    Shell,
    RestOnly,
}

pub(crate) fn classify_client_message(message: &ClientMessage) -> MessageGroup {
    if rest_only_route(message).is_some() {
        return MessageGroup::RestOnly;
    }

    match message {
        ClientMessage::SubscribeList
        | ClientMessage::SubscribeSession { .. }
        | ClientMessage::UnsubscribeSession { .. } => MessageGroup::Subscribe,

        ClientMessage::CreateSession { .. }
        | ClientMessage::EndSession { .. }
        | ClientMessage::RenameSession { .. }
        | ClientMessage::UpdateSessionConfig { .. }
        | ClientMessage::ForkSession { .. }
        | ClientMessage::ForkSessionToWorktree { .. }
        | ClientMessage::ForkSessionToExistingWorktree { .. } => MessageGroup::SessionCrud,

        ClientMessage::ResumeSession { .. } | ClientMessage::TakeoverSession { .. } => {
            MessageGroup::SessionLifecycle
        }

        ClientMessage::SendMessage { .. }
        | ClientMessage::SteerTurn { .. }
        | ClientMessage::AnswerQuestion { .. }
        | ClientMessage::RespondToPermissionRequest { .. }
        | ClientMessage::InterruptSession { .. }
        | ClientMessage::CompactContext { .. }
        | ClientMessage::UndoLastTurn { .. }
        | ClientMessage::RollbackTurns { .. }
        | ClientMessage::StopTask { .. }
        | ClientMessage::RewindFiles { .. } => MessageGroup::Messaging,

        ClientMessage::ApproveTool { .. }
        | ClientMessage::ListApprovals { .. }
        | ClientMessage::DeleteApproval { .. } => MessageGroup::Approvals,

        ClientMessage::SetClientPrimaryClaim { .. } => MessageGroup::Config,

        ClientMessage::ClaudeSessionStart { .. }
        | ClientMessage::ClaudeSessionEnd { .. }
        | ClientMessage::ClaudeStatusEvent { .. }
        | ClientMessage::ClaudeToolEvent { .. }
        | ClientMessage::ClaudeSubagentEvent { .. }
        | ClientMessage::GetSubagentTools { .. } => MessageGroup::ClaudeHooks,

        ClientMessage::ExecuteShell { .. } | ClientMessage::CancelShell { .. } => {
            MessageGroup::Shell
        }

        _ => unreachable!("rest-only messages should be handled before classification"),
    }
}

#[cfg(test)]
mod tests {
    use orbitdock_protocol::{ClientMessage, Provider};

    use super::{classify_client_message, MessageGroup};

    #[test]
    fn classifies_subscription_messages() {
        assert_eq!(
            classify_client_message(&ClientMessage::SubscribeList),
            MessageGroup::Subscribe
        );
        assert_eq!(
            classify_client_message(&ClientMessage::SubscribeSession {
                session_id: "session-1".to_string(),
                since_revision: None,
                include_snapshot: true,
            }),
            MessageGroup::Subscribe
        );
    }

    #[test]
    fn classifies_live_session_messages() {
        assert_eq!(
            classify_client_message(&ClientMessage::CreateSession {
                provider: Provider::Claude,
                cwd: "/tmp/project".to_string(),
                model: None,
                approval_policy: None,
                sandbox_mode: None,
                permission_mode: None,
                allowed_tools: vec![],
                disallowed_tools: vec![],
                effort: None,
                collaboration_mode: None,
                multi_agent: None,
                personality: None,
                service_tier: None,
                developer_instructions: None,
                system_prompt: None,
                append_system_prompt: None,
            }),
            MessageGroup::SessionCrud
        );
        assert_eq!(
            classify_client_message(&ClientMessage::ResumeSession {
                session_id: "session-1".to_string(),
            }),
            MessageGroup::SessionLifecycle
        );
        assert_eq!(
            classify_client_message(&ClientMessage::SendMessage {
                session_id: "session-1".to_string(),
                content: "hello".to_string(),
                model: None,
                effort: None,
                skills: vec![],
                images: vec![],
                mentions: vec![],
            }),
            MessageGroup::Messaging
        );
    }

    #[test]
    fn classifies_approval_and_shell_messages() {
        assert_eq!(
            classify_client_message(&ClientMessage::ApproveTool {
                session_id: "session-1".to_string(),
                request_id: "approval-1".to_string(),
                decision: "approved".to_string(),
                message: None,
                interrupt: None,
                updated_input: None,
            }),
            MessageGroup::Approvals
        );
        assert_eq!(
            classify_client_message(&ClientMessage::ExecuteShell {
                session_id: "session-1".to_string(),
                command: "pwd".to_string(),
                cwd: None,
                timeout_secs: 30,
            }),
            MessageGroup::Shell
        );
    }

    #[test]
    fn classifies_claude_hook_messages() {
        assert_eq!(
            classify_client_message(&ClientMessage::ClaudeSessionStart {
                session_id: "claude-1".to_string(),
                cwd: "/tmp".to_string(),
                model: None,
                source: None,
                context_label: None,
                transcript_path: None,
                permission_mode: None,
                agent_type: None,
                terminal_session_id: None,
                terminal_app: None,
            }),
            MessageGroup::ClaudeHooks
        );
        assert_eq!(
            classify_client_message(&ClientMessage::GetSubagentTools {
                session_id: "claude-1".to_string(),
                subagent_id: "agent-1".to_string(),
            }),
            MessageGroup::ClaudeHooks
        );
    }

    #[test]
    fn classifies_rest_only_messages() {
        assert_eq!(
            classify_client_message(&ClientMessage::BrowseDirectory {
                path: Some("/tmp".to_string()),
                request_id: "request-1".to_string(),
            }),
            MessageGroup::RestOnly
        );
        assert_eq!(
            classify_client_message(&ClientMessage::ListWorktrees {
                request_id: "request-1".to_string(),
                repo_root: None,
            }),
            MessageGroup::RestOnly
        );
        assert_eq!(
            classify_client_message(&ClientMessage::CreateReviewComment {
                session_id: "session-1".to_string(),
                turn_id: None,
                file_path: "src/main.rs".to_string(),
                line_start: 42,
                line_end: None,
                body: "Needs a test".to_string(),
                tag: None,
            }),
            MessageGroup::RestOnly
        );
        assert_eq!(
            classify_client_message(&ClientMessage::ListRecentProjects {
                request_id: "request-1".to_string(),
            }),
            MessageGroup::RestOnly
        );
    }
}
