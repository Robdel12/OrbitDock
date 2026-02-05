//! OrbitDock Server
//!
//! Mission control for AI coding agents.
//! Provides real-time session management via WebSocket.

mod codex_session;
mod persistence;
mod session;
mod state;
mod websocket;

use std::net::SocketAddr;
use std::sync::Arc;

use axum::{response::IntoResponse, routing::get, Router};
use tokio::sync::Mutex;
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;
use tracing::info;
use tracing_subscriber::fmt;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::EnvFilter;

use crate::persistence::{create_persistence_channel, PersistenceWriter};
use crate::state::AppState;
use crate::websocket::ws_handler;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Ensure log directory exists
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let log_dir = std::path::PathBuf::from(home).join(".orbitdock").join("logs");
    std::fs::create_dir_all(&log_dir)?;

    // File appender - writes JSON to ~/.orbitdock/logs/server.log
    let file_appender = tracing_appender::rolling::never(&log_dir, "server.log");

    // Combined subscriber: stderr (human-readable) + file (JSON, greppable)
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("debug,tower_http=info,hyper=info"));

    tracing_subscriber::registry()
        .with(filter)
        .with(
            fmt::layer()
                .with_writer(std::io::stderr)
                .with_file(true)
                .with_line_number(true)
                .with_target(false)
                .compact(),
        )
        .with(
            fmt::layer()
                .with_writer(file_appender)
                .json()
                .with_file(true)
                .with_line_number(true)
                .with_target(true)
                .with_current_span(false),
        )
        .init();

    info!("Starting OrbitDock Server...");

    // Create persistence channel and spawn writer
    let (persist_tx, persist_rx) = create_persistence_channel();
    let persistence_writer = PersistenceWriter::new(persist_rx);
    tokio::spawn(persistence_writer.run());

    // Create app state with persistence sender
    let state = Arc::new(Mutex::new(AppState::new(persist_tx)));

    // Build router
    let app = Router::new()
        .route("/ws", get(ws_handler))
        .route("/health", get(health_handler))
        .layer(TraceLayer::new_for_http())
        .layer(
            CorsLayer::new()
                .allow_origin(Any)
                .allow_methods(Any)
                .allow_headers(Any),
        )
        .with_state(state);

    // Start server
    let addr = SocketAddr::from(([127, 0, 0, 1], 4000));
    info!("Listening on {}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

async fn health_handler() -> impl IntoResponse {
    "OK"
}
