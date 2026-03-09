use std::sync::Arc;

use orbitdock_protocol::{
    ClaudeIntegrationMode, CodexIntegrationMode, Provider, SessionState, SessionStatus, TokenUsage,
    TurnDiff, WorkStatus,
};
use tokio::sync::oneshot;
use tracing::warn;

use crate::domain::sessions::conversation::{ConversationBootstrap, ConversationPage};
use crate::infrastructure::persistence::{
    load_message_page_for_session, load_messages_for_session, load_messages_from_transcript_path,
    load_session_by_id, load_subagents_for_session, RestoredSession,
};
use crate::runtime::conversation_policy::{
    conversation_page_from_messages, conversation_page_with_total, expected_page_message_count,
    prepend_conversation_page, requires_coherent_history_page, COHERENT_HISTORY_MAX_MESSAGES,
};
use crate::runtime::session_actor::SessionActorHandle;
use crate::runtime::session_commands::SessionCommand;
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_runtime_helpers::hydrate_full_message_history;

#[derive(Debug)]
pub(crate) enum SessionLoadError {
    NotFound,
    Db(String),
    Runtime(String),
}

async fn expand_conversation_page(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    mut page: ConversationPage,
    chunk_limit: usize,
) -> Result<ConversationPage, SessionLoadError> {
    let page_chunk_limit = chunk_limit.max(1);

    while requires_coherent_history_page(&page.messages, page.has_more_before)
        && page.messages.len() < COHERENT_HISTORY_MAX_MESSAGES
    {
        let Some(before_sequence) = page.oldest_sequence else {
            break;
        };
        let remaining = COHERENT_HISTORY_MAX_MESSAGES.saturating_sub(page.messages.len());
        if remaining == 0 {
            break;
        }

        let older = load_raw_conversation_page(
            state,
            session_id,
            Some(before_sequence),
            page_chunk_limit.min(remaining),
        )
        .await?;
        if older.messages.is_empty() {
            break;
        }

        let previous_len = page.messages.len();
        page = prepend_conversation_page(page, older);
        if page.messages.len() == previous_len {
            break;
        }
    }

    Ok(page)
}

async fn top_up_runtime_page_from_db(
    session_id: &str,
    page: ConversationPage,
    before_sequence: Option<u64>,
    limit: usize,
) -> Result<ConversationPage, SessionLoadError> {
    if limit == 0 {
        return Ok(page);
    }

    let expected_count =
        expected_page_message_count(page.total_message_count, before_sequence, limit);
    if page.messages.len() >= expected_count {
        return Ok(page);
    }

    if page.messages.is_empty() {
        let db_page = load_message_page_for_session(session_id, before_sequence, limit)
            .await
            .map_err(|err| SessionLoadError::Db(err.to_string()))?;
        return Ok(conversation_page_with_total(
            db_page.messages,
            page.total_message_count.max(db_page.total_count),
        ));
    }

    let Some(oldest_runtime_sequence) = page.messages.first().and_then(|message| message.sequence)
    else {
        return Ok(page);
    };
    let remaining = limit.saturating_sub(page.messages.len());
    if remaining == 0 {
        return Ok(page);
    }

    let db_page =
        load_message_page_for_session(session_id, Some(oldest_runtime_sequence), remaining)
            .await
            .map_err(|err| SessionLoadError::Db(err.to_string()))?;
    if db_page.messages.is_empty() {
        return Ok(page);
    }

    let mut messages = db_page.messages;
    messages.extend(page.messages);
    Ok(conversation_page_with_total(
        messages,
        page.total_message_count.max(db_page.total_count),
    ))
}

async fn load_raw_conversation_page(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    before_sequence: Option<u64>,
    limit: usize,
) -> Result<ConversationPage, SessionLoadError> {
    if let Some(actor) = state.get_session(session_id) {
        let (reply_tx, reply_rx) = oneshot::channel();
        actor
            .send(SessionCommand::GetConversationPage {
                before_sequence,
                limit,
                reply: reply_tx,
            })
            .await;

        let page = reply_rx
            .await
            .map_err(|err| SessionLoadError::Runtime(err.to_string()))?;
        if !page.messages.is_empty() || page.total_message_count > 0 {
            return top_up_runtime_page_from_db(session_id, page, before_sequence, limit).await;
        }

        let snapshot = actor.snapshot();
        if let Some(path) = snapshot.transcript_path.clone() {
            let (reply_tx, reply_rx) = oneshot::channel();
            actor
                .send(SessionCommand::LoadTranscriptAndSync {
                    path,
                    session_id: session_id.to_string(),
                    reply: reply_tx,
                })
                .await;
            if let Ok(Some(loaded)) = reply_rx.await {
                return Ok(conversation_page_from_messages(
                    loaded.messages,
                    before_sequence,
                    limit,
                ));
            }
        }

        let page = load_message_page_for_session(session_id, before_sequence, limit)
            .await
            .map_err(|err| SessionLoadError::Db(err.to_string()))?;
        return Ok(ConversationPage {
            has_more_before: page
                .messages
                .first()
                .and_then(|message| message.sequence)
                .is_some_and(|sequence| sequence > 0),
            oldest_sequence: page.messages.first().and_then(|message| message.sequence),
            newest_sequence: page.messages.last().and_then(|message| message.sequence),
            total_message_count: page.total_count,
            messages: page.messages,
        });
    }

    match load_session_by_id(session_id).await {
        Ok(Some(mut restored)) => {
            let page = load_message_page_for_session(session_id, before_sequence, limit)
                .await
                .map_err(|err| SessionLoadError::Db(err.to_string()))?;
            if !page.messages.is_empty() || page.total_count > 0 {
                return Ok(ConversationPage {
                    has_more_before: page
                        .messages
                        .first()
                        .and_then(|message| message.sequence)
                        .is_some_and(|sequence| sequence > 0),
                    oldest_sequence: page.messages.first().and_then(|message| message.sequence),
                    newest_sequence: page.messages.last().and_then(|message| message.sequence),
                    total_message_count: page.total_count,
                    messages: page.messages,
                });
            }

            if restored.messages.is_empty() {
                if let Some(ref transcript_path) = restored.transcript_path {
                    if let Ok(messages) =
                        load_messages_from_transcript_path(transcript_path, session_id).await
                    {
                        restored.messages = messages;
                    }
                }
            }

            Ok(conversation_page_from_messages(
                restored.messages,
                before_sequence,
                limit,
            ))
        }
        Ok(None) => Err(SessionLoadError::NotFound),
        Err(err) => Err(SessionLoadError::Db(err.to_string())),
    }
}

pub(crate) async fn load_conversation_page(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    before_sequence: Option<u64>,
    limit: usize,
) -> Result<ConversationPage, SessionLoadError> {
    let page = load_raw_conversation_page(state, session_id, before_sequence, limit).await?;
    expand_conversation_page(state, session_id, page, limit).await
}

pub(crate) async fn load_conversation_bootstrap(
    state: &Arc<SessionRegistry>,
    session_id: &str,
    limit: usize,
) -> Result<ConversationBootstrap, SessionLoadError> {
    if let Some(actor) = state.get_session(session_id) {
        let (reply_tx, reply_rx) = oneshot::channel();
        actor
            .send(SessionCommand::GetConversationBootstrap {
                limit,
                reply: reply_tx,
            })
            .await;

        let mut bootstrap = reply_rx
            .await
            .map_err(|err| SessionLoadError::Runtime(err.to_string()))?;

        if bootstrap.session.messages.is_empty() && bootstrap.total_message_count == 0 {
            if let Some(path) = bootstrap.session.transcript_path.clone() {
                let (reply_tx, reply_rx) = oneshot::channel();
                actor
                    .send(SessionCommand::LoadTranscriptAndSync {
                        path,
                        session_id: session_id.to_string(),
                        reply: reply_tx,
                    })
                    .await;
                if let Ok(Some(loaded)) = reply_rx.await {
                    let page =
                        conversation_page_from_messages(loaded.messages.clone(), None, limit);
                    bootstrap.session = loaded;
                    bootstrap.session.messages = page.messages.clone();
                    bootstrap.total_message_count = page.total_message_count;
                    bootstrap.has_more_before = page.has_more_before;
                    bootstrap.oldest_sequence = page.oldest_sequence;
                    bootstrap.newest_sequence = page.newest_sequence;
                }
            }
        }

        if bootstrap.session.messages.is_empty() && bootstrap.total_message_count == 0 {
            let page = load_message_page_for_session(session_id, None, limit)
                .await
                .map_err(|err| SessionLoadError::Db(err.to_string()))?;
            bootstrap.session.messages = page.messages;
            bootstrap.total_message_count = page.total_count;
            bootstrap.has_more_before = bootstrap
                .session
                .messages
                .first()
                .and_then(|message| message.sequence)
                .is_some_and(|sequence| sequence > 0);
            bootstrap.oldest_sequence = bootstrap
                .session
                .messages
                .first()
                .and_then(|message| message.sequence);
            bootstrap.newest_sequence = bootstrap
                .session
                .messages
                .last()
                .and_then(|message| message.sequence);
        }

        let page = expand_conversation_page(
            state,
            session_id,
            top_up_runtime_page_from_db(
                session_id,
                ConversationPage {
                    messages: bootstrap.session.messages.clone(),
                    total_message_count: bootstrap.total_message_count,
                    has_more_before: bootstrap.has_more_before,
                    oldest_sequence: bootstrap.oldest_sequence,
                    newest_sequence: bootstrap.newest_sequence,
                },
                None,
                limit,
            )
            .await?,
            limit,
        )
        .await?;
        bootstrap.session.messages = page.messages.clone();
        bootstrap.session.total_message_count = Some(page.total_message_count);
        bootstrap.session.has_more_before = Some(page.has_more_before);
        bootstrap.session.oldest_sequence = page.oldest_sequence;
        bootstrap.session.newest_sequence = page.newest_sequence;
        bootstrap.total_message_count = page.total_message_count;
        bootstrap.has_more_before = page.has_more_before;
        bootstrap.oldest_sequence = page.oldest_sequence;
        bootstrap.newest_sequence = page.newest_sequence;

        hydrate_subagents(&mut bootstrap.session, session_id).await;
        return Ok(bootstrap);
    }

    match load_session_by_id(session_id).await {
        Ok(Some(mut restored)) => {
            let page = load_raw_conversation_page(state, session_id, None, limit).await?;
            let page = if !page.messages.is_empty() || page.total_message_count > 0 {
                page
            } else {
                if restored.messages.is_empty() {
                    if let Some(ref transcript_path) = restored.transcript_path {
                        if let Ok(messages) =
                            load_messages_from_transcript_path(transcript_path, session_id).await
                        {
                            restored.messages = messages;
                        }
                    }
                }
                conversation_page_from_messages(restored.messages.clone(), None, limit)
            };
            let page = expand_conversation_page(state, session_id, page, limit).await?;

            let mut state = restored_session_to_state(restored);
            state.messages = page.messages.clone();
            hydrate_subagents(&mut state, session_id).await;
            Ok(ConversationBootstrap {
                session: state,
                total_message_count: page.total_message_count,
                has_more_before: page.has_more_before,
                oldest_sequence: page.oldest_sequence,
                newest_sequence: page.newest_sequence,
            })
        }
        Ok(None) => Err(SessionLoadError::NotFound),
        Err(err) => Err(SessionLoadError::Db(err.to_string())),
    }
}

pub(crate) async fn load_full_session_state(
    state: &Arc<SessionRegistry>,
    session_id: &str,
) -> Result<SessionState, SessionLoadError> {
    if let Some(actor) = state.get_session(session_id) {
        let (reply_tx, reply_rx) = oneshot::channel();
        actor
            .send(SessionCommand::GetRetainedState { reply: reply_tx })
            .await;

        let mut snapshot = reply_rx
            .await
            .map_err(|err| SessionLoadError::Runtime(err.to_string()))?;

        hydrate_runtime_messages(&actor, &mut snapshot, session_id).await;
        snapshot.messages = hydrate_full_message_history(
            session_id,
            snapshot.messages,
            snapshot.total_message_count,
        )
        .await;
        snapshot.total_message_count = Some(snapshot.messages.len() as u64);
        snapshot.has_more_before = Some(false);
        snapshot.oldest_sequence = snapshot
            .messages
            .first()
            .and_then(|message| message.sequence);
        snapshot.newest_sequence = snapshot
            .messages
            .last()
            .and_then(|message| message.sequence);
        hydrate_subagents(&mut snapshot, session_id).await;
        return Ok(snapshot);
    }

    match load_session_by_id(session_id).await {
        Ok(Some(mut restored)) => {
            if restored.messages.is_empty() {
                if let Some(ref transcript_path) = restored.transcript_path {
                    if let Ok(messages) =
                        load_messages_from_transcript_path(transcript_path, session_id).await
                    {
                        if !messages.is_empty() {
                            restored.messages = messages;
                        }
                    }
                }
            }

            let mut state = restored_session_to_state(restored);
            hydrate_subagents(&mut state, session_id).await;
            Ok(state)
        }
        Ok(None) => Err(SessionLoadError::NotFound),
        Err(err) => Err(SessionLoadError::Db(err.to_string())),
    }
}

async fn hydrate_runtime_messages(
    actor: &SessionActorHandle,
    state: &mut SessionState,
    session_id: &str,
) {
    if !state.messages.is_empty() {
        return;
    }

    if let Some(path) = state.transcript_path.clone() {
        let (reply_tx, reply_rx) = oneshot::channel();
        actor
            .send(SessionCommand::LoadTranscriptAndSync {
                path,
                session_id: session_id.to_string(),
                reply: reply_tx,
            })
            .await;

        if let Ok(Some(loaded)) = reply_rx.await {
            *state = loaded;
        }
    }

    if state.messages.is_empty() {
        if let Ok(messages) = load_messages_for_session(session_id).await {
            if !messages.is_empty() {
                state.messages = messages;
            }
        }
    }
}

async fn hydrate_subagents(state: &mut SessionState, session_id: &str) {
    if !state.subagents.is_empty() {
        return;
    }

    match load_subagents_for_session(session_id).await {
        Ok(subagents) => {
            state.subagents = subagents;
        }
        Err(err) => {
            warn!(
                component = "api",
                event = "api.get_session.subagents_load_failed",
                session_id = %session_id,
                error = %err,
                "Failed to load session subagents"
            );
        }
    }
}

fn restored_session_to_state(restored: RestoredSession) -> SessionState {
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
                )| {
                    TurnDiff {
                        turn_id,
                        diff,
                        token_usage: Some(TokenUsage {
                            input_tokens: input_tokens as u64,
                            output_tokens: output_tokens as u64,
                            cached_tokens: cached_tokens as u64,
                            context_window: context_window as u64,
                        }),
                        snapshot_kind: Some(snapshot_kind),
                    }
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

fn parse_provider(value: &str) -> Provider {
    match value.to_ascii_lowercase().as_str() {
        "claude" => Provider::Claude,
        "codex" => Provider::Codex,
        _ => Provider::Claude,
    }
}

fn parse_session_status(end_reason: Option<&String>, value: &str) -> SessionStatus {
    if end_reason.is_some() {
        return SessionStatus::Ended;
    }

    if value.eq_ignore_ascii_case("ended") {
        SessionStatus::Ended
    } else {
        SessionStatus::Active
    }
}

fn parse_work_status(status: SessionStatus, value: &str) -> WorkStatus {
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

fn parse_codex_integration_mode(value: Option<String>) -> Option<CodexIntegrationMode> {
    match value.as_deref() {
        Some("direct") => Some(CodexIntegrationMode::Direct),
        Some("passive") => Some(CodexIntegrationMode::Passive),
        _ => None,
    }
}

fn parse_claude_integration_mode(value: Option<String>) -> Option<ClaudeIntegrationMode> {
    match value.as_deref() {
        Some("direct") => Some(ClaudeIntegrationMode::Direct),
        Some("passive") => Some(ClaudeIntegrationMode::Passive),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Once};

    use rusqlite::{params, Connection};
    use tokio::sync::mpsc;

    use orbitdock_protocol::{Message, MessageType, Provider};

    use crate::domain::sessions::session::SessionHandle;
    use crate::infrastructure::migration_runner;
    use crate::infrastructure::paths;

    use super::*;

    static INIT_TEST_DATA_DIR: Once = Once::new();

    fn ensure_test_data_dir() {
        INIT_TEST_DATA_DIR.call_once(|| {
            let dir = std::env::temp_dir().join("orbitdock-session-history-tests");
            paths::init_data_dir(Some(&dir));
        });
    }

    fn new_test_state() -> Arc<SessionRegistry> {
        ensure_test_data_dir();
        let (persist_tx, _persist_rx) = mpsc::channel(32);
        Arc::new(SessionRegistry::new_with_primary(persist_tx, true))
    }

    fn seed_message_history(session_id: &str, messages: &[Message]) {
        ensure_test_data_dir();
        let db_path = paths::db_path();
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent).expect("create session history test data dir");
        }
        let mut conn = Connection::open(&db_path).expect("open db");
        migration_runner::run_migrations(&mut conn).expect("run migrations");
        conn.execute(
            "INSERT OR REPLACE INTO sessions (id, project_path, project_name, provider, status, work_status, codex_integration_mode, started_at, last_activity_at)
             VALUES (?1, ?2, ?3, 'codex', 'active', 'waiting', 'direct', ?4, ?4)",
            params![
                session_id,
                "/tmp/orbitdock-session-history-test",
                "orbitdock-session-history-test",
                "2026-03-08T00:00:00Z",
            ],
        )
        .expect("insert test session");
        conn.execute(
            "DELETE FROM messages WHERE session_id = ?1",
            params![session_id],
        )
        .expect("clear test messages");

        for message in messages {
            let type_str = match message.message_type {
                MessageType::User => "user",
                MessageType::Assistant => "assistant",
                MessageType::Thinking => "thinking",
                MessageType::Tool => "tool",
                MessageType::ToolResult => "tool_result",
                MessageType::Steer => "steer",
                MessageType::Shell => "shell",
            };

            conn.execute(
                "INSERT OR REPLACE INTO messages (id, session_id, type, content, timestamp, sequence, tool_name, tool_input, tool_output, tool_duration, is_error, is_in_progress, images_json)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
                params![
                    message.id,
                    message.session_id,
                    type_str,
                    message.content,
                    message.timestamp,
                    message.sequence.map(|sequence| sequence as i64),
                    message.tool_name,
                    message.tool_input,
                    message.tool_output,
                    message.duration_ms.map(|d| d as f64 / 1000.0),
                    if message.is_error { 1 } else { 0 },
                    if message.is_in_progress { 1 } else { 0 },
                    None::<String>,
                ],
            )
            .expect("insert test message");
        }
    }

    fn test_message(
        session_id: &str,
        id: &str,
        sequence: u64,
        content: &str,
        message_type: MessageType,
    ) -> Message {
        Message {
            id: id.to_string(),
            session_id: session_id.to_string(),
            sequence: Some(sequence),
            message_type,
            content: content.to_string(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: false,
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            duration_ms: None,
            images: vec![],
        }
    }

    fn turn_messages(session_id: &str, turn_count: u64) -> Vec<Message> {
        let mut messages = Vec::with_capacity((turn_count * 2) as usize);
        for turn in 0_u64..turn_count {
            let user_sequence = turn * 2;
            let assistant_sequence = user_sequence + 1;
            messages.push(test_message(
                session_id,
                &format!("user-{turn}"),
                user_sequence,
                &format!("user-{turn}"),
                MessageType::User,
            ));
            messages.push(test_message(
                session_id,
                &format!("assistant-{turn}"),
                assistant_sequence,
                &format!("assistant-{turn}"),
                MessageType::Assistant,
            ));
        }
        messages
    }

    #[tokio::test]
    async fn conversation_bootstrap_reports_newest_window_and_total_count_for_trimmed_runtime_session(
    ) {
        let state = new_test_state();
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let mut handle = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-session-history-test".to_string(),
        );
        let messages = turn_messages(&session_id, 130);
        seed_message_history(&session_id, &messages);
        for message in messages {
            handle.add_message(message);
        }
        state.add_session(handle);

        let bootstrap = load_conversation_bootstrap(&state, &session_id, 50)
            .await
            .expect("load bootstrap for trimmed runtime session");

        assert_eq!(bootstrap.total_message_count, 260);
        assert!(bootstrap.has_more_before);
        assert_eq!(bootstrap.oldest_sequence, Some(210));
        assert_eq!(bootstrap.newest_sequence, Some(259));
        assert_eq!(bootstrap.session.total_message_count, Some(260));
        assert_eq!(bootstrap.session.messages.len(), 50);
        assert_eq!(bootstrap.session.messages[0].id, "user-105");
        assert_eq!(bootstrap.session.messages[49].id, "assistant-129");
    }

    #[tokio::test]
    async fn conversation_page_reads_older_history_from_db_when_runtime_tail_is_trimmed() {
        let state = new_test_state();
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let mut handle = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-session-history-test".to_string(),
        );
        let messages = turn_messages(&session_id, 130);
        seed_message_history(&session_id, &messages);
        for message in messages {
            handle.add_message(message);
        }
        state.add_session(handle);

        let page = load_conversation_page(&state, &session_id, Some(100), 50)
            .await
            .expect("load older history page from db");

        assert_eq!(page.total_message_count, 260);
        assert!(page.has_more_before);
        assert_eq!(page.oldest_sequence, Some(50));
        assert_eq!(page.newest_sequence, Some(99));
        assert_eq!(page.messages.len(), 50);
        assert_eq!(page.messages[0].id, "user-25");
        assert_eq!(page.messages[49].id, "assistant-49");
    }

    #[tokio::test]
    async fn full_session_state_rehydrates_trimmed_history_from_db() {
        let state = new_test_state();
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let mut handle = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-session-history-test".to_string(),
        );
        let messages = turn_messages(&session_id, 130);
        seed_message_history(&session_id, &messages);
        for message in messages {
            handle.add_message(message);
        }
        state.add_session(handle);

        let session = load_full_session_state(&state, &session_id)
            .await
            .expect("load full session state");

        assert_eq!(session.total_message_count, Some(260));
        assert_eq!(session.messages.len(), 260);
        assert_eq!(
            session.messages.first().map(|message| message.id.as_str()),
            Some("user-0")
        );
        assert_eq!(
            session.messages.last().map(|message| message.id.as_str()),
            Some("assistant-129")
        );
        assert_eq!(session.has_more_before, Some(false));
    }

    #[tokio::test]
    async fn conversation_bootstrap_expands_mid_turn_tail_to_recent_turn_boundary() {
        let state = new_test_state();
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let mut handle = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-session-history-test".to_string(),
        );
        let messages = turn_messages(&session_id, 130);
        seed_message_history(&session_id, &messages);
        for message in messages {
            handle.add_message(message);
        }
        state.add_session(handle);

        let bootstrap = load_conversation_bootstrap(&state, &session_id, 49)
            .await
            .expect("load coherent bootstrap window");

        assert_eq!(bootstrap.total_message_count, 260);
        assert!(bootstrap.has_more_before);
        assert_eq!(bootstrap.oldest_sequence, Some(162));
        assert_eq!(bootstrap.newest_sequence, Some(259));
        assert_eq!(bootstrap.session.messages.len(), 98);
        assert_eq!(bootstrap.session.messages[0].id, "user-81");
        assert_eq!(bootstrap.session.messages[97].id, "assistant-129");
    }

    #[tokio::test]
    async fn full_session_state_prefers_runtime_messages_over_stale_db_rows() {
        let state = new_test_state();
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let mut handle = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-session-history-test".to_string(),
        );
        let db_messages: Vec<Message> = turn_messages(&session_id, 130)
            .into_iter()
            .map(|mut message| {
                message.content = format!("db-{}", message.content);
                message
            })
            .collect();
        seed_message_history(&session_id, &db_messages);

        for sequence in 0_u64..260 {
            let content = if sequence == 259 {
                "runtime-updated-259".to_string()
            } else {
                format!(
                    "db-{}",
                    if sequence % 2 == 0 {
                        format!("user-{}", sequence / 2)
                    } else {
                        format!("assistant-{}", sequence / 2)
                    }
                )
            };
            handle.add_message(test_message(
                &session_id,
                &(if sequence % 2 == 0 {
                    format!("user-{}", sequence / 2)
                } else {
                    format!("assistant-{}", sequence / 2)
                }),
                sequence,
                &content,
                if sequence % 2 == 0 {
                    MessageType::User
                } else {
                    MessageType::Assistant
                },
            ));
        }
        state.add_session(handle);

        let session = load_full_session_state(&state, &session_id)
            .await
            .expect("load full session state with runtime override");

        assert_eq!(session.messages.len(), 260);
        assert_eq!(
            session
                .messages
                .last()
                .map(|message| message.content.as_str()),
            Some("runtime-updated-259")
        );
    }
}
