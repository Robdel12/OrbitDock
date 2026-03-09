use axum::{http::StatusCode, Json};
use serde::Serialize;

#[derive(Debug, Serialize)]
pub(crate) struct ApiErrorResponse {
    pub(crate) code: &'static str,
    pub(crate) error: String,
}

pub(crate) type ApiError = (StatusCode, Json<ApiErrorResponse>);
pub(crate) type ApiResult<T> = Result<Json<T>, ApiError>;
pub(crate) type ApiInnerResult<T> = Result<T, ApiError>;

pub(crate) fn api_error(
    status: StatusCode,
    code: &'static str,
    error: impl Into<String>,
) -> ApiError {
    (
        status,
        Json(ApiErrorResponse {
            code,
            error: error.into(),
        }),
    )
}

pub(crate) fn bad_request(code: &'static str, error: impl Into<String>) -> ApiError {
    api_error(StatusCode::BAD_REQUEST, code, error)
}

pub(crate) fn conflict(code: &'static str, error: impl Into<String>) -> ApiError {
    api_error(StatusCode::CONFLICT, code, error)
}

pub(crate) fn not_found(code: &'static str, error: impl Into<String>) -> ApiError {
    api_error(StatusCode::NOT_FOUND, code, error)
}

pub(crate) fn internal(code: &'static str, error: impl Into<String>) -> ApiError {
    api_error(StatusCode::INTERNAL_SERVER_ERROR, code, error)
}

pub(crate) fn service_unavailable(code: &'static str, error: impl Into<String>) -> ApiError {
    api_error(StatusCode::SERVICE_UNAVAILABLE, code, error)
}

pub(crate) fn unprocessable(code: &'static str, error: impl Into<String>) -> ApiError {
    api_error(StatusCode::UNPROCESSABLE_ENTITY, code, error)
}

pub(crate) fn gateway_timeout(code: &'static str, error: impl Into<String>) -> ApiError {
    api_error(StatusCode::GATEWAY_TIMEOUT, code, error)
}

pub(crate) fn revision_now() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};

    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros() as u64
}
