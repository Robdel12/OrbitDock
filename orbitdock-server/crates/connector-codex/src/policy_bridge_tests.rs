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
