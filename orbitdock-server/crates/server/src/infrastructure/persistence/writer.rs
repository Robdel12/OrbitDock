use std::path::PathBuf;
use std::time::Duration;

use rusqlite::Connection;
use tokio::sync::mpsc;
use tracing::{error, warn};

use super::sync::SyncPlan;
use super::{append_sync_outbox_commands, PersistCommand};

#[derive(Debug)]
pub(crate) struct FlushBatchResult {
  #[cfg(test)]
  pub command_count: usize,
  #[cfg(test)]
  pub sync_commands: Vec<super::SyncCommand>,
}

/// Persistence writer that batches SQLite writes.
pub struct PersistenceWriter {
  rx: mpsc::Receiver<PersistCommand>,
  db_path: PathBuf,
  sync_workspace_id: Option<String>,
  batch: Vec<PersistCommand>,
  batch_size: usize,
  flush_interval: Duration,
}

impl PersistenceWriter {
  /// Create a new persistence writer.
  pub fn new(rx: mpsc::Receiver<PersistCommand>, sync_workspace_id: Option<String>) -> Self {
    let db_path = crate::infrastructure::paths::db_path();
    Self::build(
      rx,
      sync_workspace_id,
      db_path,
      50,
      Duration::from_millis(100),
    )
  }

  fn build(
    rx: mpsc::Receiver<PersistCommand>,
    sync_workspace_id: Option<String>,
    db_path: PathBuf,
    batch_size: usize,
    flush_interval: Duration,
  ) -> Self {
    Self {
      rx,
      db_path,
      sync_workspace_id,
      batch: Vec::with_capacity(100),
      batch_size,
      flush_interval,
    }
  }
  /// Run the persistence writer (call from tokio::spawn).
  pub async fn run(mut self) {
    let mut interval = tokio::time::interval(self.flush_interval);

    loop {
      tokio::select! {
          maybe_cmd = self.rx.recv() => {
              match maybe_cmd {
                  Some(cmd) => {
                      let needs_flush_now = cmd.has_response_channel();
                      self.batch.push(cmd);

                      if needs_flush_now || self.batch.len() >= self.batch_size {
                          self.flush().await;
                      }
                  }
                  None => {
                      self.flush().await;
                      return;
                  }
              }
          }

          _ = interval.tick() => {
              if !self.batch.is_empty() {
                  self.flush().await;
              }
          }
      }
    }
  }

  async fn flush(&mut self) {
    if self.batch.is_empty() {
      return;
    }

    let batch = std::mem::take(&mut self.batch);
    let db_path = self.db_path.clone();
    let sync_workspace_id = self.sync_workspace_id.clone();
    let result = tokio::task::spawn_blocking(move || {
      flush_batch(&db_path, sync_workspace_id.as_deref(), batch)
    })
    .await;

    match result {
      Ok(Ok(_result)) => {}
      Ok(Err(error)) => {
        error!(
          component = "persistence",
            event = "persistence.flush.failed",
            error = %error,
            "Persistence flush failed"
        );
      }
      Err(error) => {
        error!(
            component = "persistence",
            event = "persistence.flush.task_panicked",
            error = %error,
            "spawn_blocking panicked"
        );
      }
    }
  }
}

/// Create a sender for the persistence writer.
pub fn create_persistence_channel() -> (mpsc::Sender<PersistCommand>, mpsc::Receiver<PersistCommand>)
{
  mpsc::channel(1000)
}

/// Flush a batch of commands to SQLite (runs in a blocking thread).
pub(crate) fn flush_batch(
  db_path: &PathBuf,
  sync_workspace_id: Option<&str>,
  batch: Vec<PersistCommand>,
) -> Result<FlushBatchResult, rusqlite::Error> {
  let conn = Connection::open(db_path)?;
  conn.execute_batch(
    "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;
         PRAGMA synchronous = NORMAL;
         PRAGMA foreign_keys = ON;",
  )?;

  #[cfg(test)]
  let command_count = batch.len();
  let tx = conn.unchecked_transaction()?;
  let mut sync_commands = Vec::new();

  for cmd in batch {
    let cmd_type = cmd.type_name();
    let sync_plan = SyncPlan::from_command(&cmd);
    if let Err(error) = super::execute_command(&tx, cmd) {
      if is_foreign_key_violation(&error) {
        warn!(
            component = "persistence",
            event = "persistence.command.fk_violation",
            error = %error,
            command_type = cmd_type,
            "FK constraint violation — parent row may not exist"
        );
      } else {
        error!(
            component = "persistence",
            event = "persistence.command.failed",
            error = %error,
            command_type = cmd_type,
            "Failed to execute persistence command"
        );
      }
      continue;
    }

    let sync_command = match sync_plan.row_id() {
      Some(row_id) => {
        let assigned_sequence: i64 = tx.query_row(
          "SELECT sequence FROM messages WHERE id = ?1",
          rusqlite::params![row_id],
          |row| row.get(0),
        )?;
        sync_plan.into_sync_command_with_sequence(assigned_sequence as u64)
      }
      None => sync_plan.into_sync_command_with_sequence(0),
    };

    if let Some(sync_command) = sync_command {
      sync_commands.push(sync_command);
    }
  }

  if let Some(workspace_id) = sync_workspace_id {
    append_sync_outbox_commands(&tx, workspace_id, &sync_commands).map_err(|error| {
      rusqlite::Error::ToSqlConversionFailure(Box::new(std::io::Error::other(error.to_string())))
    })?;
  }

  tx.commit()?;
  Ok(FlushBatchResult {
    #[cfg(test)]
    command_count,
    #[cfg(test)]
    sync_commands,
  })
}

fn is_foreign_key_violation(error: &rusqlite::Error) -> bool {
  matches!(
    error,
    rusqlite::Error::SqliteFailure(
      rusqlite::ffi::Error {
        extended_code: rusqlite::ffi::SQLITE_CONSTRAINT_FOREIGNKEY,
        ..
      },
      _
    )
  )
}

#[cfg(test)]
pub(crate) fn flush_batch_for_test(
  db_path: &PathBuf,
  batch: Vec<PersistCommand>,
) -> Result<FlushBatchResult, rusqlite::Error> {
  flush_batch(db_path, None, batch)
}
