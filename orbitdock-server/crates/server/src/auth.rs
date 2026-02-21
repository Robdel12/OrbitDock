//! Optional auth token middleware.
//!
//! When `--auth-token` is configured, all requests to `/ws` and `/api/hook`
//! must include `Authorization: Bearer <token>` (or `?token=<token>` for WebSocket).
//! The `/health` endpoint remains unauthenticated.

use axum::{
    body::Body,
    extract::State,
    http::{Request, StatusCode},
    middleware::Next,
    response::Response,
};

/// Axum middleware that checks for a valid auth token.
/// Skips authentication for the `/health` endpoint.
pub async fn auth_middleware(
    State(expected_token): State<String>,
    req: Request<Body>,
    next: Next,
) -> Result<Response, StatusCode> {
    let path = req.uri().path();

    // /health is always unauthenticated
    if path == "/health" {
        return Ok(next.run(req).await);
    }

    // Check Authorization header first
    if let Some(auth_header) = req.headers().get("authorization") {
        if let Ok(value) = auth_header.to_str() {
            if let Some(token) = value.strip_prefix("Bearer ") {
                if token == expected_token {
                    return Ok(next.run(req).await);
                }
            }
        }
    }

    // Check ?token= query param (for WebSocket connections)
    if let Some(query) = req.uri().query() {
        for pair in query.split('&') {
            if let Some(token) = pair.strip_prefix("token=") {
                if token == expected_token {
                    return Ok(next.run(req).await);
                }
            }
        }
    }

    Err(StatusCode::UNAUTHORIZED)
}
