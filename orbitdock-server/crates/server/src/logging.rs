use std::time::{SystemTime, UNIX_EPOCH};

use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::fmt;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::EnvFilter;

const DEFAULT_FILTER: &str = "info,tower_http=warn,hyper=warn";

pub struct LoggingHandle {
    pub run_id: String,
    pub guard: WorkerGuard,
}

pub fn init_logging() -> anyhow::Result<LoggingHandle> {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let log_dir = std::path::PathBuf::from(home)
        .join(".orbitdock")
        .join("logs");
    std::fs::create_dir_all(&log_dir)?;
    let log_path = log_dir.join("server.log");

    if std::env::var("ORBITDOCK_TRUNCATE_SERVER_LOG_ON_START").as_deref() == Ok("1") {
        let _ = std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&log_path)?;
    }

    let filter = std::env::var("ORBITDOCK_SERVER_LOG_FILTER")
        .ok()
        .and_then(|value| EnvFilter::try_new(value).ok())
        .or_else(|| EnvFilter::try_from_default_env().ok())
        .unwrap_or_else(|| EnvFilter::new(DEFAULT_FILTER));

    let file_appender = tracing_appender::rolling::never(&log_dir, "server.log");
    let (writer, guard) = tracing_appender::non_blocking(file_appender);
    let format = std::env::var("ORBITDOCK_SERVER_LOG_FORMAT").unwrap_or_else(|_| "json".into());

    let registry = tracing_subscriber::registry().with(filter);
    if format.eq_ignore_ascii_case("pretty") {
        registry
            .with(
                fmt::layer()
                    .with_writer(writer)
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
                    .with_writer(writer)
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
        filter = %std::env::var("ORBITDOCK_SERVER_LOG_FILTER")
            .or_else(|_| std::env::var("RUST_LOG"))
            .unwrap_or_else(|_| DEFAULT_FILTER.to_string()),
    );

    Ok(LoggingHandle { run_id, guard })
}
