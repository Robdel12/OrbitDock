use orbitdock_protocol::conversation_contracts::{ConversationRow, ConversationRowEntry};
use orbitdock_protocol::{ServerMessage, StateChanges};

/// Inject approval_version into approval-related transport messages so clients
/// can ignore stale events.
pub(crate) fn inject_approval_version(msg: &mut ServerMessage, version: u64) {
    match msg {
        ServerMessage::ApprovalRequested {
            approval_version, ..
        } => {
            *approval_version = Some(version);
        }
        ServerMessage::SessionDelta { changes, .. } => {
            if changes.pending_approval.is_some() && changes.approval_version.is_none() {
                changes.approval_version = Some(version);
            }
        }
        _ => {}
    }
}

fn completed_conversation_row_snippet(entry: &ConversationRowEntry) -> Option<String> {
    match &entry.row {
        ConversationRow::User(row) | ConversationRow::Assistant(row) => {
            Some(row.content.chars().take(200).collect())
        }
        _ => None,
    }
}

pub(crate) fn latest_completed_conversation_row(rows: &[ConversationRowEntry]) -> Option<String> {
    rows.iter()
        .rev()
        .find_map(completed_conversation_row_snippet)
}

pub(crate) fn should_increment_unread_for_row(entry: &ConversationRowEntry) -> bool {
    !matches!(entry.row, ConversationRow::User(_))
}

pub(crate) fn row_append_delta(
    previous_last_message: Option<&str>,
    entry: &ConversationRowEntry,
    unread_count: u64,
) -> Option<StateChanges> {
    let last_message = completed_conversation_row_snippet(entry)
        .filter(|snippet| previous_last_message != Some(snippet.as_str()))
        .map(Some);
    let unread_count = should_increment_unread_for_row(entry).then_some(unread_count);

    if last_message.is_none() && unread_count.is_none() {
        return None;
    }

    Some(StateChanges {
        last_message,
        unread_count,
        ..Default::default()
    })
}

pub(crate) fn transition_delta(
    previous_last_message: Option<&str>,
    rows: &[ConversationRowEntry],
    unread_count: Option<u64>,
) -> Option<StateChanges> {
    let last_message = latest_completed_conversation_row(rows)
        .filter(|snippet| previous_last_message != Some(snippet.as_str()))
        .map(Some);

    if last_message.is_none() && unread_count.is_none() {
        return None;
    }

    Some(StateChanges {
        last_message,
        unread_count,
        ..Default::default()
    })
}
