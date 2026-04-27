use super::{
  build_doctor_report, classify_auth_token, classify_disk_space_gb, classify_hook_registration,
  classify_hook_transport_config, classify_wal_size, count_registered_hooks, Check,
  HookTransportConfigStatus, Status,
};

#[test]
fn doctor_report_counts_statuses() {
  let report = build_doctor_report(vec![
    Check {
      name: "one",
      status: Status::Pass,
      detail: "ok".to_string(),
    },
    Check {
      name: "two",
      status: Status::Warn,
      detail: "warn".to_string(),
    },
    Check {
      name: "three",
      status: Status::Fail,
      detail: "fail".to_string(),
    },
    Check {
      name: "four",
      status: Status::Pass,
      detail: "ok".to_string(),
    },
  ]);

  assert_eq!(report.passed, 2);
  assert_eq!(report.warned, 1);
  assert_eq!(report.failed, 1);
  assert_eq!(report.checks.len(), 4);
}

#[test]
fn classify_hook_registration_distinguishes_full_partial_and_missing() {
  let pass = classify_hook_registration(15, 15);
  let warn = classify_hook_registration(4, 15);
  let fail = classify_hook_registration(0, 15);

  assert_eq!(pass.status, Status::Pass);
  assert_eq!(warn.status, Status::Warn);
  assert_eq!(fail.status, Status::Fail);
}

#[test]
fn count_registered_hooks_requires_orbitdock_transport_markers() {
  let expected = ["SessionStart", "SessionEnd", "Notification"];
  let full = r#"{"hooks":{"SessionStart":"orbitdock hook-forward","SessionEnd":"orbitdock hook-forward","Notification":"orbitdock hook-forward"}}"#;
  let unrelated =
    r#"{"hooks":{"SessionStart":"python something","SessionEnd":"python something"}}"#;

  assert_eq!(count_registered_hooks(full, &expected), 3);
  assert_eq!(count_registered_hooks(unrelated, &expected), 0);
}

#[test]
fn classify_hook_transport_config_handles_warning_cases() {
  let path = std::path::PathBuf::from("/tmp/hook-forward.json");

  let missing_server_url = classify_hook_transport_config(HookTransportConfigStatus {
    path: &path,
    server_url: None,
    encrypted_token_present: false,
    encrypted_token_decryptable: false,
  });
  assert_eq!(missing_server_url.status, Status::Fail);

  let undecryptable_token = classify_hook_transport_config(HookTransportConfigStatus {
    path: &path,
    server_url: Some("http://127.0.0.1:4000"),
    encrypted_token_present: true,
    encrypted_token_decryptable: false,
  });
  assert_eq!(undecryptable_token.status, Status::Warn);

  let healthy = classify_hook_transport_config(HookTransportConfigStatus {
    path: &path,
    server_url: Some("http://127.0.0.1:4000"),
    encrypted_token_present: true,
    encrypted_token_decryptable: true,
  });
  assert_eq!(healthy.status, Status::Pass);
}

#[test]
fn wal_and_disk_classifiers_apply_thresholds() {
  assert_eq!(classify_wal_size(10).status, Status::Pass);
  assert_eq!(classify_wal_size(60_000).status, Status::Warn);

  assert_eq!(classify_disk_space_gb(0).status, Status::Fail);
  assert_eq!(classify_disk_space_gb(3).status, Status::Warn);
  assert_eq!(classify_disk_space_gb(12).status, Status::Pass);
}

#[test]
fn auth_token_classifier_matches_user_facing_states() {
  let env_only = classify_auth_token(Some("abcd1234"), Ok(0));
  let db_only = classify_auth_token(None, Ok(2));
  let missing = classify_auth_token(None, Ok(0));

  assert_eq!(env_only.status, Status::Pass);
  assert_eq!(db_only.status, Status::Pass);
  assert_eq!(missing.status, Status::Warn);
}
