use serde_json::Value;

use super::{build_usage_json_response, ClaudeUsageResponse, CodexUsageResponse, ProviderFilter};

#[test]
fn usage_json_response_includes_requested_provider() {
  let response = build_usage_json_response(
    Some(&ProviderFilter::Codex),
    Some(CodexUsageResponse {
      usage: None,
      error_info: None,
    }),
    None,
  );
  let value = serde_json::to_value(&response).expect("serialize usage response");

  assert_eq!(value["kind"], Value::String("usage".to_string()));
  assert_eq!(
    value["requested_provider"],
    Value::String("codex".to_string())
  );
  assert!(value.get("codex").is_some());
  assert!(value.get("claude").is_none());
}

#[test]
fn usage_json_response_combines_multiple_providers() {
  let response = build_usage_json_response(
    None,
    Some(CodexUsageResponse {
      usage: None,
      error_info: None,
    }),
    Some(ClaudeUsageResponse {
      usage: None,
      error_info: None,
    }),
  );
  let value = serde_json::to_value(&response).expect("serialize usage response");

  assert!(value.get("requested_provider").is_none());
  assert_eq!(value["summaries"].as_array().map(Vec::len), Some(2));
}
