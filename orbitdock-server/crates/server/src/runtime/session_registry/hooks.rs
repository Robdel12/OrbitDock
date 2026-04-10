use std::time::{Duration, Instant};

use orbitdock_protocol::Provider;

use super::{PendingHookSession, SessionRegistry};

impl SessionRegistry {
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
}
