use super::*;
use orbitdock_connector_claude::session::ClaudeAction;
use orbitdock_connector_core::ConnectorError;
use orbitdock_protocol::{PermissionRule, SessionPermissionRules};
use tokio::sync::oneshot;
use tracing::info;

#[derive(Debug, Serialize)]
pub struct PermissionRulesResponse {
    pub session_id: String,
    pub rules: SessionPermissionRules,
}

#[derive(Debug, Deserialize)]
pub struct ModifyPermissionRuleRequest {
    pub pattern: String,
    pub behavior: String,
    #[serde(default = "default_scope")]
    pub scope: String,
}

#[derive(Debug, Serialize)]
pub struct ModifyPermissionRuleResponse {
    pub ok: bool,
}

pub async fn get_permission_rules(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<PermissionRulesResponse> {
    if state.get_claude_action_tx(&session_id).is_some() {
        let rules = try_get_settings_from_cli(&session_id, &state)
            .await
            .unwrap_or_else(|| {
                let project_path = state
                    .get_session(&session_id)
                    .map(|actor| actor.snapshot().project_path.clone());
                read_claude_settings_from_disk(project_path.as_deref())
            });

        return Ok(Json(PermissionRulesResponse { session_id, rules }));
    }

    if state.get_codex_action_tx(&session_id).is_some() {
        if let Some(actor) = state.get_session(&session_id) {
            let snap = actor.snapshot();
            let rules = SessionPermissionRules::Codex {
                approval_policy: snap.approval_policy.clone(),
                approval_policy_details: snap.approval_policy_details.clone(),
                sandbox_mode: snap.sandbox_mode.clone(),
            };
            return Ok(Json(PermissionRulesResponse { session_id, rules }));
        }
    }

    Err((
        StatusCode::NOT_FOUND,
        Json(ApiErrorResponse {
            code: "not_found",
            error: format!("No active direct session found for {}", session_id),
        }),
    ))
}

pub async fn add_permission_rule(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(req): Json<ModifyPermissionRuleRequest>,
) -> ApiResult<ModifyPermissionRuleResponse> {
    let project_path = resolve_project_path_for_claude(&session_id, &state)?;

    let settings_path = if req.scope == "global" {
        let home = std::env::var("HOME").unwrap_or_default();
        format!("{}/.claude/settings.local.json", home)
    } else {
        format!("{}/.claude/settings.local.json", project_path)
    };

    modify_settings_file(&settings_path, |perms| {
        let arr = perms
            .entry(&req.behavior)
            .or_insert_with(|| serde_json::Value::Array(Vec::new()));
        if let Some(list) = arr.as_array_mut() {
            let pattern_val = serde_json::Value::String(req.pattern.clone());
            if !list.contains(&pattern_val) {
                list.push(pattern_val);
            }
        }
    })?;

    Ok(Json(ModifyPermissionRuleResponse { ok: true }))
}

pub async fn remove_permission_rule(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(req): Json<ModifyPermissionRuleRequest>,
) -> ApiResult<ModifyPermissionRuleResponse> {
    let project_path = resolve_project_path_for_claude(&session_id, &state)?;

    let settings_path = if req.scope == "global" {
        let home = std::env::var("HOME").unwrap_or_default();
        format!("{}/.claude/settings.local.json", home)
    } else {
        format!("{}/.claude/settings.local.json", project_path)
    };

    modify_settings_file(&settings_path, |perms| {
        if let Some(arr) = perms
            .get_mut(&req.behavior)
            .and_then(|value| value.as_array_mut())
        {
            let pattern_val = serde_json::Value::String(req.pattern.clone());
            arr.retain(|value| value != &pattern_val);
        }
    })?;

    Ok(Json(ModifyPermissionRuleResponse { ok: true }))
}

fn default_scope() -> String {
    "project".into()
}

fn resolve_project_path_for_claude(
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

fn modify_settings_file(
    path: &str,
    mutate: impl FnOnce(&mut serde_json::Map<String, serde_json::Value>),
) -> Result<(), (StatusCode, Json<ApiErrorResponse>)> {
    let mut root: serde_json::Value = if let Ok(contents) = std::fs::read_to_string(path) {
        serde_json::from_str(&contents).unwrap_or_else(|_| serde_json::json!({}))
    } else {
        serde_json::json!({})
    };

    if root.get("permissions").is_none() {
        root.as_object_mut()
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

async fn try_get_settings_from_cli(
    session_id: &str,
    state: &Arc<SessionRegistry>,
) -> Option<SessionPermissionRules> {
    let tx = state.get_claude_action_tx(session_id)?;
    let (reply_tx, reply_rx) = oneshot::channel::<Result<serde_json::Value, ConnectorError>>();

    tx.send(ClaudeAction::GetSettings { reply: reply_tx })
        .await
        .ok()?;

    let val: serde_json::Value = tokio::time::timeout(std::time::Duration::from_secs(10), reply_rx)
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
            data.get("effective")
                .and_then(|effective| effective.get("permissions"))
        })
        .or_else(|| data.get("permissions"));

    let mut rules = Vec::new();

    if let Some(perms) = permissions {
        for (behavior, key) in [("allow", "allow"), ("deny", "deny"), ("ask", "ask")] {
            if let Some(arr) = perms.get(key).and_then(|value| value.as_array()) {
                for rule_val in arr {
                    if let Some(pattern) = rule_val.as_str() {
                        rules.push(PermissionRule {
                            pattern: pattern.to_string(),
                            behavior: behavior.to_string(),
                        });
                    }
                }
            }
        }
    }

    let additional_directories = permissions
        .and_then(|perms| {
            perms
                .get("additionalDirectories")
                .or_else(|| perms.get("additional_directories"))
        })
        .and_then(|value| value.as_array())
        .map(|arr| {
            arr.iter()
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

fn read_claude_settings_from_disk(project_path: Option<&str>) -> SessionPermissionRules {
    let home = std::env::var("HOME").unwrap_or_default();
    let global_path = format!("{}/.claude/settings.local.json", home);

    let mut all_allow: Vec<String> = Vec::new();
    let mut all_deny: Vec<String> = Vec::new();
    let mut all_ask: Vec<String> = Vec::new();
    let mut additional_dirs: Vec<String> = Vec::new();
    let mut permission_mode: Option<String> = None;

    if let Ok(contents) = std::fs::read_to_string(&global_path) {
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(&contents) {
            collect_permissions(
                &val,
                &mut all_allow,
                &mut all_deny,
                &mut all_ask,
                &mut additional_dirs,
                &mut permission_mode,
            );
        }
    }

    if let Some(project) = project_path {
        let project_settings = format!("{}/.claude/settings.local.json", project);
        if let Ok(contents) = std::fs::read_to_string(&project_settings) {
            if let Ok(val) = serde_json::from_str::<serde_json::Value>(&contents) {
                collect_permissions(
                    &val,
                    &mut all_allow,
                    &mut all_deny,
                    &mut all_ask,
                    &mut additional_dirs,
                    &mut permission_mode,
                );
            }
        }
    }

    let mut rules = Vec::new();
    let mut seen = std::collections::HashSet::new();

    for pattern in all_allow {
        if seen.insert(format!("allow:{}", pattern)) {
            rules.push(PermissionRule {
                pattern,
                behavior: "allow".into(),
            });
        }
    }
    for pattern in all_deny {
        if seen.insert(format!("deny:{}", pattern)) {
            rules.push(PermissionRule {
                pattern,
                behavior: "deny".into(),
            });
        }
    }
    for pattern in all_ask {
        if seen.insert(format!("ask:{}", pattern)) {
            rules.push(PermissionRule {
                pattern,
                behavior: "ask".into(),
            });
        }
    }

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

    for (target, key) in [(allow, "allow"), (deny, "deny"), (ask, "ask")] {
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
