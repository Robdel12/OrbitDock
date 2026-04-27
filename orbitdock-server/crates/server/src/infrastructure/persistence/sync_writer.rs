use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use rusqlite::Connection;
use tokio::sync::watch;
use tracing::warn;

use super::{
  acknowledge_sync_outbox, current_sync_acked_through, load_pending_sync_envelopes,
  SyncBatchRequest, SyncEnvelope,
};

const DEFAULT_BATCH_SIZE: usize = 50;
const DEFAULT_FLUSH_INTERVAL: Duration = Duration::from_millis(100);
const DEFAULT_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);
const DEFAULT_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(30);

type PostBatchFuture = Pin<Box<dyn Future<Output = anyhow::Result<()>> + Send>>;
type PostBatchFn =
  Arc<dyn Fn(&SyncWriterConfig, SyncBatchRequest) -> PostBatchFuture + Send + Sync>;

#[derive(Debug, Clone)]
pub struct SyncWriterConfig {
  pub workspace_id: String,
  pub db_path: PathBuf,
  pub server_url: String,
  pub auth_token: String,
  pub batch_size: usize,
  pub flush_interval: Duration,
  pub heartbeat_interval: Duration,
}

impl SyncWriterConfig {
  pub fn new(
    workspace_id: String,
    db_path: PathBuf,
    server_url: String,
    auth_token: String,
  ) -> Self {
    Self {
      workspace_id,
      db_path,
      server_url: server_url.trim_end_matches('/').to_string(),
      auth_token,
      batch_size: DEFAULT_BATCH_SIZE,
      flush_interval: DEFAULT_FLUSH_INTERVAL,
      heartbeat_interval: DEFAULT_HEARTBEAT_INTERVAL,
    }
  }
}

#[derive(Debug, serde::Deserialize)]
struct SyncBatchAckResponse {
  acked_through: Option<u64>,
}

pub struct SyncWriter {
  shutdown_rx: watch::Receiver<bool>,
  post_batch_fn: PostBatchFn,
  config: SyncWriterConfig,
}

impl SyncWriter {
  pub fn new(shutdown_rx: watch::Receiver<bool>, config: SyncWriterConfig) -> anyhow::Result<Self> {
    let client = reqwest::Client::builder()
      .connect_timeout(Duration::from_secs(2))
      .timeout(Duration::from_secs(5))
      .build()
      .context("build sync writer HTTP client")?;
    let post_batch_fn = build_http_post_batch_fn(client);
    Self::build(shutdown_rx, config, post_batch_fn)
  }

  fn build(
    shutdown_rx: watch::Receiver<bool>,
    config: SyncWriterConfig,
    post_batch_fn: PostBatchFn,
  ) -> anyhow::Result<Self> {
    Ok(Self {
      shutdown_rx,
      post_batch_fn,
      config,
    })
  }

  #[cfg(test)]
  fn new_with_post_fn(
    shutdown_rx: watch::Receiver<bool>,
    config: SyncWriterConfig,
    post_batch_fn: PostBatchFn,
  ) -> anyhow::Result<Self> {
    Self::build(shutdown_rx, config, post_batch_fn)
  }

  pub async fn run(mut self) {
    let mut flush_interval = tokio::time::interval(self.config.flush_interval);
    let mut heartbeat_interval = tokio::time::interval(self.config.heartbeat_interval);

    loop {
      tokio::select! {
          changed = self.shutdown_rx.changed() => {
              if changed.is_ok() && *self.shutdown_rx.borrow() {
                  self.shutdown().await;
                  return;
              }
          }
          _ = flush_interval.tick() => {
              self.flush_pending(false).await;
          }
          _ = heartbeat_interval.tick() => {
              self.flush_pending(true).await;
          }
      }
    }
  }

  async fn shutdown(&mut self) {
    let shutdown_future = async {
      self.flush_pending(false).await;
    };

    match tokio::time::timeout(DEFAULT_SHUTDOWN_TIMEOUT, shutdown_future).await {
      Ok(()) => {}
      Err(_) => {
        warn!(
          component = "sync",
          event = "sync.writer.shutdown_timeout",
          timeout_secs = DEFAULT_SHUTDOWN_TIMEOUT.as_secs(),
          "Timed out draining sync writer before shutdown"
        );
      }
    }
  }

  async fn flush_pending(&mut self, heartbeat_only: bool) {
    let db_path = self.config.db_path.clone();
    let workspace_id = self.config.workspace_id.clone();
    let batch_size = self.config.batch_size;

    let db_path_for_load = db_path.clone();
    let workspace_id_for_load = workspace_id.clone();
    let pending: (Vec<SyncEnvelope>, u64) = match tokio::task::spawn_blocking(move || {
      let conn = Connection::open(&db_path_for_load)?;
      conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;
         PRAGMA synchronous = NORMAL;
         PRAGMA foreign_keys = ON;",
      )?;
      let envelopes = load_pending_sync_envelopes(&conn, &workspace_id_for_load, batch_size)?;
      let acked_through = current_sync_acked_through(&conn, &workspace_id_for_load)?;
      Ok::<_, anyhow::Error>((envelopes, acked_through))
    })
    .await
    {
      Ok(Ok(result)) => result,
      Ok(Err(error)) => {
        warn!(
          component = "sync",
          event = "sync.outbox.load_failed",
          error = %error,
          "Failed to load sync outbox"
        );
        return;
      }
      Err(error) => {
        warn!(
          component = "sync",
          event = "sync.outbox.load_join_failed",
          error = %error,
          "Failed to join sync outbox load task"
        );
        return;
      }
    };

    let (envelopes, acked_through) = pending;

    if envelopes.is_empty() {
      if !heartbeat_only {
        return;
      }

      if let Err(error) = self
        .post_batch(SyncBatchRequest {
          commands: Vec::new(),
        })
        .await
      {
        warn!(
          component = "sync",
          event = "sync.heartbeat.failed",
          error = %error,
          "Sync heartbeat failed"
        );
        return;
      }

      let _ = persist_sync_ack_state(&db_path, &workspace_id, acked_through).await;
      return;
    }

    let command_count = envelopes.len();
    let last_sequence = envelopes.last().map(|envelope| envelope.sequence);
    if let Err(error) = self
      .post_batch(SyncBatchRequest {
        commands: envelopes,
      })
      .await
    {
      warn!(
        component = "sync",
        event = "sync.flush.failed",
        workspace_id = %workspace_id,
        command_count = command_count,
        error = %error,
        "Sync batch failed"
      );
      return;
    }

    let acked_through = last_sequence.unwrap_or(acked_through);

    let _ = persist_sync_ack_state(&db_path, &workspace_id, acked_through).await;
  }

  async fn post_batch(&self, request: SyncBatchRequest) -> anyhow::Result<()> {
    (self.post_batch_fn)(&self.config, request).await
  }
}

async fn persist_sync_ack_state(
  db_path: &Path,
  workspace_id: &str,
  acked_through: u64,
) -> anyhow::Result<()> {
  let db_path = db_path.to_path_buf();
  let workspace_id = workspace_id.to_string();
  tokio::task::spawn_blocking(move || {
    let conn = Connection::open(&db_path)?;
    conn.execute_batch(
      "PRAGMA journal_mode = WAL;
       PRAGMA busy_timeout = 5000;
       PRAGMA synchronous = NORMAL;
       PRAGMA foreign_keys = ON;",
    )?;
    acknowledge_sync_outbox(&conn, &workspace_id, acked_through).context("persist sync ack state")
  })
  .await
  .context("join sync ack task")?
}

pub fn create_sync_shutdown_channel() -> (watch::Sender<bool>, watch::Receiver<bool>) {
  watch::channel(false)
}

async fn post_batch(
  client: &reqwest::Client,
  server_url: &str,
  auth_token: &str,
  request: SyncBatchRequest,
) -> anyhow::Result<()> {
  let response = client
    .post(format!("{server_url}/api/sync"))
    .bearer_auth(auth_token)
    .json(&request)
    .send()
    .await
    .context("POST sync batch")?;

  let response = response
    .error_for_status()
    .context("sync batch returned error status")?;

  if request.commands.is_empty() {
    return Ok(());
  }

  let body = response.bytes().await.context("read sync batch ack body")?;
  if body.is_empty() {
    return Ok(());
  }

  let ack: SyncBatchAckResponse =
    serde_json::from_slice(&body).context("decode sync batch ack response")?;
  let Some(last_sequence) = request.commands.last().map(|envelope| envelope.sequence) else {
    return Ok(());
  };

  match ack.acked_through {
    Some(acked_through) if acked_through >= last_sequence => {}
    Some(acked_through) => {
      anyhow::bail!(
        "sync acked through {acked_through}, but batch required at least {last_sequence}"
      );
    }
    None => {
      warn!(
        component = "sync",
        event = "sync.post.missing_ack",
        last_sequence = last_sequence,
        "Sync batch succeeded without an acked_through value"
      );
    }
  }

  Ok(())
}

fn build_http_post_batch_fn(client: reqwest::Client) -> PostBatchFn {
  Arc::new(
    move |config: &SyncWriterConfig, request: SyncBatchRequest| {
      let client = client.clone();
      let server_url = config.server_url.clone();
      let auth_token = config.auth_token.clone();
      Box::pin(async move { post_batch(&client, &server_url, &auth_token, request).await })
    },
  )
}

#[cfg(test)]
#[path = "sync_writer_tests.rs"]
mod tests;
