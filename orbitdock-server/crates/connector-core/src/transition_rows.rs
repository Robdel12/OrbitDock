use crate::transition::{Effect, PersistOp, TransitionState};
use orbitdock_protocol::conversation_contracts::{
  compute_tool_display, extract_compact_result_text, ConversationRow, ConversationRowEntry,
  ToolDisplayInput, ToolRow,
};
use orbitdock_protocol::domain_events::ToolKind;
use serde_json::Value as JsonValue;

fn is_placeholder_dynamic_tool_invocation(value: &JsonValue) -> bool {
  let Some(obj) = value.as_object() else {
    return false;
  };
  if obj.is_empty() {
    return true;
  }
  if obj.len() != 1 {
    return false;
  }
  obj
    .get("tool_name")
    .and_then(JsonValue::as_str)
    .is_some_and(str::is_empty)
}

fn refresh_tool_display(row: &mut ToolRow) {
  let invocation_ref = row.invocation.is_object().then_some(&row.invocation);
  let result_str = extract_compact_result_text(row.result.as_ref());
  row.tool_display = Some(compute_tool_display(ToolDisplayInput {
    kind: row.kind,
    family: row.family,
    status: row.status,
    title: &row.title,
    subtitle: row.subtitle.as_deref(),
    summary: row.summary.as_deref(),
    duration_ms: row.duration_ms,
    invocation_input: invocation_ref,
    result_output: result_str.as_deref(),
  }));
}

pub(super) fn handle_row_created(
  state: &mut TransitionState,
  sid: &str,
  entry: &mut ConversationRowEntry,
  now: &str,
  effects: &mut Vec<Effect>,
) {
  entry.session_id = sid.to_string();

  // Dedup: skip echoed user rows from the connector
  let is_dup = matches!(&entry.row, ConversationRow::User(u) if {
      state.rows.iter().rev().take(5).any(|existing| {
          matches!(&existing.row, ConversationRow::User(eu) if eu.content == u.content)
      })
  });

  if is_dup {
    return;
  }

  if let Some(existing_pos) = state.rows.iter().position(|row| row.id() == entry.id()) {
    if entry.sequence == 0 {
      entry.sequence = state.rows[existing_pos].sequence;
    }

    if state.rows[existing_pos] == *entry {
      return;
    }

    state.rows[existing_pos] = entry.clone();
    state.last_activity_at = Some(now.to_string());
    state.last_progress_at = Some(now.to_string());

    effects.push(Effect::Persist(Box::new(PersistOp::RowUpsert {
      session_id: sid.to_string(),
      entry: entry.clone(),
    })));
    effects.push(Effect::Emit(Box::new(
      orbitdock_protocol::ServerMessage::ConversationRowsChanged {
        session_id: sid.to_string(),
        upserted: vec![entry.to_summary()],
        removed_row_ids: vec![],
        total_row_count: state.total_row_count,
      },
    )));
    return;
  }

  // In-memory sequence for live ordering; DB assigns authoritative sequence on persist.
  entry.sequence = state.rows.last().map(|r| r.sequence + 1).unwrap_or(0);
  state.rows.push(entry.clone());
  state.total_row_count = entry.sequence + 1;
  state.last_activity_at = Some(now.to_string());
  state.last_progress_at = Some(now.to_string());

  effects.push(Effect::Persist(Box::new(PersistOp::RowAppend {
    session_id: sid.to_string(),
    entry: entry.clone(),
  })));

  // Increment tool_count for tool rows
  if matches!(&entry.row, ConversationRow::Tool(_)) {
    effects.push(Effect::Persist(Box::new(PersistOp::ToolCountIncrement {
      session_id: sid.to_string(),
    })));
  }

  effects.push(Effect::Emit(Box::new(
    orbitdock_protocol::ServerMessage::ConversationRowsChanged {
      session_id: sid.to_string(),
      upserted: vec![entry.to_summary()],
      removed_row_ids: vec![],
      total_row_count: state.total_row_count,
    },
  )));
}

pub(super) fn handle_row_updated(
  state: &mut TransitionState,
  sid: &str,
  row_id: String,
  entry: &mut ConversationRowEntry,
  now: &str,
  effects: &mut Vec<Effect>,
) {
  // Replace the existing row in state if found, otherwise upsert it into
  // the retained window so out-of-order provider updates do not vanish.
  if let Some(existing) = state.rows.iter_mut().find(|e| e.id() == row_id.as_str()) {
    if let (ConversationRow::Tool(existing_tool), ConversationRow::Tool(incoming_tool)) =
      (&existing.row, &mut entry.row)
    {
      let mut changed = false;
      if incoming_tool.kind == ToolKind::DynamicToolCall
        && existing_tool.kind != ToolKind::DynamicToolCall
      {
        incoming_tool.kind = existing_tool.kind;
        incoming_tool.family = existing_tool.family;
        changed = true;
      }
      if incoming_tool.title.is_empty() && !existing_tool.title.is_empty() {
        incoming_tool.title = existing_tool.title.clone();
        changed = true;
      }
      if incoming_tool.subtitle.is_none() && existing_tool.subtitle.is_some() {
        incoming_tool.subtitle = existing_tool.subtitle.clone();
        changed = true;
      }
      // Dynamic tool responses currently emit a placeholder invocation payload.
      // Preserve the original invocation so expanded input rendering remains useful.
      if is_placeholder_dynamic_tool_invocation(&incoming_tool.invocation) {
        incoming_tool.invocation = existing_tool.invocation.clone();
        changed = true;
      }
      if changed {
        refresh_tool_display(incoming_tool);
      }
    }

    if entry.sequence == 0 {
      entry.sequence = existing.sequence;
    }
    if *existing == *entry {
      return;
    }
    *existing = entry.clone();
  } else {
    tracing::warn!(
        component = "transition",
        event = "transition.row_updated_missing_row",
        session_id = %sid,
        row_id = %row_id,
        "RowUpdated arrived before the row existed in transition state; upserting it"
    );
    entry.session_id = sid.to_string();
    entry.sequence = state.rows.last().map(|row| row.sequence + 1).unwrap_or(0);
    state.rows.push(entry.clone());
    state.total_row_count = state.total_row_count.max(entry.sequence + 1);
  }
  state.last_activity_at = Some(now.to_string());
  state.last_progress_at = Some(now.to_string());

  effects.push(Effect::Persist(Box::new(PersistOp::RowUpsert {
    session_id: sid.to_string(),
    entry: entry.clone(),
  })));
  effects.push(Effect::Emit(Box::new(
    orbitdock_protocol::ServerMessage::ConversationRowsChanged {
      session_id: sid.to_string(),
      upserted: vec![entry.to_summary()],
      removed_row_ids: vec![],
      total_row_count: state.total_row_count,
    },
  )));
}
