use dashmap::DashMap;
use std::collections::HashSet;
use tokio::sync::mpsc;

use crate::connectors::claude_session::ClaudeAction;
use crate::connectors::codex_session::CodexAction;

pub(crate) struct ConnectorRegistry {
  codex_actions: DashMap<String, mpsc::Sender<CodexAction>>,
  claude_actions: DashMap<String, mpsc::Sender<ClaudeAction>>,
  codex_threads: DashMap<String, String>,
  claude_threads: DashMap<String, String>,
}

impl ConnectorRegistry {
  pub(crate) fn new() -> Self {
    Self {
      codex_actions: DashMap::new(),
      claude_actions: DashMap::new(),
      codex_threads: DashMap::new(),
      claude_threads: DashMap::new(),
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

  pub(crate) fn register_codex_thread(&self, session_id: &str, thread_id: &str) {
    self
      .codex_threads
      .insert(thread_id.to_string(), session_id.to_string());
  }

  pub(crate) fn resolve_codex_thread(&self, thread_id: &str) -> Option<String> {
    self.codex_threads.get(thread_id).map(|entry| entry.clone())
  }

  pub(crate) fn register_claude_thread(&self, session_id: &str, sdk_session_id: &str) {
    self
      .claude_threads
      .insert(sdk_session_id.to_string(), session_id.to_string());
  }

  pub(crate) fn remove_session_threads(&self, session_id: &str) {
    self
      .codex_threads
      .retain(|_, mapped_session_id| mapped_session_id != session_id);
    self
      .claude_threads
      .retain(|_, mapped_session_id| mapped_session_id != session_id);
  }

  pub(crate) fn resolve_claude_thread(&self, sdk_session_id: &str) -> Option<String> {
    self
      .claude_threads
      .get(sdk_session_id)
      .map(|entry| entry.clone())
  }

  pub(crate) fn registered_claude_session_ids(&self) -> HashSet<String> {
    self
      .claude_threads
      .iter()
      .map(|entry| entry.value().clone())
      .collect()
  }

  pub(crate) fn registered_codex_session_ids(&self) -> HashSet<String> {
    self
      .codex_threads
      .iter()
      .map(|entry| entry.value().clone())
      .collect()
  }

  pub(crate) fn codex_thread_for_session(&self, session_id: &str) -> Option<String> {
    self
      .codex_threads
      .iter()
      .find(|entry| entry.value() == session_id)
      .map(|entry| entry.key().clone())
  }

  pub(crate) fn claude_sdk_id_for_session(&self, session_id: &str) -> Option<String> {
    self
      .claude_threads
      .iter()
      .find(|entry| entry.value() == session_id)
      .map(|entry| entry.key().clone())
  }
}
