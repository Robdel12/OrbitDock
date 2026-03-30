use anyhow::{Context, Result};
use rusqlite::{params, Connection, Transaction};

use crate::support::session_time::chrono_now;

use super::{SyncCommand, SyncEnvelope};

pub(crate) fn append_sync_outbox_commands(
  tx: &Transaction<'_>,
  workspace_id: &str,
  commands: &[SyncCommand],
) -> Result<()> {
  if commands.is_empty() {
    return Ok(());
  }

  let next_sequence = next_sync_outbox_sequence(tx, workspace_id)?;
  for (index, command) in commands.iter().enumerate() {
    let sequence = next_sequence + index as u64;
    tx.execute(
      "INSERT INTO sync_outbox (workspace_id, sequence, command_json)
       VALUES (?1, ?2, ?3)",
      params![
        workspace_id,
        sequence as i64,
        serde_json::to_string(command).context("serialize sync outbox command")?
      ],
    )
    .with_context(|| {
      format!("insert sync outbox row for workspace {workspace_id} sequence {sequence}")
    })?;
  }

  Ok(())
}

pub(crate) fn load_pending_sync_envelopes(
  conn: &Connection,
  workspace_id: &str,
  batch_size: usize,
) -> Result<Vec<SyncEnvelope>> {
  if batch_size == 0 {
    return Ok(Vec::new());
  }

  let acked_through = current_sync_acked_through(conn, workspace_id)?;
  let mut stmt = conn
    .prepare(
      "SELECT sequence, command_json, created_at
         FROM sync_outbox
         WHERE workspace_id = ?1
           AND sequence > ?2
         ORDER BY sequence ASC
         LIMIT ?3",
    )
    .with_context(|| format!("prepare pending sync outbox load for workspace {workspace_id}"))?;

  let rows = stmt
    .query_map(
      params![workspace_id, acked_through as i64, batch_size as i64],
      |row| {
        let sequence = row.get::<_, i64>(0)? as u64;
        let command_json: String = row.get(1)?;
        let timestamp: String = row.get(2)?;
        let command: SyncCommand = serde_json::from_str(&command_json).map_err(|error| {
          rusqlite::Error::FromSqlConversionFailure(1, rusqlite::types::Type::Text, Box::new(error))
        })?;
        Ok(SyncEnvelope {
          sequence,
          workspace_id: workspace_id.to_string(),
          timestamp,
          command,
        })
      },
    )
    .with_context(|| format!("query pending sync outbox for workspace {workspace_id}"))?
    .enumerate()
    .map(|(index, result)| {
      result.with_context(|| format!("decode sync outbox row {index} for workspace {workspace_id}"))
    })
    .collect::<Result<Vec<_>>>()?;

  Ok(rows)
}

pub(crate) fn acknowledge_sync_outbox(
  conn: &Connection,
  workspace_id: &str,
  acked_through: u64,
) -> Result<()> {
  conn
    .execute(
      "DELETE FROM sync_outbox
         WHERE workspace_id = ?1
           AND sequence <= ?2",
      params![workspace_id, acked_through as i64],
    )
    .with_context(|| format!("delete acked sync outbox rows for workspace {workspace_id}"))?;
  conn
    .execute(
      "UPDATE workspaces
         SET sync_acked_through = ?2,
             last_heartbeat_at = ?3
         WHERE id = ?1",
      params![workspace_id, acked_through as i64, chrono_now()],
    )
    .with_context(|| format!("update sync ack state for workspace {workspace_id}"))?;
  Ok(())
}

fn next_sync_outbox_sequence(tx: &Transaction<'_>, workspace_id: &str) -> Result<u64> {
  let acked_through = current_sync_acked_through(tx, workspace_id)?;
  let max_outbox_sequence =
    tx.query_row(
      "SELECT COALESCE(MAX(sequence), 0)
         FROM sync_outbox
         WHERE workspace_id = ?1",
      params![workspace_id],
      |row| row.get::<_, i64>(0),
    )
    .with_context(|| format!("load max outbox sequence for workspace {workspace_id}"))? as u64;

  Ok(acked_through.max(max_outbox_sequence) + 1)
}

pub(crate) fn current_sync_acked_through(conn: &Connection, workspace_id: &str) -> Result<u64> {
  conn
    .query_row(
      "SELECT sync_acked_through FROM workspaces WHERE id = ?1",
      params![workspace_id],
      |row| row.get::<_, i64>(0),
    )
    .with_context(|| format!("load acked_through for workspace {workspace_id}"))
    .map(|value| value as u64)
}
