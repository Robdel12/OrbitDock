use super::*;

fn codex_resume_request(
  model: Option<&str>,
  codex_config_mode: Option<CodexConfigMode>,
  codex_config_profile: Option<&str>,
  codex_model_provider: Option<&str>,
) -> CodexResumeRequest {
  CodexResumeRequest {
    session_id: "session-1".to_string(),
    project_path: "/tmp/project".to_string(),
    model: model.map(str::to_string),
    codex_thread_id: None,
    approval_policy: None,
    sandbox_mode: None,
    sandbox_policy_details: None,
    collaboration_mode: None,
    multi_agent: None,
    personality: None,
    service_tier: None,
    developer_instructions: None,
    codex_config_mode,
    codex_config_profile: codex_config_profile.map(str::to_string),
    codex_model_provider: codex_model_provider.map(str::to_string),
    codex_config_source: Some(CodexConfigSource::User),
    codex_config_overrides: None,
    include_mission_tools: false,
    handle: crate::domain::sessions::session::SessionHandle::new(
      "session-1".to_string(),
      Provider::Codex,
      "/tmp/project".to_string(),
    ),
    message_count: 0,
  }
}

#[test]
fn codex_resume_selection_clears_stale_model_for_profile_mode() {
  let request = codex_resume_request(
    Some("gpt-5.4"),
    Some(CodexConfigMode::Profile),
    Some("qwen"),
    Some("openrouter"),
  );
  let selection = codex_resume_selection(&request);

  assert_eq!(selection.config_mode, CodexConfigMode::Profile);
  assert_eq!(selection.config_profile.as_deref(), Some("qwen"));
  assert_eq!(selection.overrides.model, None);
  assert_eq!(selection.overrides.model_provider, None);
}

#[test]
fn codex_resume_selection_preserves_explicit_model_for_custom_mode() {
  let request = codex_resume_request(
    Some("qwen/qwen3-coder-next"),
    Some(CodexConfigMode::Custom),
    None,
    Some("openrouter"),
  );
  let selection = codex_resume_selection(&request);

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
