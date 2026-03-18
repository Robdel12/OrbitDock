use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::UNIX_EPOCH;

use axum::{
    extract::DefaultBodyLimit,
    http::{
        header::{AUTHORIZATION, CONTENT_TYPE},
        HeaderValue, Method,
    },
    response::IntoResponse,
    routing::get,
    Router,
};
use orbitdock_protocol::{
    CodexIntegrationMode, Provider, SessionStatus, TokenUsage, TurnDiff, WorkStatus,
};
use tokio::sync::mpsc;
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;
use tracing::{info, warn};

use crate::infrastructure::logging::init_logging;
use crate::infrastructure::persistence::{
    cleanup_dangling_in_progress_messages, cleanup_stale_permission_state,
    create_persistence_channel, load_sessions_for_startup, PersistCommand, PersistenceWriter,
};
use crate::runtime::session_registry::SessionRegistry;
use crate::transport::websocket::ws_handler;
use crate::VERSION;

/// Per-request body budget for REST uploads. Image attachments are uploaded
/// one at a time, so this should comfortably exceed the client-side single-image limit.
const MAX_HTTP_BODY_BYTES: usize = 16 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct ServerRunOptions {
    pub bind_addr: SocketAddr,
    pub auth_token: Option<String>,
    pub allow_insecure_no_auth: bool,
    pub startup_is_primary: bool,
    pub data_dir: PathBuf,
    pub tls_cert: Option<PathBuf>,
    pub tls_key: Option<PathBuf>,
}

pub async fn run_server(options: ServerRunOptions) -> anyhow::Result<()> {
    let auth_token = normalize_auth_token(options.auth_token);

    crate::infrastructure::paths::ensure_dirs()?;
    crate::infrastructure::crypto::ensure_key();

    let logging = init_logging()?;
    let run_id = logging.run_id.clone();
    let _log_guard = logging.guard;
    let _stderr_guard = logging._stderr_guard;
    let root_span =
        tracing::info_span!("orbitdock_server", service = "orbitdock", run_id = %run_id);
    let _root_span_guard = root_span.enter();

    let binary_path =
        std::env::var("ORBITDOCK_SERVER_BINARY_PATH").unwrap_or_else(|_| current_binary_path());
    let (binary_size, binary_mtime_unix) = binary_metadata(&binary_path);

    info!(
        component = "server",
        event = "server.starting",
        run_id = %run_id,
        version = VERSION,
        startup_is_primary = options.startup_is_primary,
        pid = std::process::id(),
        data_dir = %options.data_dir.display(),
        binary_path = %binary_path,
        binary_size_bytes = binary_size,
        binary_mtime_unix = binary_mtime_unix,
        "Starting OrbitDock Server..."
    );

    let db_path = crate::infrastructure::paths::db_path();
    {
        let mut conn = rusqlite::Connection::open(&db_path)
            .map_err(|e| anyhow::anyhow!("open db for migrations: {e}"))?;
        crate::infrastructure::migration_runner::run_migrations(&mut conn)
            .map_err(|e| anyhow::anyhow!("database migration failed: {e}"))?;
    }

    let active_db_tokens = crate::infrastructure::auth_tokens::active_token_count().unwrap_or(0);
    let has_db_tokens = active_db_tokens > 0;

    if !options.bind_addr.ip().is_loopback()
        && auth_token.is_none()
        && !has_db_tokens
        && !options.allow_insecure_no_auth
    {
        anyhow::bail!(
            "Refusing to bind {} without authentication. Create a secure token with `orbitdock generate-token`, pass --auth-token (or ORBITDOCK_AUTH_TOKEN), or explicitly pass --allow-insecure-no-auth for trusted LAN/dev use.",
            options.bind_addr
        );
    }
    if !options.bind_addr.ip().is_loopback()
        && auth_token.is_none()
        && !has_db_tokens
        && options.allow_insecure_no_auth
    {
        warn!(
            component = "server",
            event = "server.auth.disabled_non_loopback",
            bind_addr = %options.bind_addr,
            "Starting without auth on non-loopback bind (trusted LAN/dev only)."
        );
    }

    if !options.bind_addr.ip().is_loopback()
        && (options.tls_cert.is_none() || options.tls_key.is_none())
    {
        warn!(
            component = "server",
            event = "server.tls.not_configured_non_loopback",
            bind_addr = %options.bind_addr,
            "Non-loopback bind is running without native TLS. Use TLS termination (Cloudflare/Tailscale/reverse proxy) or pass --tls-cert/--tls-key."
        );
    }

    let persisted_is_primary = crate::infrastructure::persistence::load_config_value("server_role")
        .and_then(|value| parse_server_role_value(&value));
    let is_primary = persisted_is_primary.unwrap_or(options.startup_is_primary);
    info!(
        component = "server",
        event = "server.role.resolved",
        is_primary = is_primary,
        source = if persisted_is_primary.is_some() {
            "config"
        } else {
            "startup_default"
        },
        "Resolved server control-plane role"
    );

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

    let (persist_tx, persist_rx) = create_persistence_channel();
    let persistence_writer = PersistenceWriter::new(persist_rx);
    tokio::spawn(persistence_writer.run());

    if persisted_is_primary.is_none() {
        let initial_role = if is_primary { "primary" } else { "secondary" }.to_string();
        let _ = persist_tx
            .send(PersistCommand::SetConfig {
                key: "server_role".into(),
                value: initial_role,
            })
            .await;
    }

    let state = Arc::new(SessionRegistry::new_with_primary_and_db_path(
        persist_tx.clone(),
        db_path.clone(),
        is_primary,
    ));

    if let Err(error) = cleanup_stale_permission_state().await {
        warn!(component = "startup", error = %error, "Failed to run stale permission cleanup");
    }

    if let Err(error) = cleanup_dangling_in_progress_messages().await {
        warn!(component = "startup", error = %error, "Failed to run dangling in-progress message cleanup");
    }

    match load_sessions_for_startup().await {
        Ok(restored) if !restored.is_empty() => {
            info!(
                component = "restore",
                event = "restore.start",
                session_count = restored.len(),
                "Registering sessions (connectors created lazily on subscribe)"
            );

            let mut backfill_tasks: Vec<(String, String)> = Vec::new();

            for rs in restored {
                let crate::infrastructure::persistence::RestoredSession {
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
                    permission_mode,
                    collaboration_mode,
                    multi_agent,
                    personality,
                    service_tier,
                    developer_instructions,
                    input_tokens,
                    output_tokens,
                    cached_tokens,
                    context_window,
                    token_usage_snapshot_kind,
                    pending_tool_name,
                    pending_tool_input,
                    pending_question,
                    pending_approval_id,
                    rows,
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
                    approval_version,
                    unread_count,
                    mission_id,
                    issue_identifier,
                    allow_bypass_permissions,
                } = rs;
                let msg_count = rows.len();

                if msg_count == 0 && provider == "claude" {
                    if let Some(ref transcript_path) = transcript_path {
                        backfill_tasks.push((id.clone(), transcript_path.clone()));
                    }
                }

                let provider: Provider = provider.parse().unwrap();

                let mut handle = crate::domain::sessions::session::SessionHandle::restore(
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
                    permission_mode,
                    collaboration_mode,
                    multi_agent,
                    personality,
                    service_tier,
                    developer_instructions,
                    TokenUsage {
                        input_tokens: input_tokens.max(0) as u64,
                        output_tokens: output_tokens.max(0) as u64,
                        cached_tokens: cached_tokens.max(0) as u64,
                        context_window: context_window.max(0) as u64,
                    },
                    token_usage_snapshot_kind,
                    started_at,
                    last_activity_at,
                    rows,
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
                                snapshot_kind,
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
                                    snapshot_kind: Some(snapshot_kind),
                                }
                            },
                        )
                        .collect(),
                    git_branch,
                    git_sha,
                    current_cwd,
                    first_prompt,
                    last_message,
                    pending_tool_name,
                    pending_tool_input,
                    pending_question,
                    pending_approval_id,
                    effort,
                    terminal_session_id,
                    terminal_app,
                    approval_version,
                    unread_count,
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
                if is_claude {
                    handle.set_claude_integration_mode(Some(if is_claude_direct {
                        orbitdock_protocol::ClaudeIntegrationMode::Direct
                    } else {
                        orbitdock_protocol::ClaudeIntegrationMode::Passive
                    }));
                }
                if let Some(source_id) = forked_from_session_id {
                    handle.set_forked_from(source_id);
                }
                if mission_id.is_some() || issue_identifier.is_some() {
                    handle.set_mission_context(mission_id, issue_identifier);
                }
                if allow_bypass_permissions {
                    handle.set_allow_bypass_permissions(true);
                }

                if is_codex {
                    if let Some(ref thread_id) = codex_thread_id {
                        if orbitdock_protocol::is_provider_id(thread_id) {
                            state.register_codex_thread(&id, thread_id);
                        }
                    }
                }
                if is_claude_direct {
                    let sdk_id = claude_sdk_session_id
                        .as_deref()
                        .or(codex_thread_id.as_deref())
                        .and_then(orbitdock_protocol::ProviderSessionId::new);
                    if let Some(ref sdk_id) = sdk_id {
                        state.register_claude_thread(&id, sdk_id.as_str());
                    }
                }

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

            if !backfill_tasks.is_empty() {
                info!(
                    component = "restore",
                    event = "restore.backfill.starting",
                    count = backfill_tasks.len(),
                    "Backfilling messages from transcript files"
                );
                let backfill_persist_tx = persist_tx.clone();
                let backfill_state = state.clone();
                tokio::spawn(async move {
                    for (session_id, transcript_path) in backfill_tasks {
                        match crate::infrastructure::persistence::load_messages_from_transcript_path(
                            &transcript_path,
                            &session_id,
                        )
                        .await
                        {
                            Ok(mut rows) if !rows.is_empty() => {
                                let count = rows.len();

                                // Normalize sequences before persisting (matching
                                // what replace_rows() does internally) to keep
                                // DB and in-memory state consistent.
                                for (i, entry) in rows.iter_mut().enumerate() {
                                    entry.sequence = i as u64;
                                }
                                for entry in &rows {
                                    let _ = backfill_persist_tx
                                        .send(crate::infrastructure::persistence::PersistCommand::RowAppend {
                                            session_id: session_id.clone(),
                                            entry: entry.clone(),
                                        })
                                        .await;
                                }

                                if let Some(actor) = backfill_state.get_session(&session_id) {
                                    actor
                                        .send(
                                            crate::runtime::session_commands::SessionCommand::ReplaceRows {
                                                rows,
                                            },
                                        )
                                        .await;
                                }

                                info!(
                                    component = "restore",
                                    event = "restore.backfill.session_done",
                                    session_id = %session_id,
                                    messages = count,
                                    "Backfilled rows from transcript"
                                );
                            }
                            Ok(_) => {}
                            Err(error) => {
                                tracing::debug!(
                                    component = "restore",
                                    event = "restore.backfill.failed",
                                    session_id = %session_id,
                                    error = %error,
                                    "Failed to backfill from transcript"
                                );
                            }
                        }
                    }
                });
            }
        }
        Ok(_) => {
            info!(
                component = "restore",
                event = "restore.empty",
                "No sessions to restore"
            );
        }
        Err(error) => {
            warn!(
                component = "restore",
                event = "restore.failed",
                error = %error,
                "Failed to load sessions for restoration"
            );
        }
    }

    crate::infrastructure::persistence::backfill_claude_models_from_sessions().await;
    drain_spool(&state).await;

    {
        let summaries = state.get_session_summaries();
        for summary in &summaries {
            if summary.status == SessionStatus::Active
                && summary.summary.is_none()
                && summary.first_prompt.is_some()
            {
                if let Some(actor) = state.get_session(&summary.id) {
                    if state.naming_guard().try_claim(&summary.id) {
                        crate::support::ai_naming::spawn_naming_task(
                            summary.id.clone(),
                            summary.first_prompt.clone().unwrap(),
                            actor,
                            persist_tx.clone(),
                            state.list_tx(),
                        );
                    }
                }
            }
        }
    }

    let watcher_state = state.clone();
    let watcher_persist = persist_tx.clone();
    tokio::spawn(async move {
        if let Err(error) = crate::connectors::rollout_watcher::start_rollout_watcher(
            watcher_state,
            watcher_persist,
        )
        .await
        {
            warn!(
                component = "rollout_watcher",
                event = "rollout_watcher.stopped_with_error",
                error = %error,
                "Rollout watcher failed"
            );
        }
    });

    let expiry_state = state.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(30));
        loop {
            interval.tick().await;
            expiry_state.expire_pending_claude(std::time::Duration::from_secs(60));
        }
    });

    let git_state = state.clone();
    tokio::spawn(crate::runtime::background::git_refresh::start_git_refresh_loop(git_state));

    // Mission Control orchestrator — user-started via POST /api/missions/:id/start-orchestrator
    info!(
        component = "mission_control",
        event = "mission_control.ready",
        "Mission Control ready (start orchestrator via API)"
    );

    let shutdown_state = state.clone();
    let shutdown_persist = persist_tx.clone();

    let mut app = Router::new()
        .layer(DefaultBodyLimit::max(MAX_HTTP_BODY_BYTES))
        .route("/ws", get(ws_handler))
        .merge(crate::transport::http::build_router())
        .route("/health", get(health_handler))
        .route(
            "/metrics",
            get(crate::infrastructure::metrics::metrics_handler),
        );

    let auth_state = crate::infrastructure::auth::AuthState {
        static_token: auth_token.clone(),
    };
    app = app.layer(axum::middleware::from_fn_with_state(
        auth_state,
        crate::infrastructure::auth::auth_middleware,
    ));

    let mut app = app.layer(TraceLayer::new_for_http());
    if let Some(cors_layer) = configured_cors_layer()? {
        app = app.layer(cors_layer);
    }
    let app = app.with_state(state);

    let use_tls = options.tls_cert.is_some() && options.tls_key.is_some();

    if use_tls {
        let cert_path = options.tls_cert.unwrap();
        let key_path = options.tls_key.unwrap();

        let tls_config =
            axum_server::tls_rustls::RustlsConfig::from_pem_file(&cert_path, &key_path).await?;

        info!(
            component = "server",
            event = "server.listening",
            bind_address = %options.bind_addr,
            tls = true,
            cert = %cert_path.display(),
            "Listening for TLS connections"
        );

        write_pid_file();

        let handle = axum_server::Handle::new();
        let shutdown_handle = handle.clone();
        tokio::spawn(async move {
            shutdown_signal(shutdown_state, shutdown_persist).await;
            shutdown_handle.graceful_shutdown(Some(std::time::Duration::from_secs(5)));
        });

        axum_server::bind_rustls(options.bind_addr, tls_config)
            .handle(handle)
            .serve(app.into_make_service())
            .await?;
    } else {
        let listener = tokio::net::TcpListener::bind(options.bind_addr).await?;

        info!(
            component = "server",
            event = "server.listening",
            bind_address = %options.bind_addr,
            tls = false,
            "Listening for connections"
        );

        write_pid_file();

        axum::serve(listener, app)
            .with_graceful_shutdown(shutdown_signal(shutdown_state, shutdown_persist))
            .await?;
    }

    Ok(())
}

fn parse_server_role_value(value: &str) -> Option<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "primary" | "true" | "1" => Some(true),
        "secondary" | "false" | "0" => Some(false),
        _ => None,
    }
}

fn normalize_auth_token(auth_token: Option<String>) -> Option<String> {
    auth_token
        .map(|token| token.trim().to_string())
        .filter(|token| !token.is_empty())
}

fn configured_cors_layer() -> anyhow::Result<Option<CorsLayer>> {
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

    info!(
        component = "server",
        event = "cors.enabled",
        allowed_origins = origins.len(),
        "Enabled CORS for configured origins"
    );

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

fn write_pid_file() {
    let pid_path = crate::infrastructure::paths::pid_file_path();
    if let Err(error) = std::fs::write(&pid_path, std::process::id().to_string()) {
        warn!(
            component = "server",
            event = "server.pid_file.write_error",
            path = %pid_path.display(),
            error = %error,
            "Failed to write PID file"
        );
    }
}

fn remove_pid_file() {
    let pid_path = crate::infrastructure::paths::pid_file_path();
    let _ = std::fs::remove_file(&pid_path);
}

async fn shutdown_signal(_state: Arc<SessionRegistry>, _persist_tx: mpsc::Sender<PersistCommand>) {
    let _ = tokio::signal::ctrl_c().await;
    info!(
        component = "server",
        event = "server.shutdown",
        "Shutdown signal received — active direct sessions preserved for lazy resume"
    );
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
        .and_then(|path| path.into_os_string().into_string().ok())
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
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0);
    (size, modified)
}

async fn drain_spool(state: &Arc<SessionRegistry>) {
    let spool_dir = crate::infrastructure::paths::spool_dir();
    let entries = match std::fs::read_dir(&spool_dir) {
        Ok(entries) => entries,
        Err(_) => return,
    };

    let mut files: Vec<PathBuf> = entries
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| path.extension().and_then(|ext| ext.to_str()) == Some("json"))
        .collect();

    if files.is_empty() {
        return;
    }

    files.sort();

    let total = files.len();
    let mut drained = 0u64;
    let mut failed = 0u64;

    for path in &files {
        let content = match std::fs::read_to_string(path) {
            Ok(content) => content,
            Err(error) => {
                warn!(
                    component = "spool",
                    event = "spool.read_error",
                    path = %path.display(),
                    error = %error,
                    "Failed to read spool file, skipping"
                );
                failed += 1;
                continue;
            }
        };

        let message: orbitdock_protocol::ClientMessage = match serde_json::from_str(&content) {
            Ok(message) => message,
            Err(error) => {
                warn!(
                    component = "spool",
                    event = "spool.parse_error",
                    path = %path.display(),
                    error = %error,
                    "Failed to parse spool file, skipping"
                );
                failed += 1;
                continue;
            }
        };

        crate::connectors::hook_handler::handle_hook_message(message, state).await;
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
