use std::path::PathBuf;
use std::time::Duration;

use rusqlite::Connection;
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

use super::sync::SyncPlan;
use super::{PersistCommand, SyncCommand};

#[derive(Debug)]
pub(crate) struct FlushBatchResult {
    pub command_count: usize,
    pub sync_commands: Vec<SyncCommand>,
}

/// Persistence writer that batches SQLite writes.
pub struct PersistenceWriter {
    rx: mpsc::Receiver<PersistCommand>,
    sync_tx: Option<mpsc::Sender<SyncCommand>>,
    db_path: PathBuf,
    batch: Vec<PersistCommand>,
    batch_size: usize,
    flush_interval: Duration,
}

impl PersistenceWriter {
    /// Create a new persistence writer.
    pub fn new(
        rx: mpsc::Receiver<PersistCommand>,
        sync_tx: Option<mpsc::Sender<SyncCommand>>,
    ) -> Self {
        let db_path = crate::infrastructure::paths::db_path();
        Self::build(rx, sync_tx, db_path, 50, Duration::from_millis(100))
    }

    fn build(
        rx: mpsc::Receiver<PersistCommand>,
        sync_tx: Option<mpsc::Sender<SyncCommand>>,
        db_path: PathBuf,
        batch_size: usize,
        flush_interval: Duration,
    ) -> Self {
        Self {
            rx,
            sync_tx,
            db_path,
            batch: Vec::with_capacity(100),
            batch_size,
            flush_interval,
        }
    }
    /// Run the persistence writer (call from tokio::spawn).
    pub async fn run(mut self) {
        info!(
            component = "persistence",
            event = "persistence.writer.started",
            db_path = %self.db_path.display(),
            batch_size = self.batch_size,
            flush_interval_ms = self.flush_interval.as_millis() as u64,
            "Persistence writer started"
        );

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
                            info!(
                                component = "persistence",
                                event = "persistence.writer.stopped",
                                "Persistence writer channel closed"
                            );
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
        let result = tokio::task::spawn_blocking(move || flush_batch(&db_path, batch)).await;

        match result {
            Ok(Ok(result)) => {
                debug!(
                    component = "persistence",
                    event = "persistence.flush.succeeded",
                    command_count = result.command_count,
                    sync_command_count = result.sync_commands.len(),
                    "Persisted batched commands"
                );

                if let Some(sync_tx) = &self.sync_tx {
                    for command in result.sync_commands {
                        if sync_tx.send(command).await.is_err() {
                            warn!(
                                component = "persistence",
                                event = "persistence.sync_channel.closed",
                                "Sync writer channel closed, dropping post-commit sync commands"
                            );
                            break;
                        }
                    }
                }
            }
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
    batch: Vec<PersistCommand>,
) -> Result<FlushBatchResult, rusqlite::Error> {
    let conn = Connection::open(db_path)?;
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;
         PRAGMA synchronous = NORMAL;
         PRAGMA foreign_keys = ON;",
    )?;

    let count = batch.len();
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

    tx.commit()?;
    Ok(FlushBatchResult {
        command_count: count,
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
    flush_batch(db_path, batch)
}
