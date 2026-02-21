//! Application state

use dashmap::DashMap;
use orbitdock_protocol::SessionSummary;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{broadcast, mpsc};

use crate::ai_naming::NamingGuard;
use crate::claude_session::ClaudeAction;
use crate::codex_auth::CodexAuthService;
use crate::codex_session::CodexAction;
use crate::hook_handler::PendingClaudeSession;
use crate::persistence::PersistCommand;
use crate::session::SessionHandle;
use crate::session_actor::SessionActorHandle;

/// Shared application state backed by lock-free concurrent maps.
/// All methods take `&self` — no external Mutex needed.
pub struct SessionRegistry {
    /// Active sessions stored as actor handles
    sessions: DashMap<String, SessionActorHandle>,

    /// Action channels for Codex sessions
    codex_actions: DashMap<String, mpsc::Sender<CodexAction>>,
    /// Action channels for Claude direct sessions
    claude_actions: DashMap<String, mpsc::Sender<ClaudeAction>>,
    /// Map codex-core thread_id -> session_id for direct sessions
    codex_threads: DashMap<String, String>,
    /// Map Claude SDK session_id -> OrbitDock session_id for direct sessions
    claude_threads: DashMap<String, String>,

    /// Broadcast channel for session list updates
    list_tx: broadcast::Sender<orbitdock_protocol::ServerMessage>,

    /// Persistence channel
    persist_tx: mpsc::Sender<PersistCommand>,

    /// Global Codex account auth coordinator (not session-specific)
    codex_auth: Arc<CodexAuthService>,

    /// Dedup guard for AI session naming
    naming_guard: Arc<NamingGuard>,

    /// Pending Claude sessions awaiting first actionable hook before materialization.
    /// Keyed by Claude SDK session_id from SessionStart.
    pending_claude_sessions: DashMap<String, PendingClaudeSession>,
}

impl SessionRegistry {
    pub fn new(persist_tx: mpsc::Sender<PersistCommand>) -> Self {
        let (list_tx, _) = broadcast::channel(64);
        let codex_auth = Arc::new(CodexAuthService::new(list_tx.clone()));
        Self {
            sessions: DashMap::new(),
            codex_actions: DashMap::new(),
            claude_actions: DashMap::new(),
            codex_threads: DashMap::new(),
            claude_threads: DashMap::new(),
            list_tx,
            persist_tx,
            codex_auth,
            naming_guard: Arc::new(NamingGuard::new()),
            pending_claude_sessions: DashMap::new(),
        }
    }

    /// Get persistence sender
    pub fn persist(&self) -> &mpsc::Sender<PersistCommand> {
        &self.persist_tx
    }

    pub fn codex_auth(&self) -> Arc<CodexAuthService> {
        self.codex_auth.clone()
    }

    /// Get naming guard for AI session naming dedup
    pub fn naming_guard(&self) -> &Arc<NamingGuard> {
        &self.naming_guard
    }

    /// Store a Codex action sender
    pub fn set_codex_action_tx(&self, session_id: &str, tx: mpsc::Sender<CodexAction>) {
        self.codex_actions.insert(session_id.to_string(), tx);
    }

    /// Get a Codex action sender (cloned — DashMap refs can't outlive the lookup)
    pub fn get_codex_action_tx(&self, session_id: &str) -> Option<mpsc::Sender<CodexAction>> {
        self.codex_actions.get(session_id).map(|r| r.clone())
    }

    /// Store a Claude action sender
    pub fn set_claude_action_tx(&self, session_id: &str, tx: mpsc::Sender<ClaudeAction>) {
        self.claude_actions.insert(session_id.to_string(), tx);
    }

    /// Get a Claude action sender (cloned)
    pub fn get_claude_action_tx(&self, session_id: &str) -> Option<mpsc::Sender<ClaudeAction>> {
        self.claude_actions.get(session_id).map(|r| r.clone())
    }

    /// Get all session summaries (lock-free via snapshots)
    pub fn get_session_summaries(&self) -> Vec<SessionSummary> {
        self.sessions
            .iter()
            .map(|entry| {
                let actor = entry.value();
                let snap = actor.snapshot();
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
                    has_pending_approval: false,
                    codex_integration_mode: snap.codex_integration_mode,
                    claude_integration_mode: snap.claude_integration_mode,
                    approval_policy: snap.approval_policy.clone(),
                    sandbox_mode: snap.sandbox_mode.clone(),
                    started_at: snap.started_at.clone(),
                    last_activity_at: snap.last_activity_at.clone(),
                    git_branch: snap.git_branch.clone(),
                    git_sha: snap.git_sha.clone(),
                    current_cwd: snap.current_cwd.clone(),
                    first_prompt: snap.first_prompt.clone(),
                    last_message: snap.last_message.clone(),
                    effort: snap.effort.clone(),
                }
            })
            .collect()
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
        self.codex_actions.remove(id);
        self.claude_actions.remove(id);
        self.codex_threads.retain(|_, session_id| session_id != id);
        self.claude_threads.retain(|_, session_id| session_id != id);
        self.sessions.remove(id).map(|(_, v)| v)
    }

    /// Register codex-core thread ID for a direct session
    pub fn register_codex_thread(&self, session_id: &str, thread_id: &str) {
        self.codex_threads
            .insert(thread_id.to_string(), session_id.to_string());
    }

    /// Check whether thread ID is managed by a direct server session
    pub fn is_managed_codex_thread(&self, thread_id: &str) -> bool {
        self.codex_threads.contains_key(thread_id)
    }

    /// Register Claude SDK session ID for a direct session
    pub fn register_claude_thread(&self, session_id: &str, sdk_session_id: &str) {
        self.claude_threads
            .insert(sdk_session_id.to_string(), session_id.to_string());
    }

    /// Check whether a Claude SDK session ID is managed by a direct session
    pub fn is_managed_claude_thread(&self, sdk_session_id: &str) -> bool {
        self.claude_threads.contains_key(sdk_session_id)
    }

    /// Resolve a Claude SDK session ID to the owning OrbitDock session ID
    #[allow(dead_code)]
    pub fn resolve_claude_thread(&self, sdk_session_id: &str) -> Option<String> {
        self.claude_threads.get(sdk_session_id).map(|r| r.clone())
    }

    /// Find an active direct Claude session for a project that hasn't registered its SDK ID yet.
    /// Used by `ClaudeSessionStart` to eagerly claim the SDK ID before the `init` event arrives.
    pub fn find_unregistered_direct_claude_session(&self, project_path: &str) -> Option<String> {
        use orbitdock_protocol::{ClaudeIntegrationMode, Provider, SessionStatus};

        // Collect registered session IDs for quick lookup
        let registered: std::collections::HashSet<String> = self
            .claude_threads
            .iter()
            .map(|entry| entry.value().clone())
            .collect();

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
        self.codex_threads
            .iter()
            .find(|entry| entry.value() == session_id)
            .map(|entry| entry.key().clone())
    }

    /// Look up the Claude SDK session ID for a given session ID (reverse lookup)
    pub fn claude_sdk_id_for_session(&self, session_id: &str) -> Option<String> {
        self.claude_threads
            .iter()
            .find(|entry| entry.value() == session_id)
            .map(|entry| entry.key().clone())
    }

    /// Check if a session already has a live connector (action channel registered)
    pub fn has_codex_connector(&self, session_id: &str) -> bool {
        self.codex_actions.contains_key(session_id)
    }

    /// Check if a session already has a live Claude connector
    pub fn has_claude_connector(&self, session_id: &str) -> bool {
        self.claude_actions.contains_key(session_id)
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
    pub async fn list_recent_projects(&self) -> Vec<orbitdock_protocol::RecentProject> {
        use std::collections::HashMap;

        let mut project_map: HashMap<String, (u32, Option<String>)> = HashMap::new();
        for entry in self.sessions.iter() {
            let snap = entry.value().snapshot();
            let path = snap.project_path.clone();
            let last_activity = snap.last_activity_at.clone();

            let counter = project_map.entry(path).or_insert((0, None));
            counter.0 += 1;
            // Keep the most recent activity timestamp
            if let Some(ref activity) = last_activity {
                if counter
                    .1
                    .as_ref()
                    .map_or(true, |existing| activity > existing)
                {
                    counter.1 = last_activity;
                }
            }
        }

        let mut projects: Vec<orbitdock_protocol::RecentProject> = project_map
            .into_iter()
            .map(
                |(path, (session_count, last_active))| orbitdock_protocol::RecentProject {
                    path,
                    session_count,
                    last_active,
                },
            )
            .collect();

        // Sort by last_active descending (most recent first)
        projects.sort_by(|a, b| b.last_active.cmp(&a.last_active));
        projects
    }
}

// Note: No Default impl - requires persist_tx
