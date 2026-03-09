use axum::{http::StatusCode, Json};
use serde::Serialize;

#[derive(Debug, Serialize)]
pub(crate) struct ApiErrorResponse {
    pub(crate) code: &'static str,
    pub(crate) error: String,
}

pub(crate) type ApiResult<T> = Result<Json<T>, (StatusCode, Json<ApiErrorResponse>)>;
pub(crate) type ApiInnerResult<T> = Result<T, (StatusCode, Json<ApiErrorResponse>)>;

pub(crate) fn revision_now() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};

    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros() as u64
}
