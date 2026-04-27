use super::*;
use orbitdock_protocol::{CodexConfigMode, CodexConfigSource, Provider};

fn identity() -> SessionIdentity {
  SessionIdentity {
    id: "session-restore".to_string(),
    provider: Provider::Codex,
    project_path: "/tmp/project".to_string(),
    transcript_path: Some("/tmp/transcript.jsonl".to_string()),
    project_name: Some("Project".to_string()),
  }
}

fn config() -> SessionConfig {
  SessionConfig {
    model: Some("codex-model".to_string()),
    approval_policy: Some("never".to_string()),
    approval_policy_details: None,
    sandbox_mode: Some("workspace-write".to_string()),
    sandbox_policy_details: None,
    collaboration_mode: Some("collab".to_string()),
    multi_agent: Some(true),
    personality: Some("calm".to_string()),
    service_tier: Some("standard".to_string()),
    developer_instructions: Some("be clear".to_string()),
    codex_config_mode: Some(CodexConfigMode::Custom),
    codex_config_profile: Some("profile".to_string()),
    codex_model_provider: Some("openai".to_string()),
    codex_config_source: Some(CodexConfigSource::Orbitdock),
    codex_config_overrides: None,
    effort: Some("high".to_string()),
  }
}

fn display() -> SessionDisplay {
  SessionDisplay {
    custom_name: Some("Restored".to_string()),
    summary: Some("Summary".to_string()),
    first_prompt: Some("Prompt".to_string()),
    last_message: Some("Last".to_string()),
  }
}

fn environment() -> SessionEnvironment {
  SessionEnvironment {
    git_branch: Some("main".to_string()),
    git_sha: Some("abc123".to_string()),
    current_cwd: Some("/tmp/project".to_string()),
    repository_root: Some("/tmp".to_string()),
    is_worktree: true,
    worktree_id: Some("wt-1".to_string()),
  }
}

fn timestamps() -> SessionTimestamps {
  SessionTimestamps {
    started_at: Some("2026-04-09T00:00:00Z".to_string()),
    last_activity_at: Some("2026-04-09T00:01:00Z".to_string()),
    last_progress_at: Some("2026-04-09T00:02:00Z".to_string()),
  }
}

#[test]
fn build_restored_session_snapshot_uses_restored_defaults() {
  let turn_diffs = vec![TurnDiff {
    turn_id: "turn-1".to_string(),
    diff: "diff --git a/app.rs b/app.rs\n--- a/app.rs\n+++ b/app.rs\n@@ -1,1 +1,2 @@\n-old\n+new\n+extra".to_string(),
    token_usage: None,
    snapshot_kind: None,
  }];

  let snapshot = build_restored_session_snapshot(SessionRestoreSnapshotInput {
    identity: &identity(),
    config: &config(),
    display: &display(),
    environment: &environment(),
    timestamps: &timestamps(),
    status: SessionStatus::Active,
    work_status: WorkStatus::Working,
    control_mode: SessionControlMode::Direct,
    lifecycle_state: SessionLifecycleState::Open,
    permission_mode: Some("acceptEdits"),
    token_usage: &TokenUsage::default(),
    token_usage_snapshot_kind: TokenUsageSnapshotKind::Unknown,
    current_diff: None,
    current_plan: Some("plan"),
    turn_diffs: &turn_diffs,
    pending_tool_name: Some("Bash"),
    pending_tool_input: Some("ls"),
    pending_question: None,
    pending_approval_id: Some("approval-1"),
    approval_version: 12,
    unread_count: 3,
  });

  assert!(snapshot.has_turn_diff);
  assert_eq!(
    snapshot.diff_preview.as_ref().map(|preview| (
      preview.file_count,
      preview.additions,
      preview.deletions
    )),
    Some((1, 2, 1))
  );
  assert!(snapshot.has_pending_approval);
  assert_eq!(snapshot.repository_root, None);
  assert!(!snapshot.is_worktree);
  assert_eq!(snapshot.worktree_id, None);
  assert_eq!(snapshot.pending_tool_name.as_deref(), Some("Bash"));
  assert_eq!(snapshot.current_plan.as_deref(), Some("plan"));
  assert_eq!(snapshot.approval_version, 12);
  assert_eq!(snapshot.unread_count, 3);
}

#[test]
fn restored_predicates_are_simple_and_pure() {
  assert!(restored_has_pending_approval(Some("tool"), None, None));
  assert!(restored_has_pending_approval(None, Some("question"), None));
  assert!(restored_has_pending_approval(None, None, Some("approval")));
  assert!(!restored_has_pending_approval(None, None, None));

  let turn_diffs: Vec<TurnDiff> = vec![];
  assert!(has_turn_diff(Some("diff"), &turn_diffs));
  assert!(!has_turn_diff(None, &turn_diffs));
}
