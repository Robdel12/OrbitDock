use serde_json::Value;
use tokio::sync::oneshot;

use orbitdock_protocol::conversation_contracts::ConversationRowEntry;
use orbitdock_protocol::{
    ApprovalPreview, ApprovalQuestionPrompt, ApprovalType, CodexConfigSource, Provider,
    SessionStatus, SubagentInfo, TokenUsage, TokenUsageSnapshotKind, WorkStatus,
};

/// Commands that can be persisted.
#[derive(Debug)]
pub enum PersistCommand {
    /// Create a new session
    SessionCreate {
        id: String,
        provider: Provider,
        project_path: String,
        project_name: Option<String>,
        branch: Option<String>,
        model: Option<String>,
        approval_policy: Option<String>,
        sandbox_mode: Option<String>,
        permission_mode: Option<String>,
        collaboration_mode: Option<String>,
        multi_agent: Option<bool>,
        personality: Option<String>,
        service_tier: Option<String>,
        developer_instructions: Option<String>,
        codex_config_source: Option<CodexConfigSource>,
        codex_config_overrides_json: Option<String>,
        forked_from_session_id: Option<String>,
        mission_id: Option<String>,
        issue_identifier: Option<String>,
        allow_bypass_permissions: bool,
    },

    /// Update session status/work_status
    SessionUpdate {
        id: String,
        status: Option<SessionStatus>,
        work_status: Option<WorkStatus>,
        last_activity_at: Option<String>,
    },

    /// End a session
    SessionEnd { id: String, reason: String },

    /// Append a conversation row
    RowAppend {
        session_id: String,
        entry: ConversationRowEntry,
        /// When set, the DB-assigned sequence is sent back after INSERT.
        sequence_tx: Option<oneshot::Sender<u64>>,
    },

    /// Upsert a conversation row (update existing or insert new)
    RowUpsert {
        session_id: String,
        entry: ConversationRowEntry,
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
    ApprovalRequested {
        session_id: String,
        request_id: String,
        approval_type: ApprovalType,
        tool_name: Option<String>,
        tool_input: Option<String>,
        command: Option<String>,
        file_path: Option<String>,
        diff: Option<String>,
        question: Option<String>,
        question_prompts: Vec<ApprovalQuestionPrompt>,
        preview: Option<ApprovalPreview>,
        permission_reason: Option<String>,
        requested_permissions: Option<Value>,
        granted_permissions: Option<Value>,
        cwd: Option<String>,
        proposed_amendment: Option<Vec<String>>,
        permission_suggestions: Option<Value>,
        elicitation_mode: Option<String>,
        elicitation_schema: Option<Value>,
        elicitation_url: Option<String>,
        elicitation_message: Option<String>,
        mcp_server_name: Option<String>,
        network_host: Option<String>,
        network_protocol: Option<String>,
    },

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

    /// Replace all cached Claude models
    SaveClaudeModels {
        models: Vec<orbitdock_protocol::ClaudeModelOption>,
    },

    /// Insert a single Claude model if it doesn't already exist.
    /// Preserves richer metadata from direct connector sessions.
    UpsertClaudeModelIfAbsent { value: String, display_name: String },

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
    },

    /// Update mission settings
    MissionUpdate {
        id: String,
        name: Option<String>,
        enabled: Option<bool>,
        paused: Option<bool>,
        config_json: Option<String>,
        prompt_template: Option<String>,
        parse_error: Option<Option<String>>,
        mission_file_path: Option<Option<String>>,
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
