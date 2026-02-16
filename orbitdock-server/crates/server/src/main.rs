//! OrbitDock Server
//!
//! Mission control for AI coding agents.
//! Provides real-time session management via WebSocket.

mod ai_naming;
mod claude_session;
mod codex_auth;
mod codex_session;
mod git;
mod logging;
mod migration_runner;
mod persistence;
mod rollout_watcher;
mod session;
mod session_actor;
mod session_command;
mod session_naming;
mod state;
mod transition;
mod websocket;

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::UNIX_EPOCH;

use axum::{response::IntoResponse, routing::get, Router};
use orbitdock_protocol::{
    CodexIntegrationMode, Provider, SessionStatus, TokenUsage, TurnDiff, WorkStatus,
};
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;
use tracing::{info, warn};

use crate::codex_session::CodexSession;
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

    let runtime = tokio::runtime::Runtime::new()?;
    runtime.block_on(async_main())
}

async fn async_main() -> anyhow::Result<()> {
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
        pid = std::process::id(),
        binary_path = %binary_path,
        binary_size_bytes = binary_size,
        binary_mtime_unix = binary_mtime_unix,
        "Starting OrbitDock Server..."
    );

    // Run database migrations before anything else
    let db_path = {
        let home = std::env::var("HOME").expect("HOME not set");
        let dir = PathBuf::from(&home).join(".orbitdock");
        std::fs::create_dir_all(&dir).expect("create .orbitdock dir");
        dir.join("orbitdock.db")
    };
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

    // Restore active sessions from database
    match load_sessions_for_startup().await {
        Ok(restored) if !restored.is_empty() => {
            info!(
                component = "restore",
                event = "restore.start",
                active_sessions = restored.len(),
                "Restoring active sessions"
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
                    started_at,
                    last_activity_at,
                    approval_policy,
                    sandbox_mode,
                    codex_input_tokens,
                    codex_output_tokens,
                    codex_cached_tokens,
                    codex_context_window,
                    messages,
                    forked_from_session_id,
                    current_diff,
                    current_plan,
                    turn_diffs: restored_turn_diffs,
                    git_branch,
                    git_sha,
                    current_cwd,
                    first_prompt,
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
                        input_tokens: codex_input_tokens.max(0) as u64,
                        output_tokens: codex_output_tokens.max(0) as u64,
                        cached_tokens: codex_cached_tokens.max(0) as u64,
                        context_window: codex_context_window.max(0) as u64,
                    },
                    started_at,
                    last_activity_at,
                    messages,
                    current_diff,
                    current_plan,
                    restored_turn_diffs
                        .into_iter()
                        .map(|(turn_id, diff)| TurnDiff { turn_id, diff })
                        .collect(),
                    git_branch,
                    git_sha,
                    current_cwd,
                    first_prompt,
                );
                let is_codex = matches!(provider, Provider::Codex);
                let is_claude = matches!(provider, Provider::Claude);
                let is_passive =
                    is_codex && matches!(codex_integration_mode.as_deref(), Some("passive"));
                let is_claude_direct =
                    is_claude && matches!(claude_integration_mode.as_deref(), Some("direct"));
                let is_active = status == "active";
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

                // Determine if this session should get a live connector
                let needs_codex_connector = is_active && is_codex && !is_passive;
                let needs_claude_connector = is_active && is_claude_direct;

                if !needs_codex_connector && !needs_claude_connector {
                    // Passive session: spawn a passive actor
                    state.add_session(handle);
                    if is_codex && !is_passive {
                        if let Some(existing_thread_id) = codex_thread_id.as_deref() {
                            state.register_codex_thread(&id, existing_thread_id);
                        }
                    }
                    info!(
                        component = "restore",
                        event = "restore.session.passive",
                        session_id = %id,
                        provider = %match provider {
                            Provider::Codex => "codex",
                            Provider::Claude => "claude",
                        },
                        messages = msg_count,
                        "Restored passive session"
                    );
                    continue;
                }

                // Active Claude direct session: spawn bridge and resume
                if needs_claude_connector {
                    let claude_sdk_session_id = codex_thread_id.as_deref(); // reuses thread_id column

                    info!(
                        component = "restore",
                        event = "restore.session.claude_resuming",
                        session_id = %id,
                        claude_sdk_session_id = ?claude_sdk_session_id,
                        messages = msg_count,
                        "Resuming Claude direct session"
                    );

                    match crate::claude_session::ClaudeSession::new(
                        id.clone(),
                        &project_path,
                        model.as_deref(),
                        claude_sdk_session_id,
                    )
                    .await
                    {
                        Ok(claude_session) => {
                            let persist = state.persist().clone();
                            handle.set_list_tx(state.list_tx());
                            let (actor_handle, action_tx) =
                                claude_session.start_event_loop(handle, persist.clone(), state.list_tx());
                            state.add_session_actor(actor_handle);
                            state.set_claude_action_tx(&id, action_tx);

                            info!(
                                component = "restore",
                                event = "restore.session.claude_connected",
                                session_id = %id,
                                claude_sdk_session_id = ?claude_sdk_session_id,
                                messages = msg_count,
                                "Restored Claude session with live connector"
                            );
                        }
                        Err(e) => {
                            state.add_session(handle);
                            info!(
                                component = "restore",
                                event = "restore.session.claude_connector_unavailable",
                                session_id = %id,
                                messages = msg_count,
                                error = %e,
                                "Restored Claude session (connector unavailable)"
                            );
                        }
                    }
                    continue;
                }

                // Active Codex direct session: try to resume with conversation history
                let codex_result = if let Some(thread_id) = codex_thread_id.as_deref() {
                    info!(
                        component = "restore",
                        event = "restore.session.resuming",
                        session_id = %id,
                        thread_id = %thread_id,
                        "Resuming Codex session from rollout"
                    );
                    match CodexSession::resume(
                        id.clone(),
                        &project_path,
                        thread_id,
                        model.as_deref(),
                        approval_policy.as_deref(),
                        sandbox_mode.as_deref(),
                    )
                    .await
                    {
                        Ok(codex) => Ok(codex),
                        Err(e) => {
                            warn!(
                                component = "restore",
                                event = "restore.session.resume_failed",
                                session_id = %id,
                                error = %e,
                                "Resume failed, falling back to new thread"
                            );
                            CodexSession::new(
                                id.clone(),
                                &project_path,
                                model.as_deref(),
                                approval_policy.as_deref(),
                                sandbox_mode.as_deref(),
                            )
                            .await
                        }
                    }
                } else {
                    CodexSession::new(
                        id.clone(),
                        &project_path,
                        model.as_deref(),
                        approval_policy.as_deref(),
                        sandbox_mode.as_deref(),
                    )
                    .await
                };
                match codex_result {
                    Ok(codex) => {
                        let persist = state.persist().clone();

                        let new_thread_id = codex.thread_id().to_string();
                        let _ = persist
                            .send(PersistCommand::SetThreadId {
                                session_id: id.clone(),
                                thread_id: new_thread_id.clone(),
                            })
                            .await;
                        state.register_codex_thread(&id, &new_thread_id);

                        if state.remove_session(&new_thread_id).is_some() {
                            state.broadcast_to_list(
                                orbitdock_protocol::ServerMessage::SessionEnded {
                                    session_id: new_thread_id.clone(),
                                    reason: "direct_session_thread_claimed".into(),
                                },
                            );
                        }
                        let _ = persist
                            .send(PersistCommand::CleanupThreadShadowSession {
                                thread_id: new_thread_id.clone(),
                                reason: "legacy_codex_thread_row_cleanup".into(),
                            })
                            .await;

                        // start_event_loop takes owned handle, returns (SessionActorHandle, action_tx)
                        handle.set_list_tx(state.list_tx());
                        let (actor_handle, action_tx) = codex.start_event_loop(handle, persist);
                        state.add_session_actor(actor_handle);
                        state.set_codex_action_tx(&id, action_tx);
                        if let Some(existing_thread_id) = codex_thread_id.as_deref() {
                            state.register_codex_thread(&id, existing_thread_id);
                        }
                        info!(
                            component = "restore",
                            event = "restore.session.connected",
                            session_id = %id,
                            thread_id = %new_thread_id,
                            messages = msg_count,
                            "Restored session with live connector"
                        );
                    }
                    Err(e) => {
                        // Session visible with messages but not interactive — spawn passive actor
                        state.add_session(handle);
                        if let Some(existing_thread_id) = codex_thread_id.as_deref() {
                            state.register_codex_thread(&id, existing_thread_id);
                        }
                        info!(
                            component = "restore",
                            event = "restore.session.connector_unavailable",
                            session_id = %id,
                            messages = msg_count,
                            error = %e,
                            "Restored session (connector unavailable)"
                        );
                    }
                }
            }
        }
        Ok(_) => {
            info!(
                component = "restore",
                event = "restore.empty",
                "No active Codex sessions to restore"
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
    info!(
        component = "server",
        event = "server.listening",
        bind_address = %addr,
        "Listening for connections"
    );

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

async fn health_handler() -> impl IntoResponse {
    "OK"
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
