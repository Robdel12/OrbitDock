use orbitdock_connector_core::{ConnectorOutput, ConnectorStateEvent};
use orbitdock_protocol::conversation_contracts::{
  compute_tool_display, extract_compact_result_text, ConversationRow, ConversationRowEntry,
  ToolDisplayInput, ToolRow,
};

pub(super) fn state_output(event: ConnectorStateEvent) -> ConnectorOutput {
  event.into()
}

pub(super) fn row_created_output(entry: ConversationRowEntry) -> ConnectorOutput {
  state_output(ConnectorStateEvent::ConversationRowCreated(entry))
}

pub(super) fn row_updated_output(row_id: String, entry: ConversationRowEntry) -> ConnectorOutput {
  state_output(ConnectorStateEvent::ConversationRowUpdated { row_id, entry })
}

pub(super) fn tool_row_entry(row: ToolRow) -> ConversationRowEntry {
  let mut row = row;
  let invocation_ref = row.invocation.is_object().then_some(&row.invocation);
  let result_str = extract_compact_result_text(row.result.as_ref());
  let tool_display = compute_tool_display(ToolDisplayInput {
    kind: row.kind,
    family: row.family,
    status: row.status,
    title: &row.title,
    subtitle: row.subtitle.as_deref(),
    summary: row.summary.as_deref(),
    duration_ms: row.duration_ms,
    invocation_input: invocation_ref,
    result_output: result_str.as_deref(),
  });
  row.tool_display = Some(tool_display);
  crate::runtime::row_entry(ConversationRow::Tool(row))
}
