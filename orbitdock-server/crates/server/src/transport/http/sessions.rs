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
    State(state): State<Arc<SessionRegistry>>,
) -> ApiResult<SessionResponse> {
    match load_full_session_state(&state, &session_id).await {
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
