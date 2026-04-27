use serde_json::json;

use super::parse_network_policy_amendment;

#[test]
fn parses_nested_network_policy_amendment() {
  let input = json!({
    "network_policy_amendment": {
      "host": "api.github.com",
      "action": "allow"
    }
  });
  let parsed = parse_network_policy_amendment(Some(&input))
    .expect("parse result")
    .expect("amendment");
  assert_eq!(parsed.host, "api.github.com");
  assert_eq!(
    serde_json::to_value(parsed.action).expect("serialize action"),
    json!("allow")
  );
}

#[test]
fn rejects_unknown_network_policy_action() {
  let input = json!({
    "host": "api.github.com",
    "action": "approve"
  });
  let parsed = parse_network_policy_amendment(Some(&input));
  assert_eq!(parsed, Err("invalid_network_policy_action"));
}
