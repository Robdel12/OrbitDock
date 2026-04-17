use std::sync::Arc;

use axum::{
  extract::{Path, State},
  http::StatusCode,
  Json,
};
use orbitdock_protocol::SessionPermissionRules;

use crate::runtime::session_registry::SessionRegistry;
use crate::transport::http::{ApiErrorResponse, ApiResult};

use super::{
  query::try_get_settings_from_cli,
  settings_files::{
    modify_settings_file, read_claude_settings_from_disk, resolve_project_path_for_claude,
    settings_path_for_scope,
  },
  snapshot::load_session_detail_snapshot,
  ModifyPermissionRuleRequest, ModifyPermissionRuleResponse, PermissionRulesResponse,
};

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
        sandbox_policy_details: snap.sandbox_policy_details.clone(),
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
  let settings_path = settings_path_for_scope(&req.scope, &project_path);

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

  Ok(Json(ModifyPermissionRuleResponse {
    ok: true,
    session_detail_snapshot: load_session_detail_snapshot(&state, &session_id).await,
  }))
}

pub async fn remove_permission_rule(
  Path(session_id): Path<String>,
  State(state): State<Arc<SessionRegistry>>,
  Json(req): Json<ModifyPermissionRuleRequest>,
) -> ApiResult<ModifyPermissionRuleResponse> {
  let project_path = resolve_project_path_for_claude(&session_id, &state)?;
  let settings_path = settings_path_for_scope(&req.scope, &project_path);

  modify_settings_file(&settings_path, |perms| {
    if let Some(arr) = perms
      .get_mut(&req.behavior)
      .and_then(|value| value.as_array_mut())
    {
      let pattern_val = serde_json::Value::String(req.pattern.clone());
      arr.retain(|value| value != &pattern_val);
    }
  })?;

  Ok(Json(ModifyPermissionRuleResponse {
    ok: true,
    session_detail_snapshot: load_session_detail_snapshot(&state, &session_id).await,
  }))
}
