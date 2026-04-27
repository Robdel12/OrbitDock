use super::{
  command_value_is_orbitdock, entry_contains_orbitdock_command, merge_orbitdock_hooks,
  orbitdock_hook_index, plan_hook_install, HookInstallPlan,
};

fn test_plan() -> HookInstallPlan {
  plan_hook_install(
    Some("http://127.0.0.1:4000"),
    Some("token-123"),
    "\"/usr/local/bin/orbitdock\"",
  )
}

#[test]
fn hook_install_plan_only_requires_token_for_remote_servers() {
  let local = plan_hook_install(
    Some("http://127.0.0.1:4000"),
    None,
    "\"/usr/local/bin/orbitdock\"",
  );
  let remote = plan_hook_install(
    Some("https://orbitdock.example.com"),
    None,
    "\"/usr/local/bin/orbitdock\"",
  );
  let remote_with_explicit_token = plan_hook_install(
    Some("https://orbitdock.example.com"),
    Some("secret"),
    "\"/usr/local/bin/orbitdock\"",
  );

  assert!(!local.auth_token_required);
  assert!(remote.auth_token_required);
  assert!(!remote_with_explicit_token.auth_token_required);
  assert_eq!(
    remote_with_explicit_token.explicit_auth_token.as_deref(),
    Some("secret")
  );
}

#[test]
fn merge_orbitdock_hooks_adds_missing_hook_entries() {
  let merge = merge_orbitdock_hooks(serde_json::json!({}), &test_plan()).unwrap();
  let hooks = merge
    .settings
    .get("hooks")
    .and_then(|value| value.as_object())
    .unwrap();

  assert_eq!(merge.added.len(), super::HOOK_TYPES.len());
  assert!(merge.updated.is_empty());
  assert!(hooks.contains_key("SessionStart"));
  assert!(hooks.contains_key("PermissionRequest"));
}

#[test]
fn merge_orbitdock_hooks_replaces_existing_entry_without_duplication() {
  let existing = serde_json::json!({
      "hooks": {
          "Notification": {
              "command": "hook.sh claude_status_event"
          }
      }
  });

  let merge = merge_orbitdock_hooks(existing, &test_plan()).unwrap();
  let notification = merge
    .settings
    .get("hooks")
    .and_then(|value| value.get("Notification"))
    .and_then(|value| value.as_array())
    .unwrap();

  assert!(merge
    .updated
    .iter()
    .any(|hook| hook == "hooks.Notification"));
  assert_eq!(notification.len(), 1);
  assert!(entry_contains_orbitdock_command(&notification[0]));
}

#[test]
fn merge_orbitdock_hooks_preserves_non_orbitdock_entries_when_adding_new_one() {
  let existing = serde_json::json!({
      "hooks": {
          "Notification": [{
              "hooks": [{
                  "type": "command",
                  "command": "python notify.py",
                  "async": true
              }]
          }]
      }
  });

  let merge = merge_orbitdock_hooks(existing, &test_plan()).unwrap();
  let notification = merge
    .settings
    .get("hooks")
    .and_then(|value| value.get("Notification"))
    .and_then(|value| value.as_array())
    .unwrap();

  assert!(merge.added.iter().any(|hook| hook == "hooks.Notification"));
  assert_eq!(notification.len(), 2);
  assert!(!entry_contains_orbitdock_command(&notification[0]));
  assert!(entry_contains_orbitdock_command(&notification[1]));
}

#[test]
fn orbitdock_command_detection_handles_nested_and_bare_entries() {
  let nested = serde_json::json!({
      "hooks": [{
          "command": "\"/usr/local/bin/orbitdock\" hook-forward claude_status_event"
      }]
  });
  let bare = serde_json::json!({
      "command": "hook.sh claude_status_event"
  });
  let unrelated = serde_json::json!({
      "command": "python notify.py"
  });

  assert!(entry_contains_orbitdock_command(&nested));
  assert!(entry_contains_orbitdock_command(&bare));
  assert!(command_value_is_orbitdock(&bare));
  assert!(!entry_contains_orbitdock_command(&unrelated));
  assert_eq!(orbitdock_hook_index(&[unrelated.clone(), nested]), Some(1));
}
