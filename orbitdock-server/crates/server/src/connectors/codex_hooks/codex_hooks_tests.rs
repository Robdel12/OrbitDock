use std::sync::{Arc, Once};

use orbitdock_protocol::{
  ClientMessage, CodexIntegrationMode, Provider, SessionControlMode, WorkStatus,
};
use rusqlite::Connection;
use serde_json::json;
use tokio::sync::mpsc;

use super::handle_hook_message;
use crate::domain::sessions::session::SessionHandle;
use crate::infrastructure::migration_runner;
use crate::infrastructure::paths;
use crate::infrastructure::persistence::PersistCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::support::test_support::{ensure_server_test_data_dir, test_env_lock};

static INIT_TEST_DB: Once = Once::new();

fn collect_persist_commands(rx: &mut mpsc::Receiver<PersistCommand>) -> Vec<PersistCommand> {
  let mut commands = Vec::new();
  while let Ok(command) = rx.try_recv() {
    commands.push(command);
  }
  commands
}

fn prepare_test_db() {
  INIT_TEST_DB.call_once(|| {
    let mut conn = Connection::open(paths::db_path()).expect("open test db");
    migration_runner::run_migrations(&mut conn).expect("run test migrations");
  });
}

#[tokio::test]
async fn user_prompt_materializes_passive_codex_session_and_persists_metadata() {
  let _guard = test_env_lock().lock().await;
  ensure_server_test_data_dir();
  prepare_test_db();
  let (persist_tx, mut persist_rx) = mpsc::channel(64);
  let state = Arc::new(SessionRegistry::new_with_primary(persist_tx, true));

  handle_hook_message(
    ClientMessage::CodexSessionStart {
      session_id: "codex-thread-passive".to_string(),
      cwd: "/tmp/codex-passive".to_string(),
      transcript_path: Some("/tmp/codex-passive/transcript.jsonl".to_string()),
      model: Some("gpt-5-codex".to_string()),
      source: Some("startup".to_string()),
    },
    &state,
  )
  .await;

  handle_hook_message(
    ClientMessage::CodexUserPromptSubmit {
      session_id: "codex-thread-passive".to_string(),
      cwd: "/tmp/codex-passive".to_string(),
      transcript_path: Some("/tmp/codex-passive/transcript.jsonl".to_string()),
      model: Some("gpt-5-codex".to_string()),
      turn_id: "turn-1".to_string(),
      prompt: "Ship the fix".to_string(),
    },
    &state,
  )
  .await;

  tokio::task::yield_now().await;
  tokio::task::yield_now().await;

  let actor = state
    .get_session("codex-thread-passive")
    .expect("passive session should materialize");
  let snapshot = actor.snapshot();
  assert_eq!(snapshot.provider, Provider::Codex);
  assert_eq!(snapshot.control_mode, SessionControlMode::Passive);
  assert_eq!(
    snapshot.codex_integration_mode,
    Some(CodexIntegrationMode::Passive)
  );
  assert_eq!(
    snapshot.transcript_path.as_deref(),
    Some("/tmp/codex-passive/transcript.jsonl")
  );
  assert_eq!(snapshot.model.as_deref(), Some("gpt-5-codex"));
  assert_eq!(snapshot.work_status, WorkStatus::Working);

  let commands = collect_persist_commands(&mut persist_rx);
  assert!(commands.iter().any(|command| matches!(
    command,
    PersistCommand::ReactivateSession { id } if id == "codex-thread-passive"
  )));
  assert!(commands.iter().any(|command| matches!(
    command,
    PersistCommand::SessionCreate(params)
      if params.id == "codex-thread-passive"
        && params.control_mode == SessionControlMode::Passive
  )));
  assert!(commands.iter().any(|command| matches!(
    command,
    PersistCommand::SetThreadId { session_id, thread_id }
      if session_id == "codex-thread-passive" && thread_id == "codex-thread-passive"
  )));
  assert!(commands.iter().any(|command| matches!(
    command,
    PersistCommand::SetTranscriptPath { session_id, transcript_path }
      if session_id == "codex-thread-passive"
        && transcript_path.as_deref() == Some("/tmp/codex-passive/transcript.jsonl")
  )));
  assert!(commands.iter().any(|command| matches!(
    command,
    PersistCommand::ModelUpdate { session_id, model }
      if session_id == "codex-thread-passive" && model == "gpt-5-codex"
  )));
  assert!(commands.iter().any(|command| matches!(
    command,
    PersistCommand::CodexPromptIncrement { id, first_prompt }
      if id == "codex-thread-passive" && first_prompt.as_deref() == Some("Ship the fix")
  )));
}

#[tokio::test]
async fn direct_codex_hook_traffic_updates_owner_without_materializing_shadow() {
  let _guard = test_env_lock().lock().await;
  ensure_server_test_data_dir();
  prepare_test_db();
  let (persist_tx, mut persist_rx) = mpsc::channel(64);
  let state = Arc::new(SessionRegistry::new_with_primary(persist_tx.clone(), true));

  let mut handle = SessionHandle::new(
    "od-direct-codex".to_string(),
    Provider::Codex,
    "/tmp/codex-direct".to_string(),
  );
  handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
  state.add_session(handle);

  let _ = persist_tx
    .send(PersistCommand::SessionCreate(Box::new(
      crate::infrastructure::persistence::SessionCreateParams {
        id: "od-direct-codex".to_string(),
        provider: Provider::Codex,
        control_mode: SessionControlMode::Direct,
        project_path: "/tmp/codex-direct".to_string(),
        project_name: None,
        branch: None,
        model: None,
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
    )))
    .await;
  let _ = persist_tx
    .send(PersistCommand::SetThreadId {
      session_id: "od-direct-codex".to_string(),
      thread_id: "codex-thread-direct".to_string(),
    })
    .await;
  crate::infrastructure::persistence::flush_batch_for_test(
    state.db_path(),
    vec![
      persist_rx.recv().await.unwrap(),
      persist_rx.recv().await.unwrap(),
    ],
  )
  .unwrap();

  handle_hook_message(
    ClientMessage::CodexUserPromptSubmit {
      session_id: "codex-thread-direct".to_string(),
      cwd: "/tmp/codex-direct".to_string(),
      transcript_path: Some("/tmp/codex-direct/transcript.jsonl".to_string()),
      model: Some("gpt-5-codex".to_string()),
      turn_id: "turn-1".to_string(),
      prompt: "Keep working".to_string(),
    },
    &state,
  )
  .await;

  tokio::task::yield_now().await;
  tokio::task::yield_now().await;

  assert!(!state
    .iter_sessions()
    .any(|entry| entry.key() == "codex-thread-direct"));
  let owner = state
    .get_session("od-direct-codex")
    .expect("direct owner should still exist");
  let snapshot = owner.snapshot();
  assert_eq!(
    snapshot.codex_integration_mode,
    Some(CodexIntegrationMode::Direct)
  );
  assert_eq!(
    snapshot.transcript_path.as_deref(),
    Some("/tmp/codex-direct/transcript.jsonl")
  );
  assert_eq!(snapshot.model.as_deref(), Some("gpt-5-codex"));

  let commands = collect_persist_commands(&mut persist_rx);
  assert!(!commands.iter().any(|command| matches!(
    command,
    PersistCommand::SessionCreate(params) if params.id == "codex-thread-direct"
  )));
  assert!(commands.iter().any(|command| matches!(
    command,
    PersistCommand::SetTranscriptPath { session_id, transcript_path }
      if session_id == "od-direct-codex"
        && transcript_path.as_deref() == Some("/tmp/codex-direct/transcript.jsonl")
  )));
  assert!(commands.iter().any(|command| matches!(
    command,
    PersistCommand::ModelUpdate { session_id, model }
      if session_id == "od-direct-codex" && model == "gpt-5-codex"
  )));
}

#[tokio::test]
async fn passive_pre_tool_use_sets_pending_attention_and_persists_it() {
  let _guard = test_env_lock().lock().await;
  ensure_server_test_data_dir();
  prepare_test_db();
  let (persist_tx, mut persist_rx) = mpsc::channel(64);
  let state = Arc::new(SessionRegistry::new_with_primary(persist_tx, true));

  handle_hook_message(
    ClientMessage::CodexToolEvent {
      session_id: "codex-thread-tool-passive".to_string(),
      cwd: "/tmp/codex-tool-passive".to_string(),
      transcript_path: Some("/tmp/codex-tool-passive/transcript.jsonl".to_string()),
      model: Some("gpt-5-codex".to_string()),
      hook_event_name: "PreToolUse".to_string(),
      turn_id: "turn-1".to_string(),
      tool_name: "Bash".to_string(),
      tool_use_id: Some("toolu_123".to_string()),
      tool_input: Some(json!({
        "command": "cargo test -p orbitdock-server",
        "question": "Run the focused server tests?"
      })),
      tool_response: None,
    },
    &state,
  )
  .await;

  tokio::task::yield_now().await;
  tokio::task::yield_now().await;

  let actor = state
    .get_session("codex-thread-tool-passive")
    .expect("tool session should materialize");
  let snapshot = actor.snapshot();
  assert_eq!(snapshot.provider, Provider::Codex);
  assert_eq!(snapshot.control_mode, SessionControlMode::Passive);
  assert_eq!(snapshot.work_status, WorkStatus::Question);
  assert_eq!(snapshot.pending_tool_name.as_deref(), Some("Bash"));
  assert_eq!(
    snapshot.pending_tool_input.as_deref(),
    Some("{\"command\":\"cargo test -p orbitdock-server\",\"question\":\"Run the focused server tests?\"}")
  );
  assert_eq!(
    snapshot.pending_question.as_deref(),
    Some("Run the focused server tests?")
  );

  let commands = collect_persist_commands(&mut persist_rx);
  assert!(commands.iter().any(|command| matches!(
    command,
    PersistCommand::SessionAttentionUpdate {
      session_id,
      attention_reason,
      last_tool,
      last_tool_at,
      pending_tool_name,
      pending_tool_input,
      pending_question,
    }
      if session_id == "codex-thread-tool-passive"
        && attention_reason.as_ref() == Some(&Some("awaitingQuestion".to_string()))
        && last_tool.as_ref() == Some(&Some("Bash".to_string()))
        && last_tool_at.as_ref().is_some_and(|value| value.is_some())
        && pending_tool_name.as_ref() == Some(&Some("Bash".to_string()))
        && pending_tool_input.as_ref()
          == Some(&Some("{\"command\":\"cargo test -p orbitdock-server\",\"question\":\"Run the focused server tests?\"}".to_string()))
        && pending_question.as_ref() == Some(&Some("Run the focused server tests?".to_string()))
  )));
}

#[tokio::test]
async fn passive_post_tool_use_clears_pending_attention_and_increments_tool_count() {
  let _guard = test_env_lock().lock().await;
  ensure_server_test_data_dir();
  prepare_test_db();
  let (persist_tx, mut persist_rx) = mpsc::channel(64);
  let state = Arc::new(SessionRegistry::new_with_primary(persist_tx, true));

  handle_hook_message(
    ClientMessage::CodexToolEvent {
      session_id: "codex-thread-tool-finish".to_string(),
      cwd: "/tmp/codex-tool-finish".to_string(),
      transcript_path: Some("/tmp/codex-tool-finish/transcript.jsonl".to_string()),
      model: Some("gpt-5-codex".to_string()),
      hook_event_name: "PreToolUse".to_string(),
      turn_id: "turn-1".to_string(),
      tool_name: "Bash".to_string(),
      tool_use_id: Some("toolu_pre".to_string()),
      tool_input: Some(json!({ "command": "pwd" })),
      tool_response: None,
    },
    &state,
  )
  .await;

  handle_hook_message(
    ClientMessage::CodexToolEvent {
      session_id: "codex-thread-tool-finish".to_string(),
      cwd: "/tmp/codex-tool-finish".to_string(),
      transcript_path: Some("/tmp/codex-tool-finish/transcript.jsonl".to_string()),
      model: Some("gpt-5-codex".to_string()),
      hook_event_name: "PostToolUseFailure".to_string(),
      turn_id: "turn-1".to_string(),
      tool_name: "Bash".to_string(),
      tool_use_id: Some("toolu_post".to_string()),
      tool_input: Some(json!({ "command": "pwd" })),
      tool_response: Some(json!("permission denied")),
    },
    &state,
  )
  .await;

  tokio::task::yield_now().await;
  tokio::task::yield_now().await;

  let actor = state
    .get_session("codex-thread-tool-finish")
    .expect("passive tool hook session should exist");
  let snapshot = actor.snapshot();
  assert_eq!(snapshot.work_status, WorkStatus::Working);
  assert_eq!(snapshot.pending_tool_name, None);
  assert_eq!(snapshot.pending_tool_input, None);
  assert_eq!(snapshot.pending_question, None);

  let commands = collect_persist_commands(&mut persist_rx);
  assert!(commands.iter().any(|command| matches!(
    command,
    PersistCommand::ToolCountIncrement { session_id }
      if session_id == "codex-thread-tool-finish"
  )));
  assert!(commands.iter().any(|command| matches!(
    command,
    PersistCommand::SessionAttentionUpdate {
      session_id,
      attention_reason,
      last_tool,
      last_tool_at,
      pending_tool_name,
      pending_tool_input,
      pending_question,
    }
      if session_id == "codex-thread-tool-finish"
        && attention_reason.as_ref() == Some(&Some("none".to_string()))
        && last_tool.is_none()
        && last_tool_at.is_none()
        && pending_tool_name.as_ref() == Some(&None)
        && pending_tool_input.as_ref() == Some(&None)
        && pending_question.as_ref() == Some(&None)
  )));
}

#[tokio::test]
async fn direct_pre_tool_use_updates_owner_without_materializing_shadow() {
  let _guard = test_env_lock().lock().await;
  ensure_server_test_data_dir();
  prepare_test_db();
  let (persist_tx, mut persist_rx) = mpsc::channel(64);
  let state = Arc::new(SessionRegistry::new_with_primary(persist_tx.clone(), true));

  let mut handle = SessionHandle::new(
    "od-direct-tool-owner".to_string(),
    Provider::Codex,
    "/tmp/codex-direct-tool".to_string(),
  );
  handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct));
  state.add_session(handle);

  let _ = persist_tx
    .send(PersistCommand::SessionCreate(Box::new(
      crate::infrastructure::persistence::SessionCreateParams {
        id: "od-direct-tool-owner".to_string(),
        provider: Provider::Codex,
        control_mode: SessionControlMode::Direct,
        project_path: "/tmp/codex-direct-tool".to_string(),
        project_name: None,
        branch: None,
        model: None,
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
    )))
    .await;
  let _ = persist_tx
    .send(PersistCommand::SetThreadId {
      session_id: "od-direct-tool-owner".to_string(),
      thread_id: "codex-thread-direct-tool".to_string(),
    })
    .await;
  crate::infrastructure::persistence::flush_batch_for_test(
    state.db_path(),
    vec![
      persist_rx.recv().await.unwrap(),
      persist_rx.recv().await.unwrap(),
    ],
  )
  .unwrap();

  handle_hook_message(
    ClientMessage::CodexToolEvent {
      session_id: "codex-thread-direct-tool".to_string(),
      cwd: "/tmp/codex-direct-tool".to_string(),
      transcript_path: Some("/tmp/codex-direct-tool/transcript.jsonl".to_string()),
      model: Some("gpt-5-codex".to_string()),
      hook_event_name: "PreToolUse".to_string(),
      turn_id: "turn-22".to_string(),
      tool_name: "Bash".to_string(),
      tool_use_id: Some("toolu_direct".to_string()),
      tool_input: Some(json!({ "command": "git status" })),
      tool_response: None,
    },
    &state,
  )
  .await;

  tokio::task::yield_now().await;
  tokio::task::yield_now().await;

  assert!(!state
    .iter_sessions()
    .any(|entry| entry.key() == "codex-thread-direct-tool"));
  let owner = state
    .get_session("od-direct-tool-owner")
    .expect("direct owner should still exist");
  let snapshot = owner.snapshot();
  assert_eq!(
    snapshot.codex_integration_mode,
    Some(CodexIntegrationMode::Direct)
  );
  assert_eq!(snapshot.work_status, WorkStatus::Working);
  assert_eq!(snapshot.pending_tool_name.as_deref(), Some("Bash"));
  assert_eq!(
    snapshot.pending_tool_input.as_deref(),
    Some("{\"command\":\"git status\"}")
  );

  let commands = collect_persist_commands(&mut persist_rx);
  assert!(!commands.iter().any(|command| matches!(
    command,
    PersistCommand::SessionCreate(params) if params.id == "codex-thread-direct-tool"
  )));
  assert!(commands.iter().any(|command| matches!(
    command,
    PersistCommand::SessionAttentionUpdate {
      session_id,
      last_tool,
      pending_tool_name,
      ..
    }
      if session_id == "od-direct-tool-owner"
        && last_tool.as_ref() == Some(&Some("Bash".to_string()))
        && pending_tool_name.as_ref() == Some(&Some("Bash".to_string()))
  )));
}
