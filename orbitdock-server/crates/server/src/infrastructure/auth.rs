//! Optional auth token middleware.
//!
//! Authenticated requests should include `Authorization: Bearer <token>`.
//! The `/health` endpoint remains unauthenticated for simple liveness probes.

use std::sync::{
  atomic::{AtomicBool, Ordering},
  Arc,
};
use std::time::Duration;

use axum::{
  body::Body,
  extract::State,
  http::{Request, StatusCode},
  middleware::Next,
  response::Response,
};
use tracing::warn;

use crate::infrastructure::auth_tokens;

const MAX_BEARER_TOKEN_LEN: usize = 1024;
const DB_TOKEN_REFRESH_INTERVAL: Duration = Duration::from_secs(30);

#[derive(Clone, Debug)]
pub struct AuthState {
  pub static_token: Option<String>,
  pub database_tokens_enabled: Arc<AtomicBool>,
}

impl AuthState {
  pub fn new(static_token: Option<String>, has_active_db_tokens: bool) -> Self {
    Self {
      static_token,
      database_tokens_enabled: Arc::new(AtomicBool::new(has_active_db_tokens)),
    }
  }

  fn requires_auth(&self) -> Result<bool, StatusCode> {
    if self.static_token.is_some() {
      return Ok(true);
    }

    if self.database_tokens_enabled.load(Ordering::Relaxed) {
      return Ok(true);
    }

    match auth_tokens::active_token_count() {
      Ok(count) => {
        let enabled = count > 0;
        self
          .database_tokens_enabled
          .store(enabled, Ordering::Relaxed);
        Ok(enabled)
      }
      Err(error) => {
        warn!(
            component = "auth",
            event = "auth.token_count_error",
            error = %error,
            "Failed to determine whether database-backed auth is enabled"
        );
        Err(StatusCode::INTERNAL_SERVER_ERROR)
      }
    }
  }

  pub fn spawn_db_token_refresh(&self) {
    if self.static_token.is_some() {
      return;
    }

    let database_tokens_enabled = Arc::clone(&self.database_tokens_enabled);
    tokio::spawn(async move {
      let mut interval = tokio::time::interval(DB_TOKEN_REFRESH_INTERVAL);
      interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

      loop {
        interval.tick().await;
        let count = tokio::task::spawn_blocking(auth_tokens::active_token_count).await;
        match count {
          Ok(Ok(count)) => {
            database_tokens_enabled.store(count > 0, Ordering::Relaxed);
          }
          Ok(Err(error)) => {
            warn!(
                component = "auth",
                event = "auth.token_count_error",
                error = %error,
                "Failed to refresh database-backed auth state"
            );
          }
          Err(error) => {
            warn!(
                component = "auth",
                event = "auth.token_count_task_join_error",
                error = %error,
                "Database-backed auth refresh task failed"
            );
          }
        }
      }
    });
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

  let Some(token) = extract_token(&req) else {
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

/// Extract token from the Authorization header.
fn extract_token(req: &Request<Body>) -> Option<&str> {
  if let Some(header) = req.headers().get("authorization") {
    if let Ok(value) = header.to_str() {
      if let Some(token) = value.strip_prefix("Bearer ") {
        if token.len() <= MAX_BEARER_TOKEN_LEN {
          return Some(token);
        }
      }
    }
  }

  None
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

#[cfg(test)]
mod tests {
  use super::AuthState;

  #[test]
  fn auth_required_when_static_token_is_configured() {
    let auth = AuthState::new(Some("secret".to_string()), false);
    assert_eq!(auth.requires_auth(), Ok(true));
  }

  #[test]
  fn auth_required_when_database_tokens_are_enabled() {
    let auth = AuthState::new(None, true);
    assert_eq!(auth.requires_auth(), Ok(true));
  }

  #[test]
  fn auth_not_required_without_static_or_database_tokens() {
    let auth = AuthState::new(None, false);
    assert_eq!(auth.requires_auth(), Ok(false));
  }
}
