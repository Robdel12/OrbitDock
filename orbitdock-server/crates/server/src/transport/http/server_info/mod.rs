use orbitdock_protocol::WorkspaceProviderKind;
use serde::{Deserialize, Serialize};

mod openai;
mod server_state;
mod workspace_provider;

pub use openai::{check_open_ai_key, set_open_ai_key};
pub use server_state::{get_server_meta, set_client_primary_claim, set_server_role};
pub use workspace_provider::{
  get_workspace_provider, get_workspace_provider_config_value, set_workspace_provider,
  set_workspace_provider_config_value, test_workspace_provider,
};

#[derive(Debug, Serialize)]
pub struct OpenAiKeyStatusResponse {
  pub configured: bool,
}

#[derive(Debug, Deserialize)]
pub struct SetOpenAiKeyRequest {
  pub key: String,
}

#[derive(Debug, Deserialize)]
pub struct SetServerRoleRequest {
  pub is_primary: bool,
}

#[derive(Debug, Serialize)]
pub struct ServerRoleResponse {
  pub is_primary: bool,
}

#[derive(Debug, Serialize)]
pub struct WorkspaceProviderConfigResponse {
  pub workspace_provider: WorkspaceProviderKind,
}

#[derive(Debug, Deserialize)]
pub struct SetWorkspaceProviderRequest {
  pub workspace_provider: WorkspaceProviderKind,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorkspaceProviderConfigKey {
  PublicServerUrl,
  DaytonaApiUrl,
  DaytonaApiKey,
  DaytonaImage,
  DaytonaTarget,
}

impl WorkspaceProviderConfigKey {
  fn parse(value: &str) -> Option<Self> {
    match value {
      "public-server-url" => Some(Self::PublicServerUrl),
      "daytona-api-url" => Some(Self::DaytonaApiUrl),
      "daytona-api-key" => Some(Self::DaytonaApiKey),
      "daytona-image" => Some(Self::DaytonaImage),
      "daytona-target" => Some(Self::DaytonaTarget),
      _ => None,
    }
  }

  fn key(self) -> &'static str {
    match self {
      Self::PublicServerUrl => "public-server-url",
      Self::DaytonaApiUrl => "daytona-api-url",
      Self::DaytonaApiKey => "daytona-api-key",
      Self::DaytonaImage => "daytona-image",
      Self::DaytonaTarget => "daytona-target",
    }
  }

  fn persisted_key(self) -> &'static str {
    match self {
      Self::PublicServerUrl => "public_server_url",
      Self::DaytonaApiUrl => "daytona_api_url",
      Self::DaytonaApiKey => "daytona_api_key",
      Self::DaytonaImage => "daytona_image",
      Self::DaytonaTarget => "daytona_target",
    }
  }

  fn is_secret(self) -> bool {
    matches!(self, Self::DaytonaApiKey)
  }

  fn env_var(self) -> &'static str {
    match self {
      Self::PublicServerUrl => "ORBITDOCK_PUBLIC_SERVER_URL",
      Self::DaytonaApiUrl => "ORBITDOCK_DAYTONA_API_URL",
      Self::DaytonaApiKey => "ORBITDOCK_DAYTONA_API_KEY",
      Self::DaytonaImage => "ORBITDOCK_DAYTONA_IMAGE",
      Self::DaytonaTarget => "ORBITDOCK_DAYTONA_TARGET",
    }
  }
}

#[derive(Debug, Serialize)]
pub struct WorkspaceProviderConfigValueResponse {
  pub key: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub value: Option<String>,
  pub configured: bool,
  pub secret: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub source: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct SetWorkspaceProviderConfigValueRequest {
  pub value: String,
}

#[derive(Debug, Serialize)]
pub struct WorkspaceProviderTestResponse {
  pub ok: bool,
  pub provider: String,
  pub message: String,
}

#[derive(Debug, Deserialize)]
pub struct SetClientPrimaryClaimRequest {
  pub client_id: String,
  pub device_name: String,
  pub is_primary: bool,
}

#[cfg(test)]
mod tests;
