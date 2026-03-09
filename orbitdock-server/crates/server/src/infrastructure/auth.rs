//! Optional auth token middleware.
//!
//! All authenticated requests must include `Authorization: Bearer <token>`.
//! The `/health` endpoint remains unauthenticated for simple liveness probes.

use axum::{
    body::Body,
    extract::State,
    http::{Request, StatusCode},
    middleware::Next,
    response::Response,
};
use tracing::warn;

use crate::auth_tokens;

const MAX_BEARER_TOKEN_LEN: usize = 1024;

#[derive(Clone, Debug)]
pub struct AuthState {
    pub static_token: Option<String>,
}

impl AuthState {
    fn requires_auth(&self) -> Result<bool, StatusCode> {
        if self.static_token.is_some() {
            return Ok(true);
        }

        match auth_tokens::active_token_count() {
            Ok(count) => Ok(count > 0),
            Err(e) => {
                warn!(
                    component = "auth",
                    event = "auth.token_count_error",
                    error = %e,
                    "Failed to determine whether database-backed auth is enabled"
                );
                Err(StatusCode::INTERNAL_SERVER_ERROR)
            }
        }
    }
}

/// Axum middleware that checks for a valid auth token.
/// Skips authentication for the `/health` endpoint.
pub async fn auth_middleware(
    State(auth): State<AuthState>,
    req: Request<Body>,
    next: Next,
) -> Result<Response, StatusCode> {
    let path = req.uri().path();

    // /health is always unauthenticated
    if path == "/health" {
        return Ok(next.run(req).await);
    }

    if !auth.requires_auth()? {
        return Ok(next.run(req).await);
    }

    let Some(token) = bearer_token(&req) else {
        return Err(StatusCode::UNAUTHORIZED);
    };

    if let Some(expected) = auth.static_token.as_deref() {
        if constant_time_eq(expected.as_bytes(), token.as_bytes()) {
            return Ok(next.run(req).await);
        }
    }

    match auth_tokens::verify_bearer_token(token) {
        Ok(true) => return Ok(next.run(req).await),
        Ok(false) => {}
        Err(e) => {
            warn!(
                component = "auth",
                event = "auth.token_verify_error",
                error = %e,
                "Token verification failed due to internal error"
            );
            return Err(StatusCode::INTERNAL_SERVER_ERROR);
        }
    }

    Err(StatusCode::UNAUTHORIZED)
}

fn bearer_token(req: &Request<Body>) -> Option<&str> {
    let header = req.headers().get("authorization")?;
    let value = header.to_str().ok()?;
    let token = value.strip_prefix("Bearer ")?;
    if token.len() > MAX_BEARER_TOKEN_LEN {
        return None;
    }
    Some(token)
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    let max_len = left.len().max(right.len());
    let mut diff = left.len() ^ right.len();
    for idx in 0..max_len {
        let lhs = left.get(idx).copied().unwrap_or(0);
        let rhs = right.get(idx).copied().unwrap_or(0);
        diff |= (lhs ^ rhs) as usize;
    }
    diff == 0
}
