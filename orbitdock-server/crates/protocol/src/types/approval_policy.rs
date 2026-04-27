use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CodexApprovalMode {
  #[serde(rename = "untrusted")]
  Untrusted,
  #[serde(rename = "on-failure")]
  OnFailure,
  #[serde(rename = "on-request")]
  OnRequest,
  #[serde(rename = "never")]
  Never,
}

impl CodexApprovalMode {
  pub fn as_str(self) -> &'static str {
    match self {
      Self::Untrusted => "untrusted",
      Self::OnFailure => "on-failure",
      Self::OnRequest => "on-request",
      Self::Never => "never",
    }
  }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexApprovalsReviewer {
  User,
  GuardianSubagent,
}

impl CodexApprovalsReviewer {
  pub fn as_str(self) -> &'static str {
    match self {
      Self::User => "user",
      Self::GuardianSubagent => "guardian_subagent",
    }
  }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodexGranularApprovalPolicy {
  pub sandbox_approval: bool,
  pub rules: bool,
  pub skill_approval: bool,
  pub request_permissions: bool,
  pub mcp_elicitations: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum CodexApprovalPolicy {
  Mode(CodexApprovalMode),
  Granular {
    granular: CodexGranularApprovalPolicy,
  },
}

impl CodexApprovalPolicy {
  pub fn summary_text(&self) -> String {
    match self {
      Self::Mode(mode) => mode.as_str().to_string(),
      Self::Granular { .. } => "reject".to_string(),
    }
  }

  pub fn from_storage_text(value: &str) -> Option<Self> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
      return None;
    }

    if trimmed.starts_with('{') || trimmed.starts_with('"') {
      if let Ok(policy) = serde_json::from_str::<Self>(trimmed) {
        return Some(policy);
      }
    }

    match trimmed {
      "untrusted" | "unless-allow-listed" => Some(Self::Mode(CodexApprovalMode::Untrusted)),
      "on-failure" => Some(Self::Mode(CodexApprovalMode::OnFailure)),
      "on-request" => Some(Self::Mode(CodexApprovalMode::OnRequest)),
      "never" => Some(Self::Mode(CodexApprovalMode::Never)),
      "reject" => Some(Self::Granular {
        granular: CodexGranularApprovalPolicy {
          sandbox_approval: false,
          rules: false,
          skill_approval: false,
          request_permissions: false,
          mcp_elicitations: false,
        },
      }),
      _ => None,
    }
  }

  pub fn storage_text(&self) -> String {
    match self {
      Self::Mode(mode) => mode.as_str().to_string(),
      Self::Granular { .. } => serde_json::to_string(self).unwrap_or_else(|_| self.summary_text()),
    }
  }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum CodexSandboxMode {
  DangerFullAccess,
  ReadOnly,
  WorkspaceWrite,
  ExternalSandbox,
}

impl CodexSandboxMode {
  pub fn as_str(self) -> &'static str {
    match self {
      Self::DangerFullAccess => "danger-full-access",
      Self::ReadOnly => "read-only",
      Self::WorkspaceWrite => "workspace-write",
      Self::ExternalSandbox => "external-sandbox",
    }
  }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodexSandboxPolicy {
  pub mode: CodexSandboxMode,
  #[serde(default)]
  pub network_access: bool,
}

impl CodexSandboxPolicy {
  pub fn summary_text(&self) -> String {
    if self.network_access {
      match self.mode {
        CodexSandboxMode::DangerFullAccess => "danger-full-access".to_string(),
        CodexSandboxMode::ReadOnly => "read-only-network".to_string(),
        CodexSandboxMode::WorkspaceWrite => "workspace-write-network".to_string(),
        CodexSandboxMode::ExternalSandbox => "external-sandbox-network".to_string(),
      }
    } else {
      self.mode.as_str().to_string()
    }
  }

  pub fn from_storage_text(value: &str) -> Option<Self> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
      return None;
    }

    if trimmed.starts_with('{') {
      if let Ok(policy) = serde_json::from_str::<Self>(trimmed) {
        return Some(policy);
      }
    }

    let parsed = match trimmed {
      "danger-full-access" => Self {
        mode: CodexSandboxMode::DangerFullAccess,
        network_access: true,
      },
      "read-only" => Self {
        mode: CodexSandboxMode::ReadOnly,
        network_access: false,
      },
      "read-only-network" => Self {
        mode: CodexSandboxMode::ReadOnly,
        network_access: true,
      },
      "workspace-write" => Self {
        mode: CodexSandboxMode::WorkspaceWrite,
        network_access: false,
      },
      "workspace-write-network" => Self {
        mode: CodexSandboxMode::WorkspaceWrite,
        network_access: true,
      },
      "external-sandbox" => Self {
        mode: CodexSandboxMode::ExternalSandbox,
        network_access: false,
      },
      "external-sandbox-network" => Self {
        mode: CodexSandboxMode::ExternalSandbox,
        network_access: true,
      },
      _ => return None,
    };

    Some(parsed)
  }

  pub fn storage_text(&self) -> String {
    self.summary_text()
  }
}
