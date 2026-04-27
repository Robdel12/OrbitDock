use std::sync::Arc;

use axum::{
  body::Bytes,
  extract::{Path, Query, State},
  http::{header::CONTENT_TYPE, HeaderMap, StatusCode},
  Json,
};

use super::super::ApiErrorResponse;
use super::common::{UploadImageAttachmentQuery, UploadedImageAttachmentResponse};
use crate::{
  infrastructure::images::{read_attachment_bytes, store_uploaded_attachment},
  runtime::session_registry::SessionRegistry,
};

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

  let image = store_uploaded_attachment(
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
) -> Result<impl axum::response::IntoResponse, (StatusCode, Json<ApiErrorResponse>)> {
  let (bytes, mime_type) = read_attachment_bytes(&session_id, &attachment_id).map_err(|error| {
    let status = if error.contains("invalid attachment id") || error.contains("read attachment") {
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
