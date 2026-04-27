use orbitdock_protocol::ClientMessage;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum MessageGroup {
  Subscribe,
  SessionCrud,
  Messaging,
  Approvals,
  ClaudeHooks,
  Shell,
  Terminal,
  ToolPty,
}

pub(crate) fn classify_client_message(message: &ClientMessage) -> MessageGroup {
  match message {
    ClientMessage::SubscribeSessionsSummary { .. }
    | ClientMessage::UnsubscribeSessionsSummary
    | ClientMessage::SubscribeActiveSessions { .. }
    | ClientMessage::UnsubscribeActiveSessions
    | ClientMessage::SubscribeArchivedSessions { .. }
    | ClientMessage::UnsubscribeArchivedSessions
    | ClientMessage::SubscribeMissions { .. }
    | ClientMessage::UnsubscribeMissions
    | ClientMessage::SubscribeMission { .. }
    | ClientMessage::UnsubscribeMission { .. }
    | ClientMessage::SubscribeSessionSurface { .. }
    | ClientMessage::UnsubscribeSessionSurface { .. } => MessageGroup::Subscribe,

    ClientMessage::EndSession { .. }
    | ClientMessage::RenameSession { .. }
    | ClientMessage::UpdateSessionConfig { .. } => MessageGroup::SessionCrud,

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

    ClientMessage::ApproveTool { .. } => MessageGroup::Approvals,

    ClientMessage::ClaudeSessionStart { .. }
    | ClientMessage::ClaudeSessionEnd { .. }
    | ClientMessage::ClaudeStatusEvent { .. }
    | ClientMessage::ClaudeToolEvent { .. }
    | ClientMessage::ClaudeSubagentEvent { .. } => MessageGroup::ClaudeHooks,

    ClientMessage::ExecuteShell { .. } | ClientMessage::CancelShell { .. } => MessageGroup::Shell,

    ClientMessage::CreateTerminal { .. }
    | ClientMessage::TerminalInput { .. }
    | ClientMessage::TerminalResize { .. }
    | ClientMessage::DestroyTerminal { .. } => MessageGroup::Terminal,

    ClientMessage::SubscribeToolPty { .. } | ClientMessage::UnsubscribeToolPty { .. } => {
      MessageGroup::ToolPty
    }

    _ => unreachable!("unsupported websocket client message"),
  }
}
