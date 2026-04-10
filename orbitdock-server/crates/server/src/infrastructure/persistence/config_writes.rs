use rusqlite::{params, Connection};

pub(super) fn persist_set_config(
  conn: &Connection,
  key: String,
  value: String,
) -> Result<(), rusqlite::Error> {
  let stored_value = crate::infrastructure::crypto::encrypt(&value)
    .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?;
  conn.execute(
    "INSERT INTO config (key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    params![key, stored_value],
  )?;
  Ok(())
}
