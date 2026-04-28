use serde::Serialize;

use super::{CodexApprovalPolicy, CodexSandboxPolicy};

/// A single permission rule from a provider's configuration.
#[derive(Debug, Clone, Serialize, serde::Deserialize)]
pub struct PermissionRule {
  /// Rule pattern, e.g. "Bash(make:*)", "WebSearch", "mcp__xcode__XcodeRead"
  pub pattern: String,
  /// Behavior: "allow", "deny", or "ask"
  pub behavior: String,
}

/// Provider-specific permission configuration snapshot.
#[derive(Debug, Clone, Serialize, serde::Deserialize)]
#[serde(tag = "provider", rename_all = "snake_case")]
pub enum SessionPermissionRules {
  Claude {
    #[serde(skip_serializing_if = "Option::is_none")]
    permission_mode: Option<String>,
    rules: Vec<PermissionRule>,
    #[serde(skip_serializing_if = "Option::is_none")]
    additional_directories: Option<Vec<String>>,
  },
  Codex {
    #[serde(skip_serializing_if = "Option::is_none")]
    approval_policy: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    approval_policy_details: Option<CodexApprovalPolicy>,
    #[serde(skip_serializing_if = "Option::is_none")]
    sandbox_mode: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sandbox_policy_details: Option<CodexSandboxPolicy>,
  },
}
