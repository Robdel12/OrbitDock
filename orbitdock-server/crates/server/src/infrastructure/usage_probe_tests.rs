use super::*;

#[test]
fn maps_codex_rate_limit_reached_type_from_app_server() {
  let value = AppServerRateLimitReachedType::WorkspaceMemberUsageLimitReached;

  assert_eq!(
    app_server_rate_limit_reached_type(value),
    CodexRateLimitReachedType::WorkspaceMemberUsageLimitReached
  );
}

#[test]
fn maps_codex_rate_limit_window_from_app_server() {
  let value = AppServerRateLimitWindow {
    used_percent: 42,
    window_duration_mins: Some(300),
    resets_at: Some(1_710_000_000),
  };

  let mapped = app_server_codex_limit(Some(value)).expect("rate limit window");

  assert_eq!(mapped.used_percent, 42.0);
  assert_eq!(mapped.window_duration_mins, 300);
  assert_eq!(mapped.resets_at_unix, 1_710_000_000.0);
}

#[test]
fn defaults_missing_codex_rate_limit_window_fields() {
  let value = AppServerRateLimitWindow {
    used_percent: 7,
    window_duration_mins: None,
    resets_at: None,
  };

  let mapped = app_server_codex_limit(Some(value)).expect("rate limit window");

  assert_eq!(mapped.used_percent, 7.0);
  assert_eq!(mapped.window_duration_mins, 0);
  assert_eq!(mapped.resets_at_unix, 0.0);
}
