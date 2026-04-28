use orbitdock_protocol::conversation_contracts::{ConversationRow, TurnStatus};

pub(crate) fn row_type_str(row: &ConversationRow) -> &'static str {
  match row {
    ConversationRow::User(_) => "user",
    ConversationRow::Steer(_) => "steer",
    ConversationRow::Assistant(_) => "assistant",
    ConversationRow::Thinking(_) => "thinking",
    ConversationRow::Context(_) => "context",
    ConversationRow::Notice(_) => "notice",
    ConversationRow::ShellCommand(_) => "shell_command",
    ConversationRow::Task(_) => "task",
    ConversationRow::Tool(_) => "tool",
    ConversationRow::ActivityGroup(_) => "activity_group",
    ConversationRow::Question(_) => "question",
    ConversationRow::Approval(_) => "approval",
    ConversationRow::Worker(_) => "worker",
    ConversationRow::Plan(_) => "plan",
    ConversationRow::Hook(_) => "hook",
    ConversationRow::Handoff(_) => "handoff",
    ConversationRow::System(_) => "system",
  }
}

pub(crate) fn turn_status_str(status: TurnStatus) -> &'static str {
  match status {
    TurnStatus::Active => "active",
    TurnStatus::Undone => "undone",
    TurnStatus::RolledBack => "rolled_back",
  }
}

pub(crate) fn extract_row_content(row: &ConversationRow) -> Option<String> {
  match row {
    ConversationRow::User(m)
    | ConversationRow::Steer(m)
    | ConversationRow::Assistant(m)
    | ConversationRow::Thinking(m)
    | ConversationRow::System(m) => Some(m.content.clone()),
    ConversationRow::Context(c) => Some(c.summary.clone().unwrap_or_else(|| c.title.clone())),
    ConversationRow::Notice(n) => Some(n.summary.clone().unwrap_or_else(|| n.title.clone())),
    ConversationRow::ShellCommand(s) => Some(
      s.summary
        .clone()
        .or_else(|| s.command.clone())
        .unwrap_or_else(|| s.title.clone()),
    ),
    ConversationRow::Task(t) => Some(t.summary.clone().unwrap_or_else(|| t.title.clone())),
    ConversationRow::Tool(t) => Some(t.title.clone()),
    ConversationRow::Plan(p) => Some(p.title.clone()),
    ConversationRow::Hook(h) => Some(h.title.clone()),
    ConversationRow::Handoff(h) => Some(h.title.clone()),
    ConversationRow::Worker(w) => Some(w.title.clone()),
    ConversationRow::Approval(a) => Some(a.id.clone()),
    ConversationRow::Question(q) => Some(q.id.clone()),
    ConversationRow::ActivityGroup(g) => Some(g.title.clone()),
  }
}
