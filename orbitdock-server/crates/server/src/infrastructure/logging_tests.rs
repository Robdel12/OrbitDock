use super::*;
use serde_json::Value as JsonValue;
use tokio::sync::mpsc;
use tracing_subscriber::layer::SubscriberExt;

#[test]
fn live_layer_captures_structured_fields() {
  let (tx, mut rx) = mpsc::unbounded_channel();
  let subscriber = tracing_subscriber::registry().with(LiveEventLayer::new(tx));

  tracing::subscriber::with_default(subscriber, || {
    tracing::info!(
      component = "server",
      event = "server.starting",
      session_id = "session-123",
      request_id = "request-123",
      approval_version = 7_u64,
      "Starting OrbitDock Server..."
    );
  });

  let event = rx.try_recv().expect("expected captured event");
  assert_eq!(event.level, "INFO");
  assert_eq!(event.component.as_deref(), Some("server"));
  assert_eq!(event.event.as_deref(), Some("server.starting"));
  assert_eq!(event.session_id.as_deref(), Some("session-123"));
  assert_eq!(event.request_id.as_deref(), Some("request-123"));
  assert_eq!(event.message, "Starting OrbitDock Server...");
  assert_eq!(
    event.fields.get("approval_version"),
    Some(&JsonValue::Number(7_u64.into()))
  );
  assert!(event.file.is_some());
  assert!(event.line.is_some());
}

#[test]
fn live_layer_falls_back_to_target_when_component_is_missing() {
  let (tx, mut rx) = mpsc::unbounded_channel();
  let subscriber = tracing_subscriber::registry().with(LiveEventLayer::new(tx));

  tracing::subscriber::with_default(subscriber, || {
    let span = tracing::info_span!("orbitdock_server", service = "orbitdock");
    let _guard = span.enter();
    tracing::info!(target: "codex_otel.trace_safe", duration_ms = 12, "codex trace");
  });

  let event = rx.try_recv().expect("expected captured event");
  assert_eq!(event.target, "codex_otel.trace_safe");
  assert_eq!(event.component, None);
  assert_eq!(event.message, "codex trace");
  assert_eq!(event.current_span.as_deref(), Some("orbitdock_server"));
  assert_eq!(
    event.fields.get("duration_ms"),
    Some(&JsonValue::Number(12_u64.into()))
  );
}

#[test]
fn resolve_filter_directives_adds_trace_safe_suppression_by_default() {
  let resolved = resolve_filter_directives(None);

  assert!(resolved.contains("info"));
  assert!(resolved.contains("codex_otel.trace_safe=warn"));
  assert!(resolved.contains("codex_otel.log_only=warn"));
  assert!(resolved.contains("codex_client::custom_ca=warn"));
  assert!(resolved.contains("codex_api::endpoint::responses_websocket=warn"));
  assert!(resolved.contains("codex_core::config=warn"));
  assert!(resolved.contains("codex_core::models_manager=warn"));
  assert!(resolved.contains("connector_codex::config=warn"));
  assert!(resolved.contains("codex_core::features=error"));
  assert!(resolved.contains("feedback_tags=warn"));
  assert!(resolved.contains("rmcp::transport::worker=off"));
}

#[test]
fn resolve_filter_directives_adds_trace_safe_suppression_to_custom_filter() {
  let resolved = resolve_filter_directives(Some("debug".to_string()));

  assert!(resolved.starts_with("debug,"));
  assert!(resolved.contains("codex_otel.trace_safe=warn"));
  assert!(resolved.contains("codex_otel.log_only=warn"));
  assert!(resolved.contains("codex_client::custom_ca=warn"));
  assert!(resolved.contains("codex_api::endpoint::responses_websocket=warn"));
  assert!(resolved.contains("codex_core::config=warn"));
  assert!(resolved.contains("codex_core::models_manager=warn"));
  assert!(resolved.contains("connector_codex::config=warn"));
  assert!(resolved.contains("codex_core::features=error"));
  assert!(resolved.contains("feedback_tags=warn"));
  assert!(resolved.contains("rmcp::transport::worker=off"));
}

#[test]
fn resolve_filter_directives_preserves_explicit_trace_safe_override() {
  let resolved = resolve_filter_directives(Some("debug,codex_otel.trace_safe=info".to_string()));

  assert!(resolved.starts_with("debug,codex_otel.trace_safe=info"));
  assert!(resolved.contains("codex_otel.log_only=warn"));
  assert!(resolved.contains("feedback_tags=warn"));
  assert!(resolved.contains("rmcp::transport::worker=off"));
}

#[test]
fn resolve_filter_directives_preserves_nested_trace_safe_override() {
  let resolved = resolve_filter_directives(Some(
    "debug,codex_otel.trace_safe.summary=trace".to_string(),
  ));

  assert!(resolved.starts_with("debug,codex_otel.trace_safe.summary=trace"));
  assert!(resolved.contains("codex_otel.log_only=warn"));
  assert!(resolved.contains("feedback_tags=warn"));
  assert!(resolved.contains("rmcp::transport::worker=off"));
}
