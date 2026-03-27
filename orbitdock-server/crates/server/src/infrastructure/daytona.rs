use std::collections::HashMap;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::admin::normalize_client_server_url;
use crate::infrastructure::persistence::load_config_value;

const DEFAULT_DAYTONA_IMAGE: &str = "ghcr.io/daytonaio/workspace:latest";

#[derive(Debug, Clone, Default)]
struct DaytonaConfigSourceValues {
  api_url: Option<String>,
  api_key: Option<String>,
  public_url: Option<String>,
  image: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DaytonaConfig {
  pub api_url: String,
  pub api_key: String,
  pub server_public_url: String,
  pub image: String,
}

impl DaytonaConfig {
  pub(crate) fn load() -> Result<Self> {
    Self::from_sources(
      DaytonaConfigSourceValues {
        api_url: std::env::var("ORBITDOCK_DAYTONA_API_URL").ok(),
        api_key: std::env::var("ORBITDOCK_DAYTONA_API_KEY").ok(),
        public_url: std::env::var("ORBITDOCK_PUBLIC_SERVER_URL").ok(),
        image: std::env::var("ORBITDOCK_DAYTONA_IMAGE").ok(),
      },
      DaytonaConfigSourceValues {
        api_url: load_config_value("daytona_api_url"),
        api_key: load_config_value("daytona_api_key"),
        public_url: load_config_value("public_server_url"),
        image: load_config_value("daytona_image"),
      },
    )
  }

  fn from_sources(
    env: DaytonaConfigSourceValues,
    persisted: DaytonaConfigSourceValues,
  ) -> Result<Self> {
    let api_url = env
      .api_url
      .or(persisted.api_url)
      .map(|value| value.trim().trim_end_matches('/').to_string())
      .filter(|value| !value.is_empty())
      .ok_or_else(|| anyhow::anyhow!("Daytona provider requires daytona_api_url config"))?;
    let api_key = env
      .api_key
      .or(persisted.api_key)
      .map(|value| value.trim().to_string())
      .filter(|value| !value.is_empty())
      .ok_or_else(|| anyhow::anyhow!("Daytona provider requires daytona_api_key config"))?;
    let server_public_url = env
      .public_url
      .or(persisted.public_url)
      .map(|value| normalize_client_server_url(&value))
      .filter(|value| !value.is_empty())
      .ok_or_else(|| anyhow::anyhow!("Daytona provider requires public_server_url config"))?;
    let image = env
      .image
      .or(persisted.image)
      .map(|value| value.trim().to_string())
      .filter(|value| !value.is_empty())
      .unwrap_or_else(|| DEFAULT_DAYTONA_IMAGE.to_string());

    Ok(Self {
      api_url,
      api_key,
      server_public_url,
      image,
    })
  }
}

#[derive(Debug, Clone)]
pub(crate) struct DaytonaWorkspaceCreateRequest {
  pub name: String,
  pub repository_url: String,
  pub branch: String,
  pub image: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DaytonaWorkspaceSummary {
  pub id: String,
  pub name: String,
}

#[derive(Debug, Clone)]
pub(crate) struct DaytonaExecRequest {
  pub command: Vec<String>,
  pub env: HashMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DaytonaExecResult {
  pub exit_code: i32,
  pub stdout: String,
  pub stderr: String,
}

#[derive(Clone)]
pub(crate) struct DaytonaClient {
  http: reqwest::Client,
  config: DaytonaConfig,
}

impl DaytonaClient {
  pub(crate) fn new(config: DaytonaConfig) -> Result<Self> {
    let http = reqwest::Client::builder()
      .connect_timeout(std::time::Duration::from_secs(5))
      .timeout(std::time::Duration::from_secs(60))
      .build()
      .context("build Daytona HTTP client")?;
    Ok(Self { http, config })
  }

  pub(crate) fn config(&self) -> &DaytonaConfig {
    &self.config
  }

  pub(crate) async fn create_workspace(
    &self,
    request: &DaytonaWorkspaceCreateRequest,
  ) -> Result<DaytonaWorkspaceSummary> {
    let body = DaytonaCreateWorkspaceBody {
      name: request.name.clone(),
      repository_url: request.repository_url.clone(),
      branch: request.branch.clone(),
      image: request.image.clone(),
    };
    let response = self
      .http
      .post(format!("{}/workspaces", self.config.api_url))
      .bearer_auth(&self.config.api_key)
      .json(&body)
      .send()
      .await
      .context("create Daytona workspace")?;
    let response = error_for_status(response, "create Daytona workspace")?;
    let body: DaytonaWorkspaceResponse = response
      .json()
      .await
      .context("decode Daytona workspace response")?;

    Ok(DaytonaWorkspaceSummary {
      id: body.id,
      name: body.name,
    })
  }

  pub(crate) async fn exec_in_workspace(
    &self,
    workspace_id: &str,
    request: &DaytonaExecRequest,
  ) -> Result<DaytonaExecResult> {
    let response = self
      .http
      .post(format!(
        "{}/workspaces/{workspace_id}/exec",
        self.config.api_url
      ))
      .bearer_auth(&self.config.api_key)
      .json(&DaytonaExecBody {
        command: request.command.clone(),
        env: request.env.clone(),
      })
      .send()
      .await
      .with_context(|| format!("exec Daytona workspace {workspace_id}"))?;
    let response = error_for_status(response, "exec Daytona workspace")?;
    let body: DaytonaExecResponse = response
      .json()
      .await
      .context("decode Daytona exec response")?;
    Ok(DaytonaExecResult {
      exit_code: body.exit_code,
      stdout: body.stdout.unwrap_or_default(),
      stderr: body.stderr.unwrap_or_default(),
    })
  }

  pub(crate) async fn delete_workspace(&self, workspace_id: &str) -> Result<()> {
    let response = self
      .http
      .delete(format!("{}/workspaces/{workspace_id}", self.config.api_url))
      .bearer_auth(&self.config.api_key)
      .send()
      .await
      .with_context(|| format!("delete Daytona workspace {workspace_id}"))?;

    if response.status().is_success() || response.status() == reqwest::StatusCode::NOT_FOUND {
      return Ok(());
    }

    Err(anyhow::anyhow!(
      "delete Daytona workspace failed with HTTP {}",
      response.status().as_u16()
    ))
  }
}

fn error_for_status(response: reqwest::Response, context: &str) -> Result<reqwest::Response> {
  let status = response.status();
  if status.is_success() {
    return Ok(response);
  }

  Err(anyhow::anyhow!(
    "{context} failed with HTTP {}",
    status.as_u16()
  ))
}

#[derive(Debug, Serialize)]
struct DaytonaCreateWorkspaceBody {
  name: String,
  repository_url: String,
  branch: String,
  image: String,
}

#[derive(Debug, Deserialize)]
struct DaytonaWorkspaceResponse {
  id: String,
  name: String,
}

#[derive(Debug, Serialize)]
struct DaytonaExecBody {
  command: Vec<String>,
  env: HashMap<String, String>,
}

#[derive(Debug, Deserialize)]
struct DaytonaExecResponse {
  #[serde(default)]
  exit_code: i32,
  #[serde(default)]
  stdout: Option<String>,
  #[serde(default)]
  stderr: Option<String>,
}

#[cfg(test)]
mod tests {
  use super::{DaytonaConfig, DaytonaConfigSourceValues};

  #[test]
  fn daytona_config_prefers_env_over_persisted_values() {
    let config = DaytonaConfig::from_sources(
      DaytonaConfigSourceValues {
        api_url: Some("https://env.daytona.example".into()),
        api_key: Some("env-key".into()),
        public_url: Some("https://dock.example.com".into()),
        image: Some("custom-image".into()),
      },
      DaytonaConfigSourceValues {
        api_url: Some("https://persisted.daytona.example".into()),
        api_key: Some("persisted-key".into()),
        public_url: Some("https://persisted-dock.example.com".into()),
        image: Some("persisted-image".into()),
      },
    )
    .expect("resolve config");

    assert_eq!(config.api_url, "https://env.daytona.example");
    assert_eq!(config.api_key, "env-key");
    assert_eq!(config.server_public_url, "https://dock.example.com");
    assert_eq!(config.image, "custom-image");
  }

  #[test]
  fn daytona_config_requires_minimum_runtime_values() {
    let error = DaytonaConfig::from_sources(
      DaytonaConfigSourceValues::default(),
      DaytonaConfigSourceValues::default(),
    )
    .expect_err("missing config should fail");

    assert!(error.to_string().contains("daytona_api_url"));
  }
}
