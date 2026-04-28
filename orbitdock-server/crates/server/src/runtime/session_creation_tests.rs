use super::{
  prepare_direct_session, DirectSessionCreationInputs, DirectSessionRequest,
  PreparedPersistedDirectSession, SessionConfig,
};
use orbitdock_protocol::{ClaudeIntegrationMode, CodexIntegrationMode, Provider};
use std::time::Duration;
use tokio::sync::mpsc;

use crate::connectors::codex_session::CodexAction;
use crate::domain::sessions::session::SessionHandle;
use crate::runtime::session_runtime_helpers::{
  verify_direct_runtime_ready_snapshot, verify_direct_runtime_ready_with_startup_grace,
};
use crate::support::test_support::new_test_session_registry;

#[test]
fn prepare_direct_session_sets_codex_direct_state_and_config() {
  let prepared = prepare_direct_session(DirectSessionCreationInputs {
    id: "session-1".into(),
    provider: Provider::Codex,
    cwd: "/tmp/project".into(),
    git_branch: Some("main".into()),
    config: SessionConfig {
      model: Some("gpt-5".into()),
      approval_policy: Some("on-request".into()),
      sandbox_mode: Some("workspace-write".into()),
      collaboration_mode: Some("workers".into()),
      multi_agent: Some(true),
      personality: Some("mentor".into()),
      service_tier: Some("priority".into()),
      developer_instructions: Some("Stay focused".into()),
      effort: Some("high".into()),
      ..Default::default()
    },
    mission_id: None,
    issue_identifier: None,
    allow_bypass_permissions: false,
  });

  assert_eq!(prepared.project_name.as_deref(), Some("project"));
  assert_eq!(
    prepared.summary.codex_integration_mode,
    Some(CodexIntegrationMode::Direct)
  );
  let snapshot = prepared.handle.retained_state();
  assert_eq!(snapshot.model.as_deref(), Some("gpt-5"));
  assert_eq!(snapshot.effort.as_deref(), Some("high"));
  assert_eq!(snapshot.approval_policy.as_deref(), Some("on-request"));
  assert_eq!(snapshot.collaboration_mode.as_deref(), Some("workers"));
  assert_eq!(snapshot.multi_agent, Some(true));
  assert_eq!(snapshot.personality.as_deref(), Some("mentor"));
  assert_eq!(snapshot.service_tier.as_deref(), Some("priority"));
  assert_eq!(
    snapshot.developer_instructions.as_deref(),
    Some("Stay focused")
  );
}

#[test]
fn prepare_direct_session_sets_claude_direct_mode_without_codex_config() {
  let prepared = prepare_direct_session(DirectSessionCreationInputs {
    id: "session-2".into(),
    provider: Provider::Claude,
    cwd: "/tmp/claude".into(),
    git_branch: None,
    config: SessionConfig {
      model: Some("claude-opus".into()),
      approval_policy: Some("ignored".into()),
      sandbox_mode: Some("ignored".into()),
      collaboration_mode: Some("ignored".into()),
      multi_agent: Some(true),
      personality: Some("ignored".into()),
      service_tier: Some("ignored".into()),
      developer_instructions: Some("ignored".into()),
      effort: Some("medium".into()),
      ..Default::default()
    },
    mission_id: None,
    issue_identifier: None,
    allow_bypass_permissions: false,
  });

  assert_eq!(
    prepared.summary.claude_integration_mode,
    Some(ClaudeIntegrationMode::Direct)
  );
  let snapshot = prepared.handle.retained_state();
  assert_eq!(snapshot.model.as_deref(), Some("claude-opus"));
  assert_eq!(snapshot.approval_policy, None);
}

#[test]
fn prepared_persisted_direct_session_keeps_transport_relevant_state() {
  let request = DirectSessionRequest {
    provider: Provider::Claude,
    cwd: "/tmp/claude".into(),
    model: Some("claude-opus".into()),
    approval_policy: None,
    sandbox_mode: None,
    sandbox_policy_details: None,
    permission_mode: Some("plan".into()),
    allowed_tools: vec!["Read".into()],
    disallowed_tools: vec!["Edit".into()],
    effort: Some("medium".into()),
    collaboration_mode: Some("workers".into()),
    multi_agent: Some(true),
    personality: Some("mentor".into()),
    service_tier: Some("priority".into()),
    developer_instructions: Some("Stay focused".into()),
    mission_id: None,
    issue_identifier: None,
    worktree_id: None,
    dynamic_tools: Vec::new(),
    allow_bypass_permissions: false,
    claude_extra_env: Vec::new(),
    codex_config_mode: None,
    codex_config_profile: None,
    codex_model_provider: None,
    codex_config_source: None,
    codex_config_overrides: None,
  };
  let prepared = prepare_direct_session(DirectSessionCreationInputs {
    id: "session-3".into(),
    provider: request.provider,
    cwd: request.cwd.clone(),
    git_branch: None,
    config: SessionConfig {
      model: request.model.clone(),
      approval_policy: request.approval_policy.clone(),
      sandbox_mode: request.sandbox_mode.clone(),
      collaboration_mode: request.collaboration_mode.clone(),
      multi_agent: request.multi_agent,
      personality: request.personality.clone(),
      service_tier: request.service_tier.clone(),
      developer_instructions: request.developer_instructions.clone(),
      effort: request.effort.clone(),
      ..Default::default()
    },
    mission_id: None,
    issue_identifier: None,
    allow_bypass_permissions: false,
  });

  let persisted = PreparedPersistedDirectSession {
    id: "session-3".into(),
    request,
    handle: prepared.handle,
    summary: prepared.summary,
  };

  assert_eq!(persisted.summary.id, "session-3");
  assert_eq!(persisted.handle.retained_state().id, "session-3");
  assert_eq!(persisted.request.permission_mode.as_deref(), Some("plan"));
  assert_eq!(persisted.request.allowed_tools, vec!["Read"]);
  assert_eq!(
    persisted.request.collaboration_mode.as_deref(),
    Some("workers")
  );
  assert_eq!(persisted.request.multi_agent, Some(true));
}

#[tokio::test]
async fn verify_direct_runtime_ready_requires_registered_actor() {
  let state = new_test_session_registry(true);
  let error = verify_direct_runtime_ready_snapshot(&state, "missing-session", Provider::Codex)
    .expect_err("missing actor should fail readiness");
  assert!(error.contains("was not registered"));
}

#[tokio::test]
async fn verify_direct_runtime_ready_requires_action_channel() {
  let state = new_test_session_registry(true);
  let session_id = "readiness-no-action";
  let mut handle = SessionHandle::new(
    session_id.to_string(),
    Provider::Codex,
    "/tmp/readiness-no-action".to_string(),
  );
  handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
  state.add_session(handle);

  let error = verify_direct_runtime_ready_snapshot(&state, session_id, Provider::Codex)
    .expect_err("missing action channel should fail readiness");
  assert!(error.contains("has no action channel"));
}

#[tokio::test]
async fn verify_direct_runtime_ready_accepts_active_direct_open_with_action_channel() {
  let state = new_test_session_registry(true);
  let session_id = "readiness-ok";
  let mut handle = SessionHandle::new(
    session_id.to_string(),
    Provider::Codex,
    "/tmp/readiness-ok".to_string(),
  );
  handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
  state.add_session(handle);
  let (tx, _rx) = mpsc::channel::<CodexAction>(1);
  state.set_codex_action_tx(session_id, tx);

  verify_direct_runtime_ready_snapshot(&state, session_id, Provider::Codex)
    .expect("active direct open session should satisfy readiness");
}

#[tokio::test]
async fn verify_direct_runtime_ready_with_startup_grace_rejects_early_channel_close() {
  let state = new_test_session_registry(true);
  let session_id = "readiness-early-close";
  let mut handle = SessionHandle::new(
    session_id.to_string(),
    Provider::Codex,
    "/tmp/readiness-early-close".to_string(),
  );
  handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
  state.add_session(handle);
  let (tx, rx) = mpsc::channel::<CodexAction>(1);
  state.set_codex_action_tx(session_id, tx);
  tokio::spawn(async move {
    // Let the readiness probe reach the grace-period wait before the channel closes.
    tokio::task::yield_now().await;
    tokio::task::yield_now().await;
    drop(rx);
  });

  let error = verify_direct_runtime_ready_with_startup_grace(
    &state,
    session_id,
    Provider::Codex,
    Duration::from_millis(100),
  )
  .await
  .expect_err("early channel closure should fail readiness");
  assert!(error.contains("closed during startup grace period"));
}
