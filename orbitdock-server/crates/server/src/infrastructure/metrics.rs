//! Hand-written Prometheus text format metrics endpoint.
//!
//! ~15 gauges/counters collected from SessionRegistry + filesystem.

use std::fmt::Write;
use std::sync::Arc;

use axum::extract::State;
use axum::http::header;
use axum::response::IntoResponse;

use crate::paths;
use crate::state::SessionRegistry;

pub async fn metrics_handler(State(state): State<Arc<SessionRegistry>>) -> impl IntoResponse {
    let body = render_metrics(&state);
    (
        [(
            header::CONTENT_TYPE,
            "text/plain; version=0.0.4; charset=utf-8",
        )],
        body,
    )
}

fn render_metrics(state: &SessionRegistry) -> String {
    let mut out = String::with_capacity(2048);

    // Uptime
    gauge(
        &mut out,
        "orbitdock_uptime_seconds",
        "Time since server started",
        state.uptime_seconds() as f64,
    );

    // WebSocket connections
    gauge(
        &mut out,
        "orbitdock_websocket_connections",
        "Current active WebSocket connections",
        state.ws_connection_count() as f64,
    );

    // Sessions
    let summaries = state.get_session_summaries();
    let total = summaries.len();
    let active = summaries
        .iter()
        .filter(|s| s.status == orbitdock_protocol::SessionStatus::Active)
        .count();

    gauge(
        &mut out,
        "orbitdock_total_sessions",
        "Total sessions (active + ended)",
        total as f64,
    );
    gauge(
        &mut out,
        "orbitdock_active_sessions",
        "Currently active sessions",
        active as f64,
    );

    // Sessions by provider
    let claude_count = summaries
        .iter()
        .filter(|s| s.provider == orbitdock_protocol::Provider::Claude)
        .count();
    let codex_count = summaries
        .iter()
        .filter(|s| s.provider == orbitdock_protocol::Provider::Codex)
        .count();

    let _ = writeln!(
        out,
        "# HELP orbitdock_sessions_by_provider Sessions grouped by provider"
    );
    let _ = writeln!(out, "# TYPE orbitdock_sessions_by_provider gauge");
    let _ = writeln!(
        out,
        "orbitdock_sessions_by_provider{{provider=\"claude\"}} {}",
        claude_count
    );
    let _ = writeln!(
        out,
        "orbitdock_sessions_by_provider{{provider=\"codex\"}} {}",
        codex_count
    );

    // Sessions by work status
    let mut status_counts = std::collections::HashMap::new();
    for s in &summaries {
        let label = match s.work_status {
            orbitdock_protocol::WorkStatus::Working => "working",
            orbitdock_protocol::WorkStatus::Permission => "permission",
            orbitdock_protocol::WorkStatus::Question => "question",
            orbitdock_protocol::WorkStatus::Reply => "reply",
            orbitdock_protocol::WorkStatus::Waiting => "waiting",
            orbitdock_protocol::WorkStatus::Ended => "ended",
        };
        *status_counts.entry(label).or_insert(0u64) += 1;
    }

    let _ = writeln!(
        out,
        "# HELP orbitdock_sessions_by_status Sessions grouped by work status"
    );
    let _ = writeln!(out, "# TYPE orbitdock_sessions_by_status gauge");
    for status in &[
        "working",
        "permission",
        "question",
        "reply",
        "waiting",
        "ended",
    ] {
        let count = status_counts.get(status).copied().unwrap_or(0);
        let _ = writeln!(
            out,
            "orbitdock_sessions_by_status{{status=\"{}\"}} {}",
            status, count
        );
    }

    // Database size
    let db_path = paths::db_path();
    if let Ok(meta) = std::fs::metadata(&db_path) {
        gauge(
            &mut out,
            "orbitdock_db_size_bytes",
            "SQLite database file size",
            meta.len() as f64,
        );
    }

    // WAL size
    let wal_path = db_path.with_extension("db-wal");
    let wal_size = std::fs::metadata(&wal_path).map(|m| m.len()).unwrap_or(0);
    gauge(
        &mut out,
        "orbitdock_db_wal_size_bytes",
        "SQLite WAL file size",
        wal_size as f64,
    );

    // Spool queue depth
    let spool_depth = spool_queue_depth();
    gauge(
        &mut out,
        "orbitdock_spool_queue_depth",
        "Hook events queued in spool directory",
        spool_depth as f64,
    );

    out
}

fn gauge(out: &mut String, name: &str, help: &str, value: f64) {
    let _ = writeln!(out, "# HELP {} {}", name, help);
    let _ = writeln!(out, "# TYPE {} gauge", name);
    let _ = writeln!(out, "{} {}", name, value);
}

fn spool_queue_depth() -> u64 {
    let spool_dir = paths::spool_dir();
    std::fs::read_dir(spool_dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .filter(|e| {
                    e.path()
                        .extension()
                        .and_then(|ext| ext.to_str())
                        .map(|ext| ext == "json")
                        .unwrap_or(false)
                })
                .count() as u64
        })
        .unwrap_or(0)
}
