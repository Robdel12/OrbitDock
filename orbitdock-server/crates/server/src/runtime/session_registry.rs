//! Application state

mod connection_state;
mod connector_registry;
mod dashboard;
mod hooks;
mod library;
mod missions;
mod ownership;
mod recent_projects;
mod sessions;
mod sessions_summary;

use dashmap::DashMap;
use orbitdock_protocol::{ClientPrimaryClaim, WorkspaceProviderKind};
use std::path::PathBuf;
use std::sync::atomic::AtomicU64;
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::{broadcast, mpsc};
use uuid::Uuid;

use arc_swap::ArcSwap;
use orbitdock_protocol::DashboardSnapshot;

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;
use crate::infrastructure::persistence::PersistCommand;
use crate::infrastructure::shell::ShellService;
use crate::infrastructure::terminal::TerminalService;
use crate::infrastructure::tool_pty::ToolPtyService;
use crate::runtime::session_actor::SessionActorHandle;
use crate::support::ai_naming::NamingGuard;
use orbitdock_connector_codex::auth::CodexAuthService;

use self::connection_state::ConnectionState;
use self::connector_registry::ConnectorRegistry;

/// Cached metadata from a `ClaudeSessionStart` hook, held in memory until the
/// first actionable hook materializes the session (or `SessionEnd` discards it).
pub struct PendingClaudeSession {
  pub cwd: String,
  pub model: Option<String>,
  pub source: Option<String>,
  pub context_label: Option<String>,
  pub transcript_path: Option<String>,
  pub permission_mode: Option<String>,
  pub agent_type: Option<String>,
  pub terminal_session_id: Option<String>,
  pub terminal_app: Option<String>,
  pub cached_at: Instant,
}

/// Cached metadata from a `CodexSessionStart` hook, held in memory until the
/// first actionable turn hook materializes the passive session.
pub struct PendingCodexSession {
  pub cwd: String,
  pub model: Option<String>,
  pub transcript_path: Option<String>,
  pub cached_at: Instant,
}

/// Provider-neutral pending passive session cache entry.
///
/// The registry can keep provider-specific payloads internally while exposing
/// one shared hook lifecycle surface to the rest of the server.
pub enum PendingHookSession {
  Claude(PendingClaudeSession),
  Codex(PendingCodexSession),
}

impl PendingHookSession {
  pub fn into_claude(self) -> Option<PendingClaudeSession> {
    match self {
      PendingHookSession::Claude(pending) => Some(pending),
      PendingHookSession::Codex(_) => None,
    }
  }

  pub fn into_codex(self) -> Option<PendingCodexSession> {
    match self {
      PendingHookSession::Claude(_) => None,
      PendingHookSession::Codex(pending) => Some(pending),
    }
  }
}

/// Cached result of an update check with timestamp.
pub struct CachedUpdateStatus {
  pub update_available: bool,
  pub latest_version: Option<String>,
  pub release_url: Option<String>,
  pub channel: String,
  pub checked_at: chrono::DateTime<chrono::Utc>,
}

/// Shared application state backed by lock-free concurrent maps.
/// All methods take `&self` — no external Mutex needed.
pub struct SessionRegistry {
  /// Active sessions stored as actor handles
  sessions: DashMap<String, SessionActorHandle>,

  /// Connector action channels for active direct runtimes.
  connectors: ConnectorRegistry,

  /// Broadcast channel for session list updates
  list_tx: broadcast::Sender<orbitdock_protocol::ServerMessage>,

  /// Persistence channel
  persist_tx: mpsc::Sender<PersistCommand>,

  /// Database path for synchronous read queries
  db_path: PathBuf,

  /// Reusable read connection pool — avoids opening a new SQLite connection
  /// per query from `spawn_blocking` tasks.
  read_pool: Arc<crate::infrastructure::db_pool::ReadPool>,

  /// Global Codex account auth coordinator (not session-specific)
  codex_auth: Arc<CodexAuthService>,

  /// Dedup guard for AI session naming
  naming_guard: Arc<NamingGuard>,

  /// Pending Claude sessions awaiting first actionable hook before materialization.
  /// Keyed by Claude SDK session_id from SessionStart.
  pending_claude_sessions: DashMap<String, PendingClaudeSession>,

  /// Pending Codex passive sessions awaiting first actionable turn hook before
  /// materialization. Keyed by Codex thread/session id from SessionStart.
  pending_codex_sessions: DashMap<String, PendingCodexSession>,

  /// Immediate runtime ownership routing for provider session IDs.
  /// SQLite remains durable truth; these maps close the hook race window
  /// before persistence flushes.
  claude_runtime_owners: DashMap<String, String>,
  codex_runtime_owners: DashMap<String, String>,

  /// Provider-agnostic shell runtime service for user-initiated commands.
  shell_service: Arc<ShellService>,

  /// Interactive PTY terminal sessions.
  terminal_service: Arc<TerminalService>,

  /// Virtual PTY service for streaming bash tool output.
  tool_pty_service: Arc<ToolPtyService>,

  /// Primary claim and WebSocket connection state.
  connections: ConnectionState,

  sessions_summary_revision: Arc<AtomicU64>,
  dashboard_revision: Arc<AtomicU64>,
  library_revision: Arc<AtomicU64>,
  /// Cached dashboard snapshot with the revision it was computed at.
  /// Avoids re-iterating all sessions when the dashboard hasn't changed.
  dashboard_cache: ArcSwap<(u64, DashboardSnapshot)>,
  mission_revision: AtomicU64,
  workspace_provider_kind: std::sync::RwLock<WorkspaceProviderKind>,
  server_instance_id: std::sync::RwLock<String>,

  /// Channel for manual mission trigger requests (HTTP → orchestrator).
  mission_trigger_tx: mpsc::Sender<String>,
  mission_trigger_rx: std::sync::Mutex<Option<mpsc::Receiver<String>>>,

  /// Cached result of the most recent update check.
  update_status: std::sync::RwLock<Option<CachedUpdateStatus>>,
  /// Guard to prevent concurrent update checks.
  update_check_in_flight: std::sync::atomic::AtomicBool,
}

impl SessionRegistry {
  #[cfg(test)]
  #[allow(dead_code)]
  pub fn new(persist_tx: mpsc::Sender<PersistCommand>) -> Self {
    Self::new_with_primary_and_db_path(
      persist_tx,
      crate::infrastructure::paths::db_path(),
      true,
      WorkspaceProviderKind::default(),
    )
  }

  #[cfg(test)]
  pub fn new_with_primary(persist_tx: mpsc::Sender<PersistCommand>, is_primary: bool) -> Self {
    Self::new_with_primary_and_db_path(
      persist_tx,
      crate::infrastructure::paths::db_path(),
      is_primary,
      WorkspaceProviderKind::default(),
    )
  }

  pub fn new_with_primary_and_db_path(
    persist_tx: mpsc::Sender<PersistCommand>,
    db_path: PathBuf,
    is_primary: bool,
    workspace_provider_kind: WorkspaceProviderKind,
  ) -> Self {
    let (list_tx, _) = broadcast::channel(1024);
    #[cfg(test)]
    let codex_auth = {
      let codex_home = db_path
        .parent()
        .map(|path| path.join("codex-home"))
        .unwrap_or_else(|| std::env::temp_dir().join("orbitdock-codex-home-tests"));
      Arc::new(CodexAuthService::new_with_file_store(
        list_tx.clone(),
        codex_home,
      ))
    };
    #[cfg(not(test))]
    let codex_auth = Arc::new(CodexAuthService::new(list_tx.clone()));
    let (mission_trigger_tx, mission_trigger_rx) = mpsc::channel(32);
    let read_pool = Arc::new(crate::infrastructure::db_pool::ReadPool::new(
      db_path.clone(),
      4,
    ));
    Self {
      sessions: DashMap::new(),
      connectors: ConnectorRegistry::new(),
      list_tx,
      persist_tx,
      db_path,
      read_pool,
      codex_auth,
      naming_guard: Arc::new(NamingGuard::new()),
      pending_claude_sessions: DashMap::new(),
      pending_codex_sessions: DashMap::new(),
      claude_runtime_owners: DashMap::new(),
      codex_runtime_owners: DashMap::new(),
      shell_service: Arc::new(ShellService::new()),
      terminal_service: Arc::new(TerminalService::new()),
      tool_pty_service: Arc::new(ToolPtyService::new()),
      connections: ConnectionState::new(is_primary),
      sessions_summary_revision: Arc::new(AtomicU64::new(0)),
      dashboard_revision: Arc::new(AtomicU64::new(0)),
      library_revision: Arc::new(AtomicU64::new(0)),
      dashboard_cache: ArcSwap::from_pointee((
        0,
        DashboardSnapshot {
          revision: 0,
          conversations: vec![],
          counts: orbitdock_protocol::DashboardCounts {
            attention: 0,
            running: 0,
            ready: 0,
            direct: 0,
          },
          project_groups: vec![],
        },
      )),
      mission_revision: AtomicU64::new(0),
      workspace_provider_kind: std::sync::RwLock::new(workspace_provider_kind),
      server_instance_id: std::sync::RwLock::new(Uuid::new_v4().to_string()),
      mission_trigger_tx,
      mission_trigger_rx: std::sync::Mutex::new(Some(mission_trigger_rx)),
      update_status: std::sync::RwLock::new(None),
      update_check_in_flight: std::sync::atomic::AtomicBool::new(false),
    }
  }

  pub fn is_primary(&self) -> bool {
    self.connections.is_primary()
  }

  pub fn set_primary(&self, is_primary: bool) -> bool {
    self.connections.set_primary(is_primary)
  }

  pub fn workspace_provider_kind(&self) -> WorkspaceProviderKind {
    *self
      .workspace_provider_kind
      .read()
      .expect("workspace provider lock poisoned")
  }

  pub fn set_workspace_provider_kind(&self, provider_kind: WorkspaceProviderKind) {
    *self
      .workspace_provider_kind
      .write()
      .expect("workspace provider lock poisoned") = provider_kind;
  }

  pub fn server_instance_id(&self) -> String {
    self
      .server_instance_id
      .read()
      .expect("server instance id lock poisoned")
      .clone()
  }

  pub fn set_server_instance_id(&self, server_instance_id: String) {
    let trimmed = server_instance_id.trim();
    if trimmed.is_empty() {
      return;
    }
    *self
      .server_instance_id
      .write()
      .expect("server instance id lock poisoned") = trimmed.to_string();
  }

  pub fn update_status(&self) -> Option<orbitdock_protocol::UpdateStatus> {
    let guard = self.update_status.read().expect("update status lock");
    guard
      .as_ref()
      .map(|cached| orbitdock_protocol::UpdateStatus {
        update_available: cached.update_available,
        latest_version: cached.latest_version.clone(),
        release_url: cached.release_url.clone(),
        channel: cached.channel.clone(),
        checked_at: Some(cached.checked_at.to_rfc3339()),
      })
  }

  pub fn set_update_status(&self, status: CachedUpdateStatus) {
    *self.update_status.write().expect("update status lock") = Some(status);
  }

  pub fn should_recheck_update(&self) -> bool {
    let guard = self.update_status.read().expect("update status lock");
    match guard.as_ref() {
      None => true,
      Some(cached) => {
        let elapsed = chrono::Utc::now() - cached.checked_at;
        elapsed > chrono::Duration::hours(6)
      }
    }
  }

  pub fn should_recheck_update_manual(&self) -> bool {
    let guard = self.update_status.read().expect("update status lock");
    match guard.as_ref() {
      None => true,
      Some(cached) => {
        let elapsed = chrono::Utc::now() - cached.checked_at;
        elapsed > chrono::Duration::minutes(5)
      }
    }
  }

  pub fn claim_update_check(&self) -> bool {
    !self
      .update_check_in_flight
      .swap(true, std::sync::atomic::Ordering::SeqCst)
  }

  pub fn release_update_check(&self) {
    self
      .update_check_in_flight
      .store(false, std::sync::atomic::Ordering::SeqCst);
  }

  pub fn ws_connect(&self) -> u64 {
    self.connections.ws_connect()
  }

  pub fn ws_disconnect(&self) -> u64 {
    self.connections.ws_disconnect()
  }

  pub fn ws_connection_count(&self) -> u64 {
    self.connections.ws_connection_count()
  }

  pub fn uptime_seconds(&self) -> u64 {
    self.connections.uptime_seconds()
  }

  pub fn try_start_orchestrator(&self) -> bool {
    self.connections.try_start_orchestrator()
  }

  pub fn stop_orchestrator(&self) {
    self.connections.stop_orchestrator()
  }

  pub fn is_orchestrator_running(&self) -> bool {
    self.connections.is_orchestrator_running()
  }

  pub fn set_client_primary_claim(
    &self,
    conn_id: u64,
    client_id: String,
    device_name: String,
    is_primary: bool,
  ) {
    self
      .connections
      .set_client_primary_claim(conn_id, client_id, device_name, is_primary);
  }

  pub fn clear_client_primary_claim(&self, conn_id: u64) -> bool {
    self.connections.clear_client_primary_claim(conn_id)
  }

  pub fn active_client_primary_claims(&self) -> Vec<ClientPrimaryClaim> {
    self.connections.active_client_primary_claims()
  }

  pub fn persist(&self) -> &mpsc::Sender<PersistCommand> {
    &self.persist_tx
  }

  pub fn db_path(&self) -> &PathBuf {
    &self.db_path
  }

  pub fn codex_auth(&self) -> Arc<CodexAuthService> {
    self.codex_auth.clone()
  }

  pub fn naming_guard(&self) -> &Arc<NamingGuard> {
    &self.naming_guard
  }

  pub fn shell_service(&self) -> Arc<ShellService> {
    self.shell_service.clone()
  }

  pub fn terminal_service(&self) -> Arc<TerminalService> {
    self.terminal_service.clone()
  }

  pub fn tool_pty_service(&self) -> Arc<ToolPtyService> {
    self.tool_pty_service.clone()
  }

  pub fn set_codex_action_tx(&self, session_id: &str, tx: mpsc::Sender<CodexAction>) {
    self.connectors.set_codex_action_tx(session_id, tx);
  }

  pub fn get_codex_action_tx(&self, session_id: &str) -> Option<mpsc::Sender<CodexAction>> {
    self.connectors.get_codex_action_tx(session_id).or_else(|| {
      self
        .resolve_runtime_owner_session_id(session_id)
        .and_then(|owner| self.connectors.get_codex_action_tx(&owner))
    })
  }

  pub fn set_claude_action_tx(&self, session_id: &str, tx: mpsc::Sender<ClaudeAction>) {
    self.connectors.set_claude_action_tx(session_id, tx);
  }

  pub fn remove_codex_action_tx(&self, session_id: &str) {
    self.connectors.remove_codex_action_tx(session_id);
  }

  pub fn get_claude_action_tx(&self, session_id: &str) -> Option<mpsc::Sender<ClaudeAction>> {
    self
      .connectors
      .get_claude_action_tx(session_id)
      .or_else(|| {
        self
          .resolve_runtime_owner_session_id(session_id)
          .and_then(|owner| self.connectors.get_claude_action_tx(&owner))
      })
  }

  pub fn remove_claude_action_tx(&self, session_id: &str) {
    self.connectors.remove_claude_action_tx(session_id);
  }

  pub fn subscribe_list(&self) -> broadcast::Receiver<orbitdock_protocol::ServerMessage> {
    self.list_tx.subscribe()
  }

  pub fn read_pool(&self) -> &Arc<crate::infrastructure::db_pool::ReadPool> {
    &self.read_pool
  }
}

// Note: No Default impl - requires persist_tx

/// Flush all pending DB writes, then publish an active-sessions invalidation.
/// This guarantees the client reads committed state when it processes the WS event.
pub async fn flush_and_publish_conversation(
  persist_tx: &mpsc::Sender<PersistCommand>,
  state: &Arc<SessionRegistry>,
  session_id: &str,
) {
  let (tx, rx) = tokio::sync::oneshot::channel();
  let _ = persist_tx.send(PersistCommand::Flush { ack: tx }).await;
  let _ = rx.await;
  state.publish_active_sessions_invalidation_for_session(session_id);
}

#[cfg(test)]
mod tests;
