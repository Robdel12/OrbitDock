use super::{app_server_sandbox_mode, parse_approvals_reviewer, parse_service_tier_override};
use codex_app_server_protocol::SandboxMode as AppServerSandboxMode;
use orbitdock_protocol::{CodexSandboxMode, CodexSandboxPolicy};

#[test]
fn app_server_sandbox_mode_prefers_explicit_policy_details() {
  let details = CodexSandboxPolicy {
    mode: CodexSandboxMode::ExternalSandbox,
    network_access: true,
  };

  assert_eq!(
    app_server_sandbox_mode(Some("workspace-write"), Some(&details)),
    Some(AppServerSandboxMode::WorkspaceWrite)
  );
}

#[test]
fn parse_approvals_reviewer_recognizes_auto_review_aliases() {
  assert_eq!(
    parse_approvals_reviewer(Some("guardian_subagent")),
    Some(codex_protocol::config_types::ApprovalsReviewer::AutoReview)
  );
  assert_eq!(
    parse_approvals_reviewer(Some("auto_review")),
    Some(codex_protocol::config_types::ApprovalsReviewer::AutoReview)
  );
}

#[test]
fn parse_service_tier_override_maps_known_values() {
  assert_eq!(
    parse_service_tier_override(Some("fast")),
    Some(Some(codex_protocol::config_types::ServiceTier::Fast))
  );
  assert_eq!(parse_service_tier_override(Some("off")), Some(None));
}
