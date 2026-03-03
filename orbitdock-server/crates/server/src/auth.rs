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
    pub allow_database_tokens: bool,
}

impl AuthState {
    pub fn is_enabled(&self) -> bool {
        self.static_token.is_some() || self.allow_database_tokens
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

    let Some(token) = bearer_token(&req) else {
        return Err(StatusCode::UNAUTHORIZED);
    };

    if let Some(expected) = auth.static_token.as_deref() {
        if constant_time_eq(expected.as_bytes(), token.as_bytes()) {
            return Ok(next.run(req).await);
        }
    }

    if auth.allow_database_tokens {
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
            }
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
