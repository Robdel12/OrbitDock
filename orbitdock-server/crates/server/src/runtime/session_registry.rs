//! Application state

mod connection_state;
mod connector_registry;
mod dashboard;
mod hooks;
mod missions;
mod ownership;
mod recent_projects;
mod sessions;

use dashmap::DashMap;
use orbitdock_protocol::{ClientPrimaryClaim, WorkspaceProviderKind};
use std::path::PathBuf;
use std::sync::atomic::AtomicU64;
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::{broadcast, mpsc, Mutex as AsyncMutex};
use uuid::Uuid;

use arc_swap::ArcSwap;
use orbitdock_protocol::DashboardSnapshot;

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;
use crate::infrastructure::persistence::PersistCommand;
use crate::infrastructure::shell::ShellService;
use crate::infrastructure::terminal::TerminalService;
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

  /// Primary claim and WebSocket connection state.
  connections: ConnectionState,

  dashboard_revision: Arc<AtomicU64>,
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

  /// Per-session gate to prevent duplicate direct-runtime auto-resume launches.
  auto_resume_locks: DashMap<String, Arc<AsyncMutex<()>>>,
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
      connections: ConnectionState::new(is_primary),
      dashboard_revision: Arc::new(AtomicU64::new(0)),
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
      auto_resume_locks: DashMap::new(),
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

  pub fn auto_resume_lock(&self, session_id: &str) -> Arc<AsyncMutex<()>> {
    self
      .auto_resume_locks
      .entry(session_id.to_string())
      .or_insert_with(|| Arc::new(AsyncMutex::new(())))
      .clone()
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

  pub fn has_active_connector_action_tx(&self, session_id: &str) -> bool {
    self.get_codex_action_tx(session_id).is_some()
      || self.get_claude_action_tx(session_id).is_some()
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

/// Flush all pending DB writes, then publish a granular dashboard update for a single session.
/// This guarantees the client reads committed state when it processes the WS event.
pub async fn flush_and_publish_conversation(
  persist_tx: &mpsc::Sender<PersistCommand>,
  state: &Arc<SessionRegistry>,
  session_id: &str,
) {
  let (tx, rx) = tokio::sync::oneshot::channel();
  let _ = persist_tx.send(PersistCommand::Flush { ack: tx }).await;
  let _ = rx.await;
  state.publish_dashboard_conversation_updated(session_id);
}

#[cfg(test)]
mod tests {
  use super::SessionRegistry;
  use crate::domain::sessions::session::SessionHandle;
  use crate::support::test_support::ensure_server_test_data_dir;
  use orbitdock_protocol::domain_events::AgentType;
  use orbitdock_protocol::{
    CodexIntegrationMode, Provider, SessionControlMode, SessionLifecycleState, SessionStatus,
    SubagentInfo, SubagentStatus, WorkStatus,
  };
  use tokio::sync::mpsc;

  #[test]
  fn registry_clears_primary_claims_by_connection() {
    ensure_server_test_data_dir();
    let (persist_tx, _persist_rx) = mpsc::channel(8);
    let registry = SessionRegistry::new_with_primary(persist_tx, true);

    registry.set_client_primary_claim(1, "client-a".into(), "MacBook Pro".into(), true);
    assert!(registry.clear_client_primary_claim(1));
    assert!(registry.active_client_primary_claims().is_empty());
    assert!(!registry.clear_client_primary_claim(1));
  }

  #[tokio::test]
  async fn dashboard_conversations_only_include_active_sessions() {
    ensure_server_test_data_dir();
    let (persist_tx, _persist_rx) = mpsc::channel(8);
    let registry = SessionRegistry::new_with_primary(persist_tx, true);

    let mut active = SessionHandle::new(
      "active-session".to_string(),
      Provider::Codex,
      "/tmp/orbitdock-active".to_string(),
    );
    active.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
    active.set_work_status(WorkStatus::Waiting);
    active.refresh_snapshot();
    registry.add_session(active);

    let mut ended = SessionHandle::new(
      "ended-session".to_string(),
      Provider::Codex,
      "/tmp/orbitdock-ended".to_string(),
    );
    ended.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
    ended.set_status(SessionStatus::Ended);
    ended.set_work_status(WorkStatus::Ended);
    ended.refresh_snapshot();
    registry.add_session(ended);

    let conversations =
      crate::runtime::dashboard::dashboard_snapshot_from_registry(&registry).conversations;
    assert_eq!(conversations.len(), 1);
    assert_eq!(conversations[0].session_id, "active-session");
  }

  #[tokio::test]
  async fn dashboard_conversations_include_server_owned_summary_fields() {
    ensure_server_test_data_dir();
    let (persist_tx, _persist_rx) = mpsc::channel(8);
    let registry = SessionRegistry::new_with_primary(persist_tx, true);

    let mut session = SessionHandle::new(
      "summary-session".to_string(),
      Provider::Codex,
      "/tmp/orbitdock-summary".to_string(),
    );
    session.set_codex_integration_mode(Some(CodexIntegrationMode::Passive));
    session.set_project_name(Some("orbitdock".to_string()));
    session.set_worktree_info(Some("/tmp/orbitdock".to_string()), false, None);
    session.set_first_prompt(Some("Check the latest output".to_string()));
    session.set_last_message(Some("## Heading with `code`".to_string()));
    session.set_pending_attention(
      Some("Bash".to_string()),
      Some(r#"{"command":"ls -la"}"#.to_string()),
      None,
    );
    session.set_work_status(WorkStatus::Waiting);
    session.refresh_snapshot();
    registry.add_session(session);

    let conversations =
      crate::runtime::dashboard::dashboard_snapshot_from_registry(&registry).conversations;
    assert_eq!(conversations.len(), 1);

    let conversation = &conversations[0];
    assert_eq!(
      conversation.preview_text.as_deref(),
      Some("Heading with code")
    );
    assert_eq!(
      conversation.activity_summary.as_deref(),
      Some("Running Bash")
    );
    assert_eq!(conversation.alert_context.as_deref(), Some("ls -la"));
    assert_eq!(
      conversation.grouping_path.as_deref(),
      Some("/tmp/orbitdock")
    );
    assert_eq!(conversation.grouping_name.as_deref(), Some("orbitdock"));
  }

  #[tokio::test]
  async fn dashboard_conversations_project_control_and_lifecycle_state() {
    ensure_server_test_data_dir();
    let (persist_tx, _persist_rx) = mpsc::channel(8);
    let (action_tx, _action_rx) = mpsc::channel(8);
    let registry = SessionRegistry::new_with_primary(persist_tx, true);

    let mut direct = SessionHandle::new(
      "direct-session".to_string(),
      Provider::Codex,
      "/tmp/orbitdock-direct".to_string(),
    );
    direct.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
    direct.set_work_status(WorkStatus::Waiting);
    direct.set_status(SessionStatus::Active);
    direct.refresh_snapshot();
    registry.add_session(direct);
    registry.set_codex_action_tx("direct-session", action_tx);

    let conversations =
      crate::runtime::dashboard::dashboard_snapshot_from_registry(&registry).conversations;
    let conversation = conversations
      .iter()
      .find(|entry| entry.session_id == "direct-session")
      .expect("direct session should be visible");

    assert_eq!(conversation.control_mode, SessionControlMode::Direct);
    assert_eq!(conversation.lifecycle_state, SessionLifecycleState::Open);
  }

  #[tokio::test]
  async fn dashboard_and_session_summaries_preserve_worker_and_issue_fields() {
    ensure_server_test_data_dir();
    let (persist_tx, _persist_rx) = mpsc::channel(8);
    let registry = SessionRegistry::new_with_primary(persist_tx, true);

    let mut session = SessionHandle::new(
      "mission-session".to_string(),
      Provider::Codex,
      "/tmp/orbitdock-mission".to_string(),
    );
    session.set_mission_context(Some("mission-1".to_string()), Some("PROJ-42".to_string()));
    session.set_subagents(vec![
      SubagentInfo {
        id: "worker-1".to_string(),
        agent_type: AgentType::BackgroundTask,
        started_at: "2026-03-30T10:00:00Z".to_string(),
        ended_at: None,
        provider: None,
        label: None,
        status: SubagentStatus::Running,
        task_summary: None,
        result_summary: None,
        error_summary: None,
        parent_subagent_id: None,
        model: None,
        last_activity_at: None,
      },
      SubagentInfo {
        id: "worker-2".to_string(),
        agent_type: AgentType::BackgroundTask,
        started_at: "2026-03-30T09:00:00Z".to_string(),
        ended_at: Some("2026-03-30T09:30:00Z".to_string()),
        provider: None,
        label: None,
        status: SubagentStatus::Completed,
        task_summary: None,
        result_summary: None,
        error_summary: None,
        parent_subagent_id: None,
        model: None,
        last_activity_at: None,
      },
    ]);
    session.refresh_snapshot();
    registry.add_session(session);

    let summary = registry
      .get_session_summaries()
      .into_iter()
      .find(|item| item.id == "mission-session")
      .expect("session summary should exist");
    assert_eq!(summary.active_worker_count, 1);
    assert_eq!(summary.mission_id.as_deref(), Some("mission-1"));
    assert_eq!(summary.issue_identifier.as_deref(), Some("PROJ-42"));

    let conversation = crate::runtime::dashboard::dashboard_snapshot_from_registry(&registry)
      .conversations
      .into_iter()
      .find(|item| item.session_id == "mission-session")
      .expect("dashboard conversation should exist");
    assert_eq!(conversation.active_worker_count, 1);
    assert_eq!(conversation.issue_identifier.as_deref(), Some("PROJ-42"));
  }

  #[tokio::test]
  async fn dashboard_snapshot_reflects_in_memory_tool_count() {
    ensure_server_test_data_dir();
    let (persist_tx, _persist_rx) = mpsc::channel(8);
    let registry = SessionRegistry::new_with_primary(persist_tx, true);

    let mut session = SessionHandle::new(
      "tool-session".to_string(),
      Provider::Codex,
      "/tmp/orbitdock-tools".to_string(),
    );
    for _ in 0..7 {
      session.increment_tool_count();
    }
    session.refresh_snapshot();
    registry.add_session(session);

    let conversation = crate::runtime::dashboard::dashboard_snapshot_from_registry(&registry)
      .conversations
      .into_iter()
      .find(|item| item.session_id == "tool-session")
      .expect("dashboard conversation should exist");
    assert_eq!(conversation.tool_count, 7);
  }

  #[tokio::test]
  async fn runtime_owner_registration_resolves_before_sqlite_flush() {
    ensure_server_test_data_dir();
    let (persist_tx, _persist_rx) = mpsc::channel(8);
    let registry = SessionRegistry::new_with_primary(persist_tx, true);

    let mut codex_session = SessionHandle::new(
      "direct-codex-owner".to_string(),
      Provider::Codex,
      "/tmp/orbitdock-direct-codex-owner".to_string(),
    );
    codex_session
      .set_codex_integration_mode(Some(orbitdock_protocol::CodexIntegrationMode::Direct));
    codex_session.set_status(orbitdock_protocol::SessionStatus::Active);
    codex_session.refresh_snapshot();
    registry.add_session(codex_session);

    let mut claude_session = SessionHandle::new(
      "direct-claude-owner".to_string(),
      Provider::Claude,
      "/tmp/orbitdock-direct-claude-owner".to_string(),
    );
    claude_session
      .set_claude_integration_mode(Some(orbitdock_protocol::ClaudeIntegrationMode::Direct));
    claude_session.set_status(orbitdock_protocol::SessionStatus::Active);
    claude_session.refresh_snapshot();
    registry.add_session(claude_session);

    registry.register_codex_runtime_owner("thread-immediate", "direct-codex-owner");
    registry.register_claude_runtime_owner("sdk-immediate", "direct-claude-owner");

    assert_eq!(
      registry.resolve_codex_thread("thread-immediate"),
      Some("direct-codex-owner".to_string())
    );
    assert_eq!(
      registry.resolve_claude_thread("sdk-immediate"),
      Some("direct-claude-owner".to_string())
    );
  }
}
