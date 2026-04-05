//! Application state

mod connection_state;
mod connector_registry;
mod recent_projects;

use dashmap::DashMap;
use orbitdock_protocol::{
  ClientPrimaryClaim, DashboardConversationItem, DashboardCounts, DashboardDiffPreview,
  DashboardSnapshot, MissionsSnapshot, Provider, SessionListItem, SessionSummary,
  WorkspaceProviderKind,
};
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{broadcast, mpsc, Mutex as AsyncMutex};
use tracing::warn;

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;
use crate::domain::sessions::session::{accepts_user_input_from_parts, SessionHandle};
use crate::infrastructure::persistence::PersistCommand;
use crate::infrastructure::shell::ShellService;
use crate::infrastructure::terminal::TerminalService;
use crate::runtime::session_actor::SessionActorHandle;
use crate::support::ai_naming::NamingGuard;
use orbitdock_connector_codex::auth::CodexAuthService;

use self::connection_state::ConnectionState;
use self::connector_registry::ConnectorRegistry;
use self::recent_projects::collect_recent_projects;

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

  /// Provider-agnostic shell runtime service for user-initiated commands.
  shell_service: Arc<ShellService>,

  /// Interactive PTY terminal sessions.
  terminal_service: Arc<TerminalService>,

  /// Primary claim and WebSocket connection state.
  connections: ConnectionState,

  dashboard_revision: Arc<AtomicU64>,
  mission_revision: AtomicU64,
  workspace_provider_kind: std::sync::RwLock<WorkspaceProviderKind>,

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
  fn open_ownership_db(&self, operation: &'static str) -> Option<Connection> {
    let conn = match Connection::open(&self.db_path) {
      Ok(conn) => conn,
      Err(error) => {
        warn!(
          component = "state",
          event = "state.ownership.db_open_failed",
          operation = operation,
          db_path = %self.db_path.display(),
          error = %error,
          "Failed to open SQLite database for ownership operation"
        );
        return None;
      }
    };

    if let Err(error) = conn.busy_timeout(Duration::from_secs(5)) {
      warn!(
        component = "state",
        event = "state.ownership.busy_timeout_config_failed",
        operation = operation,
        error = %error,
        "Failed to configure SQLite busy_timeout for ownership operation"
      );
      return None;
    }

    Some(conn)
  }

  fn resolve_runtime_owner_session_id(&self, session_id: &str) -> Option<String> {
    if orbitdock_protocol::is_orbitdock_id(session_id) {
      return None;
    }

    self
      .resolve_claude_thread(session_id)
      .or_else(|| self.resolve_codex_thread(session_id))
  }

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
    let (list_tx, _) = broadcast::channel(256);
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
    Self {
      sessions: DashMap::new(),
      connectors: ConnectorRegistry::new(),
      list_tx,
      persist_tx,
      db_path,
      codex_auth,
      naming_guard: Arc::new(NamingGuard::new()),
      pending_claude_sessions: DashMap::new(),
      pending_codex_sessions: DashMap::new(),
      shell_service: Arc::new(ShellService::new()),
      terminal_service: Arc::new(TerminalService::new()),
      connections: ConnectionState::new(is_primary),
      dashboard_revision: Arc::new(AtomicU64::new(0)),
      mission_revision: AtomicU64::new(0),
      workspace_provider_kind: std::sync::RwLock::new(workspace_provider_kind),
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

  /// Read the cached update check result.
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

  /// Store a new update check result.
  pub fn set_update_status(&self, status: CachedUpdateStatus) {
    *self.update_status.write().expect("update status lock") = Some(status);
  }

  /// Returns true if enough time has passed to warrant a new update check.
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

  /// Returns true if a manual re-check should be allowed (5-min debounce).
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

  /// Attempt to claim the update-check-in-flight guard. Returns true if
  /// this caller won the race and should perform the check.
  pub fn claim_update_check(&self) -> bool {
    !self
      .update_check_in_flight
      .swap(true, std::sync::atomic::Ordering::SeqCst)
  }

  /// Release the update-check-in-flight guard after a check completes.
  pub fn release_update_check(&self) {
    self
      .update_check_in_flight
      .store(false, std::sync::atomic::Ordering::SeqCst);
  }

  /// Fetch or create the per-session auto-resume mutex.
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

  /// Atomically claim orchestrator ownership. Returns `true` if this call
  /// transitioned from stopped → running. Returns `false` if already running.
  pub fn try_start_orchestrator(&self) -> bool {
    self.connections.try_start_orchestrator()
  }

  pub fn stop_orchestrator(&self) {
    self.connections.stop_orchestrator()
  }

  pub fn is_orchestrator_running(&self) -> bool {
    self.connections.is_orchestrator_running()
  }

  /// Send a manual trigger to force an immediate poll for a mission.
  pub async fn trigger_mission(&self, mission_id: String) {
    let _ = self.mission_trigger_tx.send(mission_id).await;
  }

  /// Take the trigger receiver (called once by the orchestrator at startup).
  pub fn take_mission_trigger_rx(&self) -> Option<mpsc::Receiver<String>> {
    self.mission_trigger_rx.lock().unwrap().take()
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

  /// Get persistence sender
  pub fn persist(&self) -> &mpsc::Sender<PersistCommand> {
    &self.persist_tx
  }

  /// Get database path for synchronous read queries
  pub fn db_path(&self) -> &PathBuf {
    &self.db_path
  }

  pub fn codex_auth(&self) -> Arc<CodexAuthService> {
    self.codex_auth.clone()
  }

  /// Get naming guard for AI session naming dedup
  pub fn naming_guard(&self) -> &Arc<NamingGuard> {
    &self.naming_guard
  }

  pub fn shell_service(&self) -> Arc<ShellService> {
    self.shell_service.clone()
  }

  pub fn terminal_service(&self) -> Arc<TerminalService> {
    self.terminal_service.clone()
  }

  /// Store a Codex action sender
  pub fn set_codex_action_tx(&self, session_id: &str, tx: mpsc::Sender<CodexAction>) {
    self.connectors.set_codex_action_tx(session_id, tx);
  }

  /// Get a Codex action sender (cloned — DashMap refs can't outlive the lookup)
  pub fn get_codex_action_tx(&self, session_id: &str) -> Option<mpsc::Sender<CodexAction>> {
    self.connectors.get_codex_action_tx(session_id).or_else(|| {
      self
        .resolve_runtime_owner_session_id(session_id)
        .and_then(|owner| self.connectors.get_codex_action_tx(&owner))
    })
  }

  /// Store a Claude action sender
  pub fn set_claude_action_tx(&self, session_id: &str, tx: mpsc::Sender<ClaudeAction>) {
    self.connectors.set_claude_action_tx(session_id, tx);
  }

  /// Remove a Codex action sender (stale channel cleanup)
  pub fn remove_codex_action_tx(&self, session_id: &str) {
    self.connectors.remove_codex_action_tx(session_id);
  }

  /// Get a Claude action sender (cloned)
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

  /// True when either provider-specific action channel is currently registered.
  pub fn has_active_connector_action_tx(&self, session_id: &str) -> bool {
    self.get_codex_action_tx(session_id).is_some()
      || self.get_claude_action_tx(session_id).is_some()
  }

  /// Remove a Claude action sender (stale channel cleanup)
  pub fn remove_claude_action_tx(&self, session_id: &str) {
    self.connectors.remove_claude_action_tx(session_id);
  }

  /// Get all session summaries (lock-free via snapshots)
  pub fn get_session_summaries(&self) -> Vec<SessionSummary> {
    self
      .sessions
      .iter()
      .map(|entry| {
        let actor = entry.value();
        let snap = actor.snapshot();
        let control_mode = snap.control_mode;
        let lifecycle_state = snap.lifecycle_state;
        let accepts_user_input =
          accepts_user_input_from_parts(snap.status, control_mode, lifecycle_state);
        let display_title = SessionSummary::display_title_from_parts(
          snap.custom_name.as_deref(),
          snap.summary.as_deref(),
          snap.first_prompt.as_deref(),
          snap.project_name.as_deref(),
          &snap.project_path,
        );
        let context_line = SessionSummary::context_line_from_parts(
          snap.summary.as_deref(),
          snap.first_prompt.as_deref(),
          snap.last_message.as_deref(),
        );
        SessionSummary {
          id: snap.id.clone(),
          provider: snap.provider,
          project_path: snap.project_path.clone(),
          transcript_path: snap.transcript_path.clone(),
          project_name: snap.project_name.clone(),
          model: snap.model.clone(),
          custom_name: snap.custom_name.clone(),
          summary: snap.summary.clone(),
          status: snap.status,
          work_status: snap.work_status,
          control_mode,
          lifecycle_state,
          accepts_user_input,
          token_usage: snap.token_usage.clone(),
          token_usage_snapshot_kind: snap.token_usage_snapshot_kind,
          has_pending_approval: snap.has_pending_approval,
          codex_integration_mode: snap.codex_integration_mode,
          claude_integration_mode: snap.claude_integration_mode,
          approval_policy: snap.approval_policy.clone(),
          approval_policy_details: snap.approval_policy_details.clone(),
          sandbox_mode: snap.sandbox_mode.clone(),
          permission_mode: snap.permission_mode.clone(),
          collaboration_mode: snap.collaboration_mode.clone(),
          multi_agent: snap.multi_agent,
          personality: snap.personality.clone(),
          service_tier: snap.service_tier.clone(),
          developer_instructions: snap.developer_instructions.clone(),
          codex_config_mode: snap.codex_config_mode,
          codex_config_profile: snap.codex_config_profile.clone(),
          codex_model_provider: snap.codex_model_provider.clone(),
          codex_config_source: snap.codex_config_source,
          codex_config_overrides: snap.codex_config_overrides.clone(),
          pending_tool_name: snap.pending_tool_name.clone(),
          pending_tool_input: snap.pending_tool_input.clone(),
          pending_question: snap.pending_question.clone(),
          pending_approval_id: snap.pending_approval_id.clone(),
          started_at: snap.started_at.clone(),
          last_activity_at: snap.last_activity_at.clone(),
          last_progress_at: snap.last_progress_at.clone(),
          git_branch: snap.git_branch.clone(),
          git_sha: snap.git_sha.clone(),
          current_cwd: snap.current_cwd.clone(),
          first_prompt: snap.first_prompt.clone(),
          last_message: snap.last_message.clone(),
          effort: snap.effort.clone(),
          approval_version: Some(snap.approval_version),
          summary_revision: snap.revision,
          repository_root: snap.repository_root.clone(),
          is_worktree: snap.is_worktree,
          worktree_id: snap.worktree_id.clone(),
          unread_count: snap.unread_count,
          has_turn_diff: snap.has_turn_diff,
          display_title,
          context_line,
          list_status: SessionSummary::list_status_from_parts(snap.status, snap.work_status),
          active_worker_count: snap.active_worker_count,
          pending_tool_family: None,
          forked_from_session_id: None,
          mission_id: snap.mission_id.clone(),
          steerable: snap.steerable,
          issue_identifier: snap.issue_identifier.clone(),
          allow_bypass_permissions: snap.allow_bypass_permissions,
        }
      })
      .collect()
  }

  #[allow(dead_code)]
  pub fn get_session_list_items(&self) -> Vec<SessionListItem> {
    self
      .get_session_summaries()
      .into_iter()
      .map(SessionListItem::from)
      .collect()
  }

  #[allow(dead_code)]
  pub fn get_dashboard_conversations(&self) -> Vec<DashboardConversationItem> {
    let tool_counts_by_session = self.load_active_tool_counts();
    let mut conversations: Vec<DashboardConversationItem> = self
      .sessions
      .iter()
      .filter(|entry| entry.value().snapshot().status == orbitdock_protocol::SessionStatus::Active)
      .map(|entry| {
        let snap = entry.value().snapshot();
        let display_title = SessionSummary::display_title_from_parts(
          snap.custom_name.as_deref(),
          snap.summary.as_deref(),
          snap.first_prompt.as_deref(),
          snap.project_name.as_deref(),
          &snap.project_path,
        );
        let context_line = SessionSummary::context_line_from_parts(
          snap.summary.as_deref(),
          snap.first_prompt.as_deref(),
          snap.last_message.as_deref(),
        );
        let preview_text =
          dashboard_preview_text(snap.last_message.as_deref(), context_line.as_deref());
        let activity_summary = dashboard_activity_summary(
          snap.pending_tool_name.as_deref(),
          snap.last_message.as_deref(),
          context_line.as_deref(),
        );
        let alert_context = dashboard_alert_context(
          snap.pending_question.as_deref(),
          snap.pending_tool_name.as_deref(),
          snap.pending_tool_input.as_deref(),
          snap.last_message.as_deref(),
          context_line.as_deref(),
        );
        let control_mode = snap.control_mode;
        let lifecycle_state = snap.lifecycle_state;
        let (grouping_path, grouping_name) = dashboard_grouping_details(
          &snap.project_path,
          snap.repository_root.as_deref(),
          snap.project_name.as_deref(),
        );

        DashboardConversationItem {
          session_id: snap.id.clone(),
          provider: snap.provider,
          project_path: snap.project_path.clone(),
          grouping_path: Some(grouping_path),
          grouping_name: Some(grouping_name),
          project_name: snap.project_name.clone(),
          repository_root: snap.repository_root.clone(),
          git_branch: snap.git_branch.clone(),
          is_worktree: snap.is_worktree,
          worktree_id: snap.worktree_id.clone(),
          model: snap.model.clone(),
          codex_integration_mode: snap.codex_integration_mode,
          claude_integration_mode: snap.claude_integration_mode,
          status: snap.status,
          work_status: snap.work_status,
          control_mode,
          lifecycle_state,
          list_status: SessionSummary::list_status_from_parts(snap.status, snap.work_status),
          display_title,
          context_line,
          last_message: snap.last_message.clone(),
          started_at: snap.started_at.clone(),
          last_activity_at: snap.last_activity_at.clone(),
          unread_count: snap.unread_count,
          has_turn_diff: snap.has_turn_diff,
          diff_preview: dashboard_diff_preview(snap.current_diff.as_deref()),
          pending_tool_name: snap.pending_tool_name.clone(),
          pending_tool_input: snap.pending_tool_input.clone(),
          pending_question: snap.pending_question.clone(),
          preview_text: Some(preview_text),
          activity_summary: Some(activity_summary),
          alert_context: Some(alert_context),
          tool_count: tool_counts_by_session.get(&snap.id).copied().unwrap_or(0),
          active_worker_count: snap.active_worker_count,
          issue_identifier: snap.issue_identifier.clone(),
          effort: snap.effort.clone(),
        }
      })
      .collect();

    conversations.sort_by(|lhs, rhs| {
      dashboard_priority(lhs)
        .cmp(&dashboard_priority(rhs))
        .then_with(|| rhs.last_activity_at.cmp(&lhs.last_activity_at))
        .then_with(|| lhs.display_title.cmp(&rhs.display_title))
    });

    conversations
  }

  fn load_active_tool_counts(&self) -> HashMap<String, u64> {
    let conn = match Connection::open(&self.db_path) {
      Ok(conn) => conn,
      Err(error) => {
        warn!(
            component = "dashboard",
            event = "dashboard.tool_counts.db_open_failed",
            error = %error,
            "Failed to open database for dashboard tool counts"
        );
        return HashMap::new();
      }
    };

    let mut stmt = match conn.prepare(
      "SELECT id, COALESCE(tool_count, 0) AS tool_count
         FROM sessions
        WHERE status = 'active'",
    ) {
      Ok(stmt) => stmt,
      Err(error) => {
        warn!(
            component = "dashboard",
            event = "dashboard.tool_counts.query_prepare_failed",
            error = %error,
            "Failed to prepare dashboard tool count query"
        );
        return HashMap::new();
      }
    };

    let rows = match stmt.query_map([], |row| {
      let session_id: String = row.get(0)?;
      let tool_count: i64 = row.get(1)?;
      Ok((session_id, tool_count.max(0) as u64))
    }) {
      Ok(rows) => rows,
      Err(error) => {
        warn!(
            component = "dashboard",
            event = "dashboard.tool_counts.query_failed",
            error = %error,
            "Failed to read dashboard tool counts"
        );
        return HashMap::new();
      }
    };

    rows.filter_map(Result::ok).collect()
  }

  /// Iterate over all sessions (lock-free DashMap iteration).
  pub fn iter_sessions(&self) -> dashmap::iter::Iter<'_, String, SessionActorHandle> {
    self.sessions.iter()
  }

  /// Get a session actor handle (cheap Clone)
  pub fn get_session(&self, id: &str) -> Option<SessionActorHandle> {
    self.sessions.get(id).map(|r| r.clone()).or_else(|| {
      self
        .resolve_runtime_owner_session_id(id)
        .and_then(|owner| self.sessions.get(&owner).map(|entry| entry.clone()))
    })
  }

  /// Add a session by spawning an actor
  pub fn add_session(&self, mut handle: SessionHandle) -> SessionActorHandle {
    handle.set_list_tx(self.list_tx.clone());
    handle.set_dashboard_revision_counter(self.dashboard_revision.clone());
    let id = handle.id().to_string();
    let actor = SessionActorHandle::spawn(handle, self.persist_tx.clone());
    self.sessions.insert(id, actor.clone());
    actor
  }

  /// Add a pre-spawned actor handle (e.g. from CodexSession event loop)
  pub fn add_session_actor(&self, actor: SessionActorHandle) {
    self.sessions.insert(actor.id.clone(), actor);
  }

  /// Remove a session
  pub fn remove_session(&self, id: &str) -> Option<SessionActorHandle> {
    self.connectors.remove_action_txs(id);
    self.sessions.remove(id).map(|(_, v)| v)
  }

  /// Register codex-core thread ID for a direct session.
  ///
  /// Ownership is DB-driven; this helper writes the mapping to SQLite so hook
  /// routing and reverse lookups do not depend on in-memory aliases.
  pub fn register_codex_thread(&self, session_id: &str, thread_id: &str) -> bool {
    if orbitdock_protocol::is_orbitdock_id(thread_id) {
      tracing::error!(
          component = "state",
          event = "state.register_codex_thread.rejected",
          session_id = %session_id,
          thread_id = %thread_id,
          "Rejected OrbitDock ID as codex thread ID"
      );
      return false;
    }

    let Some(mut conn) = self.open_ownership_db("register_codex_thread") else {
      return false;
    };

    let now = chrono::Utc::now().to_rfc3339();
    let project_path = self
      .get_session(session_id)
      .map(|actor| actor.snapshot().project_path.clone())
      .unwrap_or_else(|| "/unknown".to_string());

    let tx = match conn.transaction() {
      Ok(tx) => tx,
      Err(error) => {
        warn!(
          component = "state",
          event = "state.register_codex_thread.transaction_failed",
          session_id = %session_id,
          thread_id = %thread_id,
          error = %error,
          "Failed to start SQLite transaction for codex thread registration"
        );
        return false;
      }
    };

    if let Err(error) = tx.execute(
      "INSERT OR IGNORE INTO sessions (
         id, provider, control_mode, codex_integration_mode, status, work_status,
         project_path, started_at, last_activity_at
       ) VALUES (?1, 'codex', 'direct', 'direct', 'active', 'waiting', ?2, ?3, ?3)",
      params![session_id, project_path, now],
    ) {
      warn!(
        component = "state",
        event = "state.register_codex_thread.insert_failed",
        session_id = %session_id,
        thread_id = %thread_id,
        error = %error,
        "Failed to ensure direct Codex owner row before thread registration"
      );
      return false;
    }

    if let Err(error) = tx.execute(
      "UPDATE sessions SET codex_thread_id = ?1 WHERE id = ?2",
      params![thread_id, session_id],
    ) {
      warn!(
        component = "state",
        event = "state.register_codex_thread.update_failed",
        session_id = %session_id,
        thread_id = %thread_id,
        error = %error,
        "Failed to persist Codex thread ownership mapping"
      );
      return false;
    }

    if let Err(error) = tx.commit() {
      warn!(
        component = "state",
        event = "state.register_codex_thread.commit_failed",
        session_id = %session_id,
        thread_id = %thread_id,
        error = %error,
        "Failed to commit Codex thread ownership mapping transaction"
      );
      return false;
    }

    true
  }

  /// Register Claude SDK session ID for a direct session.
  ///
  /// Ownership is DB-driven; this helper writes the mapping to SQLite so hook
  /// routing and reverse lookups do not depend on in-memory aliases.
  pub fn register_claude_thread(&self, session_id: &str, sdk_session_id: &str) -> bool {
    if orbitdock_protocol::is_orbitdock_id(sdk_session_id) {
      tracing::error!(
          component = "state",
          event = "state.register_claude_thread.rejected",
          session_id = %session_id,
          sdk_session_id = %sdk_session_id,
          "Rejected OrbitDock ID as Claude SDK session ID"
      );
      return false;
    }

    let Some(mut conn) = self.open_ownership_db("register_claude_thread") else {
      return false;
    };

    let now = chrono::Utc::now().to_rfc3339();
    let project_path = self
      .get_session(session_id)
      .map(|actor| actor.snapshot().project_path.clone())
      .unwrap_or_else(|| "/unknown".to_string());

    let tx = match conn.transaction() {
      Ok(tx) => tx,
      Err(error) => {
        warn!(
          component = "state",
          event = "state.register_claude_thread.transaction_failed",
          session_id = %session_id,
          sdk_session_id = %sdk_session_id,
          error = %error,
          "Failed to start SQLite transaction for Claude SDK registration"
        );
        return false;
      }
    };

    if let Err(error) = tx.execute(
      "INSERT OR IGNORE INTO sessions (
         id, provider, control_mode, claude_integration_mode, status, work_status,
         project_path, started_at, last_activity_at
       ) VALUES (?1, 'claude', 'direct', 'direct', 'active', 'waiting', ?2, ?3, ?3)",
      params![session_id, project_path, now],
    ) {
      warn!(
        component = "state",
        event = "state.register_claude_thread.insert_failed",
        session_id = %session_id,
        sdk_session_id = %sdk_session_id,
        error = %error,
        "Failed to ensure direct Claude owner row before SDK registration"
      );
      return false;
    }

    if let Err(error) = tx.execute(
      "UPDATE sessions SET claude_sdk_session_id = ?1 WHERE id = ?2",
      params![sdk_session_id, session_id],
    ) {
      warn!(
        component = "state",
        event = "state.register_claude_thread.update_failed",
        session_id = %session_id,
        sdk_session_id = %sdk_session_id,
        error = %error,
        "Failed to persist Claude SDK ownership mapping"
      );
      return false;
    }

    if let Err(error) = tx.commit() {
      warn!(
        component = "state",
        event = "state.register_claude_thread.commit_failed",
        session_id = %session_id,
        sdk_session_id = %sdk_session_id,
        error = %error,
        "Failed to commit Claude SDK ownership mapping transaction"
      );
      return false;
    }

    true
  }

  /// Resolve a Claude SDK session ID to the owning OrbitDock session ID
  #[allow(dead_code)]
  pub fn resolve_claude_thread(&self, sdk_session_id: &str) -> Option<String> {
    let conn = self.open_ownership_db("resolve_claude_thread")?;
    conn
      .query_row(
        "SELECT s.id
           FROM sessions s
          WHERE s.provider = 'claude'
            AND s.claude_sdk_session_id = ?1
            AND COALESCE(s.control_mode, CASE
                  WHEN s.provider = 'claude' AND s.claude_integration_mode = 'direct'
                    THEN 'direct'
                  ELSE 'passive'
                END) = 'direct'
          ORDER BY CASE s.status WHEN 'active' THEN 0 ELSE 1 END,
                   COALESCE(s.last_activity_at, s.started_at, '') DESC
          LIMIT 1",
        params![sdk_session_id],
        |row| row.get::<_, String>(0),
      )
      .optional()
      .map_err(|error| {
        warn!(
          component = "state",
          event = "state.resolve_claude_thread.query_failed",
          sdk_session_id = %sdk_session_id,
          error = %error,
          "Failed to resolve Claude SDK session ownership from SQLite"
        );
        error
      })
      .ok()
      .flatten()
  }

  /// Resolve a Codex thread ID to the owning OrbitDock session ID.
  pub fn resolve_codex_thread(&self, thread_id: &str) -> Option<String> {
    let conn = self.open_ownership_db("resolve_codex_thread")?;
    conn
      .query_row(
        "SELECT s.id
           FROM sessions s
          WHERE s.provider = 'codex'
            AND s.codex_thread_id = ?1
            AND COALESCE(s.control_mode, CASE
                  WHEN s.provider = 'codex' AND s.codex_integration_mode = 'direct'
                    THEN 'direct'
                  ELSE 'passive'
                END) = 'direct'
          ORDER BY CASE s.status WHEN 'active' THEN 0 ELSE 1 END,
                   COALESCE(s.last_activity_at, s.started_at, '') DESC
          LIMIT 1",
        params![thread_id],
        |row| row.get::<_, String>(0),
      )
      .optional()
      .map_err(|error| {
        warn!(
          component = "state",
          event = "state.resolve_codex_thread.query_failed",
          thread_id = %thread_id,
          error = %error,
          "Failed to resolve Codex thread ownership from SQLite"
        );
        error
      })
      .ok()
      .flatten()
  }

  /// Find an active direct Claude session for a project that hasn't registered its SDK ID yet.
  /// Used by `ClaudeSessionStart` to eagerly claim the SDK ID before the `init` event arrives.
  pub fn find_unregistered_direct_claude_session(&self, project_path: &str) -> Option<String> {
    let conn = Connection::open(&self.db_path).ok()?;
    let candidate: Option<String> = conn
      .query_row(
        "SELECT id
           FROM sessions
          WHERE provider = 'claude'
            AND project_path = ?1
            AND status = 'active'
            AND COALESCE(control_mode, CASE
                  WHEN provider = 'claude' AND claude_integration_mode = 'direct'
                    THEN 'direct'
                  ELSE 'passive'
                END) = 'direct'
            AND claude_sdk_session_id IS NULL
          ORDER BY COALESCE(last_activity_at, started_at, '') DESC
          LIMIT 1",
        params![project_path],
        |row| row.get(0),
      )
      .optional()
      .ok()
      .flatten();
    candidate.filter(|session_id| self.get_session(session_id).is_some())
  }

  /// Find an active direct Codex session for a project that hasn't registered
  /// its thread ID yet. Used by Codex SessionStart hooks to claim direct
  /// ownership before a passive shadow is materialized.
  pub fn find_unregistered_direct_codex_session(&self, project_path: &str) -> Option<String> {
    let conn = Connection::open(&self.db_path).ok()?;
    let candidate: Option<String> = conn
      .query_row(
        "SELECT id
           FROM sessions
          WHERE provider = 'codex'
            AND project_path = ?1
            AND status = 'active'
            AND COALESCE(control_mode, CASE
                  WHEN provider = 'codex' AND codex_integration_mode = 'direct'
                    THEN 'direct'
                  ELSE 'passive'
                END) = 'direct'
            AND codex_thread_id IS NULL
          ORDER BY COALESCE(last_activity_at, started_at, '') DESC
          LIMIT 1",
        params![project_path],
        |row| row.get(0),
      )
      .optional()
      .ok()
      .flatten();
    candidate.filter(|session_id| self.get_session(session_id).is_some())
  }

  /// Look up the Codex thread ID for a given session ID (reverse lookup)
  pub fn codex_thread_for_session(&self, session_id: &str) -> Option<String> {
    let conn = Connection::open(&self.db_path).ok()?;
    conn
      .query_row(
        "SELECT codex_thread_id FROM sessions WHERE id = ?1",
        params![session_id],
        |row| row.get::<_, Option<String>>(0),
      )
      .optional()
      .ok()
      .flatten()
      .flatten()
  }

  /// Look up the Claude SDK session ID for a given session ID (reverse lookup)
  pub fn claude_sdk_id_for_session(&self, session_id: &str) -> Option<String> {
    let conn = Connection::open(&self.db_path).ok()?;
    conn
      .query_row(
        "SELECT claude_sdk_session_id FROM sessions WHERE id = ?1",
        params![session_id],
        |row| row.get::<_, Option<String>>(0),
      )
      .optional()
      .ok()
      .flatten()
      .flatten()
  }

  /// Subscribe to list updates
  pub fn subscribe_list(&self) -> broadcast::Receiver<orbitdock_protocol::ServerMessage> {
    self.list_tx.subscribe()
  }

  pub fn current_dashboard_revision(&self) -> u64 {
    self.dashboard_revision.load(Ordering::Relaxed)
  }

  #[allow(dead_code)]
  pub fn current_dashboard_snapshot(&self) -> DashboardSnapshot {
    let sessions = self.get_session_list_items();
    let conversations = self.get_dashboard_conversations();
    let counts = DashboardCounts {
      attention: conversations
        .iter()
        .filter(|conversation| {
          matches!(
            conversation.list_status,
            orbitdock_protocol::SessionListStatus::Permission
              | orbitdock_protocol::SessionListStatus::Question
          )
        })
        .count() as u32,
      running: conversations
        .iter()
        .filter(|conversation| {
          matches!(
            conversation.list_status,
            orbitdock_protocol::SessionListStatus::Working
          )
        })
        .count() as u32,
      ready: conversations
        .iter()
        .filter(|conversation| {
          matches!(
            conversation.list_status,
            orbitdock_protocol::SessionListStatus::Reply
          )
        })
        .count() as u32,
      direct: conversations
        .iter()
        .filter(|conversation| {
          matches!(
            (
              conversation.provider,
              conversation.codex_integration_mode,
              conversation.claude_integration_mode
            ),
            (
              orbitdock_protocol::Provider::Codex,
              Some(orbitdock_protocol::CodexIntegrationMode::Direct),
              _
            ) | (
              orbitdock_protocol::Provider::Claude,
              _,
              Some(orbitdock_protocol::ClaudeIntegrationMode::Direct)
            )
          )
        })
        .count() as u32,
    };

    DashboardSnapshot {
      revision: self.dashboard_revision.load(Ordering::Relaxed),
      sessions,
      conversations,
      counts,
    }
  }

  pub fn current_missions_snapshot(&self) -> MissionsSnapshot {
    let rows = match Connection::open(&self.db_path) {
      Ok(conn) => match crate::infrastructure::persistence::load_missions_with_counts(&conn) {
        Ok(rows) => rows,
        Err(error) => {
          warn!(
              component = "mission_control",
              event = "missions.snapshot.load_failed",
              error = %error,
              "Failed to build missions snapshot from persistence"
          );
          Vec::new()
        }
      },
      Err(error) => {
        warn!(
            component = "mission_control",
            event = "missions.snapshot.load_failed",
            error = %error,
            "Failed to build missions snapshot from persistence"
        );
        Vec::new()
      }
    };
    let orchestrator_running = self.is_orchestrator_running();
    let missions = rows
      .into_iter()
      .map(|(row, (active, queued, completed, failed))| {
        crate::transport::http::mission_control::summary_from_row(
          &row,
          active,
          queued,
          completed,
          failed,
          orchestrator_running,
        )
      })
      .collect();

    MissionsSnapshot {
      revision: self.mission_revision.load(Ordering::Relaxed),
      missions,
    }
  }

  pub fn current_missions_revision(&self) -> u64 {
    self.mission_revision.load(Ordering::Relaxed)
  }

  pub fn publish_dashboard_snapshot(&self) {
    let revision = self.dashboard_revision.fetch_add(1, Ordering::Relaxed) + 1;
    let _ = self
      .list_tx
      .send(orbitdock_protocol::ServerMessage::DashboardInvalidated { revision });
  }

  pub fn publish_missions_snapshot(&self) {
    let revision = self.mission_revision.fetch_add(1, Ordering::Relaxed) + 1;
    let _ = self
      .list_tx
      .send(orbitdock_protocol::ServerMessage::MissionsInvalidated { revision });
  }

  /// Broadcast a message to all list subscribers
  pub fn broadcast_to_list(&self, msg: orbitdock_protocol::ServerMessage) {
    let should_emit_dashboard = matches!(
      msg,
      orbitdock_protocol::ServerMessage::SessionEnded { .. }
        | orbitdock_protocol::ServerMessage::SessionForked { .. }
    );
    let _ = self.list_tx.send(msg);
    if should_emit_dashboard {
      self.publish_dashboard_snapshot();
    }
  }

  /// Get a clone of the list broadcast sender (for passing to background tasks)
  pub fn list_tx(&self) -> broadcast::Sender<orbitdock_protocol::ServerMessage> {
    self.list_tx.clone()
  }

  /// Get a clone of the shared dashboard revision counter.
  pub fn dashboard_revision_counter(&self) -> Arc<AtomicU64> {
    self.dashboard_revision.clone()
  }

  // ── Pending hook session cache ────────────────────────────────────

  /// Cache a provider-backed passive session until an actionable hook
  /// materializes it.
  pub fn cache_pending_hook_session(&self, session_id: String, pending: PendingHookSession) {
    match pending {
      PendingHookSession::Claude(pending) => {
        self.pending_claude_sessions.insert(session_id, pending);
      }
      PendingHookSession::Codex(pending) => {
        self.pending_codex_sessions.insert(session_id, pending);
      }
    }
  }

  /// Take (remove) a pending provider hook session for materialization.
  pub fn take_pending_hook_session(
    &self,
    provider: Provider,
    session_id: &str,
  ) -> Option<PendingHookSession> {
    match provider {
      Provider::Claude => self
        .pending_claude_sessions
        .remove(session_id)
        .map(|(_, pending)| PendingHookSession::Claude(pending)),
      Provider::Codex => self
        .pending_codex_sessions
        .remove(session_id)
        .map(|(_, pending)| PendingHookSession::Codex(pending)),
    }
  }

  /// Discard a pending hook session before it materializes.
  pub fn discard_pending_hook_session(&self, provider: Provider, session_id: &str) -> bool {
    match provider {
      Provider::Claude => self.pending_claude_sessions.remove(session_id).is_some(),
      Provider::Codex => self.pending_codex_sessions.remove(session_id).is_some(),
    }
  }

  /// Peek at a pending hook session's cwd without removing it.
  pub fn peek_pending_hook_cwd(&self, provider: Provider, session_id: &str) -> Option<String> {
    match provider {
      Provider::Claude => self
        .pending_claude_sessions
        .get(session_id)
        .map(|entry| entry.cwd.clone()),
      Provider::Codex => self
        .pending_codex_sessions
        .get(session_id)
        .map(|entry| entry.cwd.clone()),
    }
  }

  /// Expire pending hook sessions older than `ttl`.
  pub fn expire_pending_hook_sessions(&self, ttl: Duration) {
    let cutoff = Instant::now() - ttl;
    self
      .pending_claude_sessions
      .retain(|_, pending| pending.cached_at > cutoff);
    self
      .pending_codex_sessions
      .retain(|_, pending| pending.cached_at > cutoff);
  }

  /// Collect recent project paths from active/ended sessions.
  /// Archived/completed worktrees are marked `removed` and should stay out of launch pickers.
  pub async fn list_recent_projects(&self) -> Vec<orbitdock_protocol::RecentProject> {
    let removed_worktree_paths =
      crate::infrastructure::persistence::load_removed_worktree_paths(&self.db_path);
    let sessions = self.sessions.iter().map(|entry| {
      let snap = entry.value().snapshot();
      (snap.project_path.clone(), snap.last_activity_at.clone())
    });
    collect_recent_projects(sessions, &removed_worktree_paths)
  }
}

fn dashboard_priority(item: &DashboardConversationItem) -> u8 {
  match item.list_status {
    orbitdock_protocol::SessionListStatus::Permission => 0,
    orbitdock_protocol::SessionListStatus::Question => 1,
    orbitdock_protocol::SessionListStatus::Working => 2,
    orbitdock_protocol::SessionListStatus::Reply => 3,
    orbitdock_protocol::SessionListStatus::Ended => 4,
  }
}

fn dashboard_grouping_details(
  project_path: &str,
  repository_root: Option<&str>,
  project_name: Option<&str>,
) -> (String, String) {
  let grouping_path = repository_root.unwrap_or(project_path).to_string();
  let grouping_name = project_name
    .map(str::trim)
    .filter(|name| !name.is_empty())
    .map(ToOwned::to_owned)
    .unwrap_or_else(|| {
      grouping_path
        .rsplit('/')
        .find(|segment| !segment.is_empty())
        .map(std::string::ToString::to_string)
        .unwrap_or_else(|| "Unknown".to_string())
    });

  (grouping_path, grouping_name)
}

fn dashboard_preview_text(last_message: Option<&str>, context_line: Option<&str>) -> String {
  sanitize_dashboard_text(
    last_message
      .or(context_line)
      .unwrap_or("Waiting for your next message."),
  )
}

fn dashboard_activity_summary(
  pending_tool_name: Option<&str>,
  last_message: Option<&str>,
  context_line: Option<&str>,
) -> String {
  if let Some(tool_name) = pending_tool_name {
    return format!("Running {tool_name}");
  }

  sanitize_dashboard_text(last_message.or(context_line).unwrap_or("Processing…"))
}

fn dashboard_alert_context(
  pending_question: Option<&str>,
  pending_tool_name: Option<&str>,
  pending_tool_input: Option<&str>,
  last_message: Option<&str>,
  context_line: Option<&str>,
) -> String {
  if let Some(question) = pending_question.filter(|value| !value.is_empty()) {
    return question.to_string();
  }

  if let Some(tool_name) = pending_tool_name {
    return format_tool_context(tool_name, pending_tool_input);
  }

  sanitize_dashboard_text(
    last_message
      .or(context_line)
      .unwrap_or("Needs your attention."),
  )
}

fn sanitize_dashboard_text(text: &str) -> String {
  text
    .replace("**", "")
    .replace("__", "")
    .replace('`', "")
    .replace("## ", "")
    .replace("# ", "")
}

fn format_tool_context(tool_name: &str, input: Option<&str>) -> String {
  let Some(input) = input.filter(|value| !value.is_empty()) else {
    return format!("Wants to run {tool_name}");
  };

  let Ok(json) = serde_json::from_str::<serde_json::Value>(input) else {
    return format!("Wants to run {tool_name}");
  };

  match tool_name {
    "Bash" => json
      .get("command")
      .and_then(serde_json::Value::as_str)
      .map(ToOwned::to_owned),
    "Edit" | "Write" | "Read" => json
      .get("file_path")
      .and_then(serde_json::Value::as_str)
      .and_then(|path| std::path::Path::new(path).file_name())
      .and_then(|name| name.to_str())
      .map(|name| format!("{tool_name} {name}")),
    "Grep" => json
      .get("pattern")
      .and_then(serde_json::Value::as_str)
      .map(|pattern| format!("Search for \"{pattern}\"")),
    "Glob" => json
      .get("pattern")
      .and_then(serde_json::Value::as_str)
      .map(|pattern| format!("Find files matching {pattern}")),
    _ => None,
  }
  .unwrap_or_else(|| format!("Wants to run {tool_name}"))
}

fn dashboard_diff_preview(diff: Option<&str>) -> Option<DashboardDiffPreview> {
  let diff = diff?.trim();
  if diff.is_empty() {
    return None;
  }

  let mut file_paths: Vec<String> = vec![];
  let mut additions = 0_u32;
  let mut deletions = 0_u32;

  for line in diff.lines() {
    if let Some(path) = line.strip_prefix("+++ b/") {
      let path = path.trim();
      if !path.is_empty() && !file_paths.iter().any(|existing| existing == path) {
        file_paths.push(path.to_string());
      }
      continue;
    }
    if let Some(rest) = line.strip_prefix("diff --git ") {
      if let Some(path) = rest.split(" b/").nth(1) {
        let path = path.trim();
        if !path.is_empty() && !file_paths.iter().any(|existing| existing == path) {
          file_paths.push(path.to_string());
        }
      }
      continue;
    }
    if line.starts_with('+') && !line.starts_with("+++") {
      additions = additions.saturating_add(1);
    } else if line.starts_with('-') && !line.starts_with("---") {
      deletions = deletions.saturating_add(1);
    }
  }

  Some(DashboardDiffPreview {
    file_count: file_paths.len() as u32,
    additions,
    deletions,
    file_paths: file_paths.into_iter().take(3).collect(),
  })
}

// Note: No Default impl - requires persist_tx

#[cfg(test)]
mod tests {
  use super::SessionRegistry;
  use crate::domain::sessions::session::SessionHandle;
  use crate::support::test_support::ensure_server_test_data_dir;
  use orbitdock_protocol::{
    CodexIntegrationMode, Provider, SessionControlMode, SessionLifecycleState, SessionStatus,
    SubagentInfo, SubagentStatus, WorkStatus, WorkspaceProviderKind,
  };
  use rusqlite::Connection;
  use std::sync::Arc;
  use std::time::Duration;
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

    let conversations = registry.get_dashboard_conversations();
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

    let conversations = registry.get_dashboard_conversations();
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

    let conversations = registry.get_dashboard_conversations();
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
        agent_type: "worker".to_string(),
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
        agent_type: "worker".to_string(),
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

    let conversation = registry
      .get_dashboard_conversations()
      .into_iter()
      .find(|item| item.session_id == "mission-session")
      .expect("dashboard conversation should exist");
    assert_eq!(conversation.active_worker_count, 1);
    assert_eq!(conversation.issue_identifier.as_deref(), Some("PROJ-42"));
  }

  #[tokio::test]
  async fn dashboard_conversations_load_tool_count_from_persistence() {
    let db_path = std::env::temp_dir().join(format!(
      "orbitdock-session-registry-dashboard-{}.db",
      std::process::id()
    ));
    let _ = std::fs::remove_file(&db_path);
    let conn = Connection::open(&db_path).expect("open temp db");
    conn
      .execute(
        "CREATE TABLE sessions (
           id TEXT PRIMARY KEY,
           status TEXT NOT NULL,
           tool_count INTEGER NOT NULL DEFAULT 0
         )",
        [],
      )
      .expect("create sessions table");
    conn
      .execute(
        "INSERT INTO sessions (id, status, tool_count) VALUES (?1, ?2, ?3)",
        ("tool-session", "active", 7_i64),
      )
      .expect("seed session row");
    drop(conn);

    let (persist_tx, _persist_rx) = mpsc::channel(8);
    let registry = SessionRegistry::new_with_primary_and_db_path(
      persist_tx,
      db_path.clone(),
      true,
      WorkspaceProviderKind::default(),
    );

    let session = SessionHandle::new(
      "tool-session".to_string(),
      Provider::Codex,
      "/tmp/orbitdock-tools".to_string(),
    );
    registry.add_session(session);

    let conversation = registry
      .get_dashboard_conversations()
      .into_iter()
      .find(|item| item.session_id == "tool-session")
      .expect("dashboard conversation should exist");
    assert_eq!(conversation.tool_count, 7);

    let _ = std::fs::remove_file(db_path);
  }

  fn create_ownership_test_db() -> std::path::PathBuf {
    let db_path = std::env::temp_dir().join(format!(
      "orbitdock-session-registry-ownership-{}-{}.db",
      std::process::id(),
      std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
    ));
    let _ = std::fs::remove_file(&db_path);
    let conn = Connection::open(&db_path).expect("open temp ownership db");
    conn
      .execute(
        "CREATE TABLE sessions (
           id TEXT PRIMARY KEY,
           provider TEXT,
           control_mode TEXT,
           codex_integration_mode TEXT,
           claude_integration_mode TEXT,
           status TEXT,
           work_status TEXT,
           project_path TEXT,
           started_at TEXT,
           last_activity_at TEXT,
           codex_thread_id TEXT,
           claude_sdk_session_id TEXT
         )",
        [],
      )
      .expect("create ownership sessions table");
    drop(conn);
    db_path
  }

  #[test]
  fn register_codex_thread_succeeds_after_transient_sqlite_lock() {
    let db_path = create_ownership_test_db();
    let (persist_tx, _persist_rx) = mpsc::channel(8);
    let registry = Arc::new(SessionRegistry::new_with_primary_and_db_path(
      persist_tx,
      db_path.clone(),
      true,
      WorkspaceProviderKind::default(),
    ));

    let lock_conn = Connection::open(&db_path).expect("open lock connection");
    lock_conn
      .execute_batch("BEGIN IMMEDIATE")
      .expect("acquire write lock");

    let registry_for_thread = registry.clone();
    let join = std::thread::spawn(move || {
      registry_for_thread.register_codex_thread("od-lock-owner", "codex-thread-lock")
    });

    std::thread::sleep(Duration::from_millis(150));
    lock_conn
      .execute_batch("COMMIT")
      .expect("release write lock");

    assert!(join.join().expect("registration thread should join"));
    assert_eq!(
      registry.resolve_codex_thread("codex-thread-lock"),
      Some("od-lock-owner".to_string())
    );

    let _ = std::fs::remove_file(db_path);
  }

  #[test]
  fn register_thread_reports_failure_when_db_is_unavailable() {
    let missing_dir = std::env::temp_dir().join(format!(
      "orbitdock-session-registry-missing-{}-{}",
      std::process::id(),
      std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
    ));
    let db_path = missing_dir.join("missing.db");
    let (persist_tx, _persist_rx) = mpsc::channel(8);
    let registry = SessionRegistry::new_with_primary_and_db_path(
      persist_tx,
      db_path,
      true,
      WorkspaceProviderKind::default(),
    );

    assert!(!registry.register_codex_thread("od-fail-owner", "codex-thread-fail"));
    assert!(!registry.register_claude_thread("od-fail-owner", "claude-thread-fail"));
  }
}
