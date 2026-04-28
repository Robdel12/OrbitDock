use orbitdock_protocol::WorkspaceProviderKind;

pub(super) fn parse_server_role_value(value: &str) -> Option<bool> {
  match value.trim().to_ascii_lowercase().as_str() {
    "primary" | "true" | "1" => Some(true),
    "secondary" | "false" | "0" => Some(false),
    _ => None,
  }
}

pub(super) fn normalize_auth_token(auth_token: Option<String>) -> Option<String> {
  auth_token
    .map(|token| token.trim().to_string())
    .filter(|token| !token.is_empty())
}

pub(super) fn resolve_workspace_provider_kind(
  override_kind: Option<WorkspaceProviderKind>,
  persisted_value: Option<String>,
) -> anyhow::Result<WorkspaceProviderKind> {
  if let Some(override_kind) = override_kind {
    return Ok(override_kind);
  }

  match persisted_value {
    Some(value) => value
      .parse::<WorkspaceProviderKind>()
      .map_err(|error| anyhow::anyhow!(error)),
    None => Ok(WorkspaceProviderKind::default()),
  }
}

pub(super) fn load_trimmed_config_value(key: &str) -> Option<String> {
  crate::infrastructure::persistence::load_config_value(key).and_then(|value| {
    let trimmed = value.trim();
    if trimmed.is_empty() {
      None
    } else {
      Some(trimmed.to_string())
    }
  })
}
