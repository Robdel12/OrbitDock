use rusqlite::Connection;

use orbitdock_protocol::conversation_contracts::TurnStatus;

pub(super) fn persist_rows_turn_status_update(
  conn: &Connection,
  session_id: String,
  row_ids: Vec<String>,
  status: TurnStatus,
) -> Result<(), rusqlite::Error> {
  if row_ids.is_empty() {
    return Ok(());
  }

  let placeholders = std::iter::repeat_n("?", row_ids.len())
    .collect::<Vec<_>>()
    .join(", ");
  let sql = format!(
    "UPDATE messages
         SET turn_status = ?1
       WHERE session_id = ?2
         AND id IN ({placeholders})"
  );

  let mut params = Vec::with_capacity(row_ids.len() + 2);
  params.push(super::turn_status_str(status).to_string());
  params.push(session_id);
  params.extend(row_ids);

  let params_refs = params.iter().map(|value| value as &dyn rusqlite::ToSql);
  conn.execute(&sql, rusqlite::params_from_iter(params_refs))?;

  Ok(())
}
