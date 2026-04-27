use super::{config_loader_sandbox_mode, override_cwd, requested_sandbox_policy_details};
use orbitdock_protocol::{CodexSandboxMode, CodexSandboxPolicy};

#[test]
fn config_loader_sandbox_mode_preserves_supported_base_values() {
  assert_eq!(
    config_loader_sandbox_mode(Some("workspace-write"), None),
    Some("workspace-write".to_string())
  );
  assert_eq!(
    config_loader_sandbox_mode(Some("danger-full-access"), None),
    Some("danger-full-access".to_string())
  );
}

#[test]
fn config_loader_sandbox_mode_strips_network_suffixes() {
  assert_eq!(
    config_loader_sandbox_mode(Some("workspace-write-network"), None),
    Some("workspace-write".to_string())
  );
  assert_eq!(
    config_loader_sandbox_mode(Some("read-only-network"), None),
    Some("read-only".to_string())
  );
}

#[test]
fn config_loader_sandbox_mode_omits_external_sandbox() {
  assert_eq!(
    config_loader_sandbox_mode(Some("external-sandbox"), None),
    None
  );
  assert_eq!(
    config_loader_sandbox_mode(Some("external-sandbox-network"), None),
    None
  );
}

#[test]
fn requested_sandbox_policy_details_prefer_explicit_details() {
  let details = CodexSandboxPolicy {
    mode: CodexSandboxMode::ExternalSandbox,
    network_access: true,
  };
  assert_eq!(
    requested_sandbox_policy_details(Some("workspace-write"), Some(&details)),
    Some(details)
  );
}

#[test]
fn override_cwd_uses_session_workspace_for_runtime_overrides() {
  assert_eq!(
    override_cwd(" /Users/robertdeluca/Developer/OrbitDock "),
    Some(std::path::PathBuf::from(
      "/Users/robertdeluca/Developer/OrbitDock"
    ))
  );
  assert_eq!(override_cwd("  "), None);
}
