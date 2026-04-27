use super::*;

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
