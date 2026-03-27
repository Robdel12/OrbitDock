use anyhow::{Context, Result};
use reqwest::StatusCode;
use serde::{Deserialize, Serialize};

use crate::admin::normalize_client_server_url;
use crate::infrastructure::persistence::load_config_value;

const DEFAULT_DAYTONA_IMAGE: &str = "daytonaio/sandbox:latest";
const DEFAULT_SANDBOX_START_TIMEOUT_SECS: u64 = 60;

#[derive(Debug, Clone, Default)]
struct DaytonaConfigSourceValues {
  api_url: Option<String>,
  api_key: Option<String>,
  public_url: Option<String>,
  image: Option<String>,
  target: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DaytonaConfig {
  pub api_url: String,
  pub api_key: String,
  pub server_public_url: String,
  pub image: String,
  pub target: Option<String>,
}

impl DaytonaConfig {
  pub(crate) fn load() -> Result<Self> {
    Self::from_sources(
      DaytonaConfigSourceValues {
        api_url: std::env::var("ORBITDOCK_DAYTONA_API_URL").ok(),
        api_key: std::env::var("ORBITDOCK_DAYTONA_API_KEY").ok(),
        public_url: std::env::var("ORBITDOCK_PUBLIC_SERVER_URL").ok(),
        image: std::env::var("ORBITDOCK_DAYTONA_IMAGE").ok(),
        target: std::env::var("ORBITDOCK_DAYTONA_TARGET").ok(),
      },
      DaytonaConfigSourceValues {
        api_url: load_config_value("daytona_api_url"),
        api_key: load_config_value("daytona_api_key"),
        public_url: load_config_value("public_server_url"),
        image: load_config_value("daytona_image"),
        target: load_config_value("daytona_target"),
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
    let target = env
      .target
      .or(persisted.target)
      .map(|value| value.trim().to_string())
      .filter(|value| !value.is_empty());

    Ok(Self {
      api_url,
      api_key,
      server_public_url,
      image,
      target,
    })
  }
}

#[derive(Debug, Clone)]
pub(crate) struct DaytonaSandboxCreateRequest {
  pub name: String,
  pub image: String,
  pub target: Option<String>,
  pub cpu: Option<u32>,
  pub memory_gib: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum DaytonaSandboxState {
  Creating,
  Restoring,
  Destroyed,
  Destroying,
  Started,
  Stopped,
  Starting,
  Stopping,
  Error,
  BuildFailed,
  PendingBuild,
  BuildingSnapshot,
  Unknown,
  PullingSnapshot,
  Archived,
  Archiving,
  Resizing,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DaytonaSandbox {
  pub id: String,
  pub name: String,
  pub state: DaytonaSandboxState,
  pub toolbox_proxy_url: String,
}

#[derive(Debug, Clone)]
pub(crate) struct DaytonaToolboxExecRequest {
  pub command: String,
  pub cwd: Option<String>,
  pub timeout_secs: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DaytonaToolboxExecResult {
  pub exit_code: i32,
  pub result: String,
}

#[derive(Debug, Clone)]
pub(crate) struct DaytonaGitCloneRequest {
  pub url: String,
  pub path: String,
  pub branch: Option<String>,
}

#[derive(Clone)]
pub(crate) struct DaytonaClient {
  http: reqwest::Client,
  config: DaytonaConfig,
}

#[derive(Clone)]
pub(crate) struct DaytonaToolboxClient {
  http: reqwest::Client,
  base_url: String,
  api_key: String,
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

  pub(crate) async fn create_sandbox(
    &self,
    request: &DaytonaSandboxCreateRequest,
  ) -> Result<DaytonaSandbox> {
    let response = self
      .http
      .post(format!("{}/sandbox", self.config.api_url))
      .bearer_auth(&self.config.api_key)
      .json(&DaytonaCreateSandboxBody {
        name: request.name.clone(),
        target: request.target.clone(),
        cpu: request.cpu,
        memory: request.memory_gib,
        auto_stop_interval: Some(0),
        auto_delete_interval: Some(-1),
        build_info: DaytonaBuildInfoBody {
          dockerfile_content: format!("FROM {}", request.image),
        },
      })
      .send()
      .await
      .context("create Daytona sandbox")?;
    let response = error_for_status(response, "create Daytona sandbox")?;
    let body: DaytonaSandboxResponse = response
      .json()
      .await
      .context("decode Daytona sandbox response")?;
    body.into_sandbox()
  }

  pub(crate) async fn get_sandbox(&self, sandbox_id: &str) -> Result<Option<DaytonaSandbox>> {
    let response = self
      .http
      .get(format!("{}/sandbox/{sandbox_id}", self.config.api_url))
      .bearer_auth(&self.config.api_key)
      .send()
      .await
      .with_context(|| format!("get Daytona sandbox {sandbox_id}"))?;

    if response.status() == StatusCode::NOT_FOUND {
      return Ok(None);
    }

    let response = error_for_status(response, "get Daytona sandbox")?;
    let body: DaytonaSandboxResponse = response
      .json()
      .await
      .context("decode Daytona sandbox lookup response")?;
    Ok(Some(body.into_sandbox()?))
  }

  pub(crate) async fn wait_for_sandbox_started(&self, sandbox_id: &str) -> Result<DaytonaSandbox> {
    let deadline = tokio::time::Instant::now()
      + std::time::Duration::from_secs(DEFAULT_SANDBOX_START_TIMEOUT_SECS);

    loop {
      let Some(sandbox) = self.get_sandbox(sandbox_id).await? else {
        return Err(anyhow::anyhow!(
          "Daytona sandbox {sandbox_id} disappeared before startup completed"
        ));
      };

      match sandbox.state {
        DaytonaSandboxState::Started => return Ok(sandbox),
        DaytonaSandboxState::Error | DaytonaSandboxState::BuildFailed => {
          return Err(anyhow::anyhow!(
            "Daytona sandbox {sandbox_id} entered {:?}",
            sandbox.state
          ));
        }
        DaytonaSandboxState::Destroyed | DaytonaSandboxState::Destroying => {
          return Err(anyhow::anyhow!(
            "Daytona sandbox {sandbox_id} was destroyed during startup"
          ));
        }
        _ => {}
      }

      if tokio::time::Instant::now() >= deadline {
        return Err(anyhow::anyhow!(
          "Timed out waiting for Daytona sandbox {sandbox_id} to start"
        ));
      }

      tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
  }

  pub(crate) async fn delete_sandbox(&self, sandbox_id: &str) -> Result<()> {
    let response = self
      .http
      .delete(format!("{}/sandbox/{sandbox_id}", self.config.api_url))
      .bearer_auth(&self.config.api_key)
      .send()
      .await
      .with_context(|| format!("delete Daytona sandbox {sandbox_id}"))?;

    if response.status().is_success() || response.status() == StatusCode::NOT_FOUND {
      return Ok(());
    }

    Err(anyhow::anyhow!(
      "delete Daytona sandbox failed with HTTP {}",
      response.status().as_u16()
    ))
  }

  pub(crate) fn toolbox_client(&self, sandbox: &DaytonaSandbox) -> DaytonaToolboxClient {
    DaytonaToolboxClient {
      http: self.http.clone(),
      base_url: format!(
        "{}/{}",
        sandbox.toolbox_proxy_url.trim_end_matches('/'),
        sandbox.id
      ),
      api_key: self.config.api_key.clone(),
    }
  }
}

impl DaytonaToolboxClient {
  pub(crate) async fn git_clone(&self, request: &DaytonaGitCloneRequest) -> Result<()> {
    let response = self
      .http
      .post(format!("{}/git/clone", self.base_url))
      .bearer_auth(&self.api_key)
      .json(&DaytonaToolboxGitCloneBody {
        url: request.url.clone(),
        path: request.path.clone(),
        branch: request.branch.clone(),
      })
      .send()
      .await
      .context("clone repository through Daytona toolbox")?;
    let _ = error_for_status(response, "clone repository through Daytona toolbox")?;
    Ok(())
  }

  pub(crate) async fn execute_command(
    &self,
    request: &DaytonaToolboxExecRequest,
  ) -> Result<DaytonaToolboxExecResult> {
    let response = self
      .http
      .post(format!("{}/process/execute", self.base_url))
      .bearer_auth(&self.api_key)
      .json(&DaytonaToolboxExecuteBody {
        command: request.command.clone(),
        cwd: request.cwd.clone(),
        timeout: request.timeout_secs,
      })
      .send()
      .await
      .context("execute Daytona toolbox command")?;
    let response = error_for_status(response, "execute Daytona toolbox command")?;
    let body: DaytonaToolboxExecuteResponse = response
      .json()
      .await
      .context("decode Daytona toolbox execute response")?;
    Ok(DaytonaToolboxExecResult {
      exit_code: body.exit_code,
      result: body.result,
    })
  }

  pub(crate) async fn get_work_dir(&self) -> Result<String> {
    let response = self
      .http
      .get(format!("{}/work-dir", self.base_url))
      .bearer_auth(&self.api_key)
      .send()
      .await
      .context("load Daytona toolbox work dir")?;
    let response = error_for_status(response, "load Daytona toolbox work dir")?;
    let body: DaytonaToolboxDirResponse = response
      .json()
      .await
      .context("decode Daytona toolbox work dir response")?;
    Ok(body.dir)
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
#[serde(rename_all = "camelCase")]
struct DaytonaCreateSandboxBody {
  name: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  target: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  cpu: Option<u32>,
  #[serde(skip_serializing_if = "Option::is_none")]
  memory: Option<u32>,
  #[serde(skip_serializing_if = "Option::is_none")]
  auto_stop_interval: Option<i32>,
  #[serde(skip_serializing_if = "Option::is_none")]
  auto_delete_interval: Option<i32>,
  build_info: DaytonaBuildInfoBody,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct DaytonaBuildInfoBody {
  dockerfile_content: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DaytonaSandboxResponse {
  id: String,
  name: String,
  state: DaytonaSandboxState,
  toolbox_proxy_url: String,
}

impl DaytonaSandboxResponse {
  fn into_sandbox(self) -> Result<DaytonaSandbox> {
    if self.toolbox_proxy_url.trim().is_empty() {
      return Err(anyhow::anyhow!(
        "Daytona sandbox response did not include toolboxProxyUrl"
      ));
    }

    Ok(DaytonaSandbox {
      id: self.id,
      name: self.name,
      state: self.state,
      toolbox_proxy_url: self.toolbox_proxy_url,
    })
  }
}

#[derive(Debug, Serialize)]
struct DaytonaToolboxGitCloneBody {
  url: String,
  path: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  branch: Option<String>,
}

#[derive(Debug, Serialize)]
struct DaytonaToolboxExecuteBody {
  command: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  cwd: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  timeout: Option<u32>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DaytonaToolboxExecuteResponse {
  exit_code: i32,
  result: String,
}

#[derive(Debug, Deserialize)]
struct DaytonaToolboxDirResponse {
  dir: String,
}

#[cfg(test)]
mod tests {
  use super::{
    DaytonaConfig, DaytonaConfigSourceValues, DaytonaSandboxResponse, DaytonaSandboxState,
  };

  #[test]
  fn daytona_config_prefers_env_over_persisted_values() {
    let config = DaytonaConfig::from_sources(
      DaytonaConfigSourceValues {
        api_url: Some("https://env.daytona.example".into()),
        api_key: Some("env-key".into()),
        public_url: Some("https://dock.example.com".into()),
        image: Some("custom-image".into()),
        target: Some("us".into()),
      },
      DaytonaConfigSourceValues {
        api_url: Some("https://persisted.daytona.example".into()),
        api_key: Some("persisted-key".into()),
        public_url: Some("https://persisted-dock.example.com".into()),
        image: Some("persisted-image".into()),
        target: Some("eu".into()),
      },
    )
    .expect("resolve config");

    assert_eq!(config.api_url, "https://env.daytona.example");
    assert_eq!(config.api_key, "env-key");
    assert_eq!(config.server_public_url, "https://dock.example.com");
    assert_eq!(config.image, "custom-image");
    assert_eq!(config.target.as_deref(), Some("us"));
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

  #[test]
  fn sandbox_response_requires_toolbox_proxy_url() {
    let error = DaytonaSandboxResponse {
      id: "sandbox-1".into(),
      name: "orbitdock".into(),
      state: DaytonaSandboxState::Started,
      toolbox_proxy_url: String::new(),
    }
    .into_sandbox()
    .expect_err("missing toolbox url should fail");

    assert!(error.to_string().contains("toolboxProxyUrl"));
  }
}
