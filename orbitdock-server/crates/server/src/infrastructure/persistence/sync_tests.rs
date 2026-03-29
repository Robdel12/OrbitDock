use serde_json::json;
use tokio::sync::oneshot;

use orbitdock_protocol::conversation_contracts::{
  ConversationRow, ConversationRowEntry, MessageRowContent,
};
use orbitdock_protocol::{
  ApprovalPreview, ApprovalPreviewSegment, ApprovalPreviewType, ApprovalQuestionPrompt,
  ApprovalRiskLevel, ApprovalType, CodexConfigMode, CodexConfigSource, Provider, SessionStatus,
  SubagentInfo, SubagentStatus, TokenUsage, TokenUsageSnapshotKind, WorkStatus,
};

use super::super::commands::{ApprovalRequestedParams, PersistCommand, SessionCreateParams};
use super::{SyncCommand, SyncEnvelope};

fn sample_row_entry(sequence: u64) -> ConversationRowEntry {
  ConversationRowEntry {
    session_id: "session-1".into(),
    sequence,
    turn_id: Some("turn-1".into()),
    turn_status: Default::default(),
    row: ConversationRow::User(MessageRowContent {
      id: format!("row-{sequence}"),
      content: "hello".into(),
      turn_id: Some("turn-1".into()),
      timestamp: Some("2026-03-24T12:00:00Z".into()),
      is_streaming: false,
      images: Vec::new(),
      memory_citation: None,
      delivery_status: None,
    }),
  }
}

fn sample_usage() -> TokenUsage {
  TokenUsage {
    input_tokens: 10,
    output_tokens: 20,
    cached_tokens: 5,
    context_window: 100,
  }
}

fn sample_subagent() -> SubagentInfo {
  SubagentInfo {
    id: "subagent-1".into(),
    agent_type: "worker".into(),
    started_at: "2026-03-24T12:00:00Z".into(),
    ended_at: Some("2026-03-24T12:05:00Z".into()),
    provider: Some(Provider::Codex),
    label: Some("Indexer".into()),
    status: SubagentStatus::Completed,
    task_summary: Some("Index the repo".into()),
    result_summary: Some("Done".into()),
    error_summary: None,
    parent_subagent_id: Some("parent-1".into()),
    model: Some("gpt-5.4".into()),
    last_activity_at: Some("2026-03-24T12:04:00Z".into()),
  }
}

fn sample_question_prompt() -> ApprovalQuestionPrompt {
  ApprovalQuestionPrompt {
    id: "prompt-1".into(),
    header: Some("Deploy".into()),
    question: "Ship it?".into(),
    options: Vec::new(),
    allows_multiple_selection: false,
    allows_other: true,
    is_secret: false,
  }
}

fn sample_preview() -> ApprovalPreview {
  ApprovalPreview {
    preview_type: ApprovalPreviewType::ShellCommand,
    value: "git push origin feat".into(),
    shell_segments: vec![ApprovalPreviewSegment {
      command: "git push origin feat".into(),
      leading_operator: None,
    }],
    compact: Some("git push".into()),
    decision_scope: Some("session".into()),
    risk_level: Some(ApprovalRiskLevel::Normal),
    risk_findings: vec!["touches remote".into()],
    manifest: Some("manifest".into()),
  }
}

fn sample_syncable_persist_commands() -> Vec<PersistCommand> {
  vec![
    PersistCommand::SessionCreate(Box::new(SessionCreateParams {
      id: "session-1".into(),
      provider: Provider::Codex,
      control_mode: orbitdock_protocol::SessionControlMode::Direct,
      project_path: "/repo".into(),
      project_name: Some("OrbitDock".into()),
      branch: Some("feat/phase-two".into()),
      model: Some("gpt-5.4".into()),
      approval_policy: Some("strict".into()),
      sandbox_mode: Some("workspace-write".into()),
      permission_mode: Some("default".into()),
      collaboration_mode: Some("pair".into()),
      multi_agent: Some(true),
      personality: Some("warm".into()),
      service_tier: Some("pro".into()),
      developer_instructions: Some("stay typed".into()),
      codex_config_mode: Some(CodexConfigMode::Profile),
      codex_config_profile: Some("fast".into()),
      codex_model_provider: Some("openai".into()),
      codex_config_source: Some(CodexConfigSource::User),
      codex_config_overrides_json: Some("{\"sandbox\":\"workspace-write\"}".into()),
      forked_from_session_id: Some("session-0".into()),
      mission_id: Some("mission-1".into()),
      issue_identifier: Some("#23".into()),
      allow_bypass_permissions: true,
      worktree_id: Some("worktree-1".into()),
    })),
    PersistCommand::SessionUpdate {
      id: "session-1".into(),
      status: Some(SessionStatus::Active),
      work_status: Some(WorkStatus::Working),
      control_mode: None,
      lifecycle_state: None,
      last_activity_at: Some("2026-03-24T12:01:00Z".into()),
      last_progress_at: Some("2026-03-24T12:02:00Z".into()),
    },
    PersistCommand::SessionEnd {
      id: "session-1".into(),
      reason: "completed".into(),
    },
    PersistCommand::TokensUpdate {
      session_id: "session-1".into(),
      usage: sample_usage(),
      snapshot_kind: TokenUsageSnapshotKind::ContextTurn,
    },
    PersistCommand::TurnStateUpdate {
      session_id: "session-1".into(),
      diff: Some("diff --git".into()),
      plan: Some("- [x] done".into()),
    },
    PersistCommand::TurnDiffInsert {
      session_id: "session-1".into(),
      turn_id: "turn-1".into(),
      turn_seq: 9,
      diff: "diff --git".into(),
      input_tokens: 1,
      output_tokens: 2,
      cached_tokens: 3,
      context_window: 4,
      snapshot_kind: TokenUsageSnapshotKind::LifetimeTotals,
    },
    PersistCommand::SetThreadId {
      session_id: "session-1".into(),
      thread_id: "thread-1".into(),
    },
    PersistCommand::CleanupThreadShadowSession {
      thread_id: "thread-1".into(),
      reason: "takeover".into(),
    },
    PersistCommand::SetClaudeSdkSessionId {
      session_id: "session-1".into(),
      claude_sdk_session_id: "claude-1".into(),
    },
    PersistCommand::CleanupClaudeShadowSession {
      claude_sdk_session_id: "claude-1".into(),
      reason: "resume".into(),
    },
    PersistCommand::SetCustomName {
      session_id: "session-1".into(),
      custom_name: Some("Phase 2".into()),
    },
    PersistCommand::SetSummary {
      session_id: "session-1".into(),
      summary: "Summary".into(),
    },
    PersistCommand::SetSessionConfig {
      session_id: "session-1".into(),
      approval_policy: Some(Some("strict".into())),
      sandbox_mode: Some(Some("workspace-write".into())),
      permission_mode: Some(Some("default".into())),
      collaboration_mode: Some(Some("pair".into())),
      multi_agent: Some(Some(true)),
      personality: Some(Some("warm".into())),
      service_tier: Some(Some("pro".into())),
      developer_instructions: Some(Some("typed".into())),
      model: Some(Some("gpt-5.4".into())),
      effort: Some(Some("high".into())),
      codex_config_mode: Some(CodexConfigMode::Custom),
      codex_config_profile: Some("profile-1".into()),
      codex_model_provider: Some("openai".into()),
      codex_config_source: Some(CodexConfigSource::Orbitdock),
      codex_config_overrides_json: Some("{\"foo\":\"bar\"}".into()),
    },
    PersistCommand::MarkSessionRead {
      session_id: "session-1".into(),
      up_to_sequence: 42,
    },
    PersistCommand::ReactivateSession {
      id: "session-1".into(),
    },
    PersistCommand::ClaudeSessionUpsert {
      id: "session-1".into(),
      project_path: "/repo".into(),
      project_name: Some("OrbitDock".into()),
      branch: Some("main".into()),
      model: Some("claude-4".into()),
      context_label: Some("review".into()),
      transcript_path: Some("/tmp/transcript.jsonl".into()),
      source: Some("hook".into()),
      agent_type: Some("planner".into()),
      permission_mode: Some("acceptEdits".into()),
      terminal_session_id: Some("term-1".into()),
      terminal_app: Some("ghostty".into()),
      forked_from_session_id: Some("session-0".into()),
      repository_root: Some("/repo".into()),
      is_worktree: true,
      git_sha: Some("abc123".into()),
    },
    PersistCommand::ClaudeSessionUpdate {
      id: "session-1".into(),
      work_status: Some("working".into()),
      attention_reason: Some(Some("needs review".into())),
      last_tool: Some(Some("edit".into())),
      last_tool_at: Some(Some("2026-03-24T12:03:00Z".into())),
      pending_tool_name: Some(Some("apply_patch".into())),
      pending_tool_input: Some(Some("diff".into())),
      pending_question: Some(Some("Proceed?".into())),
      source: Some(Some("hook".into())),
      agent_type: Some(Some("planner".into())),
      permission_mode: Some(Some("default".into())),
      active_subagent_id: Some(Some("subagent-1".into())),
      active_subagent_type: Some(Some("worker".into())),
      first_prompt: Some("Implement phase 2".into()),
      compact_count_increment: true,
    },
    PersistCommand::ClaudeSessionEnd {
      id: "session-1".into(),
      reason: Some("done".into()),
    },
    PersistCommand::ClaudePromptIncrement {
      id: "session-1".into(),
      first_prompt: Some("first prompt".into()),
    },
    PersistCommand::ClaudeToolIncrement {
      id: "session-1".into(),
    },
    PersistCommand::ToolCountIncrement {
      session_id: "session-1".into(),
    },
    PersistCommand::ModelUpdate {
      session_id: "session-1".into(),
      model: "gpt-5.4".into(),
    },
    PersistCommand::EffortUpdate {
      session_id: "session-1".into(),
      effort: Some("high".into()),
    },
    PersistCommand::ClaudeSubagentStart {
      id: "subagent-1".into(),
      session_id: "session-1".into(),
      agent_type: "worker".into(),
    },
    PersistCommand::ClaudeSubagentEnd {
      id: "subagent-1".into(),
      transcript_path: Some("/tmp/subagent.jsonl".into()),
    },
    PersistCommand::UpsertSubagent {
      session_id: "session-1".into(),
      info: sample_subagent(),
    },
    PersistCommand::UpsertSubagents {
      session_id: "session-1".into(),
      infos: vec![sample_subagent()],
    },
    PersistCommand::CodexPromptIncrement {
      id: "session-1".into(),
      first_prompt: Some("start".into()),
    },
    PersistCommand::ApprovalRequested(Box::new(ApprovalRequestedParams {
      session_id: "session-1".into(),
      request_id: "request-1".into(),
      approval_type: ApprovalType::Exec,
      tool_name: Some("shell".into()),
      tool_input: Some("git push".into()),
      command: Some("git push origin feat".into()),
      file_path: Some("/repo/file.rs".into()),
      diff: Some("diff --git".into()),
      question: Some("Ship it?".into()),
      question_prompts: vec![sample_question_prompt()],
      preview: Some(sample_preview()),
      permission_reason: Some("network".into()),
      requested_permissions: Some(json!({"network": true})),
      granted_permissions: Some(json!({"filesystem": "workspace-write"})),
      cwd: Some("/repo".into()),
      proposed_amendment: Some(vec!["Add tests".into()]),
      permission_suggestions: Some(json!([{"label": "Allow"}])),
      elicitation_mode: Some("form".into()),
      elicitation_schema: Some(json!({"type": "object"})),
      elicitation_url: Some("https://example.com".into()),
      elicitation_message: Some("Need approval".into()),
      mcp_server_name: Some("github".into()),
      network_host: Some("api.github.com".into()),
      network_protocol: Some("https".into()),
    })),
    PersistCommand::ApprovalDecision {
      session_id: "session-1".into(),
      request_id: "request-1".into(),
      decision: "approved".into(),
    },
    PersistCommand::ReviewCommentCreate {
      id: "comment-1".into(),
      session_id: "session-1".into(),
      turn_id: Some("turn-1".into()),
      file_path: "src/lib.rs".into(),
      line_start: 10,
      line_end: Some(12),
      body: "Needs coverage".into(),
      tag: Some("nit".into()),
    },
    PersistCommand::ReviewCommentUpdate {
      id: "comment-1".into(),
      body: Some("Looks good".into()),
      tag: Some("resolved".into()),
      status: Some("closed".into()),
    },
    PersistCommand::ReviewCommentDelete {
      id: "comment-1".into(),
    },
    PersistCommand::SetIntegrationMode {
      session_id: "session-1".into(),
      codex_mode: Some("direct".into()),
      claude_mode: Some("hook".into()),
    },
    PersistCommand::EnvironmentUpdate {
      session_id: "session-1".into(),
      cwd: Some("/repo".into()),
      git_branch: Some("feat/phase-two".into()),
      git_sha: Some("abc123".into()),
      repository_root: Some("/repo".into()),
      is_worktree: Some(true),
    },
    PersistCommand::WorktreeCreate {
      id: "worktree-1".into(),
      repo_root: "/repo".into(),
      worktree_path: "/repo/.worktrees/phase-two".into(),
      branch: "feat/phase-two".into(),
      base_branch: Some("main".into()),
      created_by: "mission-control".into(),
    },
    PersistCommand::WorktreeUpdateStatus {
      id: "worktree-1".into(),
      status: "active".into(),
      last_session_ended_at: Some("2026-03-24T12:06:00Z".into()),
    },
    PersistCommand::MissionIssueUpsert {
      id: "issue-row-1".into(),
      mission_id: "mission-1".into(),
      issue_id: "23".into(),
      issue_identifier: "#23".into(),
      issue_title: Some("Phase 2".into()),
      issue_state: Some("open".into()),
      orchestration_state: "running".into(),
      provider: Some("github".into()),
      url: Some("https://github.com/Robdel12/OrbitDock/issues/23".into()),
    },
    PersistCommand::MissionIssueUpdateState {
      mission_id: "mission-1".into(),
      issue_id: "23".into(),
      orchestration_state: "running".into(),
      session_id: Some("session-1".into()),
      workspace_id: Some("workspace-1".into()),
      attempt: Some(2),
      last_error: Some(Some("transient".into())),
      retry_due_at: Some(Some("2026-03-24T12:10:00Z".into())),
      started_at: Some(Some("2026-03-24T12:00:00Z".into())),
      completed_at: Some(Some("2026-03-24T12:09:00Z".into())),
    },
    PersistCommand::MissionIssueSetPrUrl {
      mission_id: "mission-1".into(),
      issue_id: "23".into(),
      pr_url: "https://github.com/Robdel12/OrbitDock/pull/150".into(),
    },
  ]
}

fn sample_non_syncable_persist_commands() -> Vec<PersistCommand> {
  vec![
    PersistCommand::SetConfig {
      key: "workspace_provider".into(),
      value: "local".into(),
    },
    PersistCommand::MissionCreate {
      id: "mission-1".into(),
      name: "Phase 2".into(),
      repo_root: "/repo".into(),
      tracker_kind: "github".into(),
      provider: "codex".into(),
      config_json: Some("{\"workspace\":\"local\"}".into()),
      prompt_template: Some("Template".into()),
      mission_file_path: Some("/repo/MISSION.md".into()),
      tracker_api_key: Some("encrypted".into()),
    },
    PersistCommand::MissionUpdate {
      id: "mission-1".into(),
      name: Some("Phase 2 updated".into()),
      enabled: Some(true),
      paused: Some(false),
      tracker_kind: Some("github".into()),
      config_json: Some("{\"workspace\":\"remote\"}".into()),
      prompt_template: Some("Updated".into()),
      parse_error: Some(Some("warning".into())),
      mission_file_path: Some(Some("/repo/MISSION.md".into())),
    },
    PersistCommand::MissionSetTrackerKey {
      mission_id: "mission-1".into(),
      key: Some("secret".into()),
    },
    PersistCommand::MissionDelete {
      id: "mission-1".into(),
    },
  ]
}

#[test]
fn sync_command_round_trips_every_syncable_non_row_variant() {
  for persist in sample_syncable_persist_commands() {
    let sync = Option::<SyncCommand>::from(&persist)
      .expect("every syncable persist command should have a sync mirror");
    let json = serde_json::to_value(&sync).expect("sync command should serialize");
    let decoded: SyncCommand =
      serde_json::from_value(json.clone()).expect("sync command should deserialize");
    let restored = PersistCommand::from(decoded);
    let restored_json = serde_json::to_value(
      Option::<SyncCommand>::from(&restored)
        .expect("restored persist command should still have a sync mirror"),
    )
    .expect("restored sync command should serialize");
    assert_eq!(json, restored_json);
  }
}

#[test]
fn row_sync_requires_authoritative_sequence() {
  let (sequence_tx, _sequence_rx) = oneshot::channel();
  let persist = PersistCommand::RowAppend {
    session_id: "session-1".into(),
    entry: sample_row_entry(0),
    viewer_present: true,
    assigned_sequence: None,
    sequence_tx: Some(sequence_tx),
  };

  assert!(
    Option::<SyncCommand>::from(&persist).is_none(),
    "pre-persist row commands should not sync without a DB-assigned sequence"
  );

  let sync = persist
    .sync_with_assigned_sequence(0)
    .expect("row append should sync once the DB sequence is known");
  let restored = PersistCommand::from(sync);

  match restored {
    PersistCommand::RowAppend {
      sequence_tx,
      assigned_sequence,
      entry,
      ..
    } => {
      assert!(
        sequence_tx.is_none(),
        "sync restore should not recreate response channels"
      );
      assert_eq!(assigned_sequence, Some(0));
      assert_eq!(entry.sequence, 0);
    }
    other => panic!("expected row append after restore, got {other:?}"),
  }
}

#[test]
fn non_syncable_commands_are_filtered_out() {
  for persist in sample_non_syncable_persist_commands() {
    assert!(
      Option::<SyncCommand>::from(&persist).is_none(),
      "control-plane config and mission admin commands should not sync"
    );
  }
}

#[test]
fn sync_envelope_round_trips() {
  let envelope = SyncEnvelope {
    sequence: 42,
    workspace_id: "workspace-1".into(),
    timestamp: "2026-03-24T12:00:00Z".into(),
    command: Option::<SyncCommand>::from(&PersistCommand::ModelUpdate {
      session_id: "session-1".into(),
      model: "gpt-5.4".into(),
    })
    .expect("model updates should sync"),
  };

  let json = serde_json::to_string(&envelope).expect("envelope should serialize");
  let decoded: SyncEnvelope = serde_json::from_str(&json).expect("envelope should deserialize");
  let original_value = serde_json::to_value(&envelope).expect("original should serialize");
  let decoded_value = serde_json::to_value(&decoded).expect("decoded should serialize");
  assert_eq!(original_value, decoded_value);
}
