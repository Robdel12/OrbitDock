use std::net::SocketAddr;

use axum::{
  http::{
    header::{AUTHORIZATION, CONTENT_TYPE},
    HeaderValue, Method,
  },
  response::IntoResponse,
};
use tower_http::cors::CorsLayer;

use crate::VERSION;

pub(super) fn describe_bind_failure(error: std::io::Error, bind_addr: SocketAddr) -> anyhow::Error {
  if error.kind() == std::io::ErrorKind::AddrInUse {
    return anyhow::anyhow!(
      "OrbitDock could not start because {} is already in use. Stop the existing OrbitDock/dev server or choose a different `--bind` address.",
      bind_addr
    );
  }

  anyhow::Error::new(error)
}

pub(super) fn configured_cors_layer() -> anyhow::Result<Option<CorsLayer>> {
  let raw = match std::env::var("ORBITDOCK_CORS_ALLOWED_ORIGINS") {
    Ok(value) => value,
    Err(_) => return Ok(None),
  };

  let mut origins = Vec::new();
  for origin in raw.split(',') {
    let trimmed = origin.trim();
    if trimmed.is_empty() {
      continue;
    }
    origins.push(
      HeaderValue::from_str(trimmed)
        .map_err(|error| anyhow::anyhow!("invalid CORS origin '{trimmed}': {error}"))?,
    );
  }

  if origins.is_empty() {
    return Ok(None);
  }

  Ok(Some(
    CorsLayer::new()
      .allow_origin(origins)
      .allow_methods([
        Method::GET,
        Method::POST,
        Method::PUT,
        Method::PATCH,
        Method::DELETE,
        Method::OPTIONS,
      ])
      .allow_headers([AUTHORIZATION, CONTENT_TYPE]),
  ))
}

pub(super) async fn health_handler() -> impl IntoResponse {
  serde_json::json!({
      "status": "ok",
      "version": VERSION,
  })
  .to_string()
}
