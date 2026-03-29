use orbitdock_protocol::conversation_contracts::{ConversationRow, ConversationRowEntry};

#[derive(Debug, Clone)]
pub(crate) struct ForkConfigInputs {
  pub requested_model: Option<String>,
  pub requested_approval_policy: Option<String>,
  pub requested_sandbox_mode: Option<String>,
  pub requested_cwd: Option<String>,
  pub source_cwd: Option<String>,
  pub source_model: Option<String>,
  pub source_approval_policy: Option<String>,
  pub source_sandbox_mode: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ForkConfigPlan {
  pub effective_cwd: Option<String>,
  pub effective_model: Option<String>,
  pub effective_approval_policy: Option<String>,
  pub effective_sandbox_mode: Option<String>,
}

pub(crate) fn plan_fork_config(input: ForkConfigInputs) -> ForkConfigPlan {
  ForkConfigPlan {
    effective_cwd: input.requested_cwd.or(input.source_cwd),
    effective_model: input.requested_model.or(input.source_model),
    effective_approval_policy: input
      .requested_approval_policy
      .or(input.source_approval_policy),
    effective_sandbox_mode: input.requested_sandbox_mode.or(input.source_sandbox_mode),
  }
}

pub(crate) fn truncate_rows_before_nth_user_row(
  rows: &[ConversationRowEntry],
  nth_user_row: Option<u32>,
) -> Vec<ConversationRowEntry> {
  let Some(nth_user_row) = nth_user_row else {
    return rows.to_vec();
  };

  let mut user_count = 0usize;
  let mut cut_idx: Option<usize> = None;

  for (idx, entry) in rows.iter().enumerate() {
    if entry.row.starts_turn() {
      if user_count == nth_user_row as usize {
        cut_idx = Some(idx);
        break;
      }
      user_count += 1;
    }
  }

  match cut_idx {
    Some(idx) => rows[..idx].to_vec(),
    None => Vec::new(),
  }
}

pub(crate) fn remap_rows_for_fork(
  rows: Vec<ConversationRowEntry>,
  new_session_id: &str,
) -> Vec<ConversationRowEntry> {
  rows
    .into_iter()
    .enumerate()
    .map(|(idx, mut entry)| {
      let new_id = format!("{new_session_id}:fork:{idx}");
      // Update the ID inside the row variant
      match &mut entry.row {
        ConversationRow::User(row)
        | ConversationRow::Steer(row)
        | ConversationRow::Assistant(row)
        | ConversationRow::Thinking(row)
        | ConversationRow::System(row) => {
          row.id = new_id;
        }
        ConversationRow::Context(row) => {
          row.id = new_id;
        }
        ConversationRow::Notice(row) => {
          row.id = new_id;
        }
        ConversationRow::ShellCommand(row) => {
          row.id = new_id;
        }
        ConversationRow::Task(row) => {
          row.id = new_id;
        }
        ConversationRow::Tool(row) => {
          row.id = new_id;
        }
        ConversationRow::Plan(row) => {
          row.id = new_id;
        }
        ConversationRow::Hook(row) => {
          row.id = new_id;
        }
        ConversationRow::Handoff(row) => {
          row.id = new_id;
        }
        ConversationRow::ActivityGroup(row) => {
          row.id = new_id;
        }
        ConversationRow::Question(row) => {
          row.id = new_id;
        }
        ConversationRow::Approval(row) => {
          row.id = new_id;
        }
        ConversationRow::Worker(row) => {
          row.id = new_id;
        }
        ConversationRow::CommandExecution(row) => {
          row.id = new_id;
        }
      }
      entry.session_id = new_session_id.to_string();
      entry
    })
    .collect()
}

pub(crate) fn select_fork_rows(
  source_rows: Vec<ConversationRowEntry>,
  rollout_rows: Vec<ConversationRowEntry>,
) -> Vec<ConversationRowEntry> {
  if source_rows.len() >= rollout_rows.len() {
    source_rows
  } else {
    rollout_rows
  }
}

#[cfg(test)]
mod tests {
  use super::truncate_rows_before_nth_user_row;
  use orbitdock_protocol::conversation_contracts::{
    rows::MessageDeliveryStatus, ConversationRow, ConversationRowEntry, MessageRowContent,
  };

  fn user_row(id: &str, content: &str, is_steer: bool) -> ConversationRowEntry {
    ConversationRowEntry {
      session_id: "session-1".to_string(),
      sequence: 0,
      turn_id: None,
      turn_status: Default::default(),
      row: if is_steer {
        ConversationRow::Steer(MessageRowContent {
          id: id.to_string(),
          content: content.to_string(),
          turn_id: None,
          timestamp: None,
          is_streaming: false,
          images: vec![],
          memory_citation: None,
          delivery_status: Some(MessageDeliveryStatus::Pending),
        })
      } else {
        ConversationRow::User(MessageRowContent {
          id: id.to_string(),
          content: content.to_string(),
          turn_id: None,
          timestamp: None,
          is_streaming: false,
          images: vec![],
          memory_citation: None,
          delivery_status: Some(MessageDeliveryStatus::Pending),
        })
      },
    }
  }

  #[test]
  fn truncate_counts_real_user_turns_and_skips_steers() {
    let rows = vec![
      user_row("user-1", "first", false),
      user_row("steer-1", "nudge", true),
      user_row("user-2", "second", false),
    ];

    let truncated = truncate_rows_before_nth_user_row(&rows, Some(1));

    assert_eq!(truncated.len(), 2);
    assert_eq!(truncated[0].id(), "user-1");
    assert_eq!(truncated[1].id(), "steer-1");
  }
}
