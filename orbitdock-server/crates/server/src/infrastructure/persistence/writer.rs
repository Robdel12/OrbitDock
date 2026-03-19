use std::path::PathBuf;
use std::time::Duration;

use rusqlite::Connection;
use tokio::sync::mpsc;
use tracing::{debug, error, info};

use super::PersistCommand;

/// Persistence writer that batches SQLite writes.
pub struct PersistenceWriter {
    rx: mpsc::Receiver<PersistCommand>,
    db_path: PathBuf,
    batch: Vec<PersistCommand>,
    batch_size: usize,
    flush_interval: Duration,
}

impl PersistenceWriter {
    /// Create a new persistence writer.
    pub fn new(rx: mpsc::Receiver<PersistCommand>) -> Self {
        let db_path = crate::infrastructure::paths::db_path();

        Self {
            rx,
            db_path,
            batch: Vec::with_capacity(100),
            batch_size: 50,
            flush_interval: Duration::from_millis(100),
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
                Some(cmd) = self.rx.recv() => {
                    let needs_flush_now = cmd.has_response_channel();
                    self.batch.push(cmd);

                    if needs_flush_now || self.batch.len() >= self.batch_size {
                        self.flush().await;
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
            Ok(Ok(count)) => {
                debug!(
                    component = "persistence",
                    event = "persistence.flush.succeeded",
                    command_count = count,
                    "Persisted batched commands"
                );
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
) -> Result<usize, rusqlite::Error> {
    let conn = Connection::open(db_path)?;
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;
         PRAGMA synchronous = NORMAL;",
    )?;

    let count = batch.len();
    let tx = conn.unchecked_transaction()?;

    for cmd in batch {
        if let Err(error) = super::execute_command(&tx, cmd) {
            error!(
                component = "persistence",
                event = "persistence.command.failed",
                error = %error,
                "Failed to execute persistence command"
            );
        }
    }

    tx.commit()?;
    Ok(count)
}

#[cfg(test)]
pub(crate) fn flush_batch_for_test(
    db_path: &PathBuf,
    batch: Vec<PersistCommand>,
) -> Result<usize, rusqlite::Error> {
    flush_batch(db_path, batch)
}
