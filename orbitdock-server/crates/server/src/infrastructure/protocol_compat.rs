use axum::{
  body::Body,
  http::{HeaderMap, Request, Response, StatusCode},
  middleware::Next,
};
use orbitdock_protocol::{
  HTTP_HEADER_CLIENT_COMPATIBILITY, HTTP_HEADER_CLIENT_VERSION, HTTP_HEADER_COMPATIBILITY_MESSAGE,
  HTTP_HEADER_COMPATIBILITY_REASON, HTTP_HEADER_COMPATIBLE, HTTP_HEADER_MINIMUM_CLIENT_VERSION,
  HTTP_HEADER_MINIMUM_SERVER_VERSION, HTTP_HEADER_SERVER_COMPATIBILITY, HTTP_HEADER_SERVER_VERSION,
  SERVER_COMPATIBILITY,
};
use tracing::{info, warn};

use crate::{MINIMUM_CLIENT_VERSION, VERSION};

const LEGACY_MINIMUM_CLIENT_VERSION: &str = "0.4.0";

#[derive(Debug, Clone)]
pub(crate) struct VersionGate {
  pub server_version: String,
  pub minimum_client_version: String,
  pub server_compatibility: &'static str,
  pub compatible: bool,
  pub reason: Option<&'static str>,
  pub message: Option<String>,
}

pub(crate) fn version_gate_from_headers(headers: &HeaderMap) -> VersionGate {
  let client_version = header_value(headers, HTTP_HEADER_CLIENT_VERSION);
  let client_compatibility = header_value(headers, HTTP_HEADER_CLIENT_COMPATIBILITY);
  let minimum_server_version = header_value(headers, HTTP_HEADER_MINIMUM_SERVER_VERSION);
  let uses_legacy_contract = minimum_server_version.is_none()
    && client_compatibility.as_deref() == Some(SERVER_COMPATIBILITY);
  let required_minimum_client_version = if uses_legacy_contract {
    LEGACY_MINIMUM_CLIENT_VERSION
  } else {
    MINIMUM_CLIENT_VERSION
  };

  let client_version_compatible = client_version
    .as_deref()
    .is_some_and(|version| version_at_least(version, required_minimum_client_version));
  let server_version_compatible = if uses_legacy_contract {
    true
  } else {
    minimum_server_version
      .as_deref()
      .is_none_or(|minimum| version_at_least(VERSION, minimum))
  };

  let compatible = client_version_compatible && server_version_compatible;

  let (reason, message) = if compatible {
    (None, None)
  } else if !client_version_compatible {
    (
      Some("client_version_too_old"),
      Some(version_too_old_message(
        client_version.as_deref(),
        required_minimum_client_version,
      )),
    )
  } else {
    (
      Some("server_version_too_old"),
      Some(server_too_old_message(
        VERSION,
        minimum_server_version.as_deref().unwrap_or_default(),
      )),
    )
  };

  VersionGate {
    server_version: VERSION.to_string(),
    minimum_client_version: required_minimum_client_version.to_string(),
    server_compatibility: SERVER_COMPATIBILITY,
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
  response.headers_mut().insert(
    HTTP_HEADER_SERVER_COMPATIBILITY,
    gate
      .server_compatibility
      .parse()
      .expect("valid server compatibility header"),
  );
  response.headers_mut().insert(
    HTTP_HEADER_COMPATIBLE,
    if gate.compatible { "true" } else { "false" }
      .parse()
      .expect("valid compatibility status header"),
  );
  if let Some(reason) = gate.reason {
    response.headers_mut().insert(
      HTTP_HEADER_COMPATIBILITY_REASON,
      reason.parse().expect("valid compatibility reason header"),
    );
  }
  if let Some(message) = &gate.message {
    response.headers_mut().insert(
      HTTP_HEADER_COMPATIBILITY_MESSAGE,
      message
        .parse()
        .expect("valid compatibility guidance header"),
    );
  }
}

pub(crate) async fn version_middleware(req: Request<Body>, next: Next) -> Response<Body> {
  let path = req.uri().path().to_string();
  let is_ws_route = path == "/ws";

  // OrbitDock version compatibility contract:
  // 1) Modern contract clients must be at least MINIMUM_CLIENT_VERSION.
  // 2) Legacy contract clients are temporarily accepted down to LEGACY_MINIMUM_CLIENT_VERSION.
  // 3) Reject when client-advertised minimum server version is above this server VERSION.
  // 4) Never reject just because the other side is newer.
  // This keeps compatibility minimum-based and provides a temporary legacy bridge.
  // Only enforce the version gate on protocol endpoints (WebSocket + API).
  // Health, metrics, and web UI assets are not protocol clients.
  let is_protocol_route = is_ws_route || path.starts_with("/api/");
  if !is_protocol_route {
    return next.run(req).await;
  }

  let gate = version_gate_for_request(&req);
  let client_version = header_value(req.headers(), HTTP_HEADER_CLIENT_VERSION);
  let client_compatibility = header_value(req.headers(), HTTP_HEADER_CLIENT_COMPATIBILITY);
  let minimum_server_version = header_value(req.headers(), HTTP_HEADER_MINIMUM_SERVER_VERSION);
  let has_authorization = req.headers().contains_key("authorization");
  let has_token_query = req
    .uri()
    .query()
    .is_some_and(|query| query.contains("token="));

  if is_ws_route {
    info!(
      component = "protocol_compat",
      event = "protocol_version.request",
      path = %path,
      client_version = ?client_version.as_deref(),
      client_compatibility = ?client_compatibility.as_deref(),
      minimum_server_version = ?minimum_server_version.as_deref(),
      has_authorization,
      has_token_query,
      compatible = gate.compatible,
      reason = ?gate.reason,
      "Checked client version headers"
    );
  }
  if !gate.compatible {
    if is_ws_route {
      warn!(
        component = "protocol_compat",
        event = "protocol_version.rejected",
        path = %path,
        client_version = ?client_version.as_deref(),
        client_compatibility = ?client_compatibility.as_deref(),
        minimum_server_version = ?minimum_server_version.as_deref(),
        has_authorization,
        has_token_query,
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

fn server_too_old_message(server_version: &str, minimum_server_version: &str) -> String {
  if minimum_server_version.is_empty() {
    "Update OrbitDock server to a newer version.".to_string()
  } else {
    format!(
      "Update OrbitDock server to version {} or later (current: {}).",
      minimum_server_version, server_version
    )
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
    assert_eq!(gate.server_compatibility, SERVER_COMPATIBILITY);
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

  #[test]
  fn version_gate_accepts_legacy_contract_clients() {
    let mut headers = HeaderMap::new();
    headers.insert(HTTP_HEADER_CLIENT_VERSION, "0.4.0".parse().unwrap());
    headers.insert(
      HTTP_HEADER_CLIENT_COMPATIBILITY,
      SERVER_COMPATIBILITY.parse().unwrap(),
    );

    let gate = version_gate_from_headers(&headers);

    assert!(gate.compatible);
    assert_eq!(gate.minimum_client_version, LEGACY_MINIMUM_CLIENT_VERSION);
  }

  #[test]
  fn version_gate_rejects_too_old_legacy_contract_clients() {
    let mut headers = HeaderMap::new();
    headers.insert(HTTP_HEADER_CLIENT_VERSION, "0.3.9".parse().unwrap());
    headers.insert(
      HTTP_HEADER_CLIENT_COMPATIBILITY,
      SERVER_COMPATIBILITY.parse().unwrap(),
    );

    let gate = version_gate_from_headers(&headers);

    assert!(!gate.compatible);
    assert_eq!(gate.reason, Some("client_version_too_old"));
    assert_eq!(
      gate.message.as_deref(),
      Some("Update OrbitDock to version 0.4.0 or later (current: 0.3.9).")
    );
  }

  #[test]
  fn modern_contract_cannot_claim_legacy_floor() {
    let mut headers = HeaderMap::new();
    headers.insert(HTTP_HEADER_CLIENT_VERSION, "0.6.9".parse().unwrap());
    headers.insert(
      HTTP_HEADER_CLIENT_COMPATIBILITY,
      SERVER_COMPATIBILITY.parse().unwrap(),
    );
    headers.insert(HTTP_HEADER_MINIMUM_SERVER_VERSION, "0.8.0".parse().unwrap());

    let gate = version_gate_from_headers(&headers);

    assert!(!gate.compatible);
    assert_eq!(gate.reason, Some("client_version_too_old"));
    assert_eq!(gate.minimum_client_version, MINIMUM_CLIENT_VERSION);
  }

  #[test]
  fn version_gate_rejects_client_minimum_server_when_server_is_too_old() {
    let mut headers = HeaderMap::new();
    headers.insert(HTTP_HEADER_CLIENT_VERSION, "0.8.0".parse().unwrap());
    headers.insert(HTTP_HEADER_MINIMUM_SERVER_VERSION, "9.0.0".parse().unwrap());

    let gate = version_gate_from_headers(&headers);

    assert!(!gate.compatible);
    assert_eq!(gate.reason, Some("server_version_too_old"));
    assert_eq!(
      gate.message,
      Some(format!(
        "Update OrbitDock server to version 9.0.0 or later (current: {}).",
        VERSION
      ))
    );
  }
}
