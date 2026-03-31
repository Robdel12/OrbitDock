use axum::{
  body::Body,
  http::{HeaderMap, Request, Response, StatusCode},
  middleware::Next,
};
use orbitdock_protocol::{
  HTTP_HEADER_CLIENT_VERSION, HTTP_HEADER_MINIMUM_CLIENT_VERSION,
  HTTP_HEADER_MINIMUM_SERVER_VERSION, HTTP_HEADER_SERVER_VERSION,
};
use tracing::{info, warn};

use crate::{MINIMUM_CLIENT_VERSION, VERSION};

#[derive(Debug, Clone)]
pub(crate) struct VersionGate {
  pub server_version: String,
  pub minimum_client_version: String,
  pub compatible: bool,
  pub reason: Option<&'static str>,
  pub message: Option<String>,
}

pub(crate) fn version_gate_from_headers(headers: &HeaderMap) -> VersionGate {
  let client_version = header_value(headers, HTTP_HEADER_CLIENT_VERSION);

  let compatible = client_version
    .as_deref()
    .is_some_and(|version| version_at_least(version, MINIMUM_CLIENT_VERSION));

  let (reason, message) = if compatible {
    (None, None)
  } else {
    (
      Some("client_version_too_old"),
      Some(version_too_old_message(
        client_version.as_deref(),
        MINIMUM_CLIENT_VERSION,
      )),
    )
  };

  VersionGate {
    server_version: VERSION.to_string(),
    minimum_client_version: MINIMUM_CLIENT_VERSION.to_string(),
    compatible,
    reason,
    message,
  }
}

pub(crate) fn version_gate_for_request(request: &Request<Body>) -> VersionGate {
  version_gate_from_headers(request.headers())
}

fn attach_headers(response: &mut Response<Body>, gate: &VersionGate) {
  response.headers_mut().insert(
    HTTP_HEADER_SERVER_VERSION,
    gate
      .server_version
      .parse()
      .expect("valid server version header"),
  );
  response.headers_mut().insert(
    HTTP_HEADER_MINIMUM_CLIENT_VERSION,
    gate
      .minimum_client_version
      .parse()
      .expect("valid minimum client version header"),
  );
}

pub(crate) async fn version_middleware(req: Request<Body>, next: Next) -> Response<Body> {
  let path = req.uri().path().to_string();

  // Only enforce the version gate on protocol endpoints (WebSocket + API).
  // Health, metrics, and web UI assets are not protocol clients.
  let is_protocol_route = path == "/ws" || path.starts_with("/api/");
  if !is_protocol_route {
    return next.run(req).await;
  }

  let gate = version_gate_for_request(&req);
  if path == "/ws" {
    info!(
      component = "protocol_compat",
      event = "protocol_version.request",
      path = %path,
      client_version = ?header_value(req.headers(), HTTP_HEADER_CLIENT_VERSION),
      minimum_server_version = ?header_value(req.headers(), HTTP_HEADER_MINIMUM_SERVER_VERSION),
      has_authorization = req.headers().contains_key("authorization"),
      has_token_query = req.uri().query().map(|query| query.contains("token=")).unwrap_or(false),
      compatible = gate.compatible,
      reason = ?gate.reason,
      "Checked client version headers"
    );
  }
  if !gate.compatible {
    if path == "/ws" {
      warn!(
        component = "protocol_compat",
        event = "protocol_version.rejected",
        path = %path,
        client_version = ?header_value(req.headers(), HTTP_HEADER_CLIENT_VERSION),
        minimum_server_version = ?header_value(req.headers(), HTTP_HEADER_MINIMUM_SERVER_VERSION),
        has_authorization = req.headers().contains_key("authorization"),
        has_token_query = req.uri().query().map(|query| query.contains("token=")).unwrap_or(false),
        reason = ?gate.reason,
        message = ?gate.message,
        "Rejected incompatible client version"
      );
    }
    let mut response = Response::builder()
      .status(StatusCode::UPGRADE_REQUIRED)
      .header("content-type", "application/json")
      .body(Body::from(format!(
        "{{\"code\":\"incompatible_client\",\"error\":\"{}\"}}",
        gate
          .message
          .as_deref()
          .unwrap_or("Client version is too old for this server build.")
      )))
      .expect("valid upgrade required response");
    attach_headers(&mut response, &gate);
    return response;
  }

  let mut response = next.run(req).await;
  attach_headers(&mut response, &gate);
  response
}

fn header_value(headers: &HeaderMap, name: &str) -> Option<String> {
  headers
    .get(name)
    .and_then(|value| value.to_str().ok())
    .map(|value| value.to_string())
}

fn version_at_least(left: &str, right: &str) -> bool {
  match (parse_version(left), parse_version(right)) {
    (Some(left), Some(right)) => left >= right,
    _ => false,
  }
}

fn parse_version(value: &str) -> Option<(u64, u64, u64)> {
  fn parse_component(raw: &str) -> Option<u64> {
    let trimmed = raw.trim().split(['-', '+']).next().unwrap_or(raw).trim();
    trimmed.parse().ok()
  }

  let mut parts = value.trim().split('.');
  let major = parse_component(parts.next()?)?;
  let minor = parse_component(parts.next().unwrap_or("0"))?;
  let patch = parse_component(parts.next().unwrap_or("0"))?;
  Some((major, minor, patch))
}

fn version_too_old_message(client_version: Option<&str>, minimum_version: &str) -> String {
  match client_version {
    Some(version) if !version.is_empty() => format!(
      "Update OrbitDock to version {} or later (current: {}).",
      minimum_version, version
    ),
    _ => format!("Set OrbitDock to version {} or later.", minimum_version),
  }
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn version_gate_accepts_matching_client_version() {
    let mut headers = HeaderMap::new();
    headers.insert(HTTP_HEADER_CLIENT_VERSION, "0.8.0".parse().unwrap());
    headers.insert(HTTP_HEADER_MINIMUM_SERVER_VERSION, "0.8.0".parse().unwrap());

    let gate = version_gate_from_headers(&headers);

    assert!(gate.compatible);
    assert_eq!(gate.server_version, VERSION);
    assert_eq!(gate.minimum_client_version, MINIMUM_CLIENT_VERSION);
    assert_eq!(gate.reason, None);
    assert_eq!(gate.message, None);
  }

  #[test]
  fn version_gate_rejects_older_client_version() {
    let mut headers = HeaderMap::new();
    headers.insert(HTTP_HEADER_CLIENT_VERSION, "0.6.9".parse().unwrap());

    let gate = version_gate_from_headers(&headers);

    assert!(!gate.compatible);
    assert_eq!(gate.reason, Some("client_version_too_old"));
  }

  #[test]
  fn version_gate_accepts_build_metadata_in_client_version() {
    let mut headers = HeaderMap::new();
    headers.insert(HTTP_HEADER_CLIENT_VERSION, "0.8.0+2".parse().unwrap());

    let gate = version_gate_from_headers(&headers);

    assert!(gate.compatible);
    assert_eq!(gate.reason, None);
    assert_eq!(gate.message, None);
  }
}
