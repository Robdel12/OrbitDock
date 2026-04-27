use super::{
  build_hook_body, normalize_client_server_url, normalize_server_url, plan_forwarded_hook,
  resolve_hook_target_with_persisted, HookForwardType, HookTransportConfig,
};

#[test]
fn build_hook_body_injects_type() {
  let payload = r#"{"session_id":"abc","cwd":"/tmp"}"#;
  let body = build_hook_body(HookForwardType::StatusEvent, payload).expect("build hook body");
  let value: serde_json::Value = serde_json::from_str(&body).expect("parse body");
  assert_eq!(
    value.get("type").and_then(|v| v.as_str()),
    Some("claude_status_event")
  );
}

#[test]
fn build_hook_body_keeps_existing_terminal_fields() {
  let payload = r#"{
        "session_id":"abc",
        "cwd":"/tmp",
        "terminal_session_id":"my-session",
        "terminal_app":"my-term"
      }"#;
  let body = build_hook_body(HookForwardType::SessionStart, payload).expect("build hook body");
  let value: serde_json::Value = serde_json::from_str(&body).expect("parse body");
  assert_eq!(
    value.get("terminal_session_id").and_then(|v| v.as_str()),
    Some("my-session")
  );
  assert_eq!(
    value.get("terminal_app").and_then(|v| v.as_str()),
    Some("my-term")
  );
}

#[test]
fn normalize_server_url_trims_and_defaults_empty_values() {
  assert_eq!(
    normalize_server_url(" http://127.0.0.1:4000/ "),
    "http://127.0.0.1:4000"
  );
  assert_eq!(normalize_server_url("   "), "http://127.0.0.1:4000");
}

#[test]
fn normalize_client_server_url_rewrites_wildcard_hosts_to_loopback() {
  assert_eq!(
    normalize_client_server_url("http://0.0.0.0:4000/"),
    "http://127.0.0.1:4000"
  );
  assert_eq!(
    normalize_client_server_url("http://[::]:4000/"),
    "http://[::1]:4000"
  );
}

#[test]
fn resolve_hook_target_prefers_explicit_values_over_persisted_config() {
  let persisted = HookTransportConfig {
    server_url: "http://persisted:4000".to_string(),
    auth_token_enc: None,
    auth_token: Some("persisted-token".to_string()),
  };

  let explicit = resolve_hook_target_with_persisted(
    Some("http://explicit:4000/"),
    Some("  explicit-token  "),
    Some(&persisted),
  )
  .expect("resolve explicit target");
  let persisted_only = resolve_hook_target_with_persisted(None, None, Some(&persisted))
    .expect("resolve persisted target");

  assert_eq!(explicit.server_url, "http://explicit:4000");
  assert_eq!(explicit.auth_token.as_deref(), Some("explicit-token"));
  assert_eq!(persisted_only.server_url, "http://persisted:4000");
  assert_eq!(
    persisted_only.auth_token.as_deref(),
    Some("persisted-token")
  );
}

#[test]
fn forwarded_hook_plan_combines_target_resolution_and_payload_injection() {
  let payload = r#"{"session_id":"abc","cwd":"/tmp"}"#;
  let plan = plan_forwarded_hook(
    HookForwardType::ToolEvent,
    payload,
    Some("http://example.com/"),
    Some("token-123"),
    None,
  )
  .expect("plan forwarded hook");
  let value: serde_json::Value = serde_json::from_str(&plan.body).expect("parse planned hook body");

  assert_eq!(plan.target.server_url, "http://example.com");
  assert_eq!(plan.target.auth_token.as_deref(), Some("token-123"));
  assert_eq!(
    value.get("type").and_then(|value| value.as_str()),
    Some("claude_tool_event")
  );
}
