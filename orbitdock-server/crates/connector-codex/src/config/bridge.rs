use codex_app_server_protocol::SandboxPolicy as AppServerSandboxPolicy;
use codex_protocol::protocol::SandboxPolicy;
use orbitdock_connector_core::ConnectorError;
use serde::de::DeserializeOwned;
use serde::Serialize;

pub(crate) fn convert_app_server_type<T, U>(value: T, label: &str) -> Result<U, ConnectorError>
where
  T: Serialize,
  U: DeserializeOwned,
{
  serde_json::from_value(serde_json::to_value(value).map_err(|error| {
    ConnectorError::ProviderError(format!("Failed to encode Codex {label}: {error}"))
  })?)
  .map_err(|error| {
    ConnectorError::ProviderError(format!(
      "Failed to convert Codex {label} for app-server: {error}"
    ))
  })
}

pub(crate) fn convert_optional<T, U>(
  value: Option<T>,
  label: &str,
) -> Result<Option<U>, ConnectorError>
where
  T: Serialize,
  U: DeserializeOwned,
{
  value
    .map(|inner| convert_app_server_type(inner, label))
    .transpose()
}

pub(crate) fn convert_sandbox_policy(
  value: Option<SandboxPolicy>,
) -> Option<AppServerSandboxPolicy> {
  value.map(AppServerSandboxPolicy::from)
}

#[cfg(test)]
#[path = "bridge_tests.rs"]
mod bridge_tests;
