use tokio::sync::mpsc;

use orbitdock_protocol::{ServerMessage, StateChanges, WorkStatus};

use crate::domain::sessions::session::SessionHandle;
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_broadcasts::row_append_delta;

async fn execute_persist_command(cmd: PersistCommand, persist_tx: &mpsc::Sender<PersistCommand>) {
  let _ = persist_tx.send(cmd).await;
}

pub(crate) async fn execute_session_persist_op(
  cmd: PersistCommand,
  persist_tx: &mpsc::Sender<PersistCommand>,
) {
  execute_persist_command(cmd, persist_tx).await;
}

pub(crate) async fn apply_delta_and_broadcast(
  handle: &mut SessionHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
  changes: StateChanges,
  persist_op: Option<PersistCommand>,
) {
  let session_id = handle.id().to_string();
  handle.apply_changes(&changes);
  if let Some(cmd) = persist_op {
    execute_persist_command(cmd, persist_tx).await;
  }
  let mut changes = changes;
  include_derived_affordances_for_state_delta(&mut changes, handle);
  handle.broadcast(ServerMessage::SessionDelta {
    session_id,
    changes: Box::new(changes),
  });
}

fn include_derived_affordances_for_state_delta(changes: &mut StateChanges, handle: &SessionHandle) {
  if changes.status.is_none()
    && changes.work_status.is_none()
    && changes.control_mode.is_none()
    && changes.lifecycle_state.is_none()
  {
    return;
  }

  let snapshot = handle.to_snapshot();
  let retained = handle.retained_state();
  changes.steerable = Some(snapshot.steerable);
  changes.accepts_user_input = Some(retained.accepts_user_input);
}

async fn persist_and_broadcast_mark_read(
  handle: &mut SessionHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
) {
  let prev = handle.mark_read();
  if prev == 0 {
    return;
  }

  let session_id = handle.id().to_string();
  let _ = persist_tx
    .send(PersistCommand::MarkSessionRead {
      session_id: session_id.clone(),
      up_to_sequence: handle.latest_row_sequence() as i64,
    })
    .await;

  // When the user reads a session in Reply state, transition to Waiting.
  // Reply means "has unread response"; once read, it becomes "idle/waiting."
  let mut changes = StateChanges {
    unread_count: Some(0),
    ..Default::default()
  };
  if handle.work_status() == WorkStatus::Reply {
    changes.work_status = Some(WorkStatus::Waiting);
    handle.set_work_status(WorkStatus::Waiting);
    let _ = persist_tx
      .send(PersistCommand::SessionUpdate {
        id: session_id.clone(),
        status: None,
        work_status: Some(WorkStatus::Waiting),
        control_mode: None,
        lifecycle_state: None,
        last_activity_at: None,
        last_progress_at: None,
      })
      .await;
  }

  handle.broadcast(ServerMessage::SessionDelta {
    session_id: session_id.clone(),
    changes: Box::new(changes),
  });
}

async fn persist_upserted_row_and_broadcast(
  handle: &mut SessionHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
  entry: orbitdock_protocol::conversation_contracts::ConversationRowEntry,
) {
  let session_id = handle.id().to_string();
  let row_id = entry.id().to_string();
  let entry = handle.upsert_row(entry);

  let (seq_tx, seq_rx) = tokio::sync::oneshot::channel();
  let _ = persist_tx
    .send(PersistCommand::RowUpsert {
      session_id: session_id.clone(),
      entry: entry.clone(),
      viewer_present: handle.has_active_viewers(),
      assigned_sequence: None,
      sequence_tx: Some(seq_tx),
    })
    .await;

  if let Ok(db_seq) = seq_rx.await {
    handle.set_row_sequence(&row_id, db_seq);
  }

  let summary = handle
    .row_by_id(&row_id)
    .map(|row| row.to_transport_summary())
    .unwrap_or_else(|| entry.to_transport_summary());
  handle.broadcast(ServerMessage::ConversationRowsChanged {
    session_id,
    upserted: vec![summary],
    removed_row_ids: vec![],
    total_row_count: handle.message_count() as u64,
  });
}

async fn append_row_and_broadcast(
  handle: &mut SessionHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
  entry: orbitdock_protocol::conversation_contracts::ConversationRowEntry,
) -> orbitdock_protocol::conversation_contracts::ConversationRowEntry {
  let session_id = handle.id().to_string();
  let previous_last_message = handle.to_snapshot().last_message.clone();

  let entry = handle.add_row(entry);
  let row_id = entry.id().to_string();
  let viewer_present = handle.has_active_viewers();
  let unread_count_delta = handle.unread_count_after_row_append(&entry);

  let (seq_tx, seq_rx) = tokio::sync::oneshot::channel();
  let _ = persist_tx
    .send(PersistCommand::RowAppend {
      session_id: session_id.clone(),
      entry: entry.clone(),
      viewer_present,
      assigned_sequence: None,
      sequence_tx: Some(seq_tx),
    })
    .await;

  if let Ok(db_seq) = seq_rx.await {
    handle.set_row_sequence(&row_id, db_seq);
  }

  let final_entry = handle.row_by_id(&row_id).cloned().unwrap_or(entry);
  let observability_changes = row_append_delta(
    previous_last_message.as_deref(),
    &final_entry,
    unread_count_delta,
  );
  let summary = final_entry.to_transport_summary();
  let upserted = vec![summary];
  if handle.should_emit_streaming_row_update(&upserted) {
    handle.broadcast(ServerMessage::ConversationRowsChanged {
      session_id: session_id.clone(),
      upserted,
      removed_row_ids: vec![],
      total_row_count: handle.message_count() as u64,
    });
  }
  if let Some(changes) = observability_changes {
    handle.broadcast(ServerMessage::SessionDelta {
      session_id: handle.id().to_string(),
      changes: Box::new(changes),
    });
  }

  final_entry
}

pub(crate) async fn persist_mark_read(
  handle: &mut SessionHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
) {
  persist_and_broadcast_mark_read(handle, persist_tx).await;
}

pub(crate) async fn persist_row_append_and_broadcast(
  handle: &mut SessionHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
  entry: orbitdock_protocol::conversation_contracts::ConversationRowEntry,
) -> orbitdock_protocol::conversation_contracts::ConversationRowEntry {
  append_row_and_broadcast(handle, persist_tx, entry).await
}

pub(crate) async fn persist_row_upsert_and_broadcast(
  handle: &mut SessionHandle,
  persist_tx: &mpsc::Sender<PersistCommand>,
  entry: orbitdock_protocol::conversation_contracts::ConversationRowEntry,
) {
  persist_upserted_row_and_broadcast(handle, persist_tx, entry).await;
}
