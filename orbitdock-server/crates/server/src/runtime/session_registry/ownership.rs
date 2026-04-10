use rusqlite::{params, Connection, OptionalExtension};
use tracing::warn;

use orbitdock_protocol::Provider;

use super::SessionRegistry;

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

    if let Err(error) = conn.busy_timeout(std::time::Duration::from_secs(5)) {
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

  pub(crate) fn resolve_runtime_owner_session_id(&self, session_id: &str) -> Option<String> {
    if orbitdock_protocol::is_orbitdock_id(session_id) {
      return None;
    }

    self
      .resolve_claude_thread(session_id)
      .or_else(|| self.resolve_codex_thread(session_id))
  }

  fn is_active_direct_owner_session(&self, owner_session_id: &str, provider: Provider) -> bool {
    let Some(actor) = self.sessions.get(owner_session_id) else {
      return false;
    };
    let snapshot = actor.snapshot();
    snapshot.provider == provider
      && snapshot.control_mode == orbitdock_protocol::SessionControlMode::Direct
      && snapshot.status == orbitdock_protocol::SessionStatus::Active
      && snapshot.lifecycle_state != orbitdock_protocol::SessionLifecycleState::Ended
  }

  pub(crate) fn purge_runtime_ownership_for_session(&self, session_id: &str) {
    let claude_keys: Vec<String> = self
      .claude_runtime_owners
      .iter()
      .filter(|entry| entry.value() == session_id)
      .map(|entry| entry.key().clone())
      .collect();
    for key in claude_keys {
      self.claude_runtime_owners.remove(&key);
    }

    let codex_keys: Vec<String> = self
      .codex_runtime_owners
      .iter()
      .filter(|entry| entry.value() == session_id)
      .map(|entry| entry.key().clone())
      .collect();
    for key in codex_keys {
      self.codex_runtime_owners.remove(&key);
    }
  }

  /// Resolve a Claude SDK session ID to the owning OrbitDock session ID
  #[allow(dead_code)]
  pub fn resolve_claude_thread(&self, sdk_session_id: &str) -> Option<String> {
    if let Some(runtime_owner) = self
      .claude_runtime_owners
      .get(sdk_session_id)
      .map(|entry| entry.value().clone())
    {
      if self.is_active_direct_owner_session(&runtime_owner, Provider::Claude) {
        return Some(runtime_owner);
      }
      self.claude_runtime_owners.remove(sdk_session_id);
    }

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
    if let Some(runtime_owner) = self
      .codex_runtime_owners
      .get(thread_id)
      .map(|entry| entry.value().clone())
    {
      if self.is_active_direct_owner_session(&runtime_owner, Provider::Codex) {
        return Some(runtime_owner);
      }
      self.codex_runtime_owners.remove(thread_id);
    }

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

  pub fn register_claude_runtime_owner(&self, sdk_session_id: &str, owner_session_id: &str) {
    self
      .claude_runtime_owners
      .insert(sdk_session_id.to_string(), owner_session_id.to_string());
  }

  pub fn unregister_claude_runtime_owner(&self, sdk_session_id: &str) {
    self.claude_runtime_owners.remove(sdk_session_id);
  }

  pub fn register_codex_runtime_owner(&self, thread_id: &str, owner_session_id: &str) {
    self
      .codex_runtime_owners
      .insert(thread_id.to_string(), owner_session_id.to_string());
  }

  pub fn unregister_codex_runtime_owner(&self, thread_id: &str) {
    self.codex_runtime_owners.remove(thread_id);
  }
}
