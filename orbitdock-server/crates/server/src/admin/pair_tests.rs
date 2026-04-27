use super::{build_pairing_info, TokenState};

#[test]
fn pairing_info_marks_tls_urls() {
  let info = build_pairing_info(
    "https://dock.example.com:4000/",
    &TokenState {
      env_token_prefix: None,
      active_db_tokens: 0,
    },
  );

  assert_eq!(info.base_url, "https://dock.example.com:4000");
  assert_eq!(info.pair_url, "orbitdock://dock.example.com:4000?tls=1");
  assert!(info.uses_tls);
  assert!(!info.requires_separate_token);
}

#[test]
fn pairing_info_requires_token_when_db_tokens_exist() {
  let info = build_pairing_info(
    "http://dock.example.com:4000",
    &TokenState {
      env_token_prefix: None,
      active_db_tokens: 2,
    },
  );

  assert_eq!(info.pair_url, "orbitdock://dock.example.com:4000");
  assert_eq!(info.token_summary, "required (2 active database token(s))");
  assert!(info.requires_separate_token);
  assert_eq!(
    info.hook_install_command,
    "orbitdock install-hooks --server-url http://dock.example.com:4000"
  );
}

#[test]
fn pairing_info_shows_env_token_prefix() {
  let info = build_pairing_info(
    "http://127.0.0.1:4000",
    &TokenState {
      env_token_prefix: Some("abcd1234".to_string()),
      active_db_tokens: 0,
    },
  );

  assert_eq!(info.token_summary, "abcd1234...");
  assert!(info.requires_separate_token);
}
