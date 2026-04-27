use super::*;

#[test]
fn new_service_defers_app_server_start_until_used() {
  let (list_tx, _) = broadcast::channel(1);
  let service =
    CodexAuthService::new_with_auth_home(list_tx, PathBuf::from("/tmp/orbitdock-codex-auth-tests"));

  assert_eq!(
    service.auth_home,
    PathBuf::from("/tmp/orbitdock-codex-auth-tests")
  );
}

#[test]
fn new_with_file_store_uses_supplied_cwd_for_app_server_bootstrap() {
  let (list_tx, _) = broadcast::channel(1);
  let service =
    CodexAuthService::new_with_file_store(list_tx, PathBuf::from("/tmp/orbitdock-codex-tests"));

  assert_eq!(
    service.auth_home,
    PathBuf::from("/tmp/orbitdock-codex-tests")
  );
}
