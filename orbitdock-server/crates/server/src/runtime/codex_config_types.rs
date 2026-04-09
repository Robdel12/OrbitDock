use std::collections::HashMap;
use std::fmt;

use codex_app_server_protocol::MergeStrategy;
use orbitdock_protocol::{
  CodexApprovalPolicy, CodexConfigMode, CodexConfigSource, CodexSandboxPolicy,
  CodexSessionOverrides,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize)]
pub struct CodexConfigPreferencesResponse {
  pub default_config_source: CodexConfigSource,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexResolvedSettings {
  pub config_source: CodexConfigSource,
  pub config_mode: CodexConfigMode,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub config_profile: Option<String>,
  pub overrides: CodexSessionOverrides,
  pub model: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub model_provider: Option<String>,
  pub approval_policy: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub approval_policy_details: Option<CodexApprovalPolicy>,
  pub sandbox_mode: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub sandbox_policy_details: Option<CodexSandboxPolicy>,
  pub collaboration_mode: Option<String>,
  pub multi_agent: Option<bool>,
  pub personality: Option<String>,
  pub service_tier: Option<String>,
  pub developer_instructions: Option<String>,
  pub effort: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexInspectorOrigin {
  pub source_kind: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub path: Option<String>,
  pub version: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexInspectorLayer {
  pub source_kind: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub path: Option<String>,
  pub version: String,
  pub config: serde_json::Value,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub disabled_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexConfigInspectorResponse {
  pub effective_settings: CodexResolvedSettings,
  pub origins: HashMap<String, CodexInspectorOrigin>,
  pub layers: Vec<CodexInspectorLayer>,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub warnings: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct CodexConfigSelection {
  pub config_source: CodexConfigSource,
  pub config_mode: CodexConfigMode,
  pub config_profile: Option<String>,
  pub model_provider: Option<String>,
  pub overrides: CodexSessionOverrides,
}

impl CodexConfigSelection {
  pub fn normalized(mut self) -> Self {
    match self.config_mode {
      CodexConfigMode::Inherit => {
        self.config_profile = None;
        self.model_provider = None;
        self.overrides.model = None;
        self.overrides.model_provider = None;
      }
      CodexConfigMode::Profile => {
        self.model_provider = None;
        self.overrides.model = None;
        self.overrides.model_provider = None;
      }
      CodexConfigMode::Custom => {
        self.config_profile = None;
      }
    }
    self
  }
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexConfigProfileSummary {
  pub name: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub model: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub model_provider: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub source: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexProviderSummary {
  pub id: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub display_name: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub base_url: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub wire_api: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub env_key: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub is_custom: Option<bool>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexConfigCatalogResponse {
  #[serde(skip_serializing_if = "Option::is_none")]
  pub cwd: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub effective_settings: Option<CodexResolvedSettings>,
  pub profiles: Vec<CodexConfigProfileSummary>,
  pub providers: Vec<CodexProviderSummary>,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CodexConfigDocumentScope {
  User,
  Project,
}

impl fmt::Display for CodexConfigDocumentScope {
  fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
    match self {
      Self::User => write!(f, "user"),
      Self::Project => write!(f, "project"),
    }
  }
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexConfigProfileDocument {
  pub name: String,
  pub config: Value,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub model: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub model_provider: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexProviderDocument {
  pub id: String,
  pub config: Value,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub display_name: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub base_url: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub wire_api: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub env_key: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub is_custom: Option<bool>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexConfigDocument {
  pub scope: CodexConfigDocumentScope,
  pub exists: bool,
  pub writable: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub write_warning: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub file_path: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub version: Option<String>,
  pub config: Value,
  pub profiles: Vec<CodexConfigProfileDocument>,
  pub providers: Vec<CodexProviderDocument>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexConfigDocumentsResponse {
  #[serde(skip_serializing_if = "Option::is_none")]
  pub cwd: Option<String>,
  pub user: CodexConfigDocument,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub projects: Vec<CodexConfigDocument>,
  #[serde(default, skip_serializing_if = "Vec::is_empty")]
  pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CodexConfigValueWriteRequest {
  pub cwd: String,
  #[serde(default)]
  pub key_path: String,
  pub value: Value,
  #[serde(default)]
  pub merge_strategy: Option<CodexConfigMergeStrategy>,
  #[serde(default)]
  pub file_path: Option<String>,
  #[serde(default)]
  pub expected_version: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CodexConfigBatchWriteRequest {
  pub cwd: String,
  #[serde(default)]
  pub edits: Vec<CodexConfigEditRequest>,
  #[serde(default)]
  pub file_path: Option<String>,
  #[serde(default)]
  pub expected_version: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CodexConfigEditRequest {
  pub key_path: String,
  pub value: Value,
  #[serde(default)]
  pub merge_strategy: Option<CodexConfigMergeStrategy>,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexConfigMergeStrategy {
  Replace,
  Upsert,
}

impl From<CodexConfigMergeStrategy> for MergeStrategy {
  fn from(value: CodexConfigMergeStrategy) -> Self {
    match value {
      CodexConfigMergeStrategy::Replace => MergeStrategy::Replace,
      CodexConfigMergeStrategy::Upsert => MergeStrategy::Upsert,
    }
  }
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexConfigWriteResponseData {
  pub status: String,
  pub version: String,
  pub file_path: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub overridden_metadata: Option<CodexConfigOverriddenMetadata>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CodexConfigOverriddenMetadata {
  pub message: String,
  pub overriding_layer: CodexInspectorOrigin,
  pub effective_value: Value,
}
