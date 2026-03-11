use super::*;

#[derive(Debug, Serialize)]
pub struct AcceptedResponse {
    pub accepted: bool,
}

#[derive(Debug, Serialize)]
pub struct SendMessageResponse {
    pub accepted: bool,
    pub message: orbitdock_protocol::Message,
}

#[derive(Debug, Serialize)]
pub struct UploadedImageAttachmentResponse {
    pub image: ImageInput,
}

#[derive(Debug, Deserialize)]
pub struct SendSessionMessageRequest {
    pub content: String,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub effort: Option<String>,
    #[serde(default)]
    pub skills: Vec<SkillInput>,
    #[serde(default)]
    pub images: Vec<ImageInput>,
    #[serde(default)]
    pub mentions: Vec<MentionInput>,
}

#[derive(Debug, Deserialize)]
pub struct SteerTurnRequest {
    #[serde(default)]
    pub content: String,
    #[serde(default)]
    pub images: Vec<ImageInput>,
    #[serde(default)]
    pub mentions: Vec<MentionInput>,
}

#[derive(Debug, Deserialize, Default)]
pub struct UploadImageAttachmentQuery {
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default)]
    pub pixel_width: Option<u32>,
    #[serde(default)]
    pub pixel_height: Option<u32>,
}

#[derive(Debug, Deserialize)]
pub struct RollbackTurnsRequest {
    pub num_turns: u32,
}

#[derive(Debug, Deserialize)]
pub struct StopTaskRequest {
    pub task_id: String,
}

#[derive(Debug, Deserialize)]
pub struct RewindFilesRequest {
    pub user_message_id: String,
}

fn next_http_message_id(prefix: &str) -> String {
    format!("{prefix}-{}", orbitdock_protocol::new_id())
}

pub async fn post_session_message(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<SendSessionMessageRequest>,
) -> Result<(StatusCode, Json<SendMessageResponse>), (StatusCode, Json<ApiErrorResponse>)> {
    if body.content.is_empty()
        && body.images.is_empty()
        && body.mentions.is_empty()
        && body.skills.is_empty()
    {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiErrorResponse {
                code: "invalid_request",
                error: "Provide content, images, mentions, or skills to send a turn".to_string(),
            }),
        ));
    }

    let message_id = next_http_message_id("user-http");

    let user_msg = crate::runtime::message_dispatch::dispatch_send_message(
        &state,
        crate::runtime::message_dispatch::DispatchSendMessage {
            session_id: session_id.clone(),
            content: body.content,
            model: body.model,
            effort: body.effort,
            skills: body.skills,
            images: body.images,
            mentions: body.mentions,
            message_id,
        },
    )
    .await
    .map_err(|error| messaging_dispatch_error_response(error, &session_id))?;

    Ok((
        StatusCode::ACCEPTED,
        Json(SendMessageResponse {
            accepted: true,
            message: user_msg,
        }),
    ))
}

pub async fn upload_session_image_attachment(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Query(query): Query<UploadImageAttachmentQuery>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<UploadedImageAttachmentResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    if state.get_session(&session_id).is_none() {
        return Err((
            StatusCode::NOT_FOUND,
            Json(ApiErrorResponse {
                code: "not_found",
                error: format!("Session {} not found", session_id),
            }),
        ));
    }

    if body.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiErrorResponse {
                code: "invalid_request",
                error: "Provide image bytes in the request body".to_string(),
            }),
        ));
    }

    let mime_type = headers
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            (
                StatusCode::BAD_REQUEST,
                Json(ApiErrorResponse {
                    code: "invalid_request",
                    error: "Set the image MIME type in the Content-Type header".to_string(),
                }),
            )
        })?;

    let image = crate::infrastructure::images::store_uploaded_attachment(
        &session_id,
        body.as_ref(),
        mime_type,
        query.display_name.as_deref(),
        query.pixel_width,
        query.pixel_height,
    )
    .map_err(|error| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiErrorResponse {
                code: "attachment_store_failed",
                error,
            }),
        )
    })?;

    Ok(Json(UploadedImageAttachmentResponse { image }))
}

pub async fn get_session_image_attachment(
    Path((session_id, attachment_id)): Path<(String, String)>,
) -> Result<impl IntoResponse, (StatusCode, Json<ApiErrorResponse>)> {
    let (bytes, mime_type) = crate::infrastructure::images::read_attachment_bytes(
        &session_id,
        &attachment_id,
    )
    .map_err(|error| {
        let status = if error.contains("invalid attachment id") || error.contains("read attachment")
        {
            StatusCode::NOT_FOUND
        } else {
            StatusCode::INTERNAL_SERVER_ERROR
        };
        (
            status,
            Json(ApiErrorResponse {
                code: "attachment_read_failed",
                error,
            }),
        )
    })?;

    Ok(([(CONTENT_TYPE, mime_type)], bytes))
}

pub async fn post_steer_turn(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<SteerTurnRequest>,
) -> Result<(StatusCode, Json<AcceptedResponse>), (StatusCode, Json<ApiErrorResponse>)> {
    if body.content.is_empty() && body.images.is_empty() && body.mentions.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiErrorResponse {
                code: "invalid_request",
                error: "Provide content, images, or mentions to steer the active turn".to_string(),
            }),
        ));
    }

    let message_id = next_http_message_id("steer-http");

    crate::runtime::message_dispatch::dispatch_steer_turn(
        &state,
        session_id.clone(),
        body.content,
        body.images,
        body.mentions,
        message_id,
    )
    .await
    .map_err(|error| messaging_dispatch_error_response(error, &session_id))?;

    Ok((
        StatusCode::ACCEPTED,
        Json(AcceptedResponse { accepted: true }),
    ))
}

pub async fn interrupt_session(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    crate::runtime::message_dispatch::dispatch_interrupt(&state, &session_id)
        .await
        .map_err(|code| dispatch_error_response(code, &session_id))?;
    Ok(Json(AcceptedResponse { accepted: true }))
}

pub async fn compact_context(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    crate::runtime::message_dispatch::dispatch_compact(&state, &session_id)
        .await
        .map_err(|code| dispatch_error_response(code, &session_id))?;
    Ok(Json(AcceptedResponse { accepted: true }))
}

pub async fn undo_last_turn(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    crate::runtime::message_dispatch::dispatch_undo(&state, &session_id)
        .await
        .map_err(|code| dispatch_error_response(code, &session_id))?;
    Ok(Json(AcceptedResponse { accepted: true }))
}

pub async fn rollback_turns(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<RollbackTurnsRequest>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    if body.num_turns < 1 {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ApiErrorResponse {
                code: "invalid_argument",
                error: "num_turns must be >= 1".to_string(),
            }),
        ));
    }
    crate::runtime::message_dispatch::dispatch_rollback(&state, &session_id, body.num_turns)
        .await
        .map_err(|code| dispatch_error_response(code, &session_id))?;
    Ok(Json(AcceptedResponse { accepted: true }))
}

pub async fn stop_task(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<StopTaskRequest>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    crate::runtime::message_dispatch::dispatch_stop_task(&state, &session_id, body.task_id)
        .await
        .map_err(|code| dispatch_error_response(code, &session_id))?;
    Ok(Json(AcceptedResponse { accepted: true }))
}

pub async fn rewind_files(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<RewindFilesRequest>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    crate::runtime::message_dispatch::dispatch_rewind_files(
        &state,
        &session_id,
        body.user_message_id,
    )
    .await
    .map_err(|code| dispatch_error_response(code, &session_id))?;
    Ok(Json(AcceptedResponse { accepted: true }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::to_bytes;
    use axum::extract::{Path, State};
    use axum::response::IntoResponse;
    use orbitdock_protocol::{MessageType, Provider};
    use tokio::sync::mpsc;

    use crate::connectors::claude_session::ClaudeAction;
    use crate::connectors::codex_session::CodexAction;
    use crate::domain::sessions::session::SessionHandle;
    use crate::runtime::session_queries::load_full_session_state;
    use crate::transport::http::test_support::{new_test_state, upload_test_attachment};

    #[tokio::test]
    async fn image_attachment_upload_and_fetch_round_trip() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-api-test".to_string(),
        ));

        let uploaded = upload_test_attachment(state, &session_id, b"png-bytes").await;
        assert_eq!(uploaded.input_type, "attachment");
        assert_eq!(uploaded.mime_type.as_deref(), Some("image/png"));
        assert_eq!(uploaded.byte_count, Some(9));
        assert_eq!(uploaded.pixel_width, Some(320));
        assert_eq!(uploaded.pixel_height, Some(200));

        let response = get_session_image_attachment(Path((session_id, uploaded.value.clone())))
            .await
            .expect("attachment fetch should succeed")
            .into_response();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response
                .headers()
                .get(CONTENT_TYPE)
                .and_then(|value| value.to_str().ok()),
            Some("image/png")
        );

        let body = to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("attachment body should decode");
        assert_eq!(body.as_ref(), b"png-bytes");
    }

    #[tokio::test]
    async fn post_session_message_persists_attachment_refs_and_dispatches_paths() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Codex,
            "/tmp/orbitdock-api-test".to_string(),
        ));
        let (action_tx, mut action_rx) = mpsc::channel(8);
        state.set_codex_action_tx(&session_id, action_tx);

        let uploaded =
            upload_test_attachment(state.clone(), &session_id, b"send-message-image").await;

        let (status, Json(response)) = post_session_message(
            Path(session_id.clone()),
            State(state.clone()),
            Json(SendSessionMessageRequest {
                content: "look at this".to_string(),
                model: None,
                effort: None,
                skills: vec![],
                images: vec![uploaded.clone()],
                mentions: vec![],
            }),
        )
        .await
        .expect("post session message should succeed");
        assert_eq!(status, StatusCode::ACCEPTED);
        assert!(response.accepted);
        assert_eq!(response.message.message_type, MessageType::User);
        assert_eq!(response.message.content, "look at this");

        let action = action_rx
            .recv()
            .await
            .expect("message endpoint should dispatch codex action");
        match action {
            CodexAction::SendMessage { images, .. } => {
                assert_eq!(images.len(), 1);
                assert_eq!(images[0].input_type, "path");
                assert!(images[0].value.ends_with(".png"));
            }
            other => panic!("expected SendMessage action, got {:?}", other),
        }

        let persisted_state = load_full_session_state(&state, &session_id, true)
            .await
            .expect("should load full session state");
        let persisted = persisted_state
            .messages
            .last()
            .expect("expected persisted user message");
        assert_eq!(persisted.message_type, MessageType::User);
        assert_eq!(persisted.images.len(), 1);
        assert_eq!(persisted.images[0].input_type, "attachment");
        assert_eq!(persisted.images[0].value, uploaded.value);
    }

    #[tokio::test]
    async fn post_steer_turn_persists_attachment_refs_and_dispatches_paths() {
        let state = new_test_state(true);
        let session_id = format!("od-{}", orbitdock_protocol::new_id());
        state.add_session(SessionHandle::new(
            session_id.clone(),
            Provider::Claude,
            "/tmp/orbitdock-api-test".to_string(),
        ));
        let (action_tx, mut action_rx) = mpsc::channel(8);
        state.set_claude_action_tx(&session_id, action_tx);

        let uploaded = upload_test_attachment(state.clone(), &session_id, b"steer-image").await;

        let _ = post_steer_turn(
            Path(session_id.clone()),
            State(state.clone()),
            Json(SteerTurnRequest {
                content: "consider this image".to_string(),
                images: vec![uploaded.clone()],
                mentions: vec![],
            }),
        )
        .await
        .expect("post steer should succeed");

        let action = action_rx
            .recv()
            .await
            .expect("steer endpoint should dispatch claude action");
        match action {
            ClaudeAction::SteerTurn { images, .. } => {
                assert_eq!(images.len(), 1);
                assert_eq!(images[0].input_type, "path");
                assert!(images[0].value.ends_with(".png"));
            }
            other => panic!("expected SteerTurn action, got {:?}", other),
        }

        let persisted_state = load_full_session_state(&state, &session_id, true)
            .await
            .expect("should load full session state");
        let persisted = persisted_state
            .messages
            .last()
            .expect("expected persisted steer message");
        assert_eq!(persisted.message_type, MessageType::Steer);
        assert_eq!(persisted.images.len(), 1);
        assert_eq!(persisted.images[0].input_type, "attachment");
        assert_eq!(persisted.images[0].value, uploaded.value);
    }
}
