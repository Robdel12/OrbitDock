use std::{collections::HashSet, sync::Arc, time::Duration};

use orbitdock_connector_claude::session::ClaudeAction;
use orbitdock_connector_core::ConnectorError;
use orbitdock_protocol::{PermissionRule, SessionPermissionRules};
use tokio::sync::oneshot;
use tracing::info;

use crate::runtime::session_registry::SessionRegistry;

pub async fn try_get_settings_from_cli(
  session_id: &str,
  state: &Arc<SessionRegistry>,
) -> Option<SessionPermissionRules> {
  let tx = state.get_claude_action_tx(session_id)?;
  let (reply_tx, reply_rx) = oneshot::channel::<Result<serde_json::Value, ConnectorError>>();

  tx.send(ClaudeAction::GetSettings { reply: reply_tx })
    .await
    .ok()?;

  let val: serde_json::Value = tokio::time::timeout(Duration::from_secs(10), reply_rx)
    .await
    .ok()?
    .ok()?
    .ok()?;

  if val.get("subtype").and_then(|subtype| subtype.as_str()) == Some("error") {
    info!(session_id = %session_id, "get_settings unsupported by CLI, falling back to disk");
    return None;
  }

  Some(parse_permissions_from_value(&val))
}

fn parse_permissions_from_value(data: &serde_json::Value) -> SessionPermissionRules {
  let permissions = data
    .get("response")
    .and_then(|response| response.get("effective"))
    .and_then(|effective| effective.get("permissions"))
    .or_else(|| {
      data
        .get("effective")
        .and_then(|effective| effective.get("permissions"))
    })
    .or_else(|| data.get("permissions"));

  let rules = collect_permission_rules(permissions);
  let additional_directories = permissions
    .and_then(|perms| {
      perms
        .get("additionalDirectories")
        .or_else(|| perms.get("additional_directories"))
    })
    .and_then(|value| value.as_array())
    .map(|arr| {
      arr
        .iter()
        .filter_map(|value| value.as_str().map(String::from))
        .collect()
    });

  let permission_mode = permissions
    .and_then(|perms| {
      perms
        .get("defaultMode")
        .or_else(|| perms.get("default_mode"))
    })
    .and_then(|value| value.as_str())
    .map(String::from);

  SessionPermissionRules::Claude {
    permission_mode,
    rules,
    additional_directories,
  }
}

pub fn collect_permission_rules(permissions: Option<&serde_json::Value>) -> Vec<PermissionRule> {
  let mut rules = Vec::new();
  let mut seen = HashSet::new();

  if let Some(perms) = permissions {
    for (behavior, key) in [("allow", "allow"), ("deny", "deny"), ("ask", "ask")] {
      if let Some(arr) = perms.get(key).and_then(|value| value.as_array()) {
        for rule_val in arr {
          if let Some(pattern) = rule_val.as_str() {
            let dedupe_key = format!("{behavior}:{pattern}");
            if seen.insert(dedupe_key) {
              rules.push(PermissionRule {
                pattern: pattern.to_string(),
                behavior: behavior.to_string(),
              });
            }
          }
        }
      }
    }
  }

  rules
}

#[cfg(test)]
mod tests {
  use super::collect_permission_rules;
  use serde_json::json;

  #[test]
  fn collect_permission_rules_dedupes_and_preserves_behavior_order() {
    let permissions = json!({
      "allow": ["git status", "git status"],
      "deny": ["git status", "rm -rf", "rm -rf"],
      "ask": ["deploy", "deploy"],
    });

    let rules = collect_permission_rules(Some(&permissions));

    assert_eq!(rules.len(), 4);
    assert_eq!(rules[0].pattern, "git status");
    assert_eq!(rules[0].behavior, "allow");
    assert_eq!(rules[1].pattern, "git status");
    assert_eq!(rules[1].behavior, "deny");
    assert_eq!(rules[2].pattern, "rm -rf");
    assert_eq!(rules[2].behavior, "deny");
    assert_eq!(rules[3].pattern, "deploy");
    assert_eq!(rules[3].behavior, "ask");
  }
}
