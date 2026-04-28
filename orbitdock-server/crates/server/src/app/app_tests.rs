use super::resolve_workspace_provider_kind;
use orbitdock_protocol::WorkspaceProviderKind;

#[test]
fn workspace_provider_override_wins_over_persisted_value() {
  let resolved = resolve_workspace_provider_kind(
    Some(WorkspaceProviderKind::Local),
    Some("local".to_string()),
  )
  .expect("workspace provider should resolve");

  assert_eq!(resolved, WorkspaceProviderKind::Local);
}

#[test]
fn workspace_provider_defaults_to_local_when_missing() {
  let resolved =
    resolve_workspace_provider_kind(None, None).expect("workspace provider should default");

  assert_eq!(resolved, WorkspaceProviderKind::Local);
}

#[test]
fn invalid_persisted_workspace_provider_value_errors() {
  let error = resolve_workspace_provider_kind(None, Some("bogus".to_string()))
    .expect_err("invalid workspace provider should fail");

  assert!(error.to_string().contains("bogus"));
}
