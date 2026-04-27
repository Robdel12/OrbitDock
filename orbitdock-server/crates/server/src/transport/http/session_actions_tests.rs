use super::*;
use crate::{
  domain::sessions::session::SessionHandle,
  infrastructure::persistence::{flush_batch_for_test, PersistCommand, SessionCreateParams},
  transport::http::test_support::new_persist_test_state,
};
use axum::{extract::Path, extract::State, http::StatusCode, Json};
use orbitdock_protocol::{Provider, SessionControlMode};
use tokio::sync::mpsc;

use super::common::{SessionShellCommandRequest, StopTargetRequest};

fn persist_codex_session(
  db_path: &std::path::PathBuf,
  session_id: &str,
  control_mode: SessionControlMode,
) {
  flush_batch_for_test(
    db_path,
    vec![PersistCommand::SessionCreate(Box::new(
      SessionCreateParams {
        id: session_id.to_string(),
        provider: Provider::Codex,
        control_mode,
        project_path: "/tmp/orbitdock-controls-test".to_string(),
        project_name: Some("orbitdock-controls-test".to_string()),
        branch: Some("main".to_string()),
        model: Some("gpt-5".to_string()),
        approval_policy: None,
        sandbox_mode: None,
        permission_mode: None,
        collaboration_mode: None,
        multi_agent: None,
        personality: None,
        service_tier: None,
        developer_instructions: None,
        codex_config_mode: None,
        codex_config_profile: None,
        codex_model_provider: None,
        codex_config_source: None,
        codex_config_overrides_json: None,
        forked_from_session_id: None,
        mission_id: None,
        issue_identifier: None,
        allow_bypass_permissions: false,
        worktree_id: None,
      },
    ))],
  )
  .expect("persist codex session fixture");
}

fn persist_claude_session(db_path: &std::path::PathBuf, session_id: &str) {
  flush_batch_for_test(
    db_path,
    vec![PersistCommand::ClaudeSessionUpsert {
      id: session_id.to_string(),
      project_path: "/tmp/orbitdock-controls-test".to_string(),
      project_name: Some("orbitdock-controls-test".to_string()),
      branch: Some("main".to_string()),
      model: Some("claude-opus-4-1".to_string()),
      context_label: None,
      transcript_path: Some("/tmp/orbitdock-controls-test/transcript.jsonl".to_string()),
      source: Some("hook".to_string()),
      agent_type: None,
      permission_mode: Some("acceptEdits".to_string()),
      terminal_session_id: None,
      terminal_app: None,
      forked_from_session_id: None,
      repository_root: Some("/tmp/orbitdock-controls-test".to_string()),
      is_worktree: false,
      git_sha: Some("abc123".to_string()),
    }],
  )
  .expect("persist claude session fixture");
}

#[tokio::test]
async fn controls_endpoint_reports_normalized_capabilities_for_codex() {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let session_id = orbitdock_protocol::new_session_id();
  persist_codex_session(&db_path, &session_id, SessionControlMode::Direct);
  state.add_session(SessionHandle::new(
    session_id.clone(),
    Provider::Codex,
    "/tmp/orbitdock-controls-test".to_string(),
  ));
  let (action_tx, _action_rx) = mpsc::channel(4);
  state.set_codex_action_tx(&session_id, action_tx);

  let Json(response) = get_session_controls(Path(session_id), State(state))
    .await
    .expect("controls endpoint should succeed");

  assert_eq!(response.provider, Provider::Codex);
  assert!(response.controls.shell_command.supported);
  assert!(!response.controls.shell_command.available);
  assert!(response.controls.stop_active_turn.supported);
  assert!(!response.controls.stop_active_turn.available);
  assert!(response.controls.compact_context.supported);
  assert!(!response.controls.compact_context.available);
  assert!(response.controls.undo_last_turn.supported);
  assert!(!response.controls.undo_last_turn.available);
  assert!(response.controls.rollback_turns.supported);
  assert!(!response.controls.rollback_turns.available);
  assert!(!response.controls.stop_target.supported);
  assert!(!response.controls.rewind_to_message.supported);
}

#[tokio::test]
async fn stop_target_returns_unsupported_for_codex_sessions() {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let session_id = orbitdock_protocol::new_session_id();
  persist_codex_session(&db_path, &session_id, SessionControlMode::Direct);
  state.add_session(SessionHandle::new(
    session_id.clone(),
    Provider::Codex,
    "/tmp/orbitdock-controls-test".to_string(),
  ));
  let (action_tx, _action_rx) = mpsc::channel(4);
  state.set_codex_action_tx(&session_id, action_tx);

  let response = stop_target(
    Path(session_id),
    State(state),
    Json(StopTargetRequest {
      target_id: "task-123".to_string(),
    }),
  )
  .await;

  match response {
    Ok(_) => panic!("expected stop_target to fail for codex"),
    Err((status, body)) => {
      assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
      assert_eq!(body.code, "unsupported_control");
    }
  }
}

#[tokio::test]
async fn controls_endpoint_reports_targeted_controls_for_claude() {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let session_id = orbitdock_protocol::new_session_id();
  persist_claude_session(&db_path, &session_id);
  state.add_session(SessionHandle::new(
    session_id.clone(),
    Provider::Claude,
    "/tmp/orbitdock-controls-test".to_string(),
  ));
  let (action_tx, _action_rx) = mpsc::channel(4);
  state.set_claude_action_tx(&session_id, action_tx);

  let Json(response) = get_session_controls(Path(session_id), State(state))
    .await
    .expect("controls endpoint should succeed");

  assert_eq!(response.provider, Provider::Claude);
  assert!(response.controls.stop_target.supported);
  assert_eq!(response.controls.stop_target.target_kind, Some("task"));
  assert!(response.controls.rewind_to_message.supported);
  assert_eq!(
    response.controls.rewind_to_message.target_kind,
    Some("user_message")
  );
  assert!(!response.controls.shell_command.supported);
}

#[tokio::test]
async fn session_shell_command_returns_unsupported_for_claude_sessions() {
  let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
  let session_id = orbitdock_protocol::new_session_id();
  persist_claude_session(&db_path, &session_id);
  state.add_session(SessionHandle::new(
    session_id.clone(),
    Provider::Claude,
    "/tmp/orbitdock-controls-test".to_string(),
  ));
  let (action_tx, _action_rx) = mpsc::channel(4);
  state.set_claude_action_tx(&session_id, action_tx);

  let response = post_session_shell_command(
    Path(session_id),
    State(state),
    Json(SessionShellCommandRequest {
      command: "git status --short".to_string(),
    }),
  )
  .await;

  match response {
    Ok(_) => panic!("expected session shell command to fail for claude"),
    Err((status, body)) => {
      assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
      assert_eq!(body.code, "unsupported_session_shell");
    }
  }
}
