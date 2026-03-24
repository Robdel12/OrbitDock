use serde::{Deserialize, Serialize};
use serde_json::Value;

use orbitdock_protocol::conversation_contracts::ConversationRowEntry;
use orbitdock_protocol::{
    ApprovalPreview, ApprovalQuestionPrompt, ApprovalType, CodexConfigMode, CodexConfigSource,
    Provider, SessionStatus, SubagentInfo, TokenUsage, TokenUsageSnapshotKind, WorkStatus,
};

use super::super::commands::{ApprovalRequestedParams, SessionCreateParams};

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
        sequence: u64,
    },
    RowUpsert {
        session_id: String,
        entry: ConversationRowEntry,
        viewer_present: bool,
        sequence: u64,
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
