use codex_protocol::protocol::{
  AskForApproval, GranularApprovalConfig, NetworkAccess, SandboxPolicy,
};
use orbitdock_protocol::{CodexApprovalPolicy, CodexSandboxMode, CodexSandboxPolicy};

fn reject_policy() -> AskForApproval {
  AskForApproval::Granular(GranularApprovalConfig {
    sandbox_approval: false,
    rules: false,
    skill_approval: false,
    request_permissions: false,
    mcp_elicitations: false,
  })
}

fn read_only_sandbox_policy(network_access: bool) -> SandboxPolicy {
  SandboxPolicy::ReadOnly {
    access: Default::default(),
    network_access,
  }
}

fn workspace_write_sandbox_policy(network_access: bool) -> SandboxPolicy {
  SandboxPolicy::WorkspaceWrite {
    writable_roots: Vec::new(),
    read_only_access: Default::default(),
    network_access,
    exclude_tmpdir_env_var: false,
    exclude_slash_tmp: false,
  }
}

pub(crate) fn parse_approval_policy(value: Option<&str>) -> Result<Option<AskForApproval>, String> {
  let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) else {
    return Ok(None);
  };

  let parsed = match value {
    "untrusted" | "unless-allow-listed" => AskForApproval::UnlessTrusted,
    "on-failure" => AskForApproval::OnFailure,
    "on-request" => AskForApproval::OnRequest,
    "reject" => reject_policy(),
    "never" => AskForApproval::Never,
    other => {
      return Err(format!(
        "unsupported approval policy `{other}`; expected untrusted, on-failure, on-request, reject, or never"
      ));
    }
  };

  Ok(Some(parsed))
}

pub(crate) fn parse_approval_policy_with_details(
  value: Option<&str>,
  details: Option<&CodexApprovalPolicy>,
) -> Result<Option<AskForApproval>, String> {
  if let Some(details) = details {
    let parsed = match details {
      CodexApprovalPolicy::Mode(mode) => match mode {
        orbitdock_protocol::CodexApprovalMode::Untrusted => AskForApproval::UnlessTrusted,
        orbitdock_protocol::CodexApprovalMode::OnFailure => AskForApproval::OnFailure,
        orbitdock_protocol::CodexApprovalMode::OnRequest => AskForApproval::OnRequest,
        orbitdock_protocol::CodexApprovalMode::Never => AskForApproval::Never,
      },
      CodexApprovalPolicy::Granular { granular } => {
        AskForApproval::Granular(GranularApprovalConfig {
          sandbox_approval: granular.sandbox_approval,
          rules: granular.rules,
          skill_approval: granular.skill_approval,
          request_permissions: granular.request_permissions,
          mcp_elicitations: granular.mcp_elicitations,
        })
      }
    };
    return Ok(Some(parsed));
  }

  parse_approval_policy(value)
}

pub(crate) fn parse_sandbox_policy(value: Option<&str>) -> Result<Option<SandboxPolicy>, String> {
  let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) else {
    return Ok(None);
  };

  let parsed = match value {
    "danger-full-access" => SandboxPolicy::DangerFullAccess,
    "read-only" => read_only_sandbox_policy(false),
    "read-only-network" => read_only_sandbox_policy(true),
    "workspace-write" => workspace_write_sandbox_policy(false),
    "workspace-write-network" => workspace_write_sandbox_policy(true),
    "external-sandbox" => SandboxPolicy::ExternalSandbox {
      network_access: NetworkAccess::Restricted,
    },
    "external-sandbox-network" => SandboxPolicy::ExternalSandbox {
      network_access: NetworkAccess::Enabled,
    },
    other => {
      return Err(format!(
        "unsupported sandbox mode `{other}`; expected danger-full-access, read-only, workspace-write, or external-sandbox (+ optional -network suffix)"
      ));
    }
  };

  Ok(Some(parsed))
}

pub(crate) fn parse_sandbox_policy_with_details(
  value: Option<&str>,
  details: Option<&CodexSandboxPolicy>,
) -> Result<Option<SandboxPolicy>, String> {
  if let Some(details) = details {
    let parsed = match details.mode {
      CodexSandboxMode::DangerFullAccess => SandboxPolicy::DangerFullAccess,
      CodexSandboxMode::ReadOnly => read_only_sandbox_policy(details.network_access),
      CodexSandboxMode::WorkspaceWrite => workspace_write_sandbox_policy(details.network_access),
      CodexSandboxMode::ExternalSandbox => SandboxPolicy::ExternalSandbox {
        network_access: if details.network_access {
          NetworkAccess::Enabled
        } else {
          NetworkAccess::Restricted
        },
      },
    };
    return Ok(Some(parsed));
  }

  parse_sandbox_policy(value)
}

#[cfg(test)]
mod tests {
  use super::{
    parse_approval_policy, parse_approval_policy_with_details, parse_sandbox_policy,
    parse_sandbox_policy_with_details,
  };
  use codex_protocol::protocol::{AskForApproval, SandboxPolicy};

  #[test]
  fn approval_policy_reject_maps_to_granular() {
    let parsed = parse_approval_policy(Some("reject")).expect("parse reject");
    assert!(matches!(parsed, Some(AskForApproval::Granular(_))));
  }

  #[test]
  fn approval_policy_unknown_rejected() {
    assert!(parse_approval_policy(Some("strict")).is_err());
  }

  #[test]
  fn workspace_write_network_mode_is_supported() {
    let parsed = parse_sandbox_policy(Some("workspace-write-network"))
      .expect("parse workspace-write-network")
      .expect("sandbox policy");
    let is_network_enabled = match parsed {
      SandboxPolicy::WorkspaceWrite { network_access, .. } => network_access,
      _ => false,
    };
    assert!(is_network_enabled);
  }

  #[test]
  fn external_sandbox_mode_is_supported() {
    let parsed = parse_sandbox_policy(Some("external-sandbox"))
      .expect("parse external-sandbox")
      .expect("sandbox policy");
    assert!(matches!(parsed, SandboxPolicy::ExternalSandbox { .. }));
  }

  #[test]
  fn approval_policy_details_are_preferred_over_summary_string() {
    let details =
      orbitdock_protocol::CodexApprovalPolicy::Mode(orbitdock_protocol::CodexApprovalMode::Never);
    let parsed = parse_approval_policy_with_details(Some("on-request"), Some(&details))
      .expect("parse with details");
    assert!(matches!(parsed, Some(AskForApproval::Never)));
  }

  #[test]
  fn sandbox_policy_details_are_preferred_over_summary_string() {
    let details = orbitdock_protocol::CodexSandboxPolicy {
      mode: orbitdock_protocol::CodexSandboxMode::ReadOnly,
      network_access: true,
    };
    let parsed = parse_sandbox_policy_with_details(Some("workspace-write"), Some(&details))
      .expect("parse with details")
      .expect("sandbox policy");
    let is_network_enabled = match parsed {
      SandboxPolicy::ReadOnly { network_access, .. } => network_access,
      _ => false,
    };
    assert!(is_network_enabled);
  }
}
