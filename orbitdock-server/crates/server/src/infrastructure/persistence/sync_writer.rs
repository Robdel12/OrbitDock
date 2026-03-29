use std::collections::VecDeque;
use std::future::Future;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::Context;
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, watch};
use tracing::{error, warn};

use crate::infrastructure::paths;
use crate::support::session_time::chrono_now;

use super::{SyncBatchRequest, SyncCommand, SyncEnvelope};

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
  pub server_url: String,
  pub auth_token: String,
  pub spool_dir: PathBuf,
  pub batch_size: usize,
  pub flush_interval: Duration,
  pub heartbeat_interval: Duration,
}

impl SyncWriterConfig {
  pub fn new(workspace_id: String, server_url: String, auth_token: String) -> Self {
    let spool_dir = paths::sync_spool_dir_for_workspace(&workspace_id);
    Self {
      workspace_id,
      server_url: server_url.trim_end_matches('/').to_string(),
      auth_token,
      spool_dir,
      batch_size: DEFAULT_BATCH_SIZE,
      flush_interval: DEFAULT_FLUSH_INTERVAL,
      heartbeat_interval: DEFAULT_HEARTBEAT_INTERVAL,
    }
  }
}

#[derive(Debug, Serialize, Deserialize)]
struct SyncSequenceState {
  next_sequence: u64,
}

#[derive(Debug, Deserialize)]
struct SyncBatchAckResponse {
  acked_through: Option<u64>,
}

pub struct SyncWriter {
  rx: mpsc::Receiver<SyncCommand>,
  shutdown_rx: watch::Receiver<bool>,
  post_batch_fn: PostBatchFn,
  config: SyncWriterConfig,
  pending_commands: Vec<SyncCommand>,
  next_sequence: u64,
}

impl SyncWriter {
  pub fn new(
    rx: mpsc::Receiver<SyncCommand>,
    shutdown_rx: watch::Receiver<bool>,
    config: SyncWriterConfig,
  ) -> anyhow::Result<Self> {
    std::fs::create_dir_all(&config.spool_dir)
      .with_context(|| format!("create sync spool dir {}", config.spool_dir.display()))?;

    let client = reqwest::Client::builder()
      .connect_timeout(Duration::from_secs(2))
      .timeout(Duration::from_secs(5))
      .build()
      .context("build sync writer HTTP client")?;
    let post_batch_fn = build_http_post_batch_fn(client);
    Self::build(rx, shutdown_rx, config, post_batch_fn)
  }

  fn build(
    rx: mpsc::Receiver<SyncCommand>,
    shutdown_rx: watch::Receiver<bool>,
    config: SyncWriterConfig,
    post_batch_fn: PostBatchFn,
  ) -> anyhow::Result<Self> {
    let next_sequence = load_next_sequence(&config.spool_dir)?;

    Ok(Self {
      rx,
      shutdown_rx,
      post_batch_fn,
      config,
      pending_commands: Vec::with_capacity(DEFAULT_BATCH_SIZE),
      next_sequence,
    })
  }

  #[cfg(test)]
  fn new_with_post_fn(
    rx: mpsc::Receiver<SyncCommand>,
    shutdown_rx: watch::Receiver<bool>,
    config: SyncWriterConfig,
    post_batch_fn: PostBatchFn,
  ) -> anyhow::Result<Self> {
    std::fs::create_dir_all(&config.spool_dir)
      .with_context(|| format!("create sync spool dir {}", config.spool_dir.display()))?;
    Self::build(rx, shutdown_rx, config, post_batch_fn)
  }

  pub async fn run(mut self) {
    let mut flush_interval = tokio::time::interval(self.config.flush_interval);
    let mut heartbeat_interval = tokio::time::interval(self.config.heartbeat_interval);

    loop {
      tokio::select! {
          maybe_command = self.rx.recv() => {
              match maybe_command {
                  Some(command) => {
                      self.pending_commands.push(command);
                      if self.pending_commands.len() >= self.config.batch_size {
                          self.flush_pending(false).await;
                      }
                  }
                  None => {
                      self.shutdown().await;
                      return;
                  }
              }
          }
          changed = self.shutdown_rx.changed() => {
              if changed.is_ok() && *self.shutdown_rx.borrow() {
                  self.shutdown().await;
                  return;
              }
          }
          _ = flush_interval.tick() => {
              if !self.pending_commands.is_empty() {
                  self.flush_pending(false).await;
              }
          }
          _ = heartbeat_interval.tick() => {
              if self.pending_commands.is_empty() {
                  self.flush_pending(true).await;
              }
          }
      }
    }
  }

  async fn shutdown(&mut self) {
    let shutdown_future = async {
      while let Ok(command) = self.rx.try_recv() {
        self.pending_commands.push(command);
      }
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
    let commands = if heartbeat_only {
      Vec::new()
    } else {
      std::mem::take(&mut self.pending_commands)
    };

    if commands.is_empty() && !heartbeat_only {
      return;
    }

    if let Err(error) = self.drain_spool().await {
      error!(
          component = "sync",
          event = "sync.spool.drain_failed",
          error = %error,
          "Failed to drain sync spool"
      );

      if !commands.is_empty() {
        if let Err(spool_error) = self.spool_commands(commands) {
          error!(
              component = "sync",
              event = "sync.spool.write_failed",
              error = %spool_error,
              "Failed to spool unsent sync commands"
          );
        }
      }
      return;
    }

    let envelopes = match self.allocate_envelopes(commands) {
      Ok(envelopes) => envelopes,
      Err(error) => {
        error!(
            component = "sync",
            event = "sync.sequence.allocate_failed",
            error = %error,
            "Failed to allocate sync envelope sequences"
        );
        return;
      }
    };

    if envelopes.is_empty() && heartbeat_only {
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
      }
      return;
    }

    let request = SyncBatchRequest {
      commands: envelopes.clone(),
    };

    match self.post_batch(request).await {
      Ok(()) => {}
      Err(error) => {
        warn!(
            component = "sync",
            event = "sync.flush.failed",
            workspace_id = %self.config.workspace_id,
            command_count = envelopes.len(),
            error = %error,
            "Sync batch failed, spooling for retry"
        );
        if let Err(spool_error) = spool_envelopes(&self.config.spool_dir, &envelopes) {
          error!(
              component = "sync",
              event = "sync.spool.write_failed",
              error = %spool_error,
              "Failed to spool sync envelopes after POST failure"
          );
        }
      }
    }
  }

  async fn drain_spool(&mut self) -> anyhow::Result<()> {
    let mut queued = load_spooled_envelopes(&self.config.spool_dir)?;
    queued
      .make_contiguous()
      .sort_by_key(|(sequence, _, _)| *sequence);

    while !queued.is_empty() {
      let mut drained_paths = Vec::with_capacity(self.config.batch_size);
      let mut drained_envelopes = Vec::with_capacity(self.config.batch_size);

      while drained_envelopes.len() < self.config.batch_size {
        let Some((_, path, envelope)) = queued.pop_front() else {
          break;
        };
        drained_paths.push(path);
        drained_envelopes.push(envelope);
      }

      self
        .post_batch(SyncBatchRequest {
          commands: drained_envelopes,
        })
        .await?;

      for path in drained_paths {
        std::fs::remove_file(&path)
          .with_context(|| format!("remove drained sync spool file {}", path.display()))?;
      }
    }

    Ok(())
  }

  fn allocate_envelopes(
    &mut self,
    commands: Vec<SyncCommand>,
  ) -> anyhow::Result<Vec<SyncEnvelope>> {
    if commands.is_empty() {
      return Ok(Vec::new());
    }

    let start = self.next_sequence;
    self.next_sequence += commands.len() as u64;
    persist_next_sequence(&self.config.spool_dir, self.next_sequence)?;

    Ok(
      commands
        .into_iter()
        .enumerate()
        .map(|(index, command)| SyncEnvelope {
          sequence: start + index as u64,
          workspace_id: self.config.workspace_id.clone(),
          timestamp: chrono_now(),
          command,
        })
        .collect(),
    )
  }

  fn spool_commands(&mut self, commands: Vec<SyncCommand>) -> anyhow::Result<()> {
    let envelopes = self.allocate_envelopes(commands)?;
    spool_envelopes(&self.config.spool_dir, &envelopes)
  }

  async fn post_batch(&self, request: SyncBatchRequest) -> anyhow::Result<()> {
    (self.post_batch_fn)(&self.config, request).await
  }
}

pub fn create_sync_channel() -> (mpsc::Sender<SyncCommand>, mpsc::Receiver<SyncCommand>) {
  mpsc::channel(1000)
}

pub fn create_sync_shutdown_channel() -> (watch::Sender<bool>, watch::Receiver<bool>) {
  watch::channel(false)
}

fn sequence_state_path(spool_dir: &Path) -> PathBuf {
  spool_dir.join("sequence-state.json")
}

fn load_next_sequence(spool_dir: &Path) -> anyhow::Result<u64> {
  let path = sequence_state_path(spool_dir);
  if !path.exists() {
    return Ok(1);
  }

  let body = std::fs::read_to_string(&path)
    .with_context(|| format!("read sync sequence state {}", path.display()))?;
  let state: SyncSequenceState = serde_json::from_str(&body)
    .with_context(|| format!("parse sync sequence state {}", path.display()))?;
  Ok(state.next_sequence.max(1))
}

fn persist_next_sequence(spool_dir: &Path, next_sequence: u64) -> anyhow::Result<()> {
  std::fs::create_dir_all(spool_dir)
    .with_context(|| format!("create sync spool dir {}", spool_dir.display()))?;

  let body = serde_json::to_vec_pretty(&SyncSequenceState { next_sequence })
    .context("serialize sync sequence state")?;
  let path = sequence_state_path(spool_dir);
  write_secure_file(&path, &body)
}

fn load_spooled_envelopes(
  spool_dir: &Path,
) -> anyhow::Result<VecDeque<(u64, PathBuf, SyncEnvelope)>> {
  let mut queued = VecDeque::new();
  let entries = match std::fs::read_dir(spool_dir) {
    Ok(entries) => entries,
    Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(queued),
    Err(error) => {
      return Err(error).with_context(|| format!("read sync spool dir {}", spool_dir.display()));
    }
  };

  for entry in entries {
    let path = entry?.path();
    if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
      continue;
    }
    if path.file_stem().and_then(|stem| stem.to_str()) == Some("sequence-state") {
      continue;
    }

    let body = std::fs::read_to_string(&path)
      .with_context(|| format!("read sync spool file {}", path.display()))?;
    let envelope: SyncEnvelope = serde_json::from_str(&body)
      .with_context(|| format!("parse sync spool file {}", path.display()))?;
    queued.push_back((envelope.sequence, path, envelope));
  }

  Ok(queued)
}

fn spool_envelopes(spool_dir: &Path, envelopes: &[SyncEnvelope]) -> anyhow::Result<()> {
  std::fs::create_dir_all(spool_dir)
    .with_context(|| format!("create sync spool dir {}", spool_dir.display()))?;

  for envelope in envelopes {
    let ts = SystemTime::now()
      .duration_since(UNIX_EPOCH)
      .unwrap_or_default()
      .as_millis();
    let path = spool_dir.join(format!("{ts}-{}.json", envelope.sequence));
    let body = serde_json::to_vec_pretty(envelope).context("serialize sync envelope")?;
    write_secure_file(&path, &body)?;
  }

  Ok(())
}

fn write_secure_file(path: &Path, body: &[u8]) -> anyhow::Result<()> {
  #[cfg(unix)]
  {
    use std::os::unix::fs::OpenOptionsExt;

    let mut file = std::fs::OpenOptions::new()
      .write(true)
      .create(true)
      .truncate(true)
      .mode(0o600)
      .open(path)
      .with_context(|| format!("open {} for write", path.display()))?;
    file
      .write_all(body)
      .with_context(|| format!("write {}", path.display()))?;
    Ok(())
  }

  #[cfg(not(unix))]
  {
    std::fs::write(path, body).with_context(|| format!("write {}", path.display()))
  }
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
  let _status = response.status().as_u16();

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
mod tests {
  use rusqlite::Connection;
  use tempfile::TempDir;
  use tokio::sync::{mpsc, Mutex};

  use super::*;
  use crate::infrastructure::migration_runner;
  use crate::infrastructure::persistence::{flush_batch_for_test, PersistCommand};
  use orbitdock_protocol::conversation_contracts::{
    ConversationRow, ConversationRowEntry, MessageRowContent,
  };

  #[derive(Clone, Default)]
  struct SyncCaptureState {
    fail_first: Arc<Mutex<bool>>,
    requests: Arc<Mutex<Vec<SyncBatchRequest>>>,
  }

  fn sample_sync_command() -> SyncCommand {
    SyncCommand::ModelUpdate {
      session_id: "session-1".into(),
      model: "gpt-5.4".into(),
    }
  }

  fn user_entry(id: &str, sequence: u64) -> ConversationRowEntry {
    ConversationRowEntry {
      session_id: "session-1".to_string(),
      sequence,
      turn_id: None,
      turn_status: Default::default(),
      row: ConversationRow::User(MessageRowContent {
        id: id.to_string(),
        content: "hello sync".to_string(),
        turn_id: None,
        timestamp: Some("2026-03-24T12:00:00Z".to_string()),
        is_streaming: false,
        images: vec![],
        memory_citation: None,
        delivery_status: None,
      }),
    }
  }

  #[tokio::test]
  async fn sync_writer_spools_failed_batches_and_drains_before_new_commands() {
    let tempdir = TempDir::new().expect("tempdir");
    let spool_dir = tempdir.path().join("sync-spool");
    std::fs::create_dir_all(&spool_dir).expect("create spool dir");

    let state = SyncCaptureState {
      fail_first: Arc::new(Mutex::new(true)),
      requests: Arc::new(Mutex::new(Vec::new())),
    };
    let post_batch_fn: PostBatchFn = Arc::new({
      let state = state.clone();
      move |_config: &SyncWriterConfig, request: SyncBatchRequest| {
        let state = state.clone();
        Box::pin(async move {
          state.requests.lock().await.push(request);

          let mut fail_first = state.fail_first.lock().await;
          if *fail_first {
            *fail_first = false;
            anyhow::bail!("synthetic sync failure");
          }

          Ok(())
        })
      }
    });

    let (tx, rx) = mpsc::channel(16);
    let (_shutdown_tx, shutdown_rx) = watch::channel(false);
    let config = SyncWriterConfig {
      workspace_id: "workspace-1".into(),
      server_url: "http://sync.example.test".into(),
      auth_token: "token-1".into(),
      spool_dir: spool_dir.clone(),
      batch_size: 1,
      flush_interval: Duration::from_millis(25),
      heartbeat_interval: Duration::from_secs(30),
    };

    let writer = SyncWriter::new_with_post_fn(rx, shutdown_rx, config, post_batch_fn)
      .expect("build sync writer");
    let writer_handle = tokio::spawn(writer.run());

    tx.send(sample_sync_command())
      .await
      .expect("send first command");

    tokio::time::timeout(Duration::from_secs(2), async {
      loop {
        let files = std::fs::read_dir(&spool_dir)
          .expect("read spool")
          .filter_map(|entry| entry.ok())
          .filter(|entry| entry.path().extension().and_then(|ext| ext.to_str()) == Some("json"))
          .filter(|entry| {
            entry.path().file_stem().and_then(|stem| stem.to_str()) != Some("sequence-state")
          })
          .count();
        if files == 1 {
          break;
        }
        tokio::task::yield_now().await;
      }
    })
    .await
    .expect("wait for spool file");

    tx.send(sample_sync_command())
      .await
      .expect("send second command");

    tokio::time::timeout(Duration::from_secs(2), async {
      loop {
        let requests = state.requests.lock().await;
        let non_empty_requests = requests
          .iter()
          .filter(|request| !request.commands.is_empty())
          .count();
        if non_empty_requests >= 3 {
          break;
        }
        drop(requests);
        tokio::task::yield_now().await;
      }
    })
    .await
    .expect("wait for drained requests");

    let requests = state.requests.lock().await.clone();
    let non_empty_requests: Vec<_> = requests
      .iter()
      .filter(|request| !request.commands.is_empty())
      .collect();
    assert_eq!(
      non_empty_requests[0].commands.len(),
      1,
      "first request should carry the initial failed batch"
    );
    assert!(
      non_empty_requests.len() >= 3,
      "expected failed POST, drained spool, and new batch"
    );
    assert_eq!(non_empty_requests[1].commands.len(), 1);
    assert_eq!(non_empty_requests[1].commands[0].sequence, 1);
    assert_eq!(non_empty_requests[2].commands.len(), 1);
    assert_eq!(non_empty_requests[2].commands[0].sequence, 2);
    assert!(
      requests.len() >= non_empty_requests.len(),
      "recorded requests should include the non-empty sync batches"
    );

    let remaining_spool_files = std::fs::read_dir(&spool_dir)
      .expect("read spool after drain")
      .filter_map(|entry| entry.ok())
      .filter(|entry| entry.path().extension().and_then(|ext| ext.to_str()) == Some("json"))
      .filter(|entry| {
        entry.path().file_stem().and_then(|stem| stem.to_str()) != Some("sequence-state")
      })
      .count();
    assert_eq!(remaining_spool_files, 0, "drained spool should be empty");

    drop(tx);
    writer_handle
      .await
      .expect("writer should shut down cleanly");
  }

  #[test]
  fn sync_writer_persists_sequence_allocator_state() {
    let tempdir = TempDir::new().expect("tempdir");
    let spool_dir = tempdir.path().join("sync-spool");
    std::fs::create_dir_all(&spool_dir).expect("create spool dir");

    persist_next_sequence(&spool_dir, 42).expect("persist sequence");
    let next = load_next_sequence(&spool_dir).expect("load sequence");

    assert_eq!(next, 42);
  }

  #[test]
  fn load_spooled_envelopes_stays_within_workspace_scoped_spool_dir() {
    let tempdir = TempDir::new().expect("tempdir");
    let sync_root = tempdir.path().join("sync-spool");
    let workspace_one_dir = sync_root.join("workspace-1");
    let workspace_two_dir = sync_root.join("workspace-2");
    std::fs::create_dir_all(&workspace_one_dir).expect("create workspace one spool dir");
    std::fs::create_dir_all(&workspace_two_dir).expect("create workspace two spool dir");

    let workspace_one = SyncEnvelope {
      sequence: 1,
      workspace_id: "workspace-1".into(),
      timestamp: "2026-03-24T12:00:00Z".into(),
      command: sample_sync_command(),
    };
    let workspace_two = SyncEnvelope {
      sequence: 7,
      workspace_id: "workspace-2".into(),
      timestamp: "2026-03-24T12:01:00Z".into(),
      command: sample_sync_command(),
    };

    spool_envelopes(&workspace_one_dir, std::slice::from_ref(&workspace_one))
      .expect("spool workspace one envelope");
    spool_envelopes(&workspace_two_dir, std::slice::from_ref(&workspace_two))
      .expect("spool workspace two envelope");

    let loaded = load_spooled_envelopes(&workspace_one_dir).expect("load workspace one spool");

    assert_eq!(loaded.len(), 1);
    let (_, _, envelope) = loaded.front().expect("workspace one envelope present");
    assert_eq!(envelope.workspace_id, "workspace-1");
    assert_eq!(envelope.sequence, 1);
  }

  #[tokio::test]
  async fn persistence_writer_syncs_local_commit_then_spool_then_post() {
    let tempdir = TempDir::new().expect("tempdir");
    let db_path = tempdir.path().join("test.db");
    let spool_dir = tempdir.path().join("sync-spool");
    std::fs::create_dir_all(&spool_dir).expect("create spool dir");

    let mut conn = Connection::open(&db_path).expect("open test db");
    migration_runner::run_migrations(&mut conn).expect("run migrations");
    conn
      .execute(
        "INSERT INTO sessions (id, project_path, provider, status, work_status)
             VALUES (?1, ?2, 'codex', 'active', 'waiting')",
        ("session-1", "/repo"),
      )
      .expect("insert test session");
    drop(conn);

    let state = SyncCaptureState {
      fail_first: Arc::new(Mutex::new(true)),
      requests: Arc::new(Mutex::new(Vec::new())),
    };
    let post_batch_fn: PostBatchFn = Arc::new({
      let state = state.clone();
      move |_config: &SyncWriterConfig, request: SyncBatchRequest| {
        let state = state.clone();
        Box::pin(async move {
          state.requests.lock().await.push(request);

          let mut fail_first = state.fail_first.lock().await;
          if *fail_first {
            *fail_first = false;
            anyhow::bail!("synthetic sync failure");
          }

          Ok(())
        })
      }
    });

    let (sync_tx, sync_rx) = mpsc::channel(16);
    let (_shutdown_tx, shutdown_rx) = watch::channel(false);

    let sync_writer = SyncWriter::new_with_post_fn(
      sync_rx,
      shutdown_rx,
      SyncWriterConfig {
        workspace_id: "workspace-1".into(),
        server_url: "http://sync.example.test".into(),
        auth_token: "token-1".into(),
        spool_dir: spool_dir.clone(),
        batch_size: 1,
        flush_interval: Duration::from_millis(5),
        heartbeat_interval: Duration::from_secs(30),
      },
      post_batch_fn,
    )
    .expect("build sync writer");
    let sync_handle = tokio::spawn(sync_writer.run());

    let first_flush = flush_batch_for_test(
      &db_path,
      vec![PersistCommand::RowAppend {
        session_id: "session-1".into(),
        entry: user_entry("row-1", 0),
        viewer_present: false,
        assigned_sequence: None,
        sequence_tx: None,
      }],
    )
    .expect("flush first batch");
    assert_eq!(first_flush.sync_commands.len(), 1);
    sync_tx
      .send(
        first_flush
          .sync_commands
          .into_iter()
          .next()
          .expect("first sync command"),
      )
      .await
      .expect("send first sync command");

    tokio::time::timeout(Duration::from_secs(2), async {
      loop {
        let files = std::fs::read_dir(&spool_dir)
          .expect("read integration spool")
          .filter_map(|entry| entry.ok())
          .filter(|entry| entry.path().extension().and_then(|ext| ext.to_str()) == Some("json"))
          .filter(|entry| {
            entry.path().file_stem().and_then(|stem| stem.to_str()) != Some("sequence-state")
          })
          .count();
        if files == 1 {
          break;
        }
        tokio::task::yield_now().await;
      }
    })
    .await
    .expect("wait for integration spool file");

    let second_flush = flush_batch_for_test(
      &db_path,
      vec![PersistCommand::RowAppend {
        session_id: "session-1".into(),
        entry: user_entry("row-2", 0),
        viewer_present: false,
        assigned_sequence: None,
        sequence_tx: None,
      }],
    )
    .expect("flush second batch");
    assert_eq!(second_flush.sync_commands.len(), 1);
    sync_tx
      .send(
        second_flush
          .sync_commands
          .into_iter()
          .next()
          .expect("second sync command"),
      )
      .await
      .expect("send second sync command");
    drop(sync_tx);

    tokio::time::timeout(Duration::from_secs(2), sync_handle)
      .await
      .expect("sync writer should stop")
      .expect("join sync writer");

    let conn = Connection::open(&db_path).expect("reopen db");
    let message_count: i64 = conn
      .query_row(
        "SELECT COUNT(*) FROM messages WHERE session_id = ?1",
        ["session-1"],
        |row| row.get(0),
      )
      .expect("count messages");
    let row_one_sequence: i64 = conn
      .query_row(
        "SELECT sequence FROM messages WHERE id = ?1",
        ["row-1"],
        |row| row.get(0),
      )
      .expect("row one sequence");
    let row_two_sequence: i64 = conn
      .query_row(
        "SELECT sequence FROM messages WHERE id = ?1",
        ["row-2"],
        |row| row.get(0),
      )
      .expect("row two sequence");
    assert_eq!(message_count, 2);
    assert_eq!(row_one_sequence, 0);
    assert_eq!(row_two_sequence, 1);

    let requests = state.requests.lock().await.clone();
    let non_empty_requests: Vec<_> = requests
      .iter()
      .filter(|request| !request.commands.is_empty())
      .collect();
    assert!(
      non_empty_requests.len() >= 3,
      "expected failed POST, drained spool retry, and new row POST"
    );
    assert_eq!(non_empty_requests[0].commands.len(), 1);
    assert!(matches!(
      &non_empty_requests[0].commands[0].command,
      SyncCommand::RowAppend { sequence: 0, .. }
    ));
    assert_eq!(non_empty_requests[1].commands.len(), 1);
    assert!(matches!(
      &non_empty_requests[1].commands[0].command,
      SyncCommand::RowAppend { sequence: 0, .. }
    ));
    assert_eq!(non_empty_requests[2].commands.len(), 1);
    assert!(matches!(
      &non_empty_requests[2].commands[0].command,
      SyncCommand::RowAppend { sequence: 1, .. }
    ));

    let remaining_spool_files = std::fs::read_dir(&spool_dir)
      .expect("read spool after integration flow")
      .filter_map(|entry| entry.ok())
      .filter(|entry| entry.path().extension().and_then(|ext| ext.to_str()) == Some("json"))
      .filter(|entry| {
        entry.path().file_stem().and_then(|stem| stem.to_str()) != Some("sequence-state")
      })
      .count();
    assert_eq!(
      remaining_spool_files, 0,
      "spool should be drained after retry"
    );
  }
}
