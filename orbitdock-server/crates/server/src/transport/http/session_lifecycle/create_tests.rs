use axum::{extract::State, http::StatusCode, Json};
use tempfile::tempdir;

use super::*;

struct EnvVarGuard {
  key: &'static str,
  original: Option<String>,
}

impl EnvVarGuard {
  fn set(key: &'static str, value: &str) -> Self {
    let original = std::env::var(key).ok();
    unsafe {
      std::env::set_var(key, value);
    }
    Self { key, original }
  }
}

impl Drop for EnvVarGuard {
  fn drop(&mut self) {
    match &self.original {
      Some(value) => unsafe {
        std::env::set_var(self.key, value);
      },
      None => unsafe {
        std::env::remove_var(self.key);
      },
    }
  }
}

fn codex_request(
  codex_config_mode: Option<CodexConfigMode>,
  codex_config_profile: Option<&str>,
  model_provider: Option<&str>,
  model: Option<&str>,
) -> CreateSessionRequest {
  CreateSessionRequest {
    session_id: None,
    provider: Provider::Codex,
    cwd: "/tmp/project".to_string(),
    model: model.map(str::to_string),
    approval_policy_details: None,
    sandbox_policy_details: None,
    permission_mode: None,
    allowed_tools: Vec::new(),
    disallowed_tools: Vec::new(),
    effort: None,
    collaboration_mode: None,
    multi_agent: None,
    personality: None,
    service_tier: None,
    developer_instructions: None,
    system_prompt: None,
    append_system_prompt: None,
    allow_bypass_permissions: false,
    codex_config_mode,
    codex_config_profile: codex_config_profile.map(str::to_string),
    codex_model_provider: model_provider.map(str::to_string),
    codex_config_source: Some(CodexConfigSource::User),
    mission_id: None,
    issue_id: None,
    issue_identifier: None,
    workspace_id: None,
    initial_prompt: None,
    skills: Vec::new(),
    tracker_kind: None,
    tracker_api_key: None,
  }
}

#[test]
fn create_codex_selection_clears_stale_model_for_profile_mode() {
  let selection = create_codex_selection(
    &codex_request(
      Some(CodexConfigMode::Profile),
      Some("qwen"),
      Some("openrouter"),
      Some("gpt-5.4"),
    ),
    None,
    Some(CodexConfigSource::User),
  )
  .expect("selection should exist");

  assert_eq!(selection.config_mode, CodexConfigMode::Profile);
  assert_eq!(selection.config_profile.as_deref(), Some("qwen"));
  assert_eq!(selection.overrides.model, None);
  assert_eq!(selection.overrides.model_provider, None);
}

#[test]
fn create_codex_selection_preserves_explicit_model_for_custom_mode() {
  let selection = create_codex_selection(
    &codex_request(
      Some(CodexConfigMode::Custom),
      None,
      Some("openrouter"),
      Some("qwen/qwen3-coder-next"),
    ),
    None,
    Some(CodexConfigSource::User),
  )
  .expect("selection should exist");

  assert_eq!(selection.config_mode, CodexConfigMode::Custom);
  assert_eq!(
    selection.overrides.model.as_deref(),
    Some("qwen/qwen3-coder-next")
  );
  assert_eq!(
    selection.overrides.model_provider.as_deref(),
    Some("openrouter")
  );
}

#[tokio::test]
async fn create_session_reports_connector_start_failure_when_claude_binary_is_missing() {
  let (state, _persist_rx, _db_path, _guard) =
    crate::transport::http::test_support::new_persist_test_state(true).await;
  let temp_home = tempdir().expect("temp home dir");
  let _claude_bin = EnvVarGuard::set("CLAUDE_BIN", "/definitely/missing/claude");
  let _home = EnvVarGuard::set("HOME", temp_home.path().to_string_lossy().as_ref());
  let _path = EnvVarGuard::set("PATH", "");

  let response = create_session(
    State(state.clone()),
    Json(CreateSessionRequest {
      session_id: Some("create-session-failure".to_string()),
      provider: Provider::Claude,
      cwd: temp_home.path().to_string_lossy().to_string(),
      model: Some("claude-opus-4-1".to_string()),
      approval_policy_details: None,
      sandbox_policy_details: None,
      permission_mode: None,
      allowed_tools: Vec::new(),
      disallowed_tools: Vec::new(),
      effort: None,
      collaboration_mode: None,
      multi_agent: None,
      personality: None,
      service_tier: None,
      developer_instructions: None,
      system_prompt: None,
      append_system_prompt: None,
      allow_bypass_permissions: false,
      codex_config_mode: None,
      codex_config_profile: None,
      codex_model_provider: None,
      codex_config_source: None,
      mission_id: None,
      issue_id: None,
      issue_identifier: None,
      workspace_id: None,
      initial_prompt: None,
      skills: Vec::new(),
      tracker_kind: None,
      tracker_api_key: None,
    }),
  )
  .await;

  match response {
    Ok(_) => panic!("expected create_session to fail when the Claude binary is unavailable"),
    Err((status, body)) => {
      assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
      assert_eq!(body.code, "connector_start_failed");
      assert!(body.error.contains("Claude CLI binary not found"));
    }
  }

  assert!(state.get_session("create-session-failure").is_none());
}
