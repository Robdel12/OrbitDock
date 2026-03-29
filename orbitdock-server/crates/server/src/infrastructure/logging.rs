use std::time::{SystemTime, UNIX_EPOCH};

use chrono::{SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Map as JsonMap, Value as JsonValue};
use tokio::sync::mpsc;
use tracing::field::{Field, Visit};
use tracing::{Event, Subscriber};
use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::fmt;
use tracing_subscriber::layer::{Context, SubscriberExt};
use tracing_subscriber::registry::LookupSpan;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{EnvFilter, Layer};

const DEFAULT_FILTER: &str = "info,tower_http=warn,hyper=warn";
const QUIET_TARGET_DIRECTIVES: &[(&str, &str)] = &[
  ("codex_otel.trace_safe", "warn"),
  ("codex_otel.log_only", "warn"),
  ("codex_client::custom_ca", "warn"),
  ("codex_api::endpoint::responses_websocket", "warn"),
  ("codex_core::features", "error"),
  ("feedback_tags", "warn"),
  ("rmcp::transport::worker", "off"),
];
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub enum StderrLogMode {
  #[default]
  Compact,
  Off,
}

#[derive(Clone, Debug, Default)]
pub struct ServerLoggingOptions {
  pub stderr_mode: StderrLogMode,
  pub live_sink: Option<mpsc::UnboundedSender<ServerLogEvent>>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ServerLogEvent {
  pub timestamp: String,
  pub level: String,
  pub target: String,
  pub message: String,
  pub component: Option<String>,
  pub event: Option<String>,
  pub session_id: Option<String>,
  pub request_id: Option<String>,
  pub file: Option<String>,
  pub line: Option<u32>,
  pub current_span: Option<String>,
  pub fields: JsonMap<String, JsonValue>,
}

pub struct LoggingHandle {
  pub run_id: String,
  pub guard: WorkerGuard,
  pub _stderr_guard: Option<WorkerGuard>,
}

pub fn init_logging(options: &ServerLoggingOptions) -> anyhow::Result<LoggingHandle> {
  let log_dir = crate::infrastructure::paths::log_dir();
  std::fs::create_dir_all(&log_dir)?;
  let log_path = log_dir.join("server.log");

  if std::env::var("ORBITDOCK_TRUNCATE_SERVER_LOG_ON_START").as_deref() == Ok("1") {
    let _ = std::fs::OpenOptions::new()
      .create(true)
      .write(true)
      .truncate(true)
      .open(&log_path)?;
  }

  let resolved_filter = resolve_filter_directives(
    std::env::var("ORBITDOCK_SERVER_LOG_FILTER")
      .ok()
      .or_else(|| std::env::var("RUST_LOG").ok()),
  );
  let filter = EnvFilter::try_new(&resolved_filter)
    .unwrap_or_else(|_| EnvFilter::new(apply_quiet_target_directives(DEFAULT_FILTER)));

  let file_appender = tracing_appender::rolling::never(&log_dir, "server.log");
  let (file_writer, guard) = tracing_appender::non_blocking(file_appender);
  let format = std::env::var("ORBITDOCK_SERVER_LOG_FORMAT").unwrap_or_else(|_| "json".into());

  let (stderr_layer, stderr_guard) = match options.stderr_mode {
    StderrLogMode::Compact => {
      let stderr_filter = EnvFilter::try_new(&resolved_filter)
        .unwrap_or_else(|_| EnvFilter::new(apply_quiet_target_directives(DEFAULT_FILTER)));
      let (stderr_writer, stderr_guard) = tracing_appender::non_blocking(std::io::stderr());
      let stderr_layer = fmt::layer()
        .with_writer(stderr_writer)
        .with_target(true)
        .compact()
        .with_filter(stderr_filter);
      (Some(stderr_layer), Some(stderr_guard))
    }
    StderrLogMode::Off => (None, None),
  };

  let live_layer = options.live_sink.clone().map(LiveEventLayer::new);

  let registry = tracing_subscriber::registry()
    .with(filter)
    .with(stderr_layer)
    .with(live_layer);
  if format.eq_ignore_ascii_case("pretty") {
    registry
      .with(
        fmt::layer()
          .with_writer(file_writer)
          .with_ansi(false)
          .pretty()
          .with_file(true)
          .with_line_number(true)
          .with_target(true),
      )
      .init();
  } else {
    registry
      .with(
        fmt::layer()
          .with_writer(file_writer)
          .json()
          .flatten_event(true)
          .with_file(true)
          .with_line_number(true)
          .with_target(true)
          .with_current_span(true),
      )
      .init();
  }

  let run_id = std::env::var("ORBITDOCK_SERVER_RUN_ID").unwrap_or_else(|_| {
    let now = SystemTime::now()
      .duration_since(UNIX_EPOCH)
      .map(|d| d.as_millis())
      .unwrap_or(0);
    format!("pid-{}-{}", std::process::id(), now)
  });

  tracing::info!(
      component = "logging",
      event = "logging.initialized",
      log_path = %log_path.display(),
      format = %format,
      filter = %resolved_filter,
  );

  Ok(LoggingHandle {
    run_id,
    guard,
    _stderr_guard: stderr_guard,
  })
}

fn resolve_filter_directives(raw_filter: Option<String>) -> String {
  let base_filter = raw_filter.unwrap_or_else(|| DEFAULT_FILTER.to_string());
  apply_quiet_target_directives(&base_filter)
}

fn apply_quiet_target_directives(base_filter: &str) -> String {
  let mut resolved = base_filter.trim().to_string();

  for (target, level) in QUIET_TARGET_DIRECTIVES {
    if has_target_override(&resolved, target) {
      continue;
    }

    if !resolved.is_empty() {
      resolved.push(',');
    }
    resolved.push_str(target);
    resolved.push('=');
    resolved.push_str(level);
  }

  resolved
}

fn has_target_override(filter: &str, target: &str) -> bool {
  filter.split(',').map(str::trim).any(|directive| {
    let Some((name, _value)) = directive.split_once('=') else {
      return false;
    };

    let name = name.trim();
    name == target || name.starts_with(&format!("{target}."))
  })
}

struct LiveEventLayer {
  sink: mpsc::UnboundedSender<ServerLogEvent>,
}

impl LiveEventLayer {
  fn new(sink: mpsc::UnboundedSender<ServerLogEvent>) -> Self {
    Self { sink }
  }
}

impl<S> Layer<S> for LiveEventLayer
where
  S: Subscriber + for<'lookup> LookupSpan<'lookup>,
{
  fn on_event(&self, event: &Event<'_>, ctx: Context<'_, S>) {
    let metadata = event.metadata();
    let mut visitor = JsonFieldVisitor::default();
    event.record(&mut visitor);

    let mut fields = visitor.fields;
    let message = take_string_field(&mut fields, "message").unwrap_or_default();
    let component = take_string_field(&mut fields, "component");
    let event_name = take_string_field(&mut fields, "event");
    let session_id = take_string_field(&mut fields, "session_id");
    let request_id = take_string_field(&mut fields, "request_id");
    let current_span = ctx.event_scope(event).map(|scope| {
      scope
        .from_root()
        .map(|span| span.metadata().name().to_string())
        .collect::<Vec<_>>()
        .join(" > ")
    });

    let live_event = ServerLogEvent {
      timestamp: Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
      level: metadata.level().to_string(),
      target: metadata.target().to_string(),
      message,
      component,
      event: event_name,
      session_id,
      request_id,
      file: metadata.file().map(ToOwned::to_owned),
      line: metadata.line(),
      current_span,
      fields,
    };

    let _ = self.sink.send(live_event);
  }
}

#[derive(Default)]
struct JsonFieldVisitor {
  fields: JsonMap<String, JsonValue>,
}

impl Visit for JsonFieldVisitor {
  fn record_bool(&mut self, field: &Field, value: bool) {
    self
      .fields
      .insert(field.name().to_string(), JsonValue::Bool(value));
  }

  fn record_i64(&mut self, field: &Field, value: i64) {
    self.fields.insert(
      field.name().to_string(),
      JsonValue::Number(serde_json::Number::from(value)),
    );
  }

  fn record_u64(&mut self, field: &Field, value: u64) {
    self.fields.insert(
      field.name().to_string(),
      JsonValue::Number(serde_json::Number::from(value)),
    );
  }

  fn record_f64(&mut self, field: &Field, value: f64) {
    let value = serde_json::Number::from_f64(value)
      .map(JsonValue::Number)
      .unwrap_or(JsonValue::Null);
    self.fields.insert(field.name().to_string(), value);
  }

  fn record_str(&mut self, field: &Field, value: &str) {
    self.fields.insert(
      field.name().to_string(),
      JsonValue::String(value.to_string()),
    );
  }

  fn record_error(&mut self, field: &Field, value: &(dyn std::error::Error + 'static)) {
    self.fields.insert(
      field.name().to_string(),
      JsonValue::String(value.to_string()),
    );
  }

  fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
    self.fields.insert(
      field.name().to_string(),
      JsonValue::String(format!("{value:?}")),
    );
  }
}

fn take_string_field(fields: &mut JsonMap<String, JsonValue>, key: &str) -> Option<String> {
  fields.remove(key).and_then(json_value_to_string)
}

fn json_value_to_string(value: JsonValue) -> Option<String> {
  match value {
    JsonValue::Null => None,
    JsonValue::String(value) => Some(value),
    other => Some(other.to_string()),
  }
}

#[cfg(test)]
mod tests {
  use super::*;

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
    assert!(resolved.contains("codex_core::features=error"));
    assert!(resolved.contains("feedback_tags=warn"));
    assert!(resolved.contains("rmcp::transport::worker=off"));
  }

  #[test]
  fn resolve_filter_directives_adds_trace_safe_suppression_to_custom_filter() {
    let resolved = resolve_filter_directives(Some("debug".to_string()));

    assert_eq!(
            resolved,
            "debug,codex_otel.trace_safe=warn,codex_otel.log_only=warn,codex_client::custom_ca=warn,codex_api::endpoint::responses_websocket=warn,codex_core::features=error,feedback_tags=warn,rmcp::transport::worker=off"
        );
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
}
