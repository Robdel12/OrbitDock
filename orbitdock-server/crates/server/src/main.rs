//! OrbitDock Server
//!
//! Mission control for AI coding agents.
//! Provides real-time session management via WebSocket.

mod codex_session;
mod persistence;
mod rollout_watcher;
mod session;
mod state;
mod websocket;

use std::net::SocketAddr;
use std::sync::Arc;

use axum::{response::IntoResponse, routing::get, Router};
use tokio::sync::Mutex;
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;
use tracing::{info, warn};
use tracing_subscriber::fmt;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::EnvFilter;

use crate::codex_session::CodexSession;
use crate::persistence::{
    create_persistence_channel, load_active_codex_sessions, PersistCommand, PersistenceWriter,
};
use crate::session::SessionHandle;
use crate::state::AppState;
use crate::websocket::ws_handler;

fn main() -> anyhow::Result<()> {
    // Handle codex-core self-invocation (apply_patch, linux-sandbox) and
    // set up PATH so that codex-core can find the apply_patch helper.
    // This MUST run before the tokio runtime starts (modifies env vars).
    let _arg0_guard = codex_arg0::arg0_dispatch();

    let runtime = tokio::runtime::Runtime::new()?;
    runtime.block_on(async_main())
}

async fn async_main() -> anyhow::Result<()> {
    // Ensure log directory exists
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let log_dir = std::path::PathBuf::from(home)
        .join(".orbitdock")
        .join("logs");
    std::fs::create_dir_all(&log_dir)?;

    // File appender - writes JSON to ~/.orbitdock/logs/server.log
    let file_appender = tracing_appender::rolling::never(&log_dir, "server.log");

    // File-only logging — debug with: tail -f ~/.orbitdock/logs/server.log | jq .
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info,tower_http=warn,hyper=warn"));

    tracing_subscriber::registry()
        .with(filter)
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
    let state = Arc::new(Mutex::new(AppState::new(persist_tx.clone())));

    // Restore active Codex sessions from database
    match load_active_codex_sessions().await {
        Ok(restored) if !restored.is_empty() => {
            info!("Restoring {} active Codex session(s)...", restored.len());

            for rs in restored {
                let msg_count = rs.messages.len();
                let handle = SessionHandle::restore(
                    rs.id.clone(),
                    orbitdock_protocol::Provider::Codex,
                    rs.project_path.clone(),
                    rs.project_name,
                    rs.model.clone(),
                    rs.custom_name,
                    rs.started_at,
                    rs.last_activity_at,
                    rs.messages,
                );

                let mut app = state.lock().await;
                let session_arc = app.add_session(handle);

                // Try to reconnect a CodexConnector with original autonomy settings
                match CodexSession::new(
                    rs.id.clone(),
                    &rs.project_path,
                    rs.model.as_deref(),
                    rs.approval_policy.as_deref(),
                    rs.sandbox_mode.as_deref(),
                )
                .await
                {
                    Ok(codex) => {
                        let persist = app.persist().clone();

                        // Persist the new thread ID so the rollout watcher skips this session
                        let new_thread_id = codex.thread_id().to_string();
                        let _ = persist
                            .send(PersistCommand::SetThreadId {
                                session_id: rs.id.clone(),
                                thread_id: new_thread_id.clone(),
                            })
                            .await;
                        app.register_codex_thread(&rs.id, &new_thread_id);

                        let action_tx = codex.start_event_loop(session_arc, persist);
                        app.set_codex_action_tx(&rs.id, action_tx);
                        info!(
                            session_id = %rs.id,
                            thread_id = %new_thread_id,
                            messages = msg_count,
                            "Restored session with live connector"
                        );
                    }
                    Err(e) => {
                        // Session visible with messages but not interactive
                        info!(
                            session_id = %rs.id,
                            messages = msg_count,
                            error = %e,
                            "Restored session (connector unavailable)"
                        );
                    }
                }
            }
        }
        Ok(_) => {
            info!("No active Codex sessions to restore");
        }
        Err(e) => {
            warn!("Failed to load sessions for restoration: {}", e);
        }
    }

    // Start Codex rollout watcher (CLI sessions -> server state)
    let watcher_state = state.clone();
    let watcher_persist = persist_tx.clone();
    tokio::spawn(async move {
        if let Err(e) = rollout_watcher::start_rollout_watcher(watcher_state, watcher_persist).await
        {
            warn!("Rollout watcher failed: {}", e);
        }
    });

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
