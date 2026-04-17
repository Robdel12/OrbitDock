use std::{collections::HashSet, sync::Arc};

use axum::{http::StatusCode, Json};
use orbitdock_protocol::{PermissionRule, SessionPermissionRules};

use crate::runtime::session_registry::SessionRegistry;
use crate::transport::http::ApiErrorResponse;

pub fn resolve_project_path_for_claude(
  session_id: &str,
  state: &Arc<SessionRegistry>,
) -> Result<String, (StatusCode, Json<ApiErrorResponse>)> {
  if state.get_claude_action_tx(session_id).is_none() {
    return Err((
      StatusCode::NOT_FOUND,
      Json(ApiErrorResponse {
        code: "not_found",
        error: format!("No active Claude session found for {}", session_id),
      }),
    ));
  }

  state
    .get_session(session_id)
    .map(|actor| actor.snapshot().project_path.clone())
    .ok_or_else(|| {
      (
        StatusCode::NOT_FOUND,
        Json(ApiErrorResponse {
          code: "not_found",
          error: format!("Session not found: {}", session_id),
        }),
      )
    })
}

pub fn settings_path_for_scope(scope: &str, project_path: &str) -> String {
  if scope == "global" {
    let home = std::env::var("HOME").unwrap_or_default();
    format!("{home}/.claude/settings.local.json")
  } else {
    format!("{project_path}/.claude/settings.local.json")
  }
}

pub fn modify_settings_file(
  path: &str,
  mutate: impl FnOnce(&mut serde_json::Map<String, serde_json::Value>),
) -> Result<(), (StatusCode, Json<ApiErrorResponse>)> {
  let mut root: serde_json::Value = if let Ok(contents) = std::fs::read_to_string(path) {
    serde_json::from_str(&contents).unwrap_or_else(|_| serde_json::json!({}))
  } else {
    serde_json::json!({})
  };

  if root.get("permissions").is_none() {
    root
      .as_object_mut()
      .unwrap()
      .insert("permissions".into(), serde_json::json!({}));
  }

  let perms = root
    .get_mut("permissions")
    .and_then(|value| value.as_object_mut())
    .unwrap();

  mutate(perms);

  if let Some(parent) = std::path::Path::new(path).parent() {
    let _ = std::fs::create_dir_all(parent);
  }

  let json_str = serde_json::to_string_pretty(&root).map_err(|error| {
    (
      StatusCode::INTERNAL_SERVER_ERROR,
      Json(ApiErrorResponse {
        code: "serialize_error",
        error: format!("Failed to serialize settings: {}", error),
      }),
    )
  })?;

  std::fs::write(path, json_str).map_err(|error| {
    (
      StatusCode::INTERNAL_SERVER_ERROR,
      Json(ApiErrorResponse {
        code: "write_error",
        error: format!("Failed to write settings file: {}", error),
      }),
    )
  })?;

  Ok(())
}

pub fn read_claude_settings_from_disk(project_path: Option<&str>) -> SessionPermissionRules {
  let home = std::env::var("HOME").unwrap_or_default();
  let global_path = format!("{home}/.claude/settings.local.json");

  let mut all_allow = Vec::new();
  let mut all_deny = Vec::new();
  let mut all_ask = Vec::new();
  let mut additional_dirs = Vec::new();
  let mut permission_mode = None;

  collect_permissions_from_file(
    &global_path,
    &mut all_allow,
    &mut all_deny,
    &mut all_ask,
    &mut additional_dirs,
    &mut permission_mode,
  );

  if let Some(project) = project_path {
    let project_settings = format!("{project}/.claude/settings.local.json");
    collect_permissions_from_file(
      &project_settings,
      &mut all_allow,
      &mut all_deny,
      &mut all_ask,
      &mut additional_dirs,
      &mut permission_mode,
    );
  }

  let rules = build_rules(all_allow, all_deny, all_ask);

  SessionPermissionRules::Claude {
    permission_mode,
    rules,
    additional_directories: if additional_dirs.is_empty() {
      None
    } else {
      Some(additional_dirs)
    },
  }
}

fn collect_permissions_from_file(
  path: &str,
  allow: &mut Vec<String>,
  deny: &mut Vec<String>,
  ask: &mut Vec<String>,
  dirs: &mut Vec<String>,
  mode: &mut Option<String>,
) {
  if let Ok(contents) = std::fs::read_to_string(path) {
    if let Ok(val) = serde_json::from_str::<serde_json::Value>(&contents) {
      collect_permissions(&val, allow, deny, ask, dirs, mode);
    }
  }
}

fn build_rules(
  all_allow: Vec<String>,
  all_deny: Vec<String>,
  all_ask: Vec<String>,
) -> Vec<PermissionRule> {
  let mut rules = Vec::new();
  let mut seen = HashSet::new();

  append_rules(&mut rules, &mut seen, "allow", all_allow);
  append_rules(&mut rules, &mut seen, "deny", all_deny);
  append_rules(&mut rules, &mut seen, "ask", all_ask);

  rules
}

fn append_rules(
  rules: &mut Vec<PermissionRule>,
  seen: &mut HashSet<String>,
  behavior: &str,
  patterns: Vec<String>,
) {
  for pattern in patterns {
    let key = format!("{behavior}:{pattern}");
    if seen.insert(key) {
      rules.push(PermissionRule {
        pattern,
        behavior: behavior.into(),
      });
    }
  }
}

fn collect_permissions(
  val: &serde_json::Value,
  allow: &mut Vec<String>,
  deny: &mut Vec<String>,
  ask: &mut Vec<String>,
  dirs: &mut Vec<String>,
  mode: &mut Option<String>,
) {
  let perms = val
    .get("permissions")
    .or_else(|| val.get("allow").map(|_| val));
  let Some(perms) = perms else {
    return;
  };

  for (target, key) in [
    (&mut *allow, "allow"),
    (&mut *deny, "deny"),
    (&mut *ask, "ask"),
  ] {
    if let Some(arr) = perms.get(key).and_then(|value| value.as_array()) {
      for item in arr {
        if let Some(entry) = item.as_str() {
          target.push(entry.to_string());
        }
      }
    }
  }

  if let Some(arr) = perms
    .get("additionalDirectories")
    .or_else(|| perms.get("additional_directories"))
    .and_then(|value| value.as_array())
  {
    for item in arr {
      if let Some(entry) = item.as_str() {
        dirs.push(entry.to_string());
      }
    }
  }

  if let Some(default_mode) = perms
    .get("defaultMode")
    .or_else(|| perms.get("default_mode"))
    .and_then(|value| value.as_str())
  {
    *mode = Some(default_mode.to_string());
  }
}
