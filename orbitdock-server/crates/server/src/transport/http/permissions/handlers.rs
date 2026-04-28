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

#[cfg(test)]
mod tests {
  use std::fs;

  use axum::{extract::Path, extract::State, Json};
  use orbitdock_protocol::{Provider, SessionPermissionRules};
  use serde_json::json;
  use tempfile::TempDir;
  use tokio::sync::mpsc;

  use crate::{
    connectors::claude_session::ClaudeAction,
    domain::sessions::session::SessionHandle,
    infrastructure::persistence::{flush_batch_for_test, PersistCommand},
    transport::http::test_support::{new_persist_test_state, new_test_state},
  };

  use super::{
    add_permission_rule, get_permission_rules, remove_permission_rule, ModifyPermissionRuleRequest,
  };

  fn persist_claude_session(
    db_path: &std::path::PathBuf,
    session_id: &str,
    project_path: &str,
    transcript_path: &str,
  ) {
    flush_batch_for_test(
      db_path,
      vec![PersistCommand::ClaudeSessionUpsert {
        id: session_id.to_string(),
        project_path: project_path.to_string(),
        project_name: Some("orbitdock-api-test".to_string()),
        branch: Some("main".to_string()),
        model: Some("claude-opus-4-1".to_string()),
        context_label: None,
        transcript_path: Some(transcript_path.to_string()),
        source: Some("hook".to_string()),
        agent_type: None,
        permission_mode: Some("acceptEdits".to_string()),
        terminal_session_id: None,
        terminal_app: None,
        forked_from_session_id: None,
        repository_root: Some(project_path.to_string()),
        is_worktree: false,
        git_sha: Some("abc123".to_string()),
      }],
    )
    .expect("persist claude session fixture");
  }

  #[tokio::test]
  async fn get_permission_rules_endpoint_reads_claude_permissions_from_cli() {
    let state = new_test_state(true);
    let session_id = orbitdock_protocol::new_session_id();
    let (action_tx, mut action_rx) = mpsc::channel(8);
    state.set_claude_action_tx(&session_id, action_tx);

    let task = tokio::spawn(async move {
      let action = action_rx
        .recv()
        .await
        .expect("permission rules endpoint should dispatch a claude action");
      match action {
        ClaudeAction::GetSettings { reply } => {
          let _ = reply.send(Ok(json!({
            "response": {
              "effective": {
                "permissions": {
                  "allow": ["git status"],
                  "deny": ["rm -rf"],
                  "ask": ["deploy"],
                  "additionalDirectories": ["/tmp/shared"],
                  "defaultMode": "acceptEdits",
                }
              }
            }
          })));
        }
        other => panic!("expected GetSettings action, got {:?}", other),
      }
    });

    let Json(response) = get_permission_rules(Path(session_id.clone()), State(state))
      .await
      .expect("permission rules endpoint should succeed");

    task
      .await
      .expect("permission rules helper task should complete");

    assert_eq!(response.session_id, session_id);
    match response.rules {
      SessionPermissionRules::Claude {
        permission_mode,
        rules,
        additional_directories,
      } => {
        assert_eq!(permission_mode.as_deref(), Some("acceptEdits"));
        assert_eq!(rules.len(), 3);
        assert_eq!(rules[0].pattern, "git status");
        assert_eq!(rules[0].behavior, "allow");
        assert_eq!(rules[1].pattern, "rm -rf");
        assert_eq!(rules[1].behavior, "deny");
        assert_eq!(rules[2].pattern, "deploy");
        assert_eq!(rules[2].behavior, "ask");
        assert_eq!(
          additional_directories,
          Some(vec!["/tmp/shared".to_string()])
        );
      }
      other => panic!("expected Claude permission rules, got {:?}", other),
    }
  }

  #[tokio::test]
  async fn add_and_remove_permission_rules_update_claude_settings_file() {
    let (state, _persist_rx, db_path, _guard) = new_persist_test_state(true).await;
    let session_id = orbitdock_protocol::new_session_id();
    let project_dir = TempDir::new().expect("project temp dir");
    let transcript_path = project_dir.path().join("transcript.jsonl");
    fs::write(&transcript_path, "").expect("write transcript file");
    persist_claude_session(
      &db_path,
      &session_id,
      project_dir.path().to_str().expect("project temp path"),
      transcript_path.to_str().expect("transcript path"),
    );
    state.add_session(SessionHandle::new(
      session_id.clone(),
      Provider::Claude,
      project_dir.path().to_string_lossy().to_string(),
    ));
    let (action_tx, _action_rx) = mpsc::channel(1);
    state.set_claude_action_tx(&session_id, action_tx);

    let Json(add_response) = add_permission_rule(
      Path(session_id.clone()),
      State(state.clone()),
      Json(ModifyPermissionRuleRequest {
        pattern: "Bash(git status)".to_string(),
        behavior: "allow".to_string(),
        scope: "project".to_string(),
      }),
    )
    .await
    .expect("add permission rule should succeed");

    assert!(add_response.ok);
    assert!(add_response.session_detail_snapshot.is_some());

    let settings_path = project_dir.path().join(".claude/settings.local.json");
    let settings: serde_json::Value =
      serde_json::from_str(&fs::read_to_string(&settings_path).expect("read settings file"))
        .expect("parse settings file");
    assert_eq!(
      settings["permissions"]["allow"],
      json!(["Bash(git status)"])
    );

    let Json(add_again_response) = add_permission_rule(
      Path(session_id.clone()),
      State(state.clone()),
      Json(ModifyPermissionRuleRequest {
        pattern: "Bash(git status)".to_string(),
        behavior: "allow".to_string(),
        scope: "project".to_string(),
      }),
    )
    .await
    .expect("second add permission rule should succeed");

    assert!(add_again_response.ok);
    let settings: serde_json::Value =
      serde_json::from_str(&fs::read_to_string(&settings_path).expect("read settings file"))
        .expect("parse settings file");
    assert_eq!(
      settings["permissions"]["allow"],
      json!(["Bash(git status)"])
    );

    let Json(remove_response) = remove_permission_rule(
      Path(session_id),
      State(state),
      Json(ModifyPermissionRuleRequest {
        pattern: "Bash(git status)".to_string(),
        behavior: "allow".to_string(),
        scope: "project".to_string(),
      }),
    )
    .await
    .expect("remove permission rule should succeed");

    assert!(remove_response.ok);
    assert!(remove_response.session_detail_snapshot.is_some());

    let settings: serde_json::Value =
      serde_json::from_str(&fs::read_to_string(&settings_path).expect("read settings file"))
        .expect("parse settings file");
    assert_eq!(settings["permissions"]["allow"], json!([]));
  }
}
