use dashmap::DashMap;
use tokio::sync::mpsc;

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;

pub(crate) struct ConnectorRegistry {
  codex_actions: DashMap<String, mpsc::Sender<CodexAction>>,
  claude_actions: DashMap<String, mpsc::Sender<ClaudeAction>>,
}

impl ConnectorRegistry {
  pub(crate) fn new() -> Self {
    Self {
      codex_actions: DashMap::new(),
      claude_actions: DashMap::new(),
    }
  }

  pub(crate) fn set_codex_action_tx(&self, session_id: &str, tx: mpsc::Sender<CodexAction>) {
    self.codex_actions.insert(session_id.to_string(), tx);
  }

  pub(crate) fn get_codex_action_tx(&self, session_id: &str) -> Option<mpsc::Sender<CodexAction>> {
    self
      .codex_actions
      .get(session_id)
      .map(|entry| entry.clone())
  }

  pub(crate) fn set_claude_action_tx(&self, session_id: &str, tx: mpsc::Sender<ClaudeAction>) {
    self.claude_actions.insert(session_id.to_string(), tx);
  }

  pub(crate) fn get_claude_action_tx(
    &self,
    session_id: &str,
  ) -> Option<mpsc::Sender<ClaudeAction>> {
    self
      .claude_actions
      .get(session_id)
      .map(|entry| entry.clone())
  }

  pub(crate) fn remove_action_txs(&self, session_id: &str) {
    self.codex_actions.remove(session_id);
    self.claude_actions.remove(session_id);
  }

  pub(crate) fn remove_codex_action_tx(&self, session_id: &str) {
    self.codex_actions.remove(session_id);
  }

  pub(crate) fn remove_claude_action_tx(&self, session_id: &str) {
    self.claude_actions.remove(session_id);
  }
}
