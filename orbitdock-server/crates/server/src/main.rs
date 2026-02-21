//! OrbitDock Server
//!
//! Mission control for AI coding agents.
//! Provides real-time session management via WebSocket.

mod ai_naming;
mod auth;
mod claude_session;
mod cmd_init;
mod cmd_install_hooks;
mod cmd_install_service;
mod cmd_status;
mod codex_auth;
mod codex_session;
mod git;
mod hook_handler;
pub(crate) mod images;
mod logging;
mod migration_runner;
pub(crate) mod paths;
mod persistence;
mod rollout_watcher;
mod session;
mod session_actor;
mod session_command;
mod session_naming;
mod shell;
mod state;
mod subagent_parser;
mod transition;
mod websocket;

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::UNIX_EPOCH;

use axum::{
    response::IntoResponse,
    routing::{get, post},
    Router,
};
use clap::{Parser, Subcommand};
use orbitdock_protocol::{
    CodexIntegrationMode, Provider, SessionStatus, TokenUsage, TurnDiff, WorkStatus,
};
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;
use tracing::{info, warn};

use tokio::sync::mpsc;

/// Server version, baked in at compile time.
pub(crate) const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Parser, Debug)]
#[command(
    name = "orbitdock-server",
    about = "OrbitDock server — mission control for AI coding agents",
    version = VERSION,
)]
struct Cli {
    /// Data directory (default: ~/.orbitdock)
    #[arg(long, global = true, env = "ORBITDOCK_DATA_DIR")]
    data_dir: Option<PathBuf>,

    /// Bind address (top-level, for backward compat — prefer `start --bind`)
    #[arg(long, env = "ORBITDOCK_BIND_ADDR")]
    bind: Option<SocketAddr>,

    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Start the server (default when no subcommand given)
    Start {
        /// Bind address (e.g. 0.0.0.0:4000 for remote access)
        #[arg(long, default_value = "127.0.0.1:4000", env = "ORBITDOCK_BIND_ADDR")]
        bind: SocketAddr,

        /// Auth token (requests must include `Authorization: Bearer <token>`)
        #[arg(long, env = "ORBITDOCK_AUTH_TOKEN")]
        auth_token: Option<String>,
    },

    /// Bootstrap a fresh machine (create dirs, run migrations, install hook script)
    Init {
        /// Server URL the hook script will POST to
        #[arg(long, default_value = "http://127.0.0.1:4000")]
        server_url: String,
    },

    /// Install Claude Code hooks into ~/.claude/settings.json
    InstallHooks {
        /// Path to settings.json (default: ~/.claude/settings.json)
        #[arg(long)]
        settings_path: Option<PathBuf>,
    },

    /// Generate and install a launchd/systemd service file
    InstallService {
        /// Bind address for the service
        #[arg(long, default_value = "127.0.0.1:4000")]
        bind: SocketAddr,

        /// Enable the service immediately after installing
        #[arg(long)]
        enable: bool,
    },

    /// Check if the server is running
    Status,

    /// Generate a random auth token and write it to data_dir/auth-token
    GenerateToken,
}

use crate::logging::init_logging;
use crate::persistence::{
    create_persistence_channel, load_sessions_for_startup, PersistCommand, PersistenceWriter,
};
use crate::session::SessionHandle;
use crate::state::SessionRegistry;
use crate::websocket::ws_handler;

fn main() -> anyhow::Result<()> {
    // Handle codex-core self-invocation (apply_patch, linux-sandbox) and
    // set up PATH so that codex-core can find the apply_patch helper.
    // This MUST run before the tokio runtime starts (modifies env vars).
    let _arg0_guard = codex_arg0::arg0_dispatch();

    let cli = Cli::parse();

    // Initialize data dir from CLI arg / env / default — before anything else
    let data_dir = paths::init_data_dir(cli.data_dir.as_deref());

    // Dispatch subcommands that don't need the async runtime
    match &cli.command {
        Some(Command::Init { server_url }) => {
            return cmd_init::run(&data_dir, server_url);
        }
        Some(Command::InstallHooks { settings_path }) => {
            return cmd_install_hooks::run(settings_path.as_deref());
        }
        Some(Command::InstallService { bind, enable }) => {
            return cmd_install_service::run(&data_dir, *bind, *enable);
        }
        Some(Command::Status) => {
            return cmd_status::run(&data_dir);
        }
        Some(Command::GenerateToken) => {
            return cmd_status::generate_token(&data_dir);
        }
        _ => {}
    }

    // Resolve bind address: subcommand --bind > top-level --bind > default
    let (bind_addr, auth_token) = match cli.command {
        Some(Command::Start { bind, auth_token }) => (bind, auth_token),
        _ => (
            cli.bind
                .unwrap_or_else(|| "127.0.0.1:4000".parse().unwrap()),
            None,
        ),
    };

    let runtime = tokio::runtime::Runtime::new()?;
    runtime.block_on(async_main(bind_addr, auth_token, &data_dir))
}

async fn async_main(
    bind_addr: SocketAddr,
    auth_token: Option<String>,
    data_dir: &std::path::Path,
) -> anyhow::Result<()> {
    // Ensure directories exist
    paths::ensure_dirs()?;

    let logging = init_logging()?;
    let run_id = logging.run_id.clone();
    let _log_guard = logging.guard;
    let root_span =
        tracing::info_span!("orbitdock_server", service = "orbitdock-server", run_id = %run_id);
    let _root_span_guard = root_span.enter();

    let binary_path =
        std::env::var("ORBITDOCK_SERVER_BINARY_PATH").unwrap_or_else(|_| current_binary_path());
    let (binary_size, binary_mtime_unix) = binary_metadata(&binary_path);

    info!(
        component = "server",
        event = "server.starting",
        run_id = %run_id,
        version = VERSION,
        pid = std::process::id(),
        data_dir = %data_dir.display(),
        binary_path = %binary_path,
        binary_size_bytes = binary_size,
        binary_mtime_unix = binary_mtime_unix,
        "Starting OrbitDock Server..."
    );

    // Run database migrations before anything else
    let db_path = paths::db_path();
    {
        let mut conn = rusqlite::Connection::open(&db_path).expect("open db for migrations");
        if let Err(e) = migration_runner::run_migrations(&mut conn) {
            warn!(
                component = "migrations",
                event = "migrations.error",
                error = %e,
                "Migration runner failed — continuing with existing schema"
            );
        }
    }

    // Check for Claude CLI binary
    {
        let claude_found = std::env::var("CLAUDE_BIN")
            .ok()
            .filter(|p| std::path::Path::new(p).exists())
            .is_some()
            || std::env::var("HOME")
                .ok()
                .map(|h| format!("{}/.claude/local/claude", h))
                .filter(|p| std::path::Path::new(p).exists())
                .is_some()
            || std::process::Command::new("which")
                .arg("claude")
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false);

        if claude_found {
            info!(
                component = "server",
                event = "server.claude.available",
                "Claude CLI binary available"
            );
        } else {
            warn!(
                component = "server",
                event = "server.claude.missing",
                "Claude CLI binary not found — Claude direct sessions will not be available"
            );
        }
    }

    // Create persistence channel and spawn writer
    let (persist_tx, persist_rx) = create_persistence_channel();
    let persistence_writer = PersistenceWriter::new(persist_rx);
    tokio::spawn(persistence_writer.run());

    // Create app state with persistence sender
    let state = Arc::new(SessionRegistry::new(persist_tx.clone()));

    // Restore sessions from database — all registered as passive (no connectors).
    // Connectors are created lazily when a client subscribes to a session.
    match load_sessions_for_startup().await {
        Ok(restored) if !restored.is_empty() => {
            info!(
                component = "restore",
                event = "restore.start",
                session_count = restored.len(),
                "Registering sessions (connectors created lazily on subscribe)"
            );

            for rs in restored {
                let crate::persistence::RestoredSession {
                    id,
                    provider,
                    status,
                    work_status,
                    project_path,
                    transcript_path,
                    project_name,
                    model,
                    custom_name,
                    summary,
                    codex_integration_mode,
                    claude_integration_mode,
                    codex_thread_id,
                    claude_sdk_session_id,
                    started_at,
                    last_activity_at,
                    approval_policy,
                    sandbox_mode,
                    input_tokens,
                    output_tokens,
                    cached_tokens,
                    context_window,
                    messages,
                    forked_from_session_id,
                    current_diff,
                    current_plan,
                    turn_diffs: restored_turn_diffs,
                    git_branch,
                    git_sha,
                    current_cwd,
                    first_prompt,
                    last_message,
                    end_reason: _,
                    effort,
                    terminal_session_id,
                    terminal_app,
                } = rs;
                let msg_count = messages.len();

                let provider = match provider.as_str() {
                    "codex" => Provider::Codex,
                    _ => Provider::Claude,
                };
                let mut handle = SessionHandle::restore(
                    id.clone(),
                    provider,
                    project_path.clone(),
                    transcript_path,
                    project_name,
                    model.clone(),
                    custom_name,
                    summary,
                    match status.as_str() {
                        "ended" => SessionStatus::Ended,
                        _ => SessionStatus::Active,
                    },
                    match work_status.as_str() {
                        "working" => WorkStatus::Working,
                        "permission" => WorkStatus::Permission,
                        "question" => WorkStatus::Question,
                        "reply" => WorkStatus::Reply,
                        "ended" => WorkStatus::Ended,
                        _ => WorkStatus::Waiting,
                    },
                    approval_policy.clone(),
                    sandbox_mode.clone(),
                    TokenUsage {
                        input_tokens: input_tokens.max(0) as u64,
                        output_tokens: output_tokens.max(0) as u64,
                        cached_tokens: cached_tokens.max(0) as u64,
                        context_window: context_window.max(0) as u64,
                    },
                    started_at,
                    last_activity_at,
                    messages,
                    current_diff,
                    current_plan,
                    restored_turn_diffs
                        .into_iter()
                        .map(
                            |(
                                turn_id,
                                diff,
                                input_tokens,
                                output_tokens,
                                cached_tokens,
                                context_window,
                            )| {
                                let has_tokens =
                                    input_tokens > 0 || output_tokens > 0 || context_window > 0;
                                TurnDiff {
                                    turn_id,
                                    diff,
                                    token_usage: if has_tokens {
                                        Some(TokenUsage {
                                            input_tokens: input_tokens as u64,
                                            output_tokens: output_tokens as u64,
                                            cached_tokens: cached_tokens as u64,
                                            context_window: context_window as u64,
                                        })
                                    } else {
                                        None
                                    },
                                }
                            },
                        )
                        .collect(),
                    git_branch,
                    git_sha,
                    current_cwd,
                    first_prompt,
                    last_message,
                    effort,
                    terminal_session_id,
                    terminal_app,
                );
                let is_codex = matches!(provider, Provider::Codex);
                let is_claude = matches!(provider, Provider::Claude);
                let is_passive =
                    is_codex && matches!(codex_integration_mode.as_deref(), Some("passive"));
                let is_claude_direct =
                    is_claude && matches!(claude_integration_mode.as_deref(), Some("direct"));
                handle.set_codex_integration_mode(if is_passive {
                    Some(CodexIntegrationMode::Passive)
                } else if is_codex {
                    Some(CodexIntegrationMode::Direct)
                } else {
                    None
                });
                if is_claude_direct {
                    handle.set_claude_integration_mode(Some(
                        orbitdock_protocol::ClaudeIntegrationMode::Direct,
                    ));
                }
                if let Some(source_id) = forked_from_session_id {
                    handle.set_forked_from(source_id);
                }

                // Register thread IDs for duplicate detection
                if is_codex && !is_passive {
                    if let Some(ref thread_id) = codex_thread_id {
                        state.register_codex_thread(&id, thread_id);
                    }
                }
                if is_claude_direct {
                    let sdk_id = claude_sdk_session_id
                        .as_deref()
                        .or(codex_thread_id.as_deref());
                    if let Some(sdk_id) = sdk_id {
                        state.register_claude_thread(&id, sdk_id);
                    }
                }

                // All sessions start passive — connectors created on first subscribe
                state.add_session(handle);

                info!(
                    component = "restore",
                    event = "restore.session.registered",
                    session_id = %id,
                    provider = %match provider {
                        Provider::Codex => "codex",
                        Provider::Claude => "claude",
                    },
                    messages = msg_count,
                    "Registered session"
                );
            }
        }
        Ok(_) => {
            info!(
                component = "restore",
                event = "restore.empty",
                "No sessions to restore"
            );
        }
        Err(e) => {
            warn!(
                component = "restore",
                event = "restore.failed",
                error = %e,
                "Failed to load sessions for restoration"
            );
        }
    }

    // Drain spooled hook events from when the server was offline
    drain_spool(&state).await;

    // Backfill AI names for active sessions with first_prompt but no summary
    {
        let summaries = state.get_session_summaries();
        for s in &summaries {
            if s.status == SessionStatus::Active && s.summary.is_none() && s.first_prompt.is_some()
            {
                if let Some(actor) = state.get_session(&s.id) {
                    if state.naming_guard().try_claim(&s.id) {
                        ai_naming::spawn_naming_task(
                            s.id.clone(),
                            s.first_prompt.clone().unwrap(),
                            actor,
                            persist_tx.clone(),
                            state.list_tx(),
                        );
                    }
                }
            }
        }
    }

    // Start Codex rollout watcher (CLI sessions -> server state)
    let watcher_state = state.clone();
    let watcher_persist = persist_tx.clone();
    tokio::spawn(async move {
        if let Err(e) = rollout_watcher::start_rollout_watcher(watcher_state, watcher_persist).await
        {
            warn!(
                component = "rollout_watcher",
                event = "rollout_watcher.stopped_with_error",
                error = %e,
                "Rollout watcher failed"
            );
        }
    });

    // Background expiry for pending Claude sessions that never materialize
    let expiry_state = state.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(30));
        loop {
            interval.tick().await;
            expiry_state.expire_pending_claude(std::time::Duration::from_secs(60));
        }
    });

    // Keep a reference for the shutdown handler
    let shutdown_state = state.clone();
    let shutdown_persist = persist_tx.clone();

    // Build router
    let mut app = Router::new()
        .route("/ws", get(ws_handler))
        .route("/api/hook", post(hook_handler::hook_handler))
        .route("/health", get(health_handler));

    // Apply auth middleware if token configured
    if let Some(ref token) = auth_token {
        app = app.layer(axum::middleware::from_fn_with_state(
            token.clone(),
            auth::auth_middleware,
        ));
    }

    let app = app
        .layer(TraceLayer::new_for_http())
        .layer(
            CorsLayer::new()
                .allow_origin(Any)
                .allow_methods(Any)
                .allow_headers(Any),
        )
        .with_state(state);

    // Bind listener
    let listener = tokio::net::TcpListener::bind(bind_addr).await?;

    info!(
        component = "server",
        event = "server.listening",
        bind_address = %bind_addr,
        "Listening for connections"
    );

    // Write PID file after successful bind
    write_pid_file();

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal(shutdown_state, shutdown_persist))
        .await?;

    Ok(())
}

/// Write PID file to data_dir/orbitdock.pid
fn write_pid_file() {
    let pid_path = paths::pid_file_path();
    if let Err(e) = std::fs::write(&pid_path, std::process::id().to_string()) {
        warn!(
            component = "server",
            event = "server.pid_file.write_error",
            path = %pid_path.display(),
            error = %e,
            "Failed to write PID file"
        );
    }
}

/// Remove PID file on clean shutdown
fn remove_pid_file() {
    let pid_path = paths::pid_file_path();
    let _ = std::fs::remove_file(&pid_path);
}

/// Wait for shutdown signal and mark active direct sessions for resumption.
async fn shutdown_signal(state: Arc<SessionRegistry>, persist_tx: mpsc::Sender<PersistCommand>) {
    let _ = tokio::signal::ctrl_c().await;
    info!(
        component = "server",
        event = "server.shutdown",
        "Shutdown signal received, preserving direct session state"
    );

    // Mark active Claude direct sessions so they resume on next startup
    for summary in state.get_session_summaries() {
        if summary.provider == Provider::Claude
            && matches!(
                summary.claude_integration_mode,
                Some(orbitdock_protocol::ClaudeIntegrationMode::Direct)
            )
            && summary.status == orbitdock_protocol::SessionStatus::Active
        {
            let _ = persist_tx
                .send(PersistCommand::SessionEnd {
                    id: summary.id.clone(),
                    reason: "server_shutdown".to_string(),
                })
                .await;
            info!(
                component = "server",
                event = "server.shutdown.session_preserved",
                session_id = %summary.id,
                "Marked direct session for resume on restart"
            );
        }
    }

    // Give persistence writer a moment to flush
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;

    // Clean up PID file
    remove_pid_file();
}

async fn health_handler() -> impl IntoResponse {
    serde_json::json!({
        "status": "ok",
        "version": VERSION,
    })
    .to_string()
}

fn current_binary_path() -> String {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.into_os_string().into_string().ok())
        .unwrap_or_else(|| "unknown".to_string())
}

fn binary_metadata(path: &str) -> (u64, i64) {
    let Ok(metadata) = std::fs::metadata(path) else {
        return (0, 0);
    };
    let size = metadata.len();
    let modified = metadata
        .modified()
        .ok()
        .and_then(|mtime| mtime.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    (size, modified)
}

/// Drain spooled hook events written by `hook.sh` while the server was offline.
///
/// Reads all `.json` files from the spool directory, processes them in
/// timestamp order (filenames are `<epoch>-<pid>.json`), and deletes each
/// file after successful processing. Parse failures are warned and skipped.
async fn drain_spool(state: &Arc<SessionRegistry>) {
    let spool_dir = paths::spool_dir();
    let entries = match std::fs::read_dir(&spool_dir) {
        Ok(e) => e,
        Err(_) => return, // No spool dir — nothing to drain
    };

    let mut files: Vec<PathBuf> = entries
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("json"))
        .collect();

    if files.is_empty() {
        return;
    }

    // Sort by filename to preserve event order (timestamp prefix)
    files.sort();

    let total = files.len();
    let mut drained = 0u64;
    let mut failed = 0u64;

    for path in &files {
        let content = match std::fs::read_to_string(path) {
            Ok(c) => c,
            Err(e) => {
                warn!(
                    component = "spool",
                    event = "spool.read_error",
                    path = %path.display(),
                    error = %e,
                    "Failed to read spool file, skipping"
                );
                failed += 1;
                continue;
            }
        };

        let msg: orbitdock_protocol::ClientMessage = match serde_json::from_str(&content) {
            Ok(m) => m,
            Err(e) => {
                warn!(
                    component = "spool",
                    event = "spool.parse_error",
                    path = %path.display(),
                    error = %e,
                    "Failed to parse spool file, skipping"
                );
                failed += 1;
                continue;
            }
        };

        hook_handler::handle_hook_message(msg, state).await;
        let _ = std::fs::remove_file(path);
        drained += 1;
    }

    info!(
        component = "spool",
        event = "spool.drained",
        total = total,
        drained = drained,
        failed = failed,
        "Spool drain complete"
    );
}
