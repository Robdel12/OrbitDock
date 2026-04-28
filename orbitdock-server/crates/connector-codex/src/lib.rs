//! Codex connector
//!
//! OrbitDock uses an embedded Codex app-server host as the first-class session
//! runtime and keeps direct Codex crates only for setup and other surfaces the
//! app-server does not own.

pub mod app_server;
pub mod auth;
mod config;
mod policy_bridge;
mod row_mapping;
mod runtime;
pub mod session;
mod session_ops;
#[cfg(test)]
mod tests;
mod timeline;
mod workers;

/// Re-export codex-arg0 init for server startup.
/// Must be called before the tokio runtime starts.
pub use codex_arg0::arg0_dispatch;

use codex_app_server_protocol::{
  ApprovalsReviewer as AppServerApprovalsReviewer, AskForApproval as AppServerAskForApproval,
  RequestId, SandboxPolicy as AppServerSandboxPolicy,
};
use codex_protocol::config_types::{
  CollaborationMode as AppServerCollaborationMode, Personality as AppServerPersonality,
  ReasoningSummary, ServiceTier as AppServerServiceTier,
};
use codex_protocol::openai_models::ReasoningEffort;
use orbitdock_connector_core::ConnectorOutput;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::mpsc;

pub use self::config::{
  config_loader_sandbox_mode, discover_models, discover_models_for_context,
  requested_sandbox_policy_details,
};

pub use orbitdock_protocol::SteerOutcome;

#[derive(Debug, Clone, Default)]
pub(crate) struct AppServerPendingTurnContext {
  pub(crate) cwd: Option<PathBuf>,
  pub(crate) approval_policy: Option<AppServerAskForApproval>,
  pub(crate) approvals_reviewer: Option<AppServerApprovalsReviewer>,
  pub(crate) sandbox_policy: Option<AppServerSandboxPolicy>,
  pub(crate) model: Option<String>,
  pub(crate) service_tier: Option<Option<AppServerServiceTier>>,
  pub(crate) effort: Option<ReasoningEffort>,
  pub(crate) summary: Option<ReasoningSummary>,
  pub(crate) personality: Option<AppServerPersonality>,
  pub(crate) collaboration_mode: Option<AppServerCollaborationMode>,
}

/// Codex connector using the embedded Codex app-server as the first-class session runtime.
pub struct CodexConnector {
  app_server: Option<Arc<app_server::CodexAppServer>>,
  pending_app_server_requests: Arc<tokio::sync::Mutex<HashMap<String, RequestId>>>,
  pending_turn_context: Arc<tokio::sync::Mutex<AppServerPendingTurnContext>>,
  active_turn_id: Arc<tokio::sync::Mutex<Option<String>>>,
  codex_home: PathBuf,
  output_tx: mpsc::Sender<ConnectorOutput>,
  output_rx: Option<mpsc::Receiver<ConnectorOutput>>,
  thread_id: String,
  current_cwd: Arc<tokio::sync::Mutex<String>>,
  current_model: Arc<tokio::sync::Mutex<Option<String>>>,
  current_reasoning_effort: Arc<tokio::sync::Mutex<Option<ReasoningEffort>>>,
}

impl Clone for CodexConnector {
  fn clone(&self) -> Self {
    Self {
      app_server: self.app_server.clone(),
      pending_app_server_requests: Arc::clone(&self.pending_app_server_requests),
      pending_turn_context: Arc::clone(&self.pending_turn_context),
      active_turn_id: Arc::clone(&self.active_turn_id),
      codex_home: self.codex_home.clone(),
      output_tx: self.output_tx.clone(),
      output_rx: None,
      thread_id: self.thread_id.clone(),
      current_cwd: Arc::clone(&self.current_cwd),
      current_model: Arc::clone(&self.current_model),
      current_reasoning_effort: Arc::clone(&self.current_reasoning_effort),
    }
  }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CodexRuntimeOverrides {
  pub approvals_reviewer: Option<String>,
  pub collaboration_mode: Option<String>,
  pub multi_agent: Option<bool>,
  pub personality: Option<String>,
  pub service_tier: Option<String>,
  pub developer_instructions: Option<String>,
  pub effort: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CodexConfigOverrides {
  pub model_provider: Option<String>,
  pub config_profile: Option<String>,
}

pub struct UpdateConfigOptions<'a> {
  pub approval_policy: Option<&'a str>,
  pub approval_policy_details: Option<&'a orbitdock_protocol::CodexApprovalPolicy>,
  pub sandbox_mode: Option<&'a str>,
  pub sandbox_policy_details: Option<&'a orbitdock_protocol::CodexSandboxPolicy>,
  pub approvals_reviewer: Option<&'a str>,
  pub permission_mode: Option<&'a str>,
  pub collaboration_mode: Option<&'a str>,
  pub multi_agent: Option<bool>,
  pub personality: Option<&'a str>,
  pub service_tier: Option<&'a str>,
  pub developer_instructions: Option<&'a str>,
  pub model: Option<&'a str>,
  pub effort: Option<&'a str>,
}

impl CodexConnector {
  fn app_server_session(
    &self,
  ) -> Result<Arc<app_server::CodexAppServer>, orbitdock_connector_core::ConnectorError> {
    self.app_server.clone().ok_or_else(|| {
      orbitdock_connector_core::ConnectorError::ProviderError(
        "Codex app-server session is not available".to_string(),
      )
    })
  }

  /// Get the typed output receiver (can only be called once).
  pub fn take_output_rx(&mut self) -> Option<mpsc::Receiver<ConnectorOutput>> {
    self.output_rx.take()
  }

  /// Get the Codex app-server thread ID.
  pub fn thread_id(&self) -> &str {
    &self.thread_id
  }

  /// Get the codex home directory path
  pub fn codex_home(&self) -> &std::path::Path {
    &self.codex_home
  }
}
