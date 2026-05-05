use super::{
  CodexApprovalPolicy, CodexGranularApprovalPolicy, CodexSessionOverrides, OrchestrationState,
  Provider, SessionControlMode, SessionLifecycleState, SessionListItem, SessionListStatus,
  SessionStatus, SessionSummary, SessionSurface, TokenUsage, TokenUsageSnapshotKind, WorkStatus,
  WorkspaceProviderKind,
};

#[test]
fn display_title_prefers_summary_over_prompt() {
  let title = SessionSummary::display_title_from_parts(
    None,
    Some("Dashboard polish and cleanup"),
    Some("Add a calmer dashboard shell"),
    Some("OrbitDock"),
    "/Users/robert/OrbitDock",
  );

  assert_eq!(title, "Dashboard polish and cleanup");
}

#[test]
fn display_title_falls_back_to_prompt_when_summary_matches_project() {
  let title = SessionSummary::display_title_from_parts(
    None,
    Some("OrbitDock"),
    Some("Add a calmer dashboard shell"),
    Some("OrbitDock"),
    "/Users/robert/OrbitDock",
  );

  assert_eq!(title, "Add a Calmer Dashboard Shell");
}

#[test]
fn display_title_derives_cleaner_prompt_fallback() {
  let title = SessionSummary::display_title_from_parts(
    None,
    None,
    Some("Can you help me fix the session naming fallback? The restore behavior feels wrong."),
    Some("OrbitDock"),
    "/Users/robert/OrbitDock",
  );

  assert_eq!(title, "Fix the Session Naming Fallback");
}

#[test]
fn display_title_strips_skill_prefixes_before_prompt_fallback() {
  let title = SessionSummary::display_title_from_parts(
    None,
    None,
    Some("/goal Can you work through the docs for ../vizzly and ../viz"),
    Some("OrbitDock"),
    "/Users/robert/OrbitDock",
  );

  assert_eq!(title, "Work Through the Docs for ../vizzly and ../viz");
}

#[test]
fn context_line_prefers_last_message_then_distinct_prompt() {
  let context = SessionSummary::context_line_from_parts(
    Some("Project-level cleanup is in flight"),
    Some("Tighten the root shell"),
    None,
  );
  assert_eq!(context.as_deref(), Some("Tighten the root shell"));

  let duplicate = SessionSummary::context_line_from_parts(
    Some("Tighten the root shell"),
    Some("Tighten the root shell"),
    None,
  );
  assert_eq!(duplicate.as_deref(), Some("Tighten the root shell"));

  let last_message = SessionSummary::context_line_from_parts(
    Some("Project-level cleanup is in flight"),
    Some("Tighten the root shell"),
    Some("The worker finished and returned its result."),
  );
  assert_eq!(
    last_message.as_deref(),
    Some("The worker finished and returned its result.")
  );
}

#[test]
fn session_list_item_from_summary_preserves_summary_revision() {
  let summary = SessionSummary {
    id: "sess-1".to_string(),
    provider: Provider::Codex,
    project_path: "/tmp/orbitdock".to_string(),
    transcript_path: None,
    project_name: Some("OrbitDock".to_string()),
    model: Some("gpt-5.4".to_string()),
    custom_name: None,
    summary: None,
    first_prompt: None,
    last_message: None,
    status: SessionStatus::Active,
    work_status: WorkStatus::Working,
    control_mode: SessionControlMode::Direct,
    lifecycle_state: SessionLifecycleState::Open,
    accepts_user_input: true,
    steerable: true,
    token_usage: TokenUsage::default(),
    token_usage_snapshot_kind: TokenUsageSnapshotKind::default(),
    has_pending_approval: false,
    codex_integration_mode: None,
    claude_integration_mode: None,
    approval_policy: None,
    approval_policy_details: None,
    sandbox_mode: None,
    sandbox_policy_details: None,
    permission_mode: None,
    collaboration_mode: None,
    multi_agent: None,
    personality: None,
    service_tier: None,
    developer_instructions: None,
    codex_config_mode: None,
    codex_config_profile: None,
    codex_model_provider: None,
    codex_config_source: None,
    codex_config_overrides: None,
    pending_tool_name: None,
    pending_tool_input: None,
    pending_question: None,
    pending_approval_id: None,
    started_at: None,
    last_activity_at: None,
    last_progress_at: None,
    git_branch: None,
    git_sha: None,
    current_cwd: None,
    effort: None,
    approval_version: Some(4),
    summary_revision: 27,
    repository_root: None,
    is_worktree: false,
    worktree_id: None,
    unread_count: 0,
    has_turn_diff: false,
    display_title: "OrbitDock".to_string(),
    context_line: None,
    list_status: SessionListStatus::Working,
    active_worker_count: 3,
    pending_tool_family: Some(crate::domain_events::ToolFamily::Shell),
    forked_from_session_id: Some("sess-0".to_string()),
    mission_id: None,
    issue_identifier: None,
    allow_bypass_permissions: false,
  };

  let item = SessionListItem::from_summary(&summary);

  assert_eq!(item.summary_revision, 27);
  assert_eq!(item.active_worker_count, 3);
  assert_eq!(
    item.pending_tool_family,
    Some(crate::domain_events::ToolFamily::Shell)
  );
  assert_eq!(item.forked_from_session_id.as_deref(), Some("sess-0"));
}

#[test]
fn codex_approval_policy_round_trips_granular_storage_text() {
  let policy = CodexApprovalPolicy::Granular {
    granular: CodexGranularApprovalPolicy {
      sandbox_approval: false,
      rules: true,
      skill_approval: false,
      request_permissions: true,
      mcp_elicitations: false,
    },
  };

  let stored = policy.storage_text();
  let restored = CodexApprovalPolicy::from_storage_text(&stored).expect("restore approval policy");

  assert_eq!(restored, policy);
  assert_eq!(policy.summary_text(), "reject");
}

#[test]
fn codex_approval_policy_supports_granular_reject_summary() {
  let restored = CodexApprovalPolicy::from_storage_text("reject").expect("restore reject policy");

  assert_eq!(
    restored,
    CodexApprovalPolicy::Granular {
      granular: CodexGranularApprovalPolicy {
        sandbox_approval: false,
        rules: false,
        skill_approval: false,
        request_permissions: false,
        mcp_elicitations: false,
      },
    }
  );
}

#[test]
fn codex_session_overrides_reject_policy_summaries() {
  let result = serde_json::from_str::<CodexSessionOverrides>(
    r#"{
      "approval_policy":"never",
      "sandbox_mode":"external-sandbox-network"
    }"#,
  );

  assert!(result.is_err());
}

#[test]
fn codex_session_overrides_serialize_structured_policy_only() {
  let overrides = CodexSessionOverrides {
    approval_policy_details: CodexApprovalPolicy::from_storage_text("never"),
    sandbox_policy_details: super::CodexSandboxPolicy::from_storage_text(
      "external-sandbox-network",
    ),
    ..Default::default()
  };

  let serialized = serde_json::to_value(&overrides).expect("serialize codex overrides");

  assert!(serialized.get("approval_policy").is_none());
  assert!(serialized.get("sandbox_mode").is_none());
  assert!(serialized.get("approval_policy_details").is_some());
  assert!(serialized.get("sandbox_policy_details").is_some());
}

#[test]
fn session_authority_enums_round_trip() {
  let control_json =
    serde_json::to_string(&SessionControlMode::Direct).expect("serialize session control mode");
  let lifecycle_json = serde_json::to_string(&SessionLifecycleState::Resumable)
    .expect("serialize session lifecycle state");
  let surface_json =
    serde_json::to_string(&SessionSurface::Conversation).expect("serialize session surface");

  assert_eq!(
    serde_json::from_str::<SessionControlMode>(&control_json)
      .expect("deserialize session control mode"),
    SessionControlMode::Direct
  );
  assert_eq!(
    serde_json::from_str::<SessionLifecycleState>(&lifecycle_json)
      .expect("deserialize session lifecycle state"),
    SessionLifecycleState::Resumable
  );
  assert_eq!(
    serde_json::from_str::<SessionSurface>(&surface_json).expect("deserialize session surface"),
    SessionSurface::Conversation
  );
}

#[test]
fn provisioning_state_can_advance_to_running() {
  assert!(OrchestrationState::Provisioning.can_transition_to(&OrchestrationState::Running));
}

#[test]
fn workspace_provider_kind_parses_local() {
  assert_eq!(
    "local"
      .parse::<WorkspaceProviderKind>()
      .expect("parse local provider"),
    WorkspaceProviderKind::Local
  );
}

#[test]
fn workspace_provider_kind_parses_daytona() {
  assert_eq!(
    "daytona"
      .parse::<WorkspaceProviderKind>()
      .expect("parse daytona provider"),
    WorkspaceProviderKind::Daytona
  );
}

#[test]
fn workspace_provider_kind_rejects_unknown_values() {
  let error = "unknown-provider"
    .parse::<WorkspaceProviderKind>()
    .expect_err("unknown provider should fail");

  assert!(error.contains("unsupported workspace provider"));
}
