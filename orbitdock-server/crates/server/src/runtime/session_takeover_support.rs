pub(super) fn codex_runtime_overrides_from_summary(
  summary: &orbitdock_protocol::SessionSummary,
) -> orbitdock_connector_codex::CodexRuntimeOverrides {
  orbitdock_connector_codex::CodexRuntimeOverrides {
    approvals_reviewer: summary
      .codex_config_overrides
      .as_ref()
      .and_then(|overrides| overrides.approvals_reviewer)
      .map(|value| value.as_str().to_string()),
    collaboration_mode: summary.collaboration_mode.clone(),
    multi_agent: summary.multi_agent,
    personality: summary.personality.clone(),
    service_tier: summary.service_tier.clone(),
    developer_instructions: summary.developer_instructions.clone(),
    effort: summary.effort.clone(),
  }
}

pub(super) fn takeover_permission_persist_op(
  session_id: &str,
  persist_permission_mode: bool,
  permission_mode: Option<String>,
) -> Option<crate::runtime::session_commands::PersistOp> {
  if !persist_permission_mode {
    return None;
  }

  permission_mode.map(|permission_mode| {
    crate::runtime::session_commands::PersistOp::SetSessionConfig(Box::new(
      crate::runtime::session_commands::SessionConfigPersist {
        session_id: session_id.to_string(),
        approval_policy: None,
        sandbox_mode: None,
        permission_mode: Some(Some(permission_mode)),
        collaboration_mode: None,
        multi_agent: None,
        personality: None,
        service_tier: None,
        developer_instructions: None,
        model: None,
        effort: None,
        codex_config_mode: None,
        codex_config_profile: None,
        codex_model_provider: None,
        codex_config_source: None,
        codex_config_overrides_json: None,
      },
    ))
  })
}
