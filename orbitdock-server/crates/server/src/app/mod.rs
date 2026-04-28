use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use axum::{extract::DefaultBodyLimit, routing::get, Router};
use orbitdock_protocol::{SessionStatus, WorkspaceProviderKind};
use tokio::sync::{mpsc, watch};
use tower_http::trace::TraceLayer;
use tracing::{info, warn};

use anyhow::Context;

mod config_policy;
mod http_surface;
mod pid;

use crate::infrastructure::logging::{init_logging, ServerLoggingOptions};
use crate::infrastructure::persistence::{
  cleanup_dangling_in_progress_messages, cleanup_stale_permission_state,
  create_persistence_channel, create_sync_shutdown_channel, load_sessions_for_startup,
  PersistCommand, PersistenceWriter, SyncWriter, SyncWriterConfig,
};
use crate::runtime::restored_sessions::restored_session_to_persisted_handle;
use crate::runtime::session_registry::SessionRegistry;
use crate::transport::websocket::ws_handler;

use self::config_policy::{
  load_trimmed_config_value, normalize_auth_token, parse_server_role_value,
  resolve_workspace_provider_kind,
};
use self::http_surface::{configured_cors_layer, describe_bind_failure, health_handler};
use self::pid::{cleanup_stale_pid_file, remove_pid_file, write_pid_file, PidFileGuard};

/// Per-request body budget for REST uploads. Image attachments are uploaded
/// one at a time, so this should comfortably exceed the client-side single-image limit.
const MAX_HTTP_BODY_BYTES: usize = 16 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct ManagedSyncRunOptions {
  pub workspace_id: String,
  pub server_url: String,
  pub auth_token: String,
}

#[derive(Debug, Clone)]
pub struct ServerRunOptions {
  pub bind_addr: SocketAddr,
  pub auth_token: Option<String>,
  pub allow_insecure_no_auth: bool,
  pub startup_is_primary: bool,
  pub data_dir: PathBuf,
  pub tls_cert: Option<PathBuf>,
  pub tls_key: Option<PathBuf>,
  pub logging: ServerLoggingOptions,
  pub serve_web: bool,
  pub managed_sync: Option<ManagedSyncRunOptions>,
  pub workspace_provider_override: Option<WorkspaceProviderKind>,
}

pub async fn run_server(options: ServerRunOptions) -> anyhow::Result<()> {
  let auth_token = normalize_auth_token(options.auth_token);

  crate::infrastructure::paths::ensure_dirs()?;
  crate::infrastructure::crypto::ensure_key();
  cleanup_stale_pid_file();
  crate::infrastructure::housekeeping::run_housekeeping();

  let logging = init_logging(&options.logging)?;
  let run_id = logging.run_id.clone();
  let _log_guard = logging.guard;
  let _stderr_guard = logging._stderr_guard;
  let root_span = tracing::info_span!("orbitdock_server", service = "orbitdock", run_id = %run_id);
  let _root_span_guard = root_span.enter();

  let db_path = crate::infrastructure::paths::db_path();
  {
    let mut conn = rusqlite::Connection::open(&db_path)
      .map_err(|e| anyhow::anyhow!("open db for migrations: {e}"))?;
    crate::infrastructure::migration_runner::run_migrations(&mut conn)
      .context("database migration failed")?;
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
  let persisted_workspace_provider_value =
    crate::infrastructure::persistence::load_config_value("workspace_provider");
  let persisted_server_instance_id = load_trimmed_config_value("server_instance_id");
  let server_instance_id = persisted_server_instance_id
    .clone()
    .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
  let workspace_provider_kind = resolve_workspace_provider_kind(
    options.workspace_provider_override,
    persisted_workspace_provider_value.clone(),
  )?;

  let (sync_shutdown_tx, sync_writer_handle) =
    if let Some(sync_options) = options.managed_sync.clone() {
      let (shutdown_tx, shutdown_rx) = create_sync_shutdown_channel();
      let sync_writer = SyncWriter::new(
        shutdown_rx,
        SyncWriterConfig::new(
          sync_options.workspace_id,
          crate::infrastructure::paths::db_path(),
          sync_options.server_url,
          sync_options.auth_token,
        ),
      )?;
      let writer_handle = tokio::spawn(sync_writer.run());
      (Some(shutdown_tx), Some(writer_handle))
    } else {
      (None, None)
    };

  let (persist_tx, persist_rx) = create_persistence_channel();
  let sync_workspace_id = options
    .managed_sync
    .as_ref()
    .map(|sync_options| sync_options.workspace_id.clone());
  let persistence_writer = PersistenceWriter::new(persist_rx, sync_workspace_id);
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

  if persisted_server_instance_id.is_none() {
    let _ = persist_tx
      .send(PersistCommand::SetConfig {
        key: "server_instance_id".into(),
        value: server_instance_id.clone(),
      })
      .await;
  }

  let state = Arc::new(SessionRegistry::new_with_primary_and_db_path(
    persist_tx.clone(),
    db_path.clone(),
    is_primary,
    workspace_provider_kind,
  ));
  state.set_server_instance_id(server_instance_id.clone());

  let _ = cleanup_stale_permission_state().await;
  let _ = cleanup_dangling_in_progress_messages().await;

  match load_sessions_for_startup().await {
    Ok(restored) if !restored.is_empty() => {
      let mut backfill_tasks: Vec<(String, String)> = Vec::new();
      for rs in restored {
        let msg_count = rs.rows.len();

        if msg_count == 0 && rs.provider == "claude" {
          if let Some(ref transcript_path) = rs.transcript_path {
            backfill_tasks.push((rs.id.clone(), transcript_path.clone()));
          }
        }

        // Provider session IDs (claude_sdk_session_id, codex_thread_id) are already in DB.
        // No registration needed on restore — DB is source of truth.

        state.add_session(restored_session_to_persisted_handle(rs));
      }

      if !backfill_tasks.is_empty() {
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
                // Normalize sequences before persisting (matching
                // what replace_rows() does internally) to keep
                // DB and in-memory state consistent.
                for (i, entry) in rows.iter_mut().enumerate() {
                  entry.sequence = i as u64;
                }
                for entry in &rows {
                  let _ = backfill_persist_tx
                    .send(
                      crate::infrastructure::persistence::PersistCommand::RowAppend {
                        session_id: session_id.clone(),
                        entry: entry.clone(),
                        viewer_present: false,
                        assigned_sequence: Some(entry.sequence),
                        sequence_tx: None,
                      },
                    )
                    .await;
                }

                if let Some(actor) = backfill_state.get_session(&session_id) {
                  actor
                    .send(crate::runtime::session_commands::SessionCommand::ReplaceRows { rows })
                    .await;
                }
              }
              Ok(_) | Err(_) => {}
            }
          }
        });
      }
    }
    Ok(_) | Err(_) => {}
  }

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
            );
          }
        }
      }
    }
  }

  let expiry_state = state.clone();
  tokio::spawn(async move {
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(30));
    loop {
      interval.tick().await;
      expiry_state.expire_pending_hook_sessions(std::time::Duration::from_secs(60));
    }
  });

  let git_state = state.clone();
  tokio::spawn(crate::runtime::background::git_refresh::start_git_refresh_loop(git_state));

  // Delayed update check — runs ~30s after startup, then activity-based
  crate::runtime::background::update_checker::spawn_startup_check(state.clone());

  let shutdown_state = state.clone();
  let shutdown_persist = persist_tx.clone();
  let mut app = Router::new()
    .route("/ws", get(ws_handler))
    .merge(crate::transport::http::build_router())
    .route("/health", get(health_handler))
    .route(
      "/metrics",
      get(crate::infrastructure::metrics::metrics_handler),
    )
    // Must come after all routes: axum layers only wrap routes that
    // already exist in the router at the time `.layer()` is called.
    .layer(DefaultBodyLimit::max(MAX_HTTP_BODY_BYTES));

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

  let app = if options.serve_web && crate::transport::web_assets::has_web_assets() {
    app.fallback(crate::transport::web_assets::web_asset_handler)
  } else {
    app
  };

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
    let _pid_guard = PidFileGuard;

    let handle = axum_server::Handle::new();
    let shutdown_handle = handle.clone();
    let shutdown_sync = sync_shutdown_tx.clone();
    let shutdown_sync_handle = sync_writer_handle;
    tokio::spawn(async move {
      shutdown_signal(
        shutdown_state,
        shutdown_persist,
        shutdown_sync,
        shutdown_sync_handle,
      )
      .await;
      shutdown_handle.graceful_shutdown(Some(std::time::Duration::from_secs(5)));
    });

    axum_server::bind_rustls(options.bind_addr, tls_config)
      .handle(handle)
      .serve(app.into_make_service())
      .await
      .map_err(|error| describe_bind_failure(error, options.bind_addr))?;
  } else {
    let listener = tokio::net::TcpListener::bind(options.bind_addr)
      .await
      .map_err(|error| describe_bind_failure(error, options.bind_addr))?;

    info!(
        component = "server",
        event = "server.listening",
        bind_address = %options.bind_addr,
        tls = false,
        "Listening for connections"
    );

    write_pid_file();
    let _pid_guard = PidFileGuard;

    axum::serve(listener, app)
      .with_graceful_shutdown(shutdown_signal(
        shutdown_state,
        shutdown_persist,
        sync_shutdown_tx,
        sync_writer_handle,
      ))
      .await?;
  }

  Ok(())
}

async fn shutdown_signal(
  _state: Arc<SessionRegistry>,
  _persist_tx: mpsc::Sender<PersistCommand>,
  sync_shutdown_tx: Option<watch::Sender<bool>>,
  sync_writer_handle: Option<tokio::task::JoinHandle<()>>,
) {
  #[cfg(unix)]
  {
    use tokio::signal::unix::{signal, SignalKind};
    let mut sigterm = signal(SignalKind::terminate()).expect("failed to register SIGTERM handler");
    tokio::select! {
      _ = tokio::signal::ctrl_c() => {},
      _ = sigterm.recv() => {},
    }
  }
  #[cfg(not(unix))]
  {
    let _ = tokio::signal::ctrl_c().await;
  }

  if let Some(shutdown_tx) = sync_shutdown_tx {
    let _ = shutdown_tx.send(true);
  }

  if let Some(handle) = sync_writer_handle {
    let _ = tokio::time::timeout(std::time::Duration::from_secs(35), handle).await;
  }

  remove_pid_file();
}

#[cfg(test)]
#[path = "app_tests.rs"]
mod tests;
