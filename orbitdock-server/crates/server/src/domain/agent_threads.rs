use orbitdock_protocol::{
  AgentThreadCapabilities, AgentThreadConversationSummary, AgentThreadInterjectionMode,
  AgentThreadSummary, AgentThreadTranscriptFreshness, Provider, SessionState, SubagentInfo,
  SubagentStatus,
};

#[derive(Debug, Clone, Copy)]
pub(crate) struct AgentThreadTranscriptState {
  pub has_transcript: bool,
  pub total_row_count: Option<u64>,
  pub oldest_sequence: Option<u64>,
  pub newest_sequence: Option<u64>,
}

pub(crate) fn summarize_agent_thread(
  session: &SessionState,
  thread: &SubagentInfo,
  transcript: AgentThreadTranscriptState,
) -> AgentThreadSummary {
  let provider = thread.provider.unwrap_or(session.provider);
  let freshness = transcript_freshness(thread.status, transcript.has_transcript);
  let interjection_mode = interjection_mode_for(session, thread);
  let capabilities = AgentThreadCapabilities {
    can_view_transcript: transcript.has_transcript,
    has_live_updates: false,
    accepts_user_input: interjection_mode != AgentThreadInterjectionMode::None,
    can_interrupt: false,
    can_resume: false,
    can_close: false,
    interjection_mode,
  };

  AgentThreadSummary {
    id: thread.id.clone(),
    provider,
    agent_type: thread.agent_type.clone(),
    label: thread.label.clone(),
    status: thread.status,
    task_summary: thread.task_summary.clone(),
    result_summary: thread.result_summary.clone(),
    error_summary: thread.error_summary.clone(),
    parent_thread_id: thread.parent_subagent_id.clone(),
    model: thread.model.clone(),
    started_at: thread.started_at.clone(),
    last_activity_at: thread.last_activity_at.clone(),
    ended_at: thread.ended_at.clone(),
    capabilities,
    conversation: AgentThreadConversationSummary {
      freshness,
      has_transcript: transcript.has_transcript,
      total_row_count: transcript.total_row_count,
      oldest_sequence: transcript.oldest_sequence,
      newest_sequence: transcript.newest_sequence,
    },
    limitations: limitations_for(session, thread, provider, transcript.has_transcript),
  }
}

pub(crate) fn parent_mediated_message(thread: &AgentThreadSummary, content: &str) -> String {
  let label = thread.label.as_deref().unwrap_or(thread.id.as_str());
  format!(
    "Interjection for agent thread {label} ({id}):\n\n{content}",
    id = thread.id,
    content = content.trim()
  )
}

fn transcript_freshness(
  status: SubagentStatus,
  has_transcript: bool,
) -> AgentThreadTranscriptFreshness {
  if !has_transcript {
    return AgentThreadTranscriptFreshness::Unavailable;
  }

  if is_active_status(status) {
    AgentThreadTranscriptFreshness::Pollable
  } else {
    AgentThreadTranscriptFreshness::FinalOnly
  }
}

fn interjection_mode_for(
  session: &SessionState,
  thread: &SubagentInfo,
) -> AgentThreadInterjectionMode {
  if session.steerable && is_active_status(thread.status) {
    AgentThreadInterjectionMode::ParentMediated
  } else {
    AgentThreadInterjectionMode::None
  }
}

fn limitations_for(
  session: &SessionState,
  thread: &SubagentInfo,
  provider: Provider,
  has_transcript: bool,
) -> Vec<String> {
  let mut limitations = Vec::new();

  if !has_transcript {
    limitations.push("No readable agent transcript is available yet.".to_string());
  }

  if provider == Provider::Claude {
    limitations.push(
      "Claude subagent control is exposed through the parent session, not a direct child input channel."
        .to_string(),
    );
  }

  if provider == Provider::Codex {
    limitations.push(
      "Codex child-thread input is mediated through the parent session until OrbitDock owns a live child runtime handle."
        .to_string(),
    );
  }

  if !session.steerable || !is_active_status(thread.status) {
    limitations.push("This thread is observe-only in its current state.".to_string());
  }

  limitations
}

fn is_active_status(status: SubagentStatus) -> bool {
  matches!(
    status,
    SubagentStatus::Pending | SubagentStatus::Running | SubagentStatus::Interrupted
  )
}

#[cfg(test)]
mod tests {
  use super::*;
  use orbitdock_protocol::domain_events::AgentType;
  use orbitdock_protocol::{
    ClaudeIntegrationMode, CodexIntegrationMode, SessionControlMode, SessionLifecycleState,
    SessionStatus, WorkStatus,
  };

  fn session(provider: Provider, steerable: bool) -> SessionState {
    SessionState {
      id: "session-1".to_string(),
      provider,
      project_path: "/tmp/project".to_string(),
      transcript_path: None,
      project_name: None,
      model: None,
      custom_name: None,
      summary: None,
      first_prompt: None,
      last_message: None,
      status: SessionStatus::Active,
      work_status: if steerable {
        WorkStatus::Working
      } else {
        WorkStatus::Waiting
      },
      control_mode: SessionControlMode::Direct,
      lifecycle_state: SessionLifecycleState::Open,
      accepts_user_input: steerable,
      steerable,
      pending_approval: None,
      connector_attached: true,
      can_interrupt: steerable,
      permission_mode: None,
      allow_bypass_permissions: false,
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
      token_usage: Default::default(),
      token_usage_snapshot_kind: Default::default(),
      current_diff: None,
      cumulative_diff: None,
      current_plan: None,
      codex_integration_mode: Some(CodexIntegrationMode::Direct),
      claude_integration_mode: Some(ClaudeIntegrationMode::Direct),
      approval_policy: None,
      approval_policy_details: None,
      sandbox_mode: None,
      sandbox_policy_details: None,
      started_at: None,
      last_activity_at: None,
      last_progress_at: None,
      forked_from_session_id: None,
      revision: Some(7),
      current_turn_id: None,
      turn_count: 0,
      turn_diffs: vec![],
      git_branch: None,
      git_sha: None,
      current_cwd: None,
      subagents: vec![],
      effort: None,
      terminal_session_id: None,
      terminal_app: None,
      approval_version: None,
      repository_root: None,
      is_worktree: false,
      worktree_id: None,
      unread_count: 0,
      mission_id: None,
      issue_identifier: None,
      rows: vec![],
      total_row_count: 0,
      has_more_before: false,
      oldest_sequence: None,
      newest_sequence: None,
    }
  }

  fn thread(provider: Provider, status: SubagentStatus) -> SubagentInfo {
    SubagentInfo {
      id: "thread-1".to_string(),
      agent_type: AgentType::GeneralPurpose,
      started_at: "2026-04-23T00:00:00Z".to_string(),
      ended_at: None,
      provider: Some(provider),
      label: Some("Worker".to_string()),
      status,
      task_summary: Some("Check the flow".to_string()),
      result_summary: None,
      error_summary: None,
      parent_subagent_id: Some("parent-thread".to_string()),
      model: None,
      last_activity_at: None,
    }
  }

  #[test]
  fn active_thread_uses_parent_mediated_interjection_when_session_is_steerable() {
    let summary = summarize_agent_thread(
      &session(Provider::Codex, true),
      &thread(Provider::Codex, SubagentStatus::Running),
      AgentThreadTranscriptState {
        has_transcript: true,
        total_row_count: Some(3),
        oldest_sequence: Some(0),
        newest_sequence: Some(2),
      },
    );

    assert_eq!(
      summary.capabilities.interjection_mode,
      AgentThreadInterjectionMode::ParentMediated
    );
    assert!(summary.capabilities.accepts_user_input);
    assert_eq!(
      summary.conversation.freshness,
      AgentThreadTranscriptFreshness::Pollable
    );
  }

  #[test]
  fn completed_thread_is_observe_only() {
    let summary = summarize_agent_thread(
      &session(Provider::Claude, true),
      &thread(Provider::Claude, SubagentStatus::Completed),
      AgentThreadTranscriptState {
        has_transcript: true,
        total_row_count: None,
        oldest_sequence: None,
        newest_sequence: None,
      },
    );

    assert_eq!(
      summary.capabilities.interjection_mode,
      AgentThreadInterjectionMode::None
    );
    assert!(!summary.capabilities.accepts_user_input);
    assert_eq!(
      summary.conversation.freshness,
      AgentThreadTranscriptFreshness::FinalOnly
    );
  }

  #[test]
  fn missing_transcript_is_explicitly_unavailable() {
    let summary = summarize_agent_thread(
      &session(Provider::Codex, false),
      &thread(Provider::Codex, SubagentStatus::Running),
      AgentThreadTranscriptState {
        has_transcript: false,
        total_row_count: None,
        oldest_sequence: None,
        newest_sequence: None,
      },
    );

    assert!(!summary.capabilities.can_view_transcript);
    assert_eq!(
      summary.conversation.freshness,
      AgentThreadTranscriptFreshness::Unavailable
    );
    assert!(summary
      .limitations
      .iter()
      .any(|item| item.contains("No readable agent transcript")));
  }
}
