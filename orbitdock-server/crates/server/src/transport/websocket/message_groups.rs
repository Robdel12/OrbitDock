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
