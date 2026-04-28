use orbitdock_protocol::ClientMessage;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum MessageGroup {
  Subscribe,
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

    ClientMessage::ClaudeSessionStart { .. }
    | ClientMessage::ClaudeSessionEnd { .. }
    | ClientMessage::ClaudeStatusEvent(_)
    | ClientMessage::ClaudeToolEvent(_)
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
