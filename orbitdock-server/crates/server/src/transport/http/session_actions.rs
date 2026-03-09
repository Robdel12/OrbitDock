use super::*;

#[derive(Debug, Serialize)]
pub struct AcceptedResponse {
    pub accepted: bool,
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

pub async fn post_session_message(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<SendSessionMessageRequest>,
) -> Result<(StatusCode, Json<AcceptedResponse>), (StatusCode, Json<ApiErrorResponse>)> {
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

    crate::ws_handlers::messaging::dispatch_send_message(
        &state,
        session_id.clone(),
        body.content,
        body.model,
        body.effort,
        body.skills,
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

    let image = crate::images::store_uploaded_attachment(
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
    let (bytes, mime_type) = crate::images::read_attachment_bytes(&session_id, &attachment_id)
        .map_err(|error| {
            let status =
                if error.contains("invalid attachment id") || error.contains("read attachment") {
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

    crate::ws_handlers::messaging::dispatch_steer_turn(
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
    crate::ws_handlers::messaging::dispatch_interrupt(&state, &session_id)
        .await
        .map_err(|code| dispatch_error_response(code, &session_id))?;
    Ok(Json(AcceptedResponse { accepted: true }))
}

pub async fn compact_context(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    crate::ws_handlers::messaging::dispatch_compact(&state, &session_id)
        .await
        .map_err(|code| dispatch_error_response(code, &session_id))?;
    Ok(Json(AcceptedResponse { accepted: true }))
}

pub async fn undo_last_turn(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    crate::ws_handlers::messaging::dispatch_undo(&state, &session_id)
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
    crate::ws_handlers::messaging::dispatch_rollback(&state, &session_id, body.num_turns)
        .await
        .map_err(|code| dispatch_error_response(code, &session_id))?;
    Ok(Json(AcceptedResponse { accepted: true }))
}

pub async fn stop_task(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<StopTaskRequest>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    crate::ws_handlers::messaging::dispatch_stop_task(&state, &session_id, body.task_id)
        .await
        .map_err(|code| dispatch_error_response(code, &session_id))?;
    Ok(Json(AcceptedResponse { accepted: true }))
}

pub async fn rewind_files(
    Path(session_id): Path<String>,
    State(state): State<Arc<SessionRegistry>>,
    Json(body): Json<RewindFilesRequest>,
) -> Result<Json<AcceptedResponse>, (StatusCode, Json<ApiErrorResponse>)> {
    crate::ws_handlers::messaging::dispatch_rewind_files(&state, &session_id, body.user_message_id)
        .await
        .map_err(|code| dispatch_error_response(code, &session_id))?;
    Ok(Json(AcceptedResponse { accepted: true }))
}
