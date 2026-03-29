use super::super::commands::PersistCommand;
use super::SyncCommand;

impl From<SyncCommand> for PersistCommand {
  fn from(value: SyncCommand) -> Self {
    match value {
      SyncCommand::SessionCreate(params) => {
        PersistCommand::SessionCreate(Box::new((*params).into()))
      }
      SyncCommand::SessionUpdate {
        id,
        status,
        work_status,
        control_mode,
        lifecycle_state,
        last_activity_at,
        last_progress_at,
      } => PersistCommand::SessionUpdate {
        id,
        status,
        work_status,
        control_mode,
        lifecycle_state,
        last_activity_at,
        last_progress_at,
      },
      SyncCommand::SessionEnd { id, reason } => PersistCommand::SessionEnd { id, reason },
      SyncCommand::RowAppend {
        session_id,
        mut entry,
        viewer_present,
        sequence,
      } => {
        entry.sequence = sequence;
        PersistCommand::RowAppend {
          session_id,
          entry,
          viewer_present,
          assigned_sequence: Some(sequence),
          sequence_tx: None,
        }
      }
      SyncCommand::RowUpsert {
        session_id,
        mut entry,
        viewer_present,
        sequence,
      } => {
        entry.sequence = sequence;
        PersistCommand::RowUpsert {
          session_id,
          entry,
          viewer_present,
          assigned_sequence: Some(sequence),
          sequence_tx: None,
        }
      }
      SyncCommand::TokensUpdate {
        session_id,
        usage,
        snapshot_kind,
      } => PersistCommand::TokensUpdate {
        session_id,
        usage,
        snapshot_kind,
      },
      SyncCommand::TurnStateUpdate {
        session_id,
        diff,
        plan,
      } => PersistCommand::TurnStateUpdate {
        session_id,
        diff,
        plan,
      },
      SyncCommand::TurnDiffInsert {
        session_id,
        turn_id,
        turn_seq,
        diff,
        input_tokens,
        output_tokens,
        cached_tokens,
        context_window,
        snapshot_kind,
      } => PersistCommand::TurnDiffInsert {
        session_id,
        turn_id,
        turn_seq,
        diff,
        input_tokens,
        output_tokens,
        cached_tokens,
        context_window,
        snapshot_kind,
      },
      SyncCommand::SetThreadId {
        session_id,
        thread_id,
      } => PersistCommand::SetThreadId {
        session_id,
        thread_id,
      },
      SyncCommand::CleanupThreadShadowSession { thread_id, reason } => {
        PersistCommand::CleanupThreadShadowSession { thread_id, reason }
      }
      SyncCommand::SetClaudeSdkSessionId {
        session_id,
        claude_sdk_session_id,
      } => PersistCommand::SetClaudeSdkSessionId {
        session_id,
        claude_sdk_session_id,
      },
      SyncCommand::CleanupClaudeShadowSession {
        claude_sdk_session_id,
        reason,
      } => PersistCommand::CleanupClaudeShadowSession {
        claude_sdk_session_id,
        reason,
      },
      SyncCommand::SetCustomName {
        session_id,
        custom_name,
      } => PersistCommand::SetCustomName {
        session_id,
        custom_name,
      },
      SyncCommand::SetSummary {
        session_id,
        summary,
      } => PersistCommand::SetSummary {
        session_id,
        summary,
      },
      SyncCommand::SetSessionConfig {
        session_id,
        approval_policy,
        sandbox_mode,
        permission_mode,
        collaboration_mode,
        multi_agent,
        personality,
        service_tier,
        developer_instructions,
        model,
        effort,
        codex_config_mode,
        codex_config_profile,
        codex_model_provider,
        codex_config_source,
        codex_config_overrides_json,
      } => PersistCommand::SetSessionConfig {
        session_id,
        approval_policy,
        sandbox_mode,
        permission_mode,
        collaboration_mode,
        multi_agent,
        personality,
        service_tier,
        developer_instructions,
        model,
        effort,
        codex_config_mode,
        codex_config_profile,
        codex_model_provider,
        codex_config_source,
        codex_config_overrides_json,
      },
      SyncCommand::MarkSessionRead {
        session_id,
        up_to_sequence,
      } => PersistCommand::MarkSessionRead {
        session_id,
        up_to_sequence,
      },
      SyncCommand::ReactivateSession { id } => PersistCommand::ReactivateSession { id },
      SyncCommand::ClaudeSessionUpsert {
        id,
        project_path,
        project_name,
        branch,
        model,
        context_label,
        transcript_path,
        source,
        agent_type,
        permission_mode,
        terminal_session_id,
        terminal_app,
        forked_from_session_id,
        repository_root,
        is_worktree,
        git_sha,
      } => PersistCommand::ClaudeSessionUpsert {
        id,
        project_path,
        project_name,
        branch,
        model,
        context_label,
        transcript_path,
        source,
        agent_type,
        permission_mode,
        terminal_session_id,
        terminal_app,
        forked_from_session_id,
        repository_root,
        is_worktree,
        git_sha,
      },
      SyncCommand::ClaudeSessionUpdate {
        id,
        work_status,
        attention_reason,
        last_tool,
        last_tool_at,
        pending_tool_name,
        pending_tool_input,
        pending_question,
        source,
        agent_type,
        permission_mode,
        active_subagent_id,
        active_subagent_type,
        first_prompt,
        compact_count_increment,
      } => PersistCommand::ClaudeSessionUpdate {
        id,
        work_status,
        attention_reason,
        last_tool,
        last_tool_at,
        pending_tool_name,
        pending_tool_input,
        pending_question,
        source,
        agent_type,
        permission_mode,
        active_subagent_id,
        active_subagent_type,
        first_prompt,
        compact_count_increment,
      },
      SyncCommand::ClaudeSessionEnd { id, reason } => {
        PersistCommand::ClaudeSessionEnd { id, reason }
      }
      SyncCommand::ClaudePromptIncrement { id, first_prompt } => {
        PersistCommand::ClaudePromptIncrement { id, first_prompt }
      }
      SyncCommand::ClaudeToolIncrement { id } => PersistCommand::ClaudeToolIncrement { id },
      SyncCommand::ToolCountIncrement { session_id } => {
        PersistCommand::ToolCountIncrement { session_id }
      }
      SyncCommand::ModelUpdate { session_id, model } => {
        PersistCommand::ModelUpdate { session_id, model }
      }
      SyncCommand::EffortUpdate { session_id, effort } => {
        PersistCommand::EffortUpdate { session_id, effort }
      }
      SyncCommand::ClaudeSubagentStart {
        id,
        session_id,
        agent_type,
      } => PersistCommand::ClaudeSubagentStart {
        id,
        session_id,
        agent_type,
      },
      SyncCommand::ClaudeSubagentEnd {
        id,
        transcript_path,
      } => PersistCommand::ClaudeSubagentEnd {
        id,
        transcript_path,
      },
      SyncCommand::UpsertSubagent { session_id, info } => {
        PersistCommand::UpsertSubagent { session_id, info }
      }
      SyncCommand::UpsertSubagents { session_id, infos } => {
        PersistCommand::UpsertSubagents { session_id, infos }
      }
      SyncCommand::RolloutSessionUpsert { .. }
      | SyncCommand::RolloutSessionUpdate { .. }
      | SyncCommand::RolloutPromptIncrement { .. }
      | SyncCommand::RolloutToolIncrement { .. }
      | SyncCommand::UpsertRolloutCheckpoint { .. }
      | SyncCommand::DeleteRolloutCheckpoint { .. } => {
        unreachable!("legacy rollout sync commands should not be emitted after rollout cleanup")
      }
      SyncCommand::CodexPromptIncrement { id, first_prompt } => {
        PersistCommand::CodexPromptIncrement { id, first_prompt }
      }
      SyncCommand::ApprovalRequested(params) => {
        PersistCommand::ApprovalRequested(Box::new((*params).into()))
      }
      SyncCommand::ApprovalDecision {
        session_id,
        request_id,
        decision,
      } => PersistCommand::ApprovalDecision {
        session_id,
        request_id,
        decision,
      },
      SyncCommand::ReviewCommentCreate {
        id,
        session_id,
        turn_id,
        file_path,
        line_start,
        line_end,
        body,
        tag,
      } => PersistCommand::ReviewCommentCreate {
        id,
        session_id,
        turn_id,
        file_path,
        line_start,
        line_end,
        body,
        tag,
      },
      SyncCommand::ReviewCommentUpdate {
        id,
        body,
        tag,
        status,
      } => PersistCommand::ReviewCommentUpdate {
        id,
        body,
        tag,
        status,
      },
      SyncCommand::ReviewCommentDelete { id } => PersistCommand::ReviewCommentDelete { id },
      SyncCommand::SetIntegrationMode {
        session_id,
        codex_mode,
        claude_mode,
      } => PersistCommand::SetIntegrationMode {
        session_id,
        codex_mode,
        claude_mode,
      },
      SyncCommand::EnvironmentUpdate {
        session_id,
        cwd,
        git_branch,
        git_sha,
        repository_root,
        is_worktree,
      } => PersistCommand::EnvironmentUpdate {
        session_id,
        cwd,
        git_branch,
        git_sha,
        repository_root,
        is_worktree,
      },
      SyncCommand::WorktreeCreate {
        id,
        repo_root,
        worktree_path,
        branch,
        base_branch,
        created_by,
      } => PersistCommand::WorktreeCreate {
        id,
        repo_root,
        worktree_path,
        branch,
        base_branch,
        created_by,
      },
      SyncCommand::WorktreeUpdateStatus {
        id,
        status,
        last_session_ended_at,
      } => PersistCommand::WorktreeUpdateStatus {
        id,
        status,
        last_session_ended_at,
      },
      SyncCommand::MissionIssueUpsert {
        id,
        mission_id,
        issue_id,
        issue_identifier,
        issue_title,
        issue_state,
        orchestration_state,
        provider,
        url,
      } => PersistCommand::MissionIssueUpsert {
        id,
        mission_id,
        issue_id,
        issue_identifier,
        issue_title,
        issue_state,
        orchestration_state,
        provider,
        url,
      },
      SyncCommand::MissionIssueUpdateState {
        mission_id,
        issue_id,
        orchestration_state,
        session_id,
        workspace_id,
        attempt,
        last_error,
        retry_due_at,
        started_at,
        completed_at,
      } => PersistCommand::MissionIssueUpdateState {
        mission_id,
        issue_id,
        orchestration_state,
        session_id,
        workspace_id,
        attempt,
        last_error,
        retry_due_at,
        started_at,
        completed_at,
      },
      SyncCommand::MissionIssueSetPrUrl {
        mission_id,
        issue_id,
        pr_url,
      } => PersistCommand::MissionIssueSetPrUrl {
        mission_id,
        issue_id,
        pr_url,
      },
      SyncCommand::RowsTurnStatusUpdate {
        session_id,
        row_ids,
        status,
      } => PersistCommand::RowsTurnStatusUpdate {
        session_id,
        row_ids,
        status,
      },
    }
  }
}
