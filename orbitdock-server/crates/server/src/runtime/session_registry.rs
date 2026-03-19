//! Application state

mod connection_state;
mod connector_registry;
mod recent_projects;

use dashmap::DashMap;
use orbitdock_protocol::{ClientPrimaryClaim, SessionListItem, SessionSummary};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{broadcast, mpsc};

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;
use crate::domain::sessions::session::SessionHandle;
use crate::infrastructure::persistence::PersistCommand;
use crate::infrastructure::shell::ShellService;
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

/// Shared application state backed by lock-free concurrent maps.
/// All methods take `&self` — no external Mutex needed.
pub struct SessionRegistry {
    /// Active sessions stored as actor handles
    sessions: DashMap<String, SessionActorHandle>,

    /// Connector channels and provider thread ownership maps.
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

    /// Provider-agnostic shell runtime service for user-initiated commands.
    shell_service: Arc<ShellService>,

    /// Primary claim and WebSocket connection state.
    connections: ConnectionState,
}

impl SessionRegistry {
    #[cfg(test)]
    #[allow(dead_code)]
    pub fn new(persist_tx: mpsc::Sender<PersistCommand>) -> Self {
        Self::new_with_primary_and_db_path(
            persist_tx,
            crate::infrastructure::paths::db_path(),
            true,
        )
    }

    #[cfg(test)]
    pub fn new_with_primary(persist_tx: mpsc::Sender<PersistCommand>, is_primary: bool) -> Self {
        Self::new_with_primary_and_db_path(
            persist_tx,
            crate::infrastructure::paths::db_path(),
            is_primary,
        )
    }

    pub fn new_with_primary_and_db_path(
        persist_tx: mpsc::Sender<PersistCommand>,
        db_path: PathBuf,
        is_primary: bool,
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
        Self {
            sessions: DashMap::new(),
            connectors: ConnectorRegistry::new(),
            list_tx,
            persist_tx,
            db_path,
            codex_auth,
            naming_guard: Arc::new(NamingGuard::new()),
            pending_claude_sessions: DashMap::new(),
            shell_service: Arc::new(ShellService::new()),
            connections: ConnectionState::new(is_primary),
        }
    }

    pub fn is_primary(&self) -> bool {
        self.connections.is_primary()
    }

    pub fn set_primary(&self, is_primary: bool) -> bool {
        self.connections.set_primary(is_primary)
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

    pub fn set_client_primary_claim(
        &self,
        conn_id: u64,
        client_id: String,
        device_name: String,
        is_primary: bool,
    ) {
        self.connections
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

    /// Store a Codex action sender
    pub fn set_codex_action_tx(&self, session_id: &str, tx: mpsc::Sender<CodexAction>) {
        self.connectors.set_codex_action_tx(session_id, tx);
    }

    /// Get a Codex action sender (cloned — DashMap refs can't outlive the lookup)
    pub fn get_codex_action_tx(&self, session_id: &str) -> Option<mpsc::Sender<CodexAction>> {
        self.connectors.get_codex_action_tx(session_id)
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
        self.connectors.get_claude_action_tx(session_id)
    }

    /// Remove a Claude action sender (stale channel cleanup)
    pub fn remove_claude_action_tx(&self, session_id: &str) {
        self.connectors.remove_claude_action_tx(session_id);
    }

    /// Get all session summaries (lock-free via snapshots)
    pub fn get_session_summaries(&self) -> Vec<SessionSummary> {
        self.sessions
            .iter()
            .map(|entry| {
                let actor = entry.value();
                let snap = actor.snapshot();
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
                    token_usage: snap.token_usage.clone(),
                    token_usage_snapshot_kind: snap.token_usage_snapshot_kind,
                    has_pending_approval: snap.has_pending_approval,
                    codex_integration_mode: snap.codex_integration_mode,
                    claude_integration_mode: snap.claude_integration_mode,
                    approval_policy: snap.approval_policy.clone(),
                    sandbox_mode: snap.sandbox_mode.clone(),
                    permission_mode: snap.permission_mode.clone(),
                    collaboration_mode: snap.collaboration_mode.clone(),
                    multi_agent: snap.multi_agent,
                    personality: snap.personality.clone(),
                    service_tier: snap.service_tier.clone(),
                    developer_instructions: snap.developer_instructions.clone(),
                    codex_config_source: snap.codex_config_source,
                    codex_config_overrides: snap.codex_config_overrides.clone(),
                    pending_tool_name: snap.pending_tool_name.clone(),
                    pending_tool_input: snap.pending_tool_input.clone(),
                    pending_question: snap.pending_question.clone(),
                    pending_approval_id: snap.pending_approval_id.clone(),
                    started_at: snap.started_at.clone(),
                    last_activity_at: snap.last_activity_at.clone(),
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
                    list_status: SessionSummary::list_status_from_parts(
                        snap.status,
                        snap.work_status,
                    ),
                    active_worker_count: 0,
                    pending_tool_family: None,
                    forked_from_session_id: None,
                    mission_id: None,
                    issue_identifier: None,
                    allow_bypass_permissions: false,
                }
            })
            .collect()
    }

    pub fn get_session_list_items(&self) -> Vec<SessionListItem> {
        self.get_session_summaries()
            .into_iter()
            .map(SessionListItem::from)
            .collect()
    }

    /// Iterate over all sessions (lock-free DashMap iteration).
    pub fn iter_sessions(&self) -> dashmap::iter::Iter<'_, String, SessionActorHandle> {
        self.sessions.iter()
    }

    /// Get a session actor handle (cheap Clone)
    pub fn get_session(&self, id: &str) -> Option<SessionActorHandle> {
        self.sessions.get(id).map(|r| r.clone())
    }

    /// Add a session by spawning an actor
    pub fn add_session(&self, mut handle: SessionHandle) -> SessionActorHandle {
        handle.set_list_tx(self.list_tx.clone());
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
        self.connectors.remove_session_threads(id);
        self.sessions.remove(id).map(|(_, v)| v)
    }

    /// Register codex-core thread ID for a direct session.
    /// Rejects OrbitDock IDs (`od-` prefix) as a defense-in-depth guard.
    pub fn register_codex_thread(&self, session_id: &str, thread_id: &str) {
        if orbitdock_protocol::is_orbitdock_id(thread_id) {
            tracing::error!(
                component = "state",
                event = "state.register_codex_thread.rejected",
                session_id = %session_id,
                thread_id = %thread_id,
                "Rejected OrbitDock ID as codex thread ID"
            );
            return;
        }
        self.connectors.register_codex_thread(session_id, thread_id);
    }

    /// Check whether thread ID is managed by a direct server session
    pub fn is_managed_codex_thread(&self, thread_id: &str) -> bool {
        self.connectors.is_managed_codex_thread(thread_id)
    }

    /// Register Claude SDK session ID for a direct session.
    /// Rejects OrbitDock IDs (`od-` prefix) as a defense-in-depth guard.
    pub fn register_claude_thread(&self, session_id: &str, sdk_session_id: &str) {
        if orbitdock_protocol::is_orbitdock_id(sdk_session_id) {
            tracing::error!(
                component = "state",
                event = "state.register_claude_thread.rejected",
                session_id = %session_id,
                sdk_session_id = %sdk_session_id,
                "Rejected OrbitDock ID as Claude SDK session ID"
            );
            return;
        }
        self.connectors
            .register_claude_thread(session_id, sdk_session_id);
    }

    /// Check whether a Claude SDK session ID is managed by a direct session
    pub fn is_managed_claude_thread(&self, sdk_session_id: &str) -> bool {
        self.connectors.is_managed_claude_thread(sdk_session_id)
    }

    /// Resolve a Claude SDK session ID to the owning OrbitDock session ID
    #[allow(dead_code)]
    pub fn resolve_claude_thread(&self, sdk_session_id: &str) -> Option<String> {
        self.connectors.resolve_claude_thread(sdk_session_id)
    }

    /// Find an active direct Claude session for a project that hasn't registered its SDK ID yet.
    /// Used by `ClaudeSessionStart` to eagerly claim the SDK ID before the `init` event arrives.
    pub fn find_unregistered_direct_claude_session(&self, project_path: &str) -> Option<String> {
        use orbitdock_protocol::{ClaudeIntegrationMode, Provider, SessionStatus};

        // Collect registered session IDs for quick lookup
        let registered = self.connectors.registered_claude_session_ids();

        self.sessions
            .iter()
            .find(|entry| {
                let snap = entry.value().snapshot();
                snap.provider == Provider::Claude
                    && snap.claude_integration_mode == Some(ClaudeIntegrationMode::Direct)
                    && snap.status == SessionStatus::Active
                    && snap.project_path == project_path
                    && !registered.contains(&snap.id)
            })
            .map(|entry| entry.key().clone())
    }

    /// Look up the Codex thread ID for a given session ID (reverse lookup)
    pub fn codex_thread_for_session(&self, session_id: &str) -> Option<String> {
        self.connectors.codex_thread_for_session(session_id)
    }

    /// Look up the Claude SDK session ID for a given session ID (reverse lookup)
    pub fn claude_sdk_id_for_session(&self, session_id: &str) -> Option<String> {
        self.connectors.claude_sdk_id_for_session(session_id)
    }

    /// Check if a session already has a live connector (action channel registered)
    pub fn has_codex_connector(&self, session_id: &str) -> bool {
        self.connectors.has_codex_connector(session_id)
    }

    /// Check if a session already has a live Claude connector
    pub fn has_claude_connector(&self, session_id: &str) -> bool {
        self.connectors.has_claude_connector(session_id)
    }

    /// Subscribe to list updates
    pub fn subscribe_list(&self) -> broadcast::Receiver<orbitdock_protocol::ServerMessage> {
        self.list_tx.subscribe()
    }

    /// Broadcast a message to all list subscribers
    pub fn broadcast_to_list(&self, msg: orbitdock_protocol::ServerMessage) {
        let _ = self.list_tx.send(msg);
    }

    /// Get a clone of the list broadcast sender (for passing to background tasks)
    pub fn list_tx(&self) -> broadcast::Sender<orbitdock_protocol::ServerMessage> {
        self.list_tx.clone()
    }

    // ── Pending Claude session cache ──────────────────────────────────

    /// Cache a pending Claude session (called by SessionStart instead of creating a DB row).
    pub fn cache_pending_claude(&self, session_id: String, pending: PendingClaudeSession) {
        self.pending_claude_sessions.insert(session_id, pending);
    }

    /// Take (remove) a pending Claude session for materialization.
    pub fn take_pending_claude(&self, session_id: &str) -> Option<PendingClaudeSession> {
        self.pending_claude_sessions
            .remove(session_id)
            .map(|(_, v)| v)
    }

    /// Discard a pending Claude session (e.g. on SessionEnd before materialization).
    /// Returns true if there was a pending entry to discard.
    pub fn discard_pending_claude(&self, session_id: &str) -> bool {
        self.pending_claude_sessions.remove(session_id).is_some()
    }

    /// Peek at a pending Claude session's cwd without removing it.
    pub fn peek_pending_claude_cwd(&self, session_id: &str) -> Option<String> {
        self.pending_claude_sessions
            .get(session_id)
            .map(|entry| entry.cwd.clone())
    }

    /// Expire pending Claude sessions older than `ttl`.
    pub fn expire_pending_claude(&self, ttl: Duration) {
        let cutoff = Instant::now() - ttl;
        self.pending_claude_sessions
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

// Note: No Default impl - requires persist_tx

#[cfg(test)]
mod tests {
    use super::SessionRegistry;
    use crate::support::test_support::ensure_server_test_data_dir;
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
}
