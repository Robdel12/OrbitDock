use super::*;

const DEFAULT_CONVERSATION_PAGE_SIZE: usize = 50;
const MAX_CONVERSATION_PAGE_SIZE: usize = 200;

#[derive(Debug, Serialize)]
pub struct SessionsResponse {
    pub sessions: Vec<SessionSummary>,
}

#[derive(Debug, Serialize)]
pub struct SessionResponse {
    pub session: SessionState,
}

#[derive(Debug, Serialize)]
pub struct ConversationBootstrapResponse {
    pub session: SessionState,
    pub total_message_count: u64,
    pub has_more_before: bool,
    pub oldest_sequence: Option<u64>,
    pub newest_sequence: Option<u64>,
}

#[derive(Debug, Serialize)]
pub struct ConversationHistoryResponse {
    pub session_id: String,
    pub messages: Vec<Message>,
    pub total_message_count: u64,
    pub has_more_before: bool,
    pub oldest_sequence: Option<u64>,
    pub newest_sequence: Option<u64>,
}

#[derive(Debug, Deserialize, Default)]
pub struct ConversationPageQuery {
    #[serde(default)]
    pub limit: Option<usize>,
    #[serde(default)]
    pub before_sequence: Option<u64>,
}

#[derive(Debug, Deserialize, Default)]
pub struct SessionSnapshotQuery {
    #[serde(default)]
    pub include_messages: bool,
}

#[derive(Debug, Serialize)]
pub struct MarkReadResponse {
    pub session_id: String,
    pub unread_count: u64,
}

fn clamp_conversation_limit(limit: Option<usize>) -> usize {
    limit
        .unwrap_or(DEFAULT_CONVERSATION_PAGE_SIZE)
        .clamp(1, MAX_CONVERSATION_PAGE_SIZE)
}

pub async fn list_sessions(State(state): State<Arc<SessionRegistry>>) -> Json<SessionsResponse> {
    Json(SessionsResponse {
        sessions: state.get_session_summaries(),
    })
}

pub async fn get_session(
    Path(session_id): Path<String>,
    Query(query): Query<SessionSnapshotQuery>,
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<SessionResponse> {
    match load_full_session_state(&state, &session_id, query.include_messages).await {
        Ok(session) => Ok(Json(SessionResponse { session })),
        Err(SessionLoadError::NotFound) => Err((
            StatusCode::NOT_FOUND,
            Json(ApiErrorResponse {
                code: "not_found",
                error: format!("Session {} not found", session_id),
            }),
        )),
        Err(SessionLoadError::Db(err)) => {
            error!(
                component = "api",
                event = "api.get_session.db_error",
                session_id = %session_id,
                error = %err,
                "Failed to load session from database"
            );
            Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ApiErrorResponse {
                    code: "db_error",
                    error: err,
                }),
            ))
        }
        Err(SessionLoadError::Runtime(err)) => {
            error!(
                component = "api",
                event = "api.get_session.runtime_error",
                session_id = %session_id,
                error = %err,
                "Failed to load runtime session state"
            );
            Err((
                StatusCode::SERVICE_UNAVAILABLE,
                Json(ApiErrorResponse {
                    code: "runtime_error",
                    error: err,
                }),
            ))
        }
    }
}

pub async fn get_conversation_bootstrap(
    Path(session_id): Path<String>,
    Query(query): Query<ConversationPageQuery>,
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<ConversationBootstrapResponse> {
    let limit = clamp_conversation_limit(query.limit);
    match load_conversation_bootstrap(&state, &session_id, limit).await {
        Ok(bootstrap) => Ok(Json(ConversationBootstrapResponse {
            session: bootstrap.session,
            total_message_count: bootstrap.total_message_count,
            has_more_before: bootstrap.has_more_before,
            oldest_sequence: bootstrap.oldest_sequence,
            newest_sequence: bootstrap.newest_sequence,
        })),
        Err(SessionLoadError::NotFound) => Err((
            StatusCode::NOT_FOUND,
            Json(ApiErrorResponse {
                code: "not_found",
                error: format!("Session {} not found", session_id),
            }),
        )),
        Err(SessionLoadError::Db(err)) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiErrorResponse {
                code: "db_error",
                error: err,
            }),
        )),
        Err(SessionLoadError::Runtime(err)) => Err((
            StatusCode::SERVICE_UNAVAILABLE,
            Json(ApiErrorResponse {
                code: "runtime_error",
                error: err,
            }),
        )),
    }
}

pub async fn get_conversation_history(
    Path(session_id): Path<String>,
    Query(query): Query<ConversationPageQuery>,
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<ConversationHistoryResponse> {
    let limit = clamp_conversation_limit(query.limit);
    match load_conversation_page(&state, &session_id, query.before_sequence, limit).await {
        Ok(page) => Ok(Json(ConversationHistoryResponse {
            session_id,
            messages: page.messages,
            total_message_count: page.total_message_count,
            has_more_before: page.has_more_before,
            oldest_sequence: page.oldest_sequence,
            newest_sequence: page.newest_sequence,
        })),
        Err(SessionLoadError::NotFound) => Err((
            StatusCode::NOT_FOUND,
            Json(ApiErrorResponse {
                code: "not_found",
                error: format!("Session {} not found", session_id),
            }),
        )),
        Err(SessionLoadError::Db(err)) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiErrorResponse {
                code: "db_error",
                error: err,
            }),
        )),
        Err(SessionLoadError::Runtime(err)) => Err((
            StatusCode::SERVICE_UNAVAILABLE,
            Json(ApiErrorResponse {
                code: "runtime_error",
                error: err,
            }),
        )),
    }
}

pub async fn mark_session_read(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<MarkReadResponse> {
    let actor = match state.get_session(&session_id) {
        Some(actor) => actor,
        None => {
            return Err((
                StatusCode::NOT_FOUND,
                Json(ApiErrorResponse {
                    code: "session_not_found",
                    error: format!("Session {} not found", session_id),
                }),
            ));
        }
    };

    let unread_count = actor.mark_read().await.unwrap_or(0);

    let max_seq: i64 = match load_messages_for_session(&session_id).await {
        Ok(messages) => messages.len() as i64,
        Err(_) => 0,
    };
    let _ = state
        .persist()
        .send(PersistCommand::MarkSessionRead {
            session_id: session_id.clone(),
            up_to_sequence: max_seq,
        })
        .await;

    Ok(Json(MarkReadResponse {
        session_id,
        unread_count,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{extract::Path, extract::State, Json};
    use orbitdock_protocol::{Message, MessageType, Provider};
    use rusqlite::{params, Connection};

    use crate::domain::sessions::session::SessionHandle;
    use crate::domain::sessions::transition::WorkPhase;
    use crate::infrastructure::migration_runner;
    use crate::infrastructure::paths;
    use crate::support::test_support::ensure_server_test_data_dir;
    use crate::transport::http::test_support::new_test_state;

    #[tokio::test]
    async fn list_sessions_returns_runtime_summaries() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let handle = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-api-test".to_string(),
        );
        state.add_session(handle);

        let Json(response) = list_sessions(State(state)).await;
        assert!(response
            .sessions
            .iter()
            .any(|session| session.id == session_id));
    }

    #[tokio::test]
    async fn get_session_omits_messages_by_default() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let mut handle = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-api-test".to_string(),
        );
        let large_content = "x".repeat(40_000);
        handle.add_message(Message {
            id: orbitdock_protocol::new_id(),
            session_id: session_id.clone(),
            sequence: None,
            message_type: MessageType::Assistant,
            content: large_content.clone(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: false,
            timestamp: "2024-01-01T00:00:00Z".to_string(),
            duration_ms: None,
            images: vec![],
        });
        state.add_session(handle);

        let response = get_session(
            Path(session_id),
            Query(SessionSnapshotQuery::default()),
            State(state),
        )
        .await;
        match response {
            Ok(Json(payload)) => {
                assert!(payload.session.messages.is_empty());
                assert_eq!(payload.session.total_message_count, Some(1));
            }
            Err((status, body)) => panic!(
                "expected successful session response, got status {:?} with error {:?}",
                status, body.error
            ),
        }
    }

    #[tokio::test]
    async fn get_session_includes_full_untruncated_message_content_when_requested() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let mut handle = SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-api-test".to_string(),
        );
        let large_content = "x".repeat(40_000);
        handle.add_message(Message {
            id: orbitdock_protocol::new_id(),
            session_id: session_id.clone(),
            sequence: None,
            message_type: MessageType::Assistant,
            content: large_content.clone(),
            tool_name: None,
            tool_input: None,
            tool_output: None,
            is_error: false,
            is_in_progress: false,
            timestamp: "2024-01-01T00:00:00Z".to_string(),
            duration_ms: None,
            images: vec![],
        });
        state.add_session(handle);

        let response = get_session(
            Path(session_id),
            Query(SessionSnapshotQuery {
                include_messages: true,
            }),
            State(state),
        )
        .await;
        match response {
            Ok(Json(payload)) => {
                assert_eq!(payload.session.messages.len(), 1);
                assert_eq!(payload.session.messages[0].content, large_content);
                assert!(!payload.session.messages[0].content.contains("[truncated]"));
            }
            Err((status, body)) => panic!(
                "expected successful session response, got status {:?} with error {:?}",
                status, body.error
            ),
        }
    }

    fn seed_message_history(session_id: &str, messages: &[Message]) {
        ensure_server_test_data_dir();
        let db_path = paths::db_path();
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent).expect("create http session test data dir");
        }
        let mut conn = Connection::open(&db_path).expect("open db");
        migration_runner::run_migrations(&mut conn).expect("run migrations");
        conn.execute(
            "INSERT OR REPLACE INTO sessions (id, project_path, project_name, provider, status, work_status, codex_integration_mode, started_at, last_activity_at)
             VALUES (?1, ?2, ?3, 'claude', 'active', 'waiting', 'direct', ?4, ?4)",
            params![
                session_id,
                "/tmp/orbitdock-api-test",
                "orbitdock-api-test",
                "2026-03-09T00:00:00Z",
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
            timestamp: "2026-03-09T00:00:00Z".to_string(),
            duration_ms: None,
            images: vec![],
        }
    }

    #[tokio::test]
    async fn conversation_bootstrap_endpoint_returns_full_history_when_runtime_window_is_sparse() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        let mut handle = SessionHandle::new(
            session_id.clone(),
            Provider::Claude,
            "/tmp/orbitdock-api-test".to_string(),
        );

        let messages: Vec<Message> = (0_u64..108)
            .map(|sequence| {
                test_message(
                    &session_id,
                    &format!("message-{sequence}"),
                    sequence,
                    &format!("message-{sequence}"),
                    match sequence % 5 {
                        0 => MessageType::User,
                        1 => MessageType::Assistant,
                        2 => MessageType::Tool,
                        3 => MessageType::Thinking,
                        _ => MessageType::Assistant,
                    },
                )
            })
            .collect();
        seed_message_history(&session_id, &messages);
        for message in messages.clone() {
            handle.add_message(message);
        }

        let sparse_sequences = [
            0_u64, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 33, 64, 71, 75, 85, 93, 95, 98,
        ];
        let mut sparse_state = handle.extract_state();
        sparse_state.phase = WorkPhase::Idle;
        sparse_state.messages = messages
            .into_iter()
            .filter(|message| {
                message
                    .sequence
                    .is_some_and(|sequence| sparse_sequences.contains(&sequence))
            })
            .collect();
        sparse_state.total_message_count = 108;
        handle.apply_state(sparse_state);

        state.add_session(handle);

        let response = get_conversation_bootstrap(
            Path(session_id),
            Query(ConversationPageQuery {
                limit: Some(200),
                before_sequence: None,
            }),
            State(state),
        )
        .await;

        match response {
            Ok(Json(payload)) => {
                assert_eq!(payload.total_message_count, 108);
                assert_eq!(payload.oldest_sequence, Some(0));
                assert_eq!(payload.newest_sequence, Some(107));
                assert_eq!(payload.session.messages.len(), 108);
                assert_eq!(
                    payload
                        .session
                        .messages
                        .first()
                        .and_then(|message| message.sequence),
                    Some(0)
                );
                assert_eq!(
                    payload
                        .session
                        .messages
                        .last()
                        .and_then(|message| message.sequence),
                    Some(107)
                );
            }
            Err((status, body)) => panic!(
                "expected successful conversation bootstrap, got status {:?} with error {:?}",
                status, body.error
            ),
        }
    }
}
