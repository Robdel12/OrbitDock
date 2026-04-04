use super::super::commands::PersistCommand;
use super::{SyncApprovalRequestedParams, SyncCommand, SyncSessionCreateParams};

impl PersistCommand {
  /// Build a sync-safe row command using the DB-assigned sequence.
  ///
  /// This is the only sound way to sync row mutations because the control plane
  /// must replay the exact sequence chosen by the workspace's SQLite writer.
  pub fn sync_with_assigned_sequence(&self, assigned_sequence: u64) -> Option<SyncCommand> {
    match self {
      PersistCommand::RowAppend {
        session_id,
        entry,
        viewer_present,
        ..
      } => {
        let mut entry = entry.clone();
        entry.sequence = assigned_sequence;
        Some(SyncCommand::RowAppend {
          session_id: session_id.clone(),
          entry,
          viewer_present: *viewer_present,
          sequence: assigned_sequence,
        })
      }
      PersistCommand::RowUpsert {
        session_id,
        entry,
        viewer_present,
        ..
      } => {
        let mut entry = entry.clone();
        entry.sequence = assigned_sequence;
        Some(SyncCommand::RowUpsert {
          session_id: session_id.clone(),
          entry,
          viewer_present: *viewer_present,
          sequence: assigned_sequence,
        })
      }
      _ => Option::<SyncCommand>::from(self),
    }
  }
}

impl From<&PersistCommand> for Option<SyncCommand> {
  fn from(value: &PersistCommand) -> Self {
    match value {
      PersistCommand::SetTranscriptPath { .. }
      | PersistCommand::SessionAttentionUpdate { .. }
      | PersistCommand::Flush { .. } => None,
      _ => Some(match value {
        PersistCommand::SessionCreate(params) => {
          SyncCommand::SessionCreate(Box::new(SyncSessionCreateParams::from(params.as_ref())))
        }
        PersistCommand::SessionUpdate {
          id,
          status,
          work_status,
          control_mode,
          lifecycle_state,
          last_activity_at,
          last_progress_at,
        } => SyncCommand::SessionUpdate {
          id: id.clone(),
          status: *status,
          work_status: *work_status,
          control_mode: *control_mode,
          lifecycle_state: *lifecycle_state,
          last_activity_at: last_activity_at.clone(),
          last_progress_at: last_progress_at.clone(),
        },
        PersistCommand::SessionEnd { id, reason } => SyncCommand::SessionEnd {
          id: id.clone(),
          reason: reason.clone(),
        },
        PersistCommand::RowAppend { .. } | PersistCommand::RowUpsert { .. } => return None,
        PersistCommand::TokensUpdate {
          session_id,
          usage,
          snapshot_kind,
        } => SyncCommand::TokensUpdate {
          session_id: session_id.clone(),
          usage: usage.clone(),
          snapshot_kind: *snapshot_kind,
        },
        PersistCommand::TurnStateUpdate {
          session_id,
          diff,
          plan,
        } => SyncCommand::TurnStateUpdate {
          session_id: session_id.clone(),
          diff: diff.clone(),
          plan: plan.clone(),
        },
        PersistCommand::TurnDiffInsert {
          session_id,
          turn_id,
          turn_seq,
          diff,
          input_tokens,
          output_tokens,
          cached_tokens,
          context_window,
          snapshot_kind,
        } => SyncCommand::TurnDiffInsert {
          session_id: session_id.clone(),
          turn_id: turn_id.clone(),
          turn_seq: *turn_seq,
          diff: diff.clone(),
          input_tokens: *input_tokens,
          output_tokens: *output_tokens,
          cached_tokens: *cached_tokens,
          context_window: *context_window,
          snapshot_kind: *snapshot_kind,
        },
        PersistCommand::SetThreadId {
          session_id,
          thread_id,
        } => SyncCommand::SetThreadId {
          session_id: session_id.clone(),
          thread_id: thread_id.clone(),
        },
        PersistCommand::CleanupThreadShadowSession { thread_id, reason } => {
          SyncCommand::CleanupThreadShadowSession {
            thread_id: thread_id.clone(),
            reason: reason.clone(),
          }
        }
        PersistCommand::SetClaudeSdkSessionId {
          session_id,
          claude_sdk_session_id,
        } => SyncCommand::SetClaudeSdkSessionId {
          session_id: session_id.clone(),
          claude_sdk_session_id: claude_sdk_session_id.clone(),
        },
        PersistCommand::CleanupClaudeShadowSession {
          claude_sdk_session_id,
          reason,
        } => SyncCommand::CleanupClaudeShadowSession {
          claude_sdk_session_id: claude_sdk_session_id.clone(),
          reason: reason.clone(),
        },
        PersistCommand::SetCustomName {
          session_id,
          custom_name,
        } => SyncCommand::SetCustomName {
          session_id: session_id.clone(),
          custom_name: custom_name.clone(),
        },
        PersistCommand::SetSummary {
          session_id,
          summary,
        } => SyncCommand::SetSummary {
          session_id: session_id.clone(),
          summary: summary.clone(),
        },
        PersistCommand::SetSessionConfig {
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
        } => SyncCommand::SetSessionConfig {
          session_id: session_id.clone(),
          approval_policy: approval_policy.clone(),
          sandbox_mode: sandbox_mode.clone(),
          permission_mode: permission_mode.clone(),
          collaboration_mode: collaboration_mode.clone(),
          multi_agent: *multi_agent,
          personality: personality.clone(),
          service_tier: service_tier.clone(),
          developer_instructions: developer_instructions.clone(),
          model: model.clone(),
          effort: effort.clone(),
          codex_config_mode: *codex_config_mode,
          codex_config_profile: codex_config_profile.clone(),
          codex_model_provider: codex_model_provider.clone(),
          codex_config_source: *codex_config_source,
          codex_config_overrides_json: codex_config_overrides_json.clone(),
        },
        PersistCommand::MarkSessionRead {
          session_id,
          up_to_sequence,
        } => SyncCommand::MarkSessionRead {
          session_id: session_id.clone(),
          up_to_sequence: *up_to_sequence,
        },
        PersistCommand::ReactivateSession { id } => {
          SyncCommand::ReactivateSession { id: id.clone() }
        }
        PersistCommand::ClaudeSessionUpsert {
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
        } => SyncCommand::ClaudeSessionUpsert {
          id: id.clone(),
          project_path: project_path.clone(),
          project_name: project_name.clone(),
          branch: branch.clone(),
          model: model.clone(),
          context_label: context_label.clone(),
          transcript_path: transcript_path.clone(),
          source: source.clone(),
          agent_type: agent_type.clone(),
          permission_mode: permission_mode.clone(),
          terminal_session_id: terminal_session_id.clone(),
          terminal_app: terminal_app.clone(),
          forked_from_session_id: forked_from_session_id.clone(),
          repository_root: repository_root.clone(),
          is_worktree: *is_worktree,
          git_sha: git_sha.clone(),
        },
        PersistCommand::ClaudeSessionUpdate {
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
        } => SyncCommand::ClaudeSessionUpdate {
          id: id.clone(),
          work_status: work_status.clone(),
          attention_reason: attention_reason.clone(),
          last_tool: last_tool.clone(),
          last_tool_at: last_tool_at.clone(),
          pending_tool_name: pending_tool_name.clone(),
          pending_tool_input: pending_tool_input.clone(),
          pending_question: pending_question.clone(),
          source: source.clone(),
          agent_type: agent_type.clone(),
          permission_mode: permission_mode.clone(),
          active_subagent_id: active_subagent_id.clone(),
          active_subagent_type: active_subagent_type.clone(),
          first_prompt: first_prompt.clone(),
          compact_count_increment: *compact_count_increment,
        },
        PersistCommand::ClaudeSessionEnd { id, reason } => SyncCommand::ClaudeSessionEnd {
          id: id.clone(),
          reason: reason.clone(),
        },
        PersistCommand::ClaudePromptIncrement { id, first_prompt } => {
          SyncCommand::ClaudePromptIncrement {
            id: id.clone(),
            first_prompt: first_prompt.clone(),
          }
        }
        PersistCommand::ClaudeToolIncrement { id } => {
          SyncCommand::ClaudeToolIncrement { id: id.clone() }
        }
        PersistCommand::ToolCountIncrement { session_id } => SyncCommand::ToolCountIncrement {
          session_id: session_id.clone(),
        },
        PersistCommand::ModelUpdate { session_id, model } => SyncCommand::ModelUpdate {
          session_id: session_id.clone(),
          model: model.clone(),
        },
        PersistCommand::EffortUpdate { session_id, effort } => SyncCommand::EffortUpdate {
          session_id: session_id.clone(),
          effort: effort.clone(),
        },
        PersistCommand::ClaudeSubagentStart {
          id,
          session_id,
          agent_type,
        } => SyncCommand::ClaudeSubagentStart {
          id: id.clone(),
          session_id: session_id.clone(),
          agent_type: agent_type.clone(),
        },
        PersistCommand::ClaudeSubagentEnd {
          id,
          transcript_path,
        } => SyncCommand::ClaudeSubagentEnd {
          id: id.clone(),
          transcript_path: transcript_path.clone(),
        },
        PersistCommand::UpsertSubagent { session_id, info } => SyncCommand::UpsertSubagent {
          session_id: session_id.clone(),
          info: info.clone(),
        },
        PersistCommand::UpsertSubagents { session_id, infos } => SyncCommand::UpsertSubagents {
          session_id: session_id.clone(),
          infos: infos.clone(),
        },
        PersistCommand::CodexPromptIncrement { id, first_prompt } => {
          SyncCommand::CodexPromptIncrement {
            id: id.clone(),
            first_prompt: first_prompt.clone(),
          }
        }
        PersistCommand::ApprovalRequested(params) => SyncCommand::ApprovalRequested(Box::new(
          SyncApprovalRequestedParams::from(params.as_ref()),
        )),
        PersistCommand::ApprovalDecision {
          session_id,
          request_id,
          decision,
        } => SyncCommand::ApprovalDecision {
          session_id: session_id.clone(),
          request_id: request_id.clone(),
          decision: decision.clone(),
        },
        PersistCommand::ReviewCommentCreate {
          id,
          session_id,
          turn_id,
          file_path,
          line_start,
          line_end,
          body,
          tag,
        } => SyncCommand::ReviewCommentCreate {
          id: id.clone(),
          session_id: session_id.clone(),
          turn_id: turn_id.clone(),
          file_path: file_path.clone(),
          line_start: *line_start,
          line_end: *line_end,
          body: body.clone(),
          tag: tag.clone(),
        },
        PersistCommand::ReviewCommentUpdate {
          id,
          body,
          tag,
          status,
        } => SyncCommand::ReviewCommentUpdate {
          id: id.clone(),
          body: body.clone(),
          tag: tag.clone(),
          status: status.clone(),
        },
        PersistCommand::ReviewCommentDelete { id } => {
          SyncCommand::ReviewCommentDelete { id: id.clone() }
        }
        PersistCommand::SetIntegrationMode {
          session_id,
          codex_mode,
          claude_mode,
        } => SyncCommand::SetIntegrationMode {
          session_id: session_id.clone(),
          codex_mode: codex_mode.clone(),
          claude_mode: claude_mode.clone(),
        },
        PersistCommand::EnvironmentUpdate {
          session_id,
          cwd,
          git_branch,
          git_sha,
          repository_root,
          is_worktree,
        } => SyncCommand::EnvironmentUpdate {
          session_id: session_id.clone(),
          cwd: cwd.clone(),
          git_branch: git_branch.clone(),
          git_sha: git_sha.clone(),
          repository_root: repository_root.clone(),
          is_worktree: *is_worktree,
        },
        PersistCommand::SetConfig { .. } => return None,
        PersistCommand::WorktreeCreate {
          id,
          repo_root,
          worktree_path,
          branch,
          base_branch,
          created_by,
        } => SyncCommand::WorktreeCreate {
          id: id.clone(),
          repo_root: repo_root.clone(),
          worktree_path: worktree_path.clone(),
          branch: branch.clone(),
          base_branch: base_branch.clone(),
          created_by: created_by.clone(),
        },
        PersistCommand::WorktreeUpdateStatus {
          id,
          status,
          last_session_ended_at,
        } => SyncCommand::WorktreeUpdateStatus {
          id: id.clone(),
          status: status.clone(),
          last_session_ended_at: last_session_ended_at.clone(),
        },
        PersistCommand::MissionCreate { .. }
        | PersistCommand::MissionUpdate { .. }
        | PersistCommand::MissionSetTrackerKey { .. }
        | PersistCommand::MissionDelete { .. } => return None,
        PersistCommand::MissionIssueUpsert {
          id,
          mission_id,
          issue_id,
          issue_identifier,
          issue_title,
          issue_state,
          orchestration_state,
          provider,
          url,
        } => SyncCommand::MissionIssueUpsert {
          id: id.clone(),
          mission_id: mission_id.clone(),
          issue_id: issue_id.clone(),
          issue_identifier: issue_identifier.clone(),
          issue_title: issue_title.clone(),
          issue_state: issue_state.clone(),
          orchestration_state: orchestration_state.clone(),
          provider: provider.clone(),
          url: url.clone(),
        },
        PersistCommand::MissionIssueUpdateState {
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
        } => SyncCommand::MissionIssueUpdateState {
          mission_id: mission_id.clone(),
          issue_id: issue_id.clone(),
          orchestration_state: orchestration_state.clone(),
          session_id: session_id.clone(),
          workspace_id: workspace_id.clone(),
          attempt: *attempt,
          last_error: last_error.clone(),
          retry_due_at: retry_due_at.clone(),
          started_at: started_at.clone(),
          completed_at: completed_at.clone(),
        },
        PersistCommand::MissionIssueSetPrUrl {
          mission_id,
          issue_id,
          pr_url,
        } => SyncCommand::MissionIssueSetPrUrl {
          mission_id: mission_id.clone(),
          issue_id: issue_id.clone(),
          pr_url: pr_url.clone(),
        },
        PersistCommand::RowsTurnStatusUpdate {
          session_id,
          row_ids,
          status,
        } => SyncCommand::RowsTurnStatusUpdate {
          session_id: session_id.clone(),
          row_ids: row_ids.clone(),
          status: *status,
        },
        PersistCommand::SetTranscriptPath { .. }
        | PersistCommand::SessionAttentionUpdate { .. }
        | PersistCommand::Flush { .. } => {
          unreachable!("these persistence commands are intentionally excluded from sync replay")
        }
      }),
    }
  }
}
