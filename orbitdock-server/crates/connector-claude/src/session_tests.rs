use super::should_remove_shadow_runtime_session;

#[test]
fn shadow_cleanup_skips_owning_session_id() {
  assert!(!should_remove_shadow_runtime_session(
    "owning-session",
    "owning-session"
  ));
}

#[test]
fn shadow_cleanup_allows_distinct_shadow_session_id() {
  assert!(should_remove_shadow_runtime_session(
    "owning-session",
    "hook-shadow-session"
  ));
}
