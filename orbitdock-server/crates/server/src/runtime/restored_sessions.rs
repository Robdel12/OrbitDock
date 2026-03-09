use orbitdock_protocol::{
    ClaudeIntegrationMode, CodexIntegrationMode, Provider, SessionState, SessionStatus, TokenUsage,
    TurnDiff, WorkStatus,
};

use crate::domain::sessions::session::SessionHandle;
use crate::infrastructure::persistence::{load_messages_from_transcript_path, RestoredSession};

pub(crate) async fn hydrate_restored_messages_if_missing(
    restored: &mut RestoredSession,
    session_id: &str,
) {
    if !restored.messages.is_empty() {
        return;
    }

    if let Some(ref transcript_path) = restored.transcript_path {
        if let Ok(messages) = load_messages_from_transcript_path(transcript_path, session_id).await
        {
            if !messages.is_empty() {
                restored.messages = messages;
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
    let total_message_count = restored.messages.len() as u64;
    let oldest_sequence = restored
        .messages
        .first()
        .and_then(|message| message.sequence);
    let newest_sequence = restored
        .messages
        .last()
        .and_then(|message| message.sequence);

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
        messages: restored.messages,
        total_message_count: Some(total_message_count),
        has_more_before: Some(false),
        oldest_sequence,
        newest_sequence,
        pending_approval: None,
        permission_mode: restored.permission_mode,
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
        TokenUsage {
            input_tokens: restored.input_tokens.max(0) as u64,
            output_tokens: restored.output_tokens.max(0) as u64,
            cached_tokens: restored.cached_tokens.max(0) as u64,
            context_window: restored.context_window.max(0) as u64,
        },
        restored.token_usage_snapshot_kind,
        restored.started_at,
        restored.last_activity_at,
        restored.messages,
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

#[cfg(test)]
mod tests {
    use orbitdock_protocol::{
        CodexIntegrationMode, Message, MessageType, Provider, SessionStatus,
        TokenUsageSnapshotKind, WorkStatus,
    };

    use super::{
        parse_provider, parse_session_status, parse_work_status, restored_session_to_handle,
        restored_session_to_state,
    };
    use crate::infrastructure::persistence::RestoredSession;

    fn restored_session() -> RestoredSession {
        RestoredSession {
            id: "session-1".into(),
            provider: "codex".into(),
            status: "active".into(),
            work_status: "working".into(),
            project_path: "/tmp/project".into(),
            transcript_path: Some("/tmp/project/transcript.jsonl".into()),
            project_name: Some("project".into()),
            model: Some("gpt-5".into()),
            custom_name: Some("Custom".into()),
            summary: Some("Summary".into()),
            codex_integration_mode: Some("passive".into()),
            claude_integration_mode: None,
            codex_thread_id: Some("thread-1".into()),
            claude_sdk_session_id: None,
            started_at: Some("2026-03-09T00:00:00Z".into()),
            last_activity_at: Some("2026-03-09T00:01:00Z".into()),
            approval_policy: Some("on-request".into()),
            sandbox_mode: Some("workspace-write".into()),
            permission_mode: Some("acceptEdits".into()),
            input_tokens: 10,
            output_tokens: 5,
            cached_tokens: 2,
            context_window: 100,
            token_usage_snapshot_kind: TokenUsageSnapshotKind::ContextTurn,
            pending_tool_name: Some("Read".into()),
            pending_tool_input: Some("file.txt".into()),
            pending_question: Some("Continue?".into()),
            pending_approval_id: Some("approval-1".into()),
            messages: vec![Message {
                id: "message-1".into(),
                session_id: "session-1".into(),
                sequence: Some(7),
                message_type: MessageType::Assistant,
                content: "hello".into(),
                tool_name: None,
                tool_input: None,
                tool_output: None,
                is_error: false,
                is_in_progress: false,
                timestamp: "2026-03-09T00:00:00Z".into(),
                duration_ms: None,
                images: vec![],
            }],
            forked_from_session_id: Some("source-1".into()),
            current_diff: Some("diff".into()),
            current_plan: Some("plan".into()),
            turn_diffs: vec![(
                "turn-1".into(),
                "diff".into(),
                4,
                3,
                1,
                50,
                TokenUsageSnapshotKind::ContextTurn,
            )],
            git_branch: Some("main".into()),
            git_sha: Some("abc123".into()),
            current_cwd: Some("/tmp/project".into()),
            first_prompt: Some("first prompt".into()),
            last_message: Some("last message".into()),
            end_reason: None,
            effort: Some("high".into()),
            terminal_session_id: Some("term-1".into()),
            terminal_app: Some("Ghostty".into()),
            approval_version: 3,
            unread_count: 4,
        }
    }

    #[test]
    fn restored_state_preserves_visible_session_fields() {
        let state = restored_session_to_state(restored_session());

        assert_eq!(state.provider, Provider::Codex);
        assert_eq!(state.status, SessionStatus::Active);
        assert_eq!(state.work_status, WorkStatus::Working);
        assert_eq!(state.messages.len(), 1);
        assert_eq!(state.total_message_count, Some(1));
        assert_eq!(state.oldest_sequence, Some(7));
        assert_eq!(state.newest_sequence, Some(7));
        assert_eq!(
            state.codex_integration_mode,
            Some(CodexIntegrationMode::Passive)
        );
        assert_eq!(state.approval_version, Some(3));
        assert_eq!(state.unread_count, 4);
    }

    #[test]
    fn restored_handle_uses_requested_runtime_status() {
        let handle = restored_session_to_handle(
            restored_session(),
            SessionStatus::Active,
            WorkStatus::Waiting,
        );
        let snapshot = handle.retained_state();

        assert_eq!(snapshot.provider, Provider::Codex);
        assert_eq!(snapshot.status, SessionStatus::Active);
        assert_eq!(snapshot.work_status, WorkStatus::Waiting);
        assert_eq!(snapshot.messages.len(), 1);
        assert_eq!(snapshot.effort.as_deref(), Some("high"));
        assert_eq!(snapshot.permission_mode.as_deref(), Some("acceptEdits"));
        assert_eq!(snapshot.pending_question.as_deref(), Some("Continue?"));
    }

    #[test]
    fn restored_parsers_match_user_facing_status_rules() {
        assert_eq!(parse_provider("CLAUDE"), Provider::Claude);
        assert_eq!(parse_provider("codex"), Provider::Codex);
        assert_eq!(
            parse_session_status(Some(&"user_requested".into()), "active"),
            SessionStatus::Ended
        );
        assert_eq!(
            parse_work_status(SessionStatus::Ended, "working"),
            WorkStatus::Ended
        );
        assert_eq!(
            parse_work_status(SessionStatus::Active, "question"),
            WorkStatus::Question
        );
    }
}
