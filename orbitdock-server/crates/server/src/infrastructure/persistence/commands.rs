use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::oneshot;

use orbitdock_protocol::conversation_contracts::ConversationRowEntry;
use orbitdock_protocol::{
    ApprovalPreview, ApprovalQuestionPrompt, ApprovalType, CodexConfigMode, CodexConfigSource,
    Provider, SessionStatus, SubagentInfo, TokenUsage, TokenUsageSnapshotKind, WorkStatus,
};

/// Commands that can be persisted.
#[derive(Debug)]
pub enum PersistCommand {
    /// Create a new session
    SessionCreate(Box<SessionCreateParams>),

    /// Update session status/work_status
    SessionUpdate {
        id: String,
        status: Option<SessionStatus>,
        work_status: Option<WorkStatus>,
        last_activity_at: Option<String>,
        last_progress_at: Option<String>,
    },

    /// End a session
    SessionEnd { id: String, reason: String },

    /// Append a conversation row
    RowAppend {
        session_id: String,
        entry: ConversationRowEntry,
        viewer_present: bool,
        /// When set, the DB-assigned sequence is sent back after INSERT.
        sequence_tx: Option<oneshot::Sender<u64>>,
    },

    /// Upsert a conversation row (update existing or insert new)
    RowUpsert {
        session_id: String,
        entry: ConversationRowEntry,
        viewer_present: bool,
        /// When set, the DB-assigned sequence is sent back after INSERT/UPDATE.
        sequence_tx: Option<oneshot::Sender<u64>>,
    },

    /// Update token usage
    TokensUpdate {
        session_id: String,
        usage: TokenUsage,
        snapshot_kind: TokenUsageSnapshotKind,
    },

    /// Update diff/plan for session
    TurnStateUpdate {
        session_id: String,
        diff: Option<String>,
        plan: Option<String>,
    },

    /// Persist a per-turn diff snapshot
    TurnDiffInsert {
        session_id: String,
        turn_id: String,
        turn_seq: u64,
        diff: String,
        input_tokens: u64,
        output_tokens: u64,
        cached_tokens: u64,
        context_window: u64,
        snapshot_kind: TokenUsageSnapshotKind,
    },

    /// Store codex-core thread ID for a session
    SetThreadId {
        session_id: String,
        thread_id: String,
    },

    /// End any non-direct session row that accidentally uses a direct thread id as session id
    CleanupThreadShadowSession { thread_id: String, reason: String },

    /// Store Claude SDK session ID for a direct Claude session
    SetClaudeSdkSessionId {
        session_id: String,
        claude_sdk_session_id: String,
    },

    /// End the hook-created shadow row for a managed Claude direct session
    CleanupClaudeShadowSession {
        claude_sdk_session_id: String,
        reason: String,
    },

    /// Set custom name for a session
    SetCustomName {
        session_id: String,
        custom_name: Option<String>,
    },

    /// Set AI-generated summary for a session
    SetSummary { session_id: String, summary: String },

    /// Persist session autonomy configuration
    SetSessionConfig {
        session_id: String,
        approval_policy: Option<Option<String>>,
        sandbox_mode: Option<Option<String>>,
        permission_mode: Option<Option<String>>,
        collaboration_mode: Option<Option<String>>,
        multi_agent: Option<Option<bool>>,
        personality: Option<Option<String>>,
        service_tier: Option<Option<String>>,
        developer_instructions: Option<Option<String>>,
        model: Option<Option<String>>,
        effort: Option<Option<String>>,
        codex_config_mode: Option<CodexConfigMode>,
        codex_config_profile: Option<String>,
        codex_model_provider: Option<String>,
        codex_config_source: Option<CodexConfigSource>,
        codex_config_overrides_json: Option<String>,
    },

    /// Mark messages as read up to a given sequence number
    MarkSessionRead {
        session_id: String,
        up_to_sequence: i64,
    },

    /// Reactivate an ended session (for resume)
    ReactivateSession { id: String },

    /// Upsert a Claude hook-backed session
    ClaudeSessionUpsert {
        id: String,
        project_path: String,
        project_name: Option<String>,
        branch: Option<String>,
        model: Option<String>,
        context_label: Option<String>,
        transcript_path: Option<String>,
        source: Option<String>,
        agent_type: Option<String>,
        permission_mode: Option<String>,
        terminal_session_id: Option<String>,
        terminal_app: Option<String>,
        forked_from_session_id: Option<String>,
        repository_root: Option<String>,
        is_worktree: bool,
        git_sha: Option<String>,
    },

    /// Update Claude session state/metadata from hook events
    ClaudeSessionUpdate {
        id: String,
        work_status: Option<String>,
        attention_reason: Option<Option<String>>,
        last_tool: Option<Option<String>>,
        last_tool_at: Option<Option<String>>,
        pending_tool_name: Option<Option<String>>,
        pending_tool_input: Option<Option<String>>,
        pending_question: Option<Option<String>>,
        source: Option<Option<String>>,
        agent_type: Option<Option<String>>,
        permission_mode: Option<Option<String>>,
        active_subagent_id: Option<Option<String>>,
        active_subagent_type: Option<Option<String>>,
        first_prompt: Option<String>,
        compact_count_increment: bool,
    },

    /// End Claude session
    ClaudeSessionEnd { id: String, reason: Option<String> },

    /// Increment prompt counter for Claude hook session
    ClaudePromptIncrement {
        id: String,
        first_prompt: Option<String>,
    },

    /// Increment tool counter for Claude hook session
    ClaudeToolIncrement { id: String },

    /// Increment tool counter for any direct session (transition-driven)
    ToolCountIncrement { session_id: String },

    /// Update model name for a session
    ModelUpdate { session_id: String, model: String },

    /// Update effort level for a session
    EffortUpdate {
        session_id: String,
        effort: Option<String>,
    },

    /// Create/refresh subagent row
    ClaudeSubagentStart {
        id: String,
        session_id: String,
        agent_type: String,
    },

    /// End subagent row
    ClaudeSubagentEnd {
        id: String,
        transcript_path: Option<String>,
    },

    /// Upsert a provider-reported subagent/worker row
    UpsertSubagent {
        session_id: String,
        info: SubagentInfo,
    },

    /// Upsert multiple provider-reported subagent/worker rows in one persistence pass
    UpsertSubagents {
        session_id: String,
        infos: Vec<SubagentInfo>,
    },

    /// Upsert a passive rollout-backed Codex session
    RolloutSessionUpsert {
        id: String,
        thread_id: String,
        project_path: String,
        project_name: Option<String>,
        branch: Option<String>,
        model: Option<String>,
        context_label: Option<String>,
        transcript_path: String,
        started_at: String,
    },

    /// Update rollout-backed session state
    RolloutSessionUpdate {
        id: String,
        project_path: Option<String>,
        model: Option<String>,
        status: Option<SessionStatus>,
        work_status: Option<WorkStatus>,
        attention_reason: Option<Option<String>>,
        pending_tool_name: Option<Option<String>>,
        pending_tool_input: Option<Option<String>>,
        pending_question: Option<Option<String>>,
        total_tokens: Option<i64>,
        last_tool: Option<Option<String>>,
        last_tool_at: Option<Option<String>>,
        custom_name: Option<Option<String>>,
    },

    /// Increment rollout prompt counter and set first prompt if missing
    RolloutPromptIncrement {
        id: String,
        first_prompt: Option<String>,
    },

    /// Increment direct Codex prompt counter and set first prompt if missing
    CodexPromptIncrement {
        id: String,
        first_prompt: Option<String>,
    },

    /// Increment rollout tool counter
    RolloutToolIncrement { id: String },

    /// Upsert a rollout checkpoint for an active/passive Codex JSONL file cursor
    UpsertRolloutCheckpoint {
        path: String,
        offset: u64,
        session_id: Option<String>,
        project_path: Option<String>,
        model_provider: Option<String>,
        ignore_existing: bool,
    },

    /// Delete a rollout checkpoint when a tracked file should be pruned
    DeleteRolloutCheckpoint { path: String },

    /// Persist an approval request event
    ApprovalRequested(Box<ApprovalRequestedParams>),

    /// Persist the user decision for an approval request
    ApprovalDecision {
        session_id: String,
        request_id: String,
        decision: String,
    },

    /// Create a review comment
    ReviewCommentCreate {
        id: String,
        session_id: String,
        turn_id: Option<String>,
        file_path: String,
        line_start: u32,
        line_end: Option<u32>,
        body: String,
        tag: Option<String>,
    },

    /// Update a review comment
    ReviewCommentUpdate {
        id: String,
        body: Option<String>,
        tag: Option<String>,
        status: Option<String>,
    },

    /// Delete a review comment
    ReviewCommentDelete { id: String },

    /// Update integration mode for a session (takeover: passive → direct)
    SetIntegrationMode {
        session_id: String,
        codex_mode: Option<String>,
        claude_mode: Option<String>,
    },

    /// Update environment info (cwd, git branch, git sha, worktree)
    EnvironmentUpdate {
        session_id: String,
        cwd: Option<String>,
        git_branch: Option<String>,
        git_sha: Option<String>,
        repository_root: Option<String>,
        is_worktree: Option<bool>,
    },

    /// Upsert a key-value config entry
    SetConfig { key: String, value: String },

    /// Persist a new worktree row
    WorktreeCreate {
        id: String,
        repo_root: String,
        worktree_path: String,
        branch: String,
        base_branch: Option<String>,
        created_by: String,
    },

    /// Update worktree lifecycle status
    WorktreeUpdateStatus {
        id: String,
        status: String,
        last_session_ended_at: Option<String>,
    },

    /// Create a new mission
    MissionCreate {
        id: String,
        name: String,
        repo_root: String,
        tracker_kind: String,
        provider: String,
        config_json: Option<String>,
        prompt_template: Option<String>,
        mission_file_path: Option<String>,
        tracker_api_key: Option<String>,
    },

    /// Update mission settings
    MissionUpdate {
        id: String,
        name: Option<String>,
        enabled: Option<bool>,
        paused: Option<bool>,
        tracker_kind: Option<String>,
        config_json: Option<String>,
        prompt_template: Option<String>,
        parse_error: Option<Option<String>>,
        mission_file_path: Option<Option<String>>,
    },

    /// Set or clear a mission-scoped tracker API key (encrypted at rest).
    MissionSetTrackerKey {
        mission_id: String,
        /// `Some(key)` to set, `None` to clear.
        key: Option<String>,
    },

    /// Delete a mission
    MissionDelete { id: String },

    /// Upsert a mission issue row
    MissionIssueUpsert {
        id: String,
        mission_id: String,
        issue_id: String,
        issue_identifier: String,
        issue_title: Option<String>,
        issue_state: Option<String>,
        orchestration_state: String,
        provider: Option<String>,
        url: Option<String>,
    },

    /// Update mission issue orchestration state (keyed on mission_id + issue_id)
    MissionIssueUpdateState {
        mission_id: String,
        issue_id: String,
        orchestration_state: String,
        session_id: Option<String>,
        attempt: Option<u32>,
        last_error: Option<Option<String>>,
        retry_due_at: Option<Option<String>>,
        started_at: Option<Option<String>>,
        completed_at: Option<Option<String>>,
    },
    MissionIssueSetPrUrl {
        mission_id: String,
        issue_id: String,
        pr_url: String,
    },
}

/// Serializable mirror of `PersistCommand` for remote workspace sync.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum SyncCommand {
    SessionCreate(Box<SyncSessionCreateParams>),
    SessionUpdate {
        id: String,
        status: Option<SessionStatus>,
        work_status: Option<WorkStatus>,
        last_activity_at: Option<String>,
        last_progress_at: Option<String>,
    },
    SessionEnd {
        id: String,
        reason: String,
    },
    RowAppend {
        session_id: String,
        entry: ConversationRowEntry,
        viewer_present: bool,
    },
    RowUpsert {
        session_id: String,
        entry: ConversationRowEntry,
        viewer_present: bool,
    },
    TokensUpdate {
        session_id: String,
        usage: TokenUsage,
        snapshot_kind: TokenUsageSnapshotKind,
    },
    TurnStateUpdate {
        session_id: String,
        diff: Option<String>,
        plan: Option<String>,
    },
    TurnDiffInsert {
        session_id: String,
        turn_id: String,
        turn_seq: u64,
        diff: String,
        input_tokens: u64,
        output_tokens: u64,
        cached_tokens: u64,
        context_window: u64,
        snapshot_kind: TokenUsageSnapshotKind,
    },
    SetThreadId {
        session_id: String,
        thread_id: String,
    },
    CleanupThreadShadowSession {
        thread_id: String,
        reason: String,
    },
    SetClaudeSdkSessionId {
        session_id: String,
        claude_sdk_session_id: String,
    },
    CleanupClaudeShadowSession {
        claude_sdk_session_id: String,
        reason: String,
    },
    SetCustomName {
        session_id: String,
        custom_name: Option<String>,
    },
    SetSummary {
        session_id: String,
        summary: String,
    },
    SetSessionConfig {
        session_id: String,
        approval_policy: Option<Option<String>>,
        sandbox_mode: Option<Option<String>>,
        permission_mode: Option<Option<String>>,
        collaboration_mode: Option<Option<String>>,
        multi_agent: Option<Option<bool>>,
        personality: Option<Option<String>>,
        service_tier: Option<Option<String>>,
        developer_instructions: Option<Option<String>>,
        model: Option<Option<String>>,
        effort: Option<Option<String>>,
        codex_config_mode: Option<CodexConfigMode>,
        codex_config_profile: Option<String>,
        codex_model_provider: Option<String>,
        codex_config_source: Option<CodexConfigSource>,
        codex_config_overrides_json: Option<String>,
    },
    MarkSessionRead {
        session_id: String,
        up_to_sequence: i64,
    },
    ReactivateSession {
        id: String,
    },
    ClaudeSessionUpsert {
        id: String,
        project_path: String,
        project_name: Option<String>,
        branch: Option<String>,
        model: Option<String>,
        context_label: Option<String>,
        transcript_path: Option<String>,
        source: Option<String>,
        agent_type: Option<String>,
        permission_mode: Option<String>,
        terminal_session_id: Option<String>,
        terminal_app: Option<String>,
        forked_from_session_id: Option<String>,
        repository_root: Option<String>,
        is_worktree: bool,
        git_sha: Option<String>,
    },
    ClaudeSessionUpdate {
        id: String,
        work_status: Option<String>,
        attention_reason: Option<Option<String>>,
        last_tool: Option<Option<String>>,
        last_tool_at: Option<Option<String>>,
        pending_tool_name: Option<Option<String>>,
        pending_tool_input: Option<Option<String>>,
        pending_question: Option<Option<String>>,
        source: Option<Option<String>>,
        agent_type: Option<Option<String>>,
        permission_mode: Option<Option<String>>,
        active_subagent_id: Option<Option<String>>,
        active_subagent_type: Option<Option<String>>,
        first_prompt: Option<String>,
        compact_count_increment: bool,
    },
    ClaudeSessionEnd {
        id: String,
        reason: Option<String>,
    },
    ClaudePromptIncrement {
        id: String,
        first_prompt: Option<String>,
    },
    ClaudeToolIncrement {
        id: String,
    },
    ToolCountIncrement {
        session_id: String,
    },
    ModelUpdate {
        session_id: String,
        model: String,
    },
    EffortUpdate {
        session_id: String,
        effort: Option<String>,
    },
    ClaudeSubagentStart {
        id: String,
        session_id: String,
        agent_type: String,
    },
    ClaudeSubagentEnd {
        id: String,
        transcript_path: Option<String>,
    },
    UpsertSubagent {
        session_id: String,
        info: SubagentInfo,
    },
    UpsertSubagents {
        session_id: String,
        infos: Vec<SubagentInfo>,
    },
    RolloutSessionUpsert {
        id: String,
        thread_id: String,
        project_path: String,
        project_name: Option<String>,
        branch: Option<String>,
        model: Option<String>,
        context_label: Option<String>,
        transcript_path: String,
        started_at: String,
    },
    RolloutSessionUpdate {
        id: String,
        project_path: Option<String>,
        model: Option<String>,
        status: Option<SessionStatus>,
        work_status: Option<WorkStatus>,
        attention_reason: Option<Option<String>>,
        pending_tool_name: Option<Option<String>>,
        pending_tool_input: Option<Option<String>>,
        pending_question: Option<Option<String>>,
        total_tokens: Option<i64>,
        last_tool: Option<Option<String>>,
        last_tool_at: Option<Option<String>>,
        custom_name: Option<Option<String>>,
    },
    RolloutPromptIncrement {
        id: String,
        first_prompt: Option<String>,
    },
    CodexPromptIncrement {
        id: String,
        first_prompt: Option<String>,
    },
    RolloutToolIncrement {
        id: String,
    },
    UpsertRolloutCheckpoint {
        path: String,
        offset: u64,
        session_id: Option<String>,
        project_path: Option<String>,
        model_provider: Option<String>,
        ignore_existing: bool,
    },
    DeleteRolloutCheckpoint {
        path: String,
    },
    ApprovalRequested(Box<SyncApprovalRequestedParams>),
    ApprovalDecision {
        session_id: String,
        request_id: String,
        decision: String,
    },
    ReviewCommentCreate {
        id: String,
        session_id: String,
        turn_id: Option<String>,
        file_path: String,
        line_start: u32,
        line_end: Option<u32>,
        body: String,
        tag: Option<String>,
    },
    ReviewCommentUpdate {
        id: String,
        body: Option<String>,
        tag: Option<String>,
        status: Option<String>,
    },
    ReviewCommentDelete {
        id: String,
    },
    SetIntegrationMode {
        session_id: String,
        codex_mode: Option<String>,
        claude_mode: Option<String>,
    },
    EnvironmentUpdate {
        session_id: String,
        cwd: Option<String>,
        git_branch: Option<String>,
        git_sha: Option<String>,
        repository_root: Option<String>,
        is_worktree: Option<bool>,
    },
    SetConfig {
        key: String,
        value: String,
    },
    WorktreeCreate {
        id: String,
        repo_root: String,
        worktree_path: String,
        branch: String,
        base_branch: Option<String>,
        created_by: String,
    },
    WorktreeUpdateStatus {
        id: String,
        status: String,
        last_session_ended_at: Option<String>,
    },
    MissionCreate {
        id: String,
        name: String,
        repo_root: String,
        tracker_kind: String,
        provider: String,
        config_json: Option<String>,
        prompt_template: Option<String>,
        mission_file_path: Option<String>,
        tracker_api_key: Option<String>,
    },
    MissionUpdate {
        id: String,
        name: Option<String>,
        enabled: Option<bool>,
        paused: Option<bool>,
        tracker_kind: Option<String>,
        config_json: Option<String>,
        prompt_template: Option<String>,
        parse_error: Option<Option<String>>,
        mission_file_path: Option<Option<String>>,
    },
    MissionSetTrackerKey {
        mission_id: String,
        key: Option<String>,
    },
    MissionDelete {
        id: String,
    },
    MissionIssueUpsert {
        id: String,
        mission_id: String,
        issue_id: String,
        issue_identifier: String,
        issue_title: Option<String>,
        issue_state: Option<String>,
        orchestration_state: String,
        provider: Option<String>,
        url: Option<String>,
    },
    MissionIssueUpdateState {
        mission_id: String,
        issue_id: String,
        orchestration_state: String,
        session_id: Option<String>,
        attempt: Option<u32>,
        last_error: Option<Option<String>>,
        retry_due_at: Option<Option<String>>,
        started_at: Option<Option<String>>,
        completed_at: Option<Option<String>>,
    },
    MissionIssueSetPrUrl {
        mission_id: String,
        issue_id: String,
        pr_url: String,
    },
}

#[cfg_attr(not(test), allow(dead_code))]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncEnvelope {
    pub sequence: u64,
    pub workspace_id: String,
    pub timestamp: String,
    pub command: SyncCommand,
}

impl PersistCommand {
    /// Returns true if this command has a response channel that the caller is awaiting.
    /// The writer should flush immediately when any batched command needs a response.
    pub fn has_response_channel(&self) -> bool {
        matches!(
            self,
            PersistCommand::RowAppend {
                sequence_tx: Some(_),
                ..
            } | PersistCommand::RowUpsert {
                sequence_tx: Some(_),
                ..
            }
        )
    }
}

impl From<&PersistCommand> for Option<SyncCommand> {
    fn from(value: &PersistCommand) -> Self {
        Some(match value {
            PersistCommand::SessionCreate(params) => {
                SyncCommand::SessionCreate(Box::new(SyncSessionCreateParams::from(params.as_ref())))
            }
            PersistCommand::SessionUpdate {
                id,
                status,
                work_status,
                last_activity_at,
                last_progress_at,
            } => SyncCommand::SessionUpdate {
                id: id.clone(),
                status: *status,
                work_status: *work_status,
                last_activity_at: last_activity_at.clone(),
                last_progress_at: last_progress_at.clone(),
            },
            PersistCommand::SessionEnd { id, reason } => SyncCommand::SessionEnd {
                id: id.clone(),
                reason: reason.clone(),
            },
            PersistCommand::RowAppend {
                session_id,
                entry,
                viewer_present,
                ..
            } => SyncCommand::RowAppend {
                session_id: session_id.clone(),
                entry: entry.clone(),
                viewer_present: *viewer_present,
            },
            PersistCommand::RowUpsert {
                session_id,
                entry,
                viewer_present,
                ..
            } => SyncCommand::RowUpsert {
                session_id: session_id.clone(),
                entry: entry.clone(),
                viewer_present: *viewer_present,
            },
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
            PersistCommand::UpsertSubagents { session_id, infos } => {
                SyncCommand::UpsertSubagents {
                    session_id: session_id.clone(),
                    infos: infos.clone(),
                }
            }
            PersistCommand::RolloutSessionUpsert {
                id,
                thread_id,
                project_path,
                project_name,
                branch,
                model,
                context_label,
                transcript_path,
                started_at,
            } => SyncCommand::RolloutSessionUpsert {
                id: id.clone(),
                thread_id: thread_id.clone(),
                project_path: project_path.clone(),
                project_name: project_name.clone(),
                branch: branch.clone(),
                model: model.clone(),
                context_label: context_label.clone(),
                transcript_path: transcript_path.clone(),
                started_at: started_at.clone(),
            },
            PersistCommand::RolloutSessionUpdate {
                id,
                project_path,
                model,
                status,
                work_status,
                attention_reason,
                pending_tool_name,
                pending_tool_input,
                pending_question,
                total_tokens,
                last_tool,
                last_tool_at,
                custom_name,
            } => SyncCommand::RolloutSessionUpdate {
                id: id.clone(),
                project_path: project_path.clone(),
                model: model.clone(),
                status: *status,
                work_status: *work_status,
                attention_reason: attention_reason.clone(),
                pending_tool_name: pending_tool_name.clone(),
                pending_tool_input: pending_tool_input.clone(),
                pending_question: pending_question.clone(),
                total_tokens: *total_tokens,
                last_tool: last_tool.clone(),
                last_tool_at: last_tool_at.clone(),
                custom_name: custom_name.clone(),
            },
            PersistCommand::RolloutPromptIncrement { id, first_prompt } => {
                SyncCommand::RolloutPromptIncrement {
                    id: id.clone(),
                    first_prompt: first_prompt.clone(),
                }
            }
            PersistCommand::CodexPromptIncrement { id, first_prompt } => {
                SyncCommand::CodexPromptIncrement {
                    id: id.clone(),
                    first_prompt: first_prompt.clone(),
                }
            }
            PersistCommand::RolloutToolIncrement { id } => {
                SyncCommand::RolloutToolIncrement { id: id.clone() }
            }
            PersistCommand::UpsertRolloutCheckpoint {
                path,
                offset,
                session_id,
                project_path,
                model_provider,
                ignore_existing,
            } => SyncCommand::UpsertRolloutCheckpoint {
                path: path.clone(),
                offset: *offset,
                session_id: session_id.clone(),
                project_path: project_path.clone(),
                model_provider: model_provider.clone(),
                ignore_existing: *ignore_existing,
            },
            PersistCommand::DeleteRolloutCheckpoint { path } => {
                SyncCommand::DeleteRolloutCheckpoint { path: path.clone() }
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
            PersistCommand::SetConfig { key, value } => SyncCommand::SetConfig {
                key: key.clone(),
                value: value.clone(),
            },
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
            PersistCommand::MissionCreate {
                id,
                name,
                repo_root,
                tracker_kind,
                provider,
                config_json,
                prompt_template,
                mission_file_path,
                tracker_api_key,
            } => SyncCommand::MissionCreate {
                id: id.clone(),
                name: name.clone(),
                repo_root: repo_root.clone(),
                tracker_kind: tracker_kind.clone(),
                provider: provider.clone(),
                config_json: config_json.clone(),
                prompt_template: prompt_template.clone(),
                mission_file_path: mission_file_path.clone(),
                tracker_api_key: tracker_api_key.clone(),
            },
            PersistCommand::MissionUpdate {
                id,
                name,
                enabled,
                paused,
                tracker_kind,
                config_json,
                prompt_template,
                parse_error,
                mission_file_path,
            } => SyncCommand::MissionUpdate {
                id: id.clone(),
                name: name.clone(),
                enabled: *enabled,
                paused: *paused,
                tracker_kind: tracker_kind.clone(),
                config_json: config_json.clone(),
                prompt_template: prompt_template.clone(),
                parse_error: parse_error.clone(),
                mission_file_path: mission_file_path.clone(),
            },
            PersistCommand::MissionSetTrackerKey { mission_id, key } => {
                SyncCommand::MissionSetTrackerKey {
                    mission_id: mission_id.clone(),
                    key: key.clone(),
                }
            }
            PersistCommand::MissionDelete { id } => SyncCommand::MissionDelete { id: id.clone() },
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
        })
    }
}

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
                last_activity_at,
                last_progress_at,
            } => PersistCommand::SessionUpdate {
                id,
                status,
                work_status,
                last_activity_at,
                last_progress_at,
            },
            SyncCommand::SessionEnd { id, reason } => PersistCommand::SessionEnd { id, reason },
            SyncCommand::RowAppend {
                session_id,
                entry,
                viewer_present,
            } => PersistCommand::RowAppend {
                session_id,
                entry,
                viewer_present,
                sequence_tx: None,
            },
            SyncCommand::RowUpsert {
                session_id,
                entry,
                viewer_present,
            } => PersistCommand::RowUpsert {
                session_id,
                entry,
                viewer_present,
                sequence_tx: None,
            },
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
            SyncCommand::RolloutSessionUpsert {
                id,
                thread_id,
                project_path,
                project_name,
                branch,
                model,
                context_label,
                transcript_path,
                started_at,
            } => PersistCommand::RolloutSessionUpsert {
                id,
                thread_id,
                project_path,
                project_name,
                branch,
                model,
                context_label,
                transcript_path,
                started_at,
            },
            SyncCommand::RolloutSessionUpdate {
                id,
                project_path,
                model,
                status,
                work_status,
                attention_reason,
                pending_tool_name,
                pending_tool_input,
                pending_question,
                total_tokens,
                last_tool,
                last_tool_at,
                custom_name,
            } => PersistCommand::RolloutSessionUpdate {
                id,
                project_path,
                model,
                status,
                work_status,
                attention_reason,
                pending_tool_name,
                pending_tool_input,
                pending_question,
                total_tokens,
                last_tool,
                last_tool_at,
                custom_name,
            },
            SyncCommand::RolloutPromptIncrement { id, first_prompt } => {
                PersistCommand::RolloutPromptIncrement { id, first_prompt }
            }
            SyncCommand::CodexPromptIncrement { id, first_prompt } => {
                PersistCommand::CodexPromptIncrement { id, first_prompt }
            }
            SyncCommand::RolloutToolIncrement { id } => PersistCommand::RolloutToolIncrement { id },
            SyncCommand::UpsertRolloutCheckpoint {
                path,
                offset,
                session_id,
                project_path,
                model_provider,
                ignore_existing,
            } => PersistCommand::UpsertRolloutCheckpoint {
                path,
                offset,
                session_id,
                project_path,
                model_provider,
                ignore_existing,
            },
            SyncCommand::DeleteRolloutCheckpoint { path } => {
                PersistCommand::DeleteRolloutCheckpoint { path }
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
            SyncCommand::ReviewCommentDelete { id } => {
                PersistCommand::ReviewCommentDelete { id }
            }
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
            SyncCommand::SetConfig { key, value } => PersistCommand::SetConfig { key, value },
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
            SyncCommand::MissionCreate {
                id,
                name,
                repo_root,
                tracker_kind,
                provider,
                config_json,
                prompt_template,
                mission_file_path,
                tracker_api_key,
            } => PersistCommand::MissionCreate {
                id,
                name,
                repo_root,
                tracker_kind,
                provider,
                config_json,
                prompt_template,
                mission_file_path,
                tracker_api_key,
            },
            SyncCommand::MissionUpdate {
                id,
                name,
                enabled,
                paused,
                tracker_kind,
                config_json,
                prompt_template,
                parse_error,
                mission_file_path,
            } => PersistCommand::MissionUpdate {
                id,
                name,
                enabled,
                paused,
                tracker_kind,
                config_json,
                prompt_template,
                parse_error,
                mission_file_path,
            },
            SyncCommand::MissionSetTrackerKey { mission_id, key } => {
                PersistCommand::MissionSetTrackerKey { mission_id, key }
            }
            SyncCommand::MissionDelete { id } => PersistCommand::MissionDelete { id },
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
        }
    }
}

/// Payload for `PersistCommand::SessionCreate`, boxed to keep the enum small.
#[derive(Debug)]
pub struct SessionCreateParams {
    pub id: String,
    pub provider: Provider,
    pub project_path: String,
    pub project_name: Option<String>,
    pub branch: Option<String>,
    pub model: Option<String>,
    pub approval_policy: Option<String>,
    pub sandbox_mode: Option<String>,
    pub permission_mode: Option<String>,
    pub collaboration_mode: Option<String>,
    pub multi_agent: Option<bool>,
    pub personality: Option<String>,
    pub service_tier: Option<String>,
    pub developer_instructions: Option<String>,
    pub codex_config_mode: Option<CodexConfigMode>,
    pub codex_config_profile: Option<String>,
    pub codex_model_provider: Option<String>,
    pub codex_config_source: Option<CodexConfigSource>,
    pub codex_config_overrides_json: Option<String>,
    pub forked_from_session_id: Option<String>,
    pub mission_id: Option<String>,
    pub issue_identifier: Option<String>,
    pub allow_bypass_permissions: bool,
    pub worktree_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncSessionCreateParams {
    pub id: String,
    pub provider: Provider,
    pub project_path: String,
    pub project_name: Option<String>,
    pub branch: Option<String>,
    pub model: Option<String>,
    pub approval_policy: Option<String>,
    pub sandbox_mode: Option<String>,
    pub permission_mode: Option<String>,
    pub collaboration_mode: Option<String>,
    pub multi_agent: Option<bool>,
    pub personality: Option<String>,
    pub service_tier: Option<String>,
    pub developer_instructions: Option<String>,
    pub codex_config_mode: Option<CodexConfigMode>,
    pub codex_config_profile: Option<String>,
    pub codex_model_provider: Option<String>,
    pub codex_config_source: Option<CodexConfigSource>,
    pub codex_config_overrides_json: Option<String>,
    pub forked_from_session_id: Option<String>,
    pub mission_id: Option<String>,
    pub issue_identifier: Option<String>,
    pub allow_bypass_permissions: bool,
    pub worktree_id: Option<String>,
}

impl From<&SessionCreateParams> for SyncSessionCreateParams {
    fn from(value: &SessionCreateParams) -> Self {
        Self {
            id: value.id.clone(),
            provider: value.provider,
            project_path: value.project_path.clone(),
            project_name: value.project_name.clone(),
            branch: value.branch.clone(),
            model: value.model.clone(),
            approval_policy: value.approval_policy.clone(),
            sandbox_mode: value.sandbox_mode.clone(),
            permission_mode: value.permission_mode.clone(),
            collaboration_mode: value.collaboration_mode.clone(),
            multi_agent: value.multi_agent,
            personality: value.personality.clone(),
            service_tier: value.service_tier.clone(),
            developer_instructions: value.developer_instructions.clone(),
            codex_config_mode: value.codex_config_mode,
            codex_config_profile: value.codex_config_profile.clone(),
            codex_model_provider: value.codex_model_provider.clone(),
            codex_config_source: value.codex_config_source,
            codex_config_overrides_json: value.codex_config_overrides_json.clone(),
            forked_from_session_id: value.forked_from_session_id.clone(),
            mission_id: value.mission_id.clone(),
            issue_identifier: value.issue_identifier.clone(),
            allow_bypass_permissions: value.allow_bypass_permissions,
            worktree_id: value.worktree_id.clone(),
        }
    }
}

impl From<SyncSessionCreateParams> for SessionCreateParams {
    fn from(value: SyncSessionCreateParams) -> Self {
        Self {
            id: value.id,
            provider: value.provider,
            project_path: value.project_path,
            project_name: value.project_name,
            branch: value.branch,
            model: value.model,
            approval_policy: value.approval_policy,
            sandbox_mode: value.sandbox_mode,
            permission_mode: value.permission_mode,
            collaboration_mode: value.collaboration_mode,
            multi_agent: value.multi_agent,
            personality: value.personality,
            service_tier: value.service_tier,
            developer_instructions: value.developer_instructions,
            codex_config_mode: value.codex_config_mode,
            codex_config_profile: value.codex_config_profile,
            codex_model_provider: value.codex_model_provider,
            codex_config_source: value.codex_config_source,
            codex_config_overrides_json: value.codex_config_overrides_json,
            forked_from_session_id: value.forked_from_session_id,
            mission_id: value.mission_id,
            issue_identifier: value.issue_identifier,
            allow_bypass_permissions: value.allow_bypass_permissions,
            worktree_id: value.worktree_id,
        }
    }
}

/// Payload for `PersistCommand::ApprovalRequested`, boxed to keep the enum small.
#[derive(Debug)]
pub struct ApprovalRequestedParams {
    pub session_id: String,
    pub request_id: String,
    pub approval_type: ApprovalType,
    pub tool_name: Option<String>,
    pub tool_input: Option<String>,
    pub command: Option<String>,
    pub file_path: Option<String>,
    pub diff: Option<String>,
    pub question: Option<String>,
    pub question_prompts: Vec<ApprovalQuestionPrompt>,
    pub preview: Option<ApprovalPreview>,
    pub permission_reason: Option<String>,
    pub requested_permissions: Option<Value>,
    pub granted_permissions: Option<Value>,
    pub cwd: Option<String>,
    pub proposed_amendment: Option<Vec<String>>,
    pub permission_suggestions: Option<Value>,
    pub elicitation_mode: Option<String>,
    pub elicitation_schema: Option<Value>,
    pub elicitation_url: Option<String>,
    pub elicitation_message: Option<String>,
    pub mcp_server_name: Option<String>,
    pub network_host: Option<String>,
    pub network_protocol: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncApprovalRequestedParams {
    pub session_id: String,
    pub request_id: String,
    pub approval_type: ApprovalType,
    pub tool_name: Option<String>,
    pub tool_input: Option<String>,
    pub command: Option<String>,
    pub file_path: Option<String>,
    pub diff: Option<String>,
    pub question: Option<String>,
    pub question_prompts: Vec<ApprovalQuestionPrompt>,
    pub preview: Option<ApprovalPreview>,
    pub permission_reason: Option<String>,
    pub requested_permissions: Option<Value>,
    pub granted_permissions: Option<Value>,
    pub cwd: Option<String>,
    pub proposed_amendment: Option<Vec<String>>,
    pub permission_suggestions: Option<Value>,
    pub elicitation_mode: Option<String>,
    pub elicitation_schema: Option<Value>,
    pub elicitation_url: Option<String>,
    pub elicitation_message: Option<String>,
    pub mcp_server_name: Option<String>,
    pub network_host: Option<String>,
    pub network_protocol: Option<String>,
}

impl From<&ApprovalRequestedParams> for SyncApprovalRequestedParams {
    fn from(value: &ApprovalRequestedParams) -> Self {
        Self {
            session_id: value.session_id.clone(),
            request_id: value.request_id.clone(),
            approval_type: value.approval_type,
            tool_name: value.tool_name.clone(),
            tool_input: value.tool_input.clone(),
            command: value.command.clone(),
            file_path: value.file_path.clone(),
            diff: value.diff.clone(),
            question: value.question.clone(),
            question_prompts: value.question_prompts.clone(),
            preview: value.preview.clone(),
            permission_reason: value.permission_reason.clone(),
            requested_permissions: value.requested_permissions.clone(),
            granted_permissions: value.granted_permissions.clone(),
            cwd: value.cwd.clone(),
            proposed_amendment: value.proposed_amendment.clone(),
            permission_suggestions: value.permission_suggestions.clone(),
            elicitation_mode: value.elicitation_mode.clone(),
            elicitation_schema: value.elicitation_schema.clone(),
            elicitation_url: value.elicitation_url.clone(),
            elicitation_message: value.elicitation_message.clone(),
            mcp_server_name: value.mcp_server_name.clone(),
            network_host: value.network_host.clone(),
            network_protocol: value.network_protocol.clone(),
        }
    }
}

impl From<SyncApprovalRequestedParams> for ApprovalRequestedParams {
    fn from(value: SyncApprovalRequestedParams) -> Self {
        Self {
            session_id: value.session_id,
            request_id: value.request_id,
            approval_type: value.approval_type,
            tool_name: value.tool_name,
            tool_input: value.tool_input,
            command: value.command,
            file_path: value.file_path,
            diff: value.diff,
            question: value.question,
            question_prompts: value.question_prompts,
            preview: value.preview,
            permission_reason: value.permission_reason,
            requested_permissions: value.requested_permissions,
            granted_permissions: value.granted_permissions,
            cwd: value.cwd,
            proposed_amendment: value.proposed_amendment,
            permission_suggestions: value.permission_suggestions,
            elicitation_mode: value.elicitation_mode,
            elicitation_schema: value.elicitation_schema,
            elicitation_url: value.elicitation_url,
            elicitation_message: value.elicitation_message,
            mcp_server_name: value.mcp_server_name,
            network_host: value.network_host,
            network_protocol: value.network_protocol,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use orbitdock_protocol::conversation_contracts::{
        ConversationRow, ConversationRowEntry, MessageRowContent,
    };
    use orbitdock_protocol::{
        ApprovalPreviewSegment, ApprovalPreviewType, ApprovalRiskLevel, SessionStatus,
        SubagentStatus,
    };
    use serde_json::json;

    fn sample_row_entry() -> ConversationRowEntry {
        ConversationRowEntry {
            session_id: "session-1".into(),
            sequence: 7,
            turn_id: Some("turn-1".into()),
            row: ConversationRow::User(MessageRowContent {
                id: "row-1".into(),
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

    fn sample_persist_commands() -> Vec<PersistCommand> {
        vec![
            PersistCommand::SessionCreate(Box::new(SessionCreateParams {
                id: "session-1".into(),
                provider: Provider::Codex,
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
                last_activity_at: Some("2026-03-24T12:01:00Z".into()),
                last_progress_at: Some("2026-03-24T12:02:00Z".into()),
            },
            PersistCommand::SessionEnd {
                id: "session-1".into(),
                reason: "completed".into(),
            },
            PersistCommand::RowAppend {
                session_id: "session-1".into(),
                entry: sample_row_entry(),
                viewer_present: true,
                sequence_tx: None,
            },
            PersistCommand::RowUpsert {
                session_id: "session-1".into(),
                entry: sample_row_entry(),
                viewer_present: false,
                sequence_tx: None,
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
            PersistCommand::RolloutSessionUpsert {
                id: "session-1".into(),
                thread_id: "thread-1".into(),
                project_path: "/repo".into(),
                project_name: Some("OrbitDock".into()),
                branch: Some("main".into()),
                model: Some("gpt-5.4".into()),
                context_label: Some("rollout".into()),
                transcript_path: "/tmp/rollout.jsonl".into(),
                started_at: "2026-03-24T12:00:00Z".into(),
            },
            PersistCommand::RolloutSessionUpdate {
                id: "session-1".into(),
                project_path: Some("/repo".into()),
                model: Some("gpt-5.4".into()),
                status: Some(SessionStatus::Ended),
                work_status: Some(WorkStatus::Ended),
                attention_reason: Some(Some("done".into())),
                pending_tool_name: Some(Some("shell".into())),
                pending_tool_input: Some(Some("ls".into())),
                pending_question: Some(Some("Continue?".into())),
                total_tokens: Some(123),
                last_tool: Some(Some("shell".into())),
                last_tool_at: Some(Some("2026-03-24T12:03:00Z".into())),
                custom_name: Some(Some("Rollout".into())),
            },
            PersistCommand::RolloutPromptIncrement {
                id: "session-1".into(),
                first_prompt: Some("start".into()),
            },
            PersistCommand::CodexPromptIncrement {
                id: "session-1".into(),
                first_prompt: Some("start".into()),
            },
            PersistCommand::RolloutToolIncrement {
                id: "session-1".into(),
            },
            PersistCommand::UpsertRolloutCheckpoint {
                path: "/tmp/rollout.jsonl".into(),
                offset: 99,
                session_id: Some("session-1".into()),
                project_path: Some("/repo".into()),
                model_provider: Some("openai".into()),
                ignore_existing: true,
            },
            PersistCommand::DeleteRolloutCheckpoint {
                path: "/tmp/rollout.jsonl".into(),
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
            PersistCommand::SetConfig {
                key: "workspace_provider".into(),
                value: "local".into(),
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

    #[test]
    fn sync_command_round_trips_every_persist_variant() {
        for persist in sample_persist_commands() {
            let sync = Option::<SyncCommand>::from(&persist)
                .expect("every persist command should have a sync mirror");
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
    fn sync_envelope_round_trips() {
        let envelope = SyncEnvelope {
            sequence: 42,
            workspace_id: "workspace-1".into(),
            timestamp: "2026-03-24T12:00:00Z".into(),
            command: Option::<SyncCommand>::from(&PersistCommand::SetConfig {
                key: "workspace_provider".into(),
                value: "daytona".into(),
            })
            .expect("set config should sync"),
        };

        let json = serde_json::to_string(&envelope).expect("envelope should serialize");
        let decoded: SyncEnvelope =
            serde_json::from_str(&json).expect("envelope should deserialize");
        let original_value = serde_json::to_value(&envelope).expect("original should serialize");
        let decoded_value = serde_json::to_value(&decoded).expect("decoded should serialize");
        assert_eq!(original_value, decoded_value);
    }

    #[test]
    fn row_sync_conversion_drops_response_channels() {
        let (sequence_tx, _sequence_rx) = oneshot::channel();
        let persist = PersistCommand::RowAppend {
            session_id: "session-1".into(),
            entry: sample_row_entry(),
            viewer_present: true,
            sequence_tx: Some(sequence_tx),
        };

        let sync = Option::<SyncCommand>::from(&persist).expect("row append should sync");
        let restored = PersistCommand::from(sync);

        match restored {
            PersistCommand::RowAppend { sequence_tx, .. } => {
                assert!(sequence_tx.is_none(), "sync restore should not recreate response channels");
            }
            other => panic!("expected row append after restore, got {other:?}"),
        }
    }
}
