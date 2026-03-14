use orbitdock_protocol::{
    ClaudeIntegrationMode, CodexIntegrationMode, Provider, SessionState, SessionStatus,
    SessionSummary, TokenUsage, TurnDiff, WorkStatus,
};

use crate::domain::sessions::session::SessionHandle;
use crate::infrastructure::persistence::{
    load_messages_from_transcript_path, load_session_by_id, RestoredSession,
};

pub(crate) struct PreparedResumeSession {
    pub provider: Provider,
    pub project_path: String,
    pub transcript_path: Option<String>,
    pub model: Option<String>,
    pub codex_thread_id: Option<String>,
    pub approval_policy: Option<String>,
    pub sandbox_mode: Option<String>,
    pub collaboration_mode: Option<String>,
    pub multi_agent: Option<bool>,
    pub personality: Option<String>,
    pub service_tier: Option<String>,
    pub developer_instructions: Option<String>,
    pub claude_sdk_session_id: Option<String>,
    pub row_count: usize,
    pub transcript_loaded: bool,
    pub summary: SessionSummary,
    pub handle: SessionHandle,
}

pub(crate) async fn hydrate_restored_rows_if_missing(
    restored: &mut RestoredSession,
    session_id: &str,
) {
    if !restored.rows.is_empty() {
        return;
    }

    if let Some(ref transcript_path) = restored.transcript_path {
        if let Ok(rows) = load_messages_from_transcript_path(transcript_path, session_id).await {
            if !rows.is_empty() {
                restored.rows = rows;
            }
        }
    }
}

pub(crate) fn parse_provider(value: &str) -> Provider {
    match value.to_ascii_lowercase().as_str() {
        "claude" => Provider::Claude,
        "codex" => Provider::Codex,
        _ => Provider::Claude,
    }
}

pub(crate) fn parse_session_status(end_reason: Option<&String>, value: &str) -> SessionStatus {
    if end_reason.is_some() {
        return SessionStatus::Ended;
    }

    if value.eq_ignore_ascii_case("ended") {
        SessionStatus::Ended
    } else {
        SessionStatus::Active
    }
}

pub(crate) fn parse_work_status(status: SessionStatus, value: &str) -> WorkStatus {
    if status == SessionStatus::Ended {
        return WorkStatus::Ended;
    }

    match value.to_ascii_lowercase().as_str() {
        "working" => WorkStatus::Working,
        "waiting" => WorkStatus::Waiting,
        "permission" => WorkStatus::Permission,
        "question" => WorkStatus::Question,
        "reply" => WorkStatus::Reply,
        "ended" => WorkStatus::Ended,
        _ => WorkStatus::Waiting,
    }
}

pub(crate) fn restored_session_to_state(restored: RestoredSession) -> SessionState {
    let provider = parse_provider(&restored.provider);
    let status = parse_session_status(restored.end_reason.as_ref(), &restored.status);
    let work_status = parse_work_status(status, &restored.work_status);
    let total_row_count = restored.rows.len() as u64;
    let oldest_sequence = restored.rows.first().map(|entry| entry.sequence);
    let newest_sequence = restored.rows.last().map(|entry| entry.sequence);

    SessionState {
        id: restored.id,
        provider,
        project_path: restored.project_path,
        transcript_path: restored.transcript_path,
        project_name: restored.project_name,
        model: restored.model,
        custom_name: restored.custom_name,
        summary: restored.summary,
        first_prompt: restored.first_prompt,
        last_message: restored.last_message,
        status,
        work_status,
        rows: restored.rows,
        total_row_count,
        has_more_before: false,
        oldest_sequence,
        newest_sequence,
        pending_approval: None,
        permission_mode: restored.permission_mode,
        collaboration_mode: restored.collaboration_mode,
        multi_agent: restored.multi_agent,
        personality: restored.personality,
        service_tier: restored.service_tier,
        developer_instructions: restored.developer_instructions,
        pending_tool_name: restored.pending_tool_name,
        pending_tool_input: restored.pending_tool_input,
        pending_question: restored.pending_question,
        pending_approval_id: restored.pending_approval_id,
        token_usage: TokenUsage {
            input_tokens: restored.input_tokens as u64,
            output_tokens: restored.output_tokens as u64,
            cached_tokens: restored.cached_tokens as u64,
            context_window: restored.context_window as u64,
        },
        token_usage_snapshot_kind: restored.token_usage_snapshot_kind,
        current_diff: restored.current_diff,
        current_plan: restored.current_plan,
        codex_integration_mode: parse_codex_integration_mode(restored.codex_integration_mode),
        claude_integration_mode: parse_claude_integration_mode(restored.claude_integration_mode),
        approval_policy: restored.approval_policy,
        sandbox_mode: restored.sandbox_mode,
        started_at: restored.started_at,
        last_activity_at: restored.last_activity_at,
        forked_from_session_id: restored.forked_from_session_id,
        revision: Some(0),
        current_turn_id: None,
        turn_count: 0,
        turn_diffs: restored
            .turn_diffs
            .into_iter()
            .map(
                |(
                    turn_id,
                    diff,
                    input_tokens,
                    output_tokens,
                    cached_tokens,
                    context_window,
                    snapshot_kind,
                )| TurnDiff {
                    turn_id,
                    diff,
                    token_usage: Some(TokenUsage {
                        input_tokens: input_tokens as u64,
                        output_tokens: output_tokens as u64,
                        cached_tokens: cached_tokens as u64,
                        context_window: context_window as u64,
                    }),
                    snapshot_kind: Some(snapshot_kind),
                },
            )
            .collect(),
        git_branch: restored.git_branch,
        git_sha: restored.git_sha,
        current_cwd: restored.current_cwd,
        subagents: Vec::new(),
        effort: restored.effort,
        terminal_session_id: restored.terminal_session_id,
        terminal_app: restored.terminal_app,
        approval_version: Some(restored.approval_version),
        repository_root: None,
        is_worktree: false,
        worktree_id: None,
        unread_count: restored.unread_count,
        messages: vec![],
    }
}

pub(crate) fn restored_session_to_handle(
    restored: RestoredSession,
    status: SessionStatus,
    work_status: WorkStatus,
) -> SessionHandle {
    let provider = parse_provider(&restored.provider);

    SessionHandle::restore(
        restored.id,
        provider,
        restored.project_path,
        restored.transcript_path,
        restored.project_name,
        restored.model,
        restored.custom_name,
        restored.summary,
        status,
        work_status,
        restored.approval_policy,
        restored.sandbox_mode,
        restored.permission_mode,
        restored.collaboration_mode,
        restored.multi_agent,
        restored.personality,
        restored.service_tier,
        restored.developer_instructions,
        TokenUsage {
            input_tokens: restored.input_tokens.max(0) as u64,
            output_tokens: restored.output_tokens.max(0) as u64,
            cached_tokens: restored.cached_tokens.max(0) as u64,
            context_window: restored.context_window.max(0) as u64,
        },
        restored.token_usage_snapshot_kind,
        restored.started_at,
        restored.last_activity_at,
        restored.rows,
        restored.current_diff,
        restored.current_plan,
        restored
            .turn_diffs
            .into_iter()
            .map(
                |(
                    turn_id,
                    diff,
                    input_tokens,
                    output_tokens,
                    cached_tokens,
                    context_window,
                    snapshot_kind,
                )| {
                    let has_tokens = input_tokens > 0 || output_tokens > 0 || context_window > 0;
                    TurnDiff {
                        turn_id,
                        diff,
                        token_usage: if has_tokens {
                            Some(TokenUsage {
                                input_tokens: input_tokens as u64,
                                output_tokens: output_tokens as u64,
                                cached_tokens: cached_tokens as u64,
                                context_window: context_window as u64,
                            })
                        } else {
                            None
                        },
                        snapshot_kind: Some(snapshot_kind),
                    }
                },
            )
            .collect(),
        restored.git_branch,
        restored.git_sha,
        restored.current_cwd,
        restored.first_prompt,
        restored.last_message,
        restored.pending_tool_name,
        restored.pending_tool_input,
        restored.pending_question,
        restored.pending_approval_id,
        restored.effort,
        restored.terminal_session_id,
        restored.terminal_app,
        restored.approval_version,
        restored.unread_count,
    )
}

pub(crate) fn prepare_restored_session_for_direct_resume(
    restored: RestoredSession,
    transcript_loaded: bool,
) -> PreparedResumeSession {
    let provider = parse_provider(&restored.provider);
    let project_path = restored.project_path.clone();
    let transcript_path = restored.transcript_path.clone();
    let model = restored.model.clone();
    let codex_thread_id = restored.codex_thread_id.clone();
    let approval_policy = restored.approval_policy.clone();
    let sandbox_mode = restored.sandbox_mode.clone();
    let collaboration_mode = restored.collaboration_mode.clone();
    let multi_agent = restored.multi_agent;
    let personality = restored.personality.clone();
    let service_tier = restored.service_tier.clone();
    let developer_instructions = restored.developer_instructions.clone();
    let claude_sdk_session_id = restored.claude_sdk_session_id.clone();
    let row_count = restored.rows.len();

    let mut handle =
        restored_session_to_handle(restored, SessionStatus::Active, WorkStatus::Waiting);
    match provider {
        Provider::Claude => handle.set_claude_integration_mode(Some(ClaudeIntegrationMode::Direct)),
        Provider::Codex => handle.set_codex_integration_mode(Some(CodexIntegrationMode::Direct)),
    }
    let summary = handle.summary();

    PreparedResumeSession {
        provider,
        project_path,
        transcript_path,
        model,
        codex_thread_id,
        approval_policy,
        sandbox_mode,
        collaboration_mode,
        multi_agent,
        personality,
        service_tier,
        developer_instructions,
        claude_sdk_session_id,
        row_count,
        transcript_loaded,
        summary,
        handle,
    }
}

pub(crate) async fn load_prepared_resume_session(
    session_id: &str,
) -> Result<Option<PreparedResumeSession>, anyhow::Error> {
    let Some(mut restored) = load_session_by_id(session_id).await? else {
        return Ok(None);
    };

    let initial_row_count = restored.rows.len();
    hydrate_restored_rows_if_missing(&mut restored, session_id).await;
    let transcript_loaded = initial_row_count == 0 && !restored.rows.is_empty();

    Ok(Some(prepare_restored_session_for_direct_resume(
        restored,
        transcript_loaded,
    )))
}

fn parse_codex_integration_mode(value: Option<String>) -> Option<CodexIntegrationMode> {
    match value.as_deref().map(str::to_ascii_lowercase).as_deref() {
        Some("direct") => Some(CodexIntegrationMode::Direct),
        Some("passive") => Some(CodexIntegrationMode::Passive),
        _ => None,
    }
}

fn parse_claude_integration_mode(value: Option<String>) -> Option<ClaudeIntegrationMode> {
    match value.as_deref().map(str::to_ascii_lowercase).as_deref() {
        Some("direct") => Some(ClaudeIntegrationMode::Direct),
        Some("passive") => Some(ClaudeIntegrationMode::Passive),
        _ => None,
    }
}
