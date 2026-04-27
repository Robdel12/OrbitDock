use super::*;

#[test]
fn new_id_has_od_prefix() {
  let id = new_id();
  assert!(id.starts_with("od-"), "expected od- prefix, got: {id}");
}

#[test]
fn new_session_id_has_od_prefix() {
  let id = new_session_id();
  assert!(id.starts_with("od-"), "expected od- prefix, got: {id}");
}

#[test]
fn is_orbitdock_id_classifies_correctly() {
  assert!(is_orbitdock_id("od-550e8400-e29b-41d4-a716-446655440000"));
  assert!(!is_orbitdock_id("550e8400-e29b-41d4-a716-446655440000"));
  assert!(!is_orbitdock_id(""));
}

#[test]
fn is_provider_id_classifies_correctly() {
  assert!(is_provider_id("550e8400-e29b-41d4-a716-446655440000"));
  assert!(is_provider_id("some-thread-id"));
  assert!(!is_provider_id("od-550e8400-e29b-41d4-a716-446655440000"));
  assert!(!is_provider_id(""));
}

#[test]
fn provider_session_id_rejects_od_prefix() {
  assert!(ProviderSessionId::new("od-abc123").is_none());
}

#[test]
fn provider_session_id_rejects_empty() {
  assert!(ProviderSessionId::new("").is_none());
}

#[test]
fn provider_session_id_accepts_plain_uuid() {
  let id = ProviderSessionId::new("550e8400-e29b-41d4-a716-446655440000");
  assert!(id.is_some());
  assert_eq!(id.unwrap().as_str(), "550e8400-e29b-41d4-a716-446655440000");
}

#[test]
fn provider_session_id_display() {
  let id = ProviderSessionId::new("abc-123").unwrap();
  assert_eq!(format!("{id}"), "abc-123");
}
