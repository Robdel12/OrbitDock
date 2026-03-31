use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Instant, UNIX_EPOCH};

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
  ClaudeIntegrationMode, CodexApprovalPolicy, CodexIntegrationMode, Provider, SessionControlMode,
  SessionLifecycleState, SessionStatus, TokenUsage, TurnDiff, WorkStatus, WorkspaceProviderKind,
};
use tokio::sync::{mpsc, watch};
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;
use tracing::{info, warn};

use crate::domain::sessions::session::{
  SessionConfig, SessionDisplay, SessionEnvironment, SessionIdentity, SessionTimestamps,
};
use crate::infrastructure::logging::{init_logging, ServerLoggingOptions};
use crate::infrastructure::persistence::{
  cleanup_dangling_in_progress_messages, cleanup_stale_permission_state,
  create_persistence_channel, create_sync_shutdown_channel, load_sessions_for_startup,
  PersistCommand, PersistenceWriter, SyncWriter, SyncWriterConfig,
};
use crate::runtime::restored_sessions::{
  load_prepared_resume_session, prepare_restored_session_for_direct_resume,
};
use crate::runtime::session_registry::SessionRegistry;
use crate::runtime::session_resume::launch_resumed_session;
use crate::runtime::session_runtime_helpers::direct_resume_failure_changes;
use crate::transport::websocket::ws_handler;
use crate::VERSION;

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
  let persisted_workspace_provider_value =
    crate::infrastructure::persistence::load_config_value("workspace_provider");
  let workspace_provider_kind = resolve_workspace_provider_kind(
    options.workspace_provider_override,
    persisted_workspace_provider_value.clone(),
  )?;
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
  info!(
    component = "server",
    event = "server.workspace_provider.resolved",
    provider = workspace_provider_kind.as_str(),
    source = if options.workspace_provider_override.is_some() {
      "startup_override"
    } else if persisted_workspace_provider_value.is_some() {
      "config"
    } else {
      "default"
    },
    "Resolved workspace provider"
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

  let state = Arc::new(SessionRegistry::new_with_primary_and_db_path(
    persist_tx.clone(),
    db_path.clone(),
    is_primary,
    workspace_provider_kind,
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
      let mut startup_resume_ready: Vec<tokio::sync::oneshot::Receiver<()>> = Vec::new();

      for rs in restored {
        let should_restore_live_direct = rs.status.eq_ignore_ascii_case("active")
          && rs.lifecycle_state == SessionLifecycleState::Open
          && rs.control_mode == SessionControlMode::Direct;

        if should_restore_live_direct {
          let session_id = rs.id.clone();
          let provider = rs.provider.clone();
          let message_count = rs.rows.len();
          let prepared = prepare_restored_session_for_direct_resume(rs, false);

          match launch_resumed_session(&state, &session_id, prepared).await {
            Ok(launch) => {
              if let Some(startup_ready) = launch.startup_ready {
                startup_resume_ready.push(startup_ready);
              }
              info!(
                  component = "restore",
                  event = "restore.session.resumed",
                  session_id = %session_id,
                  provider = %provider,
                  messages = message_count,
                  "Restored direct open session and reattached connector"
              );
            }
            Err(error) => {
              warn!(
                  component = "restore",
                  event = "restore.session.resume_failed",
                  session_id = %session_id,
                  provider = %provider,
                  error_code = error.code(),
                  error = %error.message(),
                  "Failed to restore direct open session connector"
              );

              if state.get_session(&session_id).is_none() {
                match load_prepared_resume_session(&session_id).await {
                  Ok(Some(mut prepared)) => {
                    prepared
                      .handle
                      .apply_changes(&direct_resume_failure_changes(prepared.provider));
                    state.add_session(prepared.handle);
                    state.publish_dashboard_snapshot();
                    warn!(
                        component = "restore",
                        event = "restore.session.downgraded_to_resumable",
                        session_id = %session_id,
                        provider = %provider,
                        "Registered direct session as resumable after restore failure"
                    );
                  }
                  Ok(None) => {
                    warn!(
                        component = "restore",
                        event = "restore.session.missing_after_resume_failure",
                        session_id = %session_id,
                        provider = %provider,
                        "Session disappeared while applying resumable restore fallback"
                    );
                  }
                  Err(load_error) => {
                    warn!(
                        component = "restore",
                        event = "restore.session.fallback_load_failed",
                        session_id = %session_id,
                        provider = %provider,
                        error = %load_error,
                        "Failed to reload session for resumable restore fallback"
                    );
                  }
                }
              }
            }
          }
          continue;
        }

        let crate::infrastructure::persistence::RestoredSession {
          id,
          provider,
          status,
          work_status,
          control_mode,
          lifecycle_state,
          project_path,
          transcript_path,
          project_name,
          model,
          custom_name,
          summary,
          codex_integration_mode: _,
          claude_integration_mode: _,
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
          codex_config_mode,
          codex_config_profile,
          codex_model_provider,
          codex_config_source,
          codex_config_overrides,
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
          last_progress_at,
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
        let approval_policy_details = codex_config_overrides
          .as_ref()
          .and_then(|overrides| overrides.approval_policy_details.clone())
          .or_else(|| {
            approval_policy
              .as_deref()
              .and_then(CodexApprovalPolicy::from_storage_text)
          });

        let mut handle = crate::domain::sessions::session::SessionHandle::restore(
          crate::domain::sessions::session::SessionRestoreData {
            identity: SessionIdentity {
              id: id.clone(),
              provider,
              project_path: project_path.clone(),
              transcript_path,
              project_name,
            },
            config: SessionConfig {
              model: model.clone(),
              approval_policy: approval_policy.clone(),
              approval_policy_details,
              sandbox_mode: sandbox_mode.clone(),
              collaboration_mode,
              multi_agent,
              personality,
              service_tier,
              developer_instructions,
              codex_config_mode,
              codex_config_profile,
              codex_model_provider,
              codex_config_source,
              codex_config_overrides,
              effort,
            },
            display: SessionDisplay {
              custom_name,
              summary,
              first_prompt,
              last_message,
            },
            environment: SessionEnvironment {
              git_branch,
              git_sha,
              current_cwd,
              ..Default::default()
            },
            timestamps: SessionTimestamps {
              started_at,
              last_activity_at,
              last_progress_at,
            },
            status: match status.as_str() {
              "ended" => SessionStatus::Ended,
              _ => SessionStatus::Active,
            },
            work_status: match work_status.as_str() {
              "working" => WorkStatus::Working,
              "permission" => WorkStatus::Permission,
              "question" => WorkStatus::Question,
              "reply" => WorkStatus::Reply,
              "ended" => WorkStatus::Ended,
              _ => WorkStatus::Waiting,
            },
            control_mode,
            lifecycle_state,
            permission_mode,
            token_usage: TokenUsage {
              input_tokens: input_tokens.max(0) as u64,
              output_tokens: output_tokens.max(0) as u64,
              cached_tokens: cached_tokens.max(0) as u64,
              context_window: context_window.max(0) as u64,
            },
            token_usage_snapshot_kind,
            rows,
            current_diff,
            current_plan,
            turn_diffs: restored_turn_diffs
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
                  let has_tokens = input_tokens > 0 || output_tokens > 0 || context_window > 0;
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
            pending_tool_name,
            pending_tool_input,
            pending_question,
            pending_approval_id,
            terminal_session_id,
            terminal_app,
            approval_version,
            unread_count,
          },
        );
        let is_codex = matches!(provider, Provider::Codex);
        let is_claude = matches!(provider, Provider::Claude);
        let is_direct = control_mode == SessionControlMode::Direct;
        handle.set_codex_integration_mode(if is_codex {
          Some(if is_direct {
            CodexIntegrationMode::Direct
          } else {
            CodexIntegrationMode::Passive
          })
        } else {
          None
        });
        if is_claude {
          handle.set_claude_integration_mode(Some(if is_direct {
            ClaudeIntegrationMode::Direct
          } else {
            ClaudeIntegrationMode::Passive
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
        if is_claude && is_direct {
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

      for startup_ready in startup_resume_ready {
        let _ = startup_ready.await;
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

  spawn_spool_replay(state.clone());

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
  app = app.layer(axum::middleware::from_fn(
    crate::infrastructure::protocol_compat::version_middleware,
  ));

  let mut app = app.layer(TraceLayer::new_for_http());
  if let Some(cors_layer) = configured_cors_layer()? {
    app = app.layer(cors_layer);
  }
  let app = app.with_state(state);

  let app = if options.serve_web && crate::transport::web_assets::has_web_assets() {
    info!(
      component = "server",
      event = "server.web_ui.enabled",
      "Serving embedded web UI"
    );
    app.fallback(crate::transport::web_assets::web_asset_handler)
  } else {
    if options.serve_web {
      warn!(
        component = "server",
        event = "server.web_ui.no_assets",
        "Web UI requested but no assets bundled in this build"
      );
    }
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

fn resolve_workspace_provider_kind(
  override_kind: Option<WorkspaceProviderKind>,
  persisted_value: Option<String>,
) -> anyhow::Result<WorkspaceProviderKind> {
  if let Some(override_kind) = override_kind {
    return Ok(override_kind);
  }

  match persisted_value {
    Some(value) => value
      .parse::<WorkspaceProviderKind>()
      .map_err(|error| anyhow::anyhow!(error)),
    None => Ok(WorkspaceProviderKind::default()),
  }
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

fn cleanup_stale_pid_file() {
  let pid_path = crate::infrastructure::paths::pid_file_path();
  let Ok(pid_str) = std::fs::read_to_string(&pid_path) else {
    return;
  };

  let Ok(pid) = pid_str.trim().parse::<u32>() else {
    remove_pid_file();
    return;
  };

  if pid == 0 || !process_alive(pid) {
    warn!(
        component = "server",
        event = "server.pid_file.stale_removed",
        path = %pid_path.display(),
        stale_pid = pid,
        "Removed stale PID file before startup"
    );
    remove_pid_file();
  }
}

fn remove_pid_file() {
  let pid_path = crate::infrastructure::paths::pid_file_path();
  let _ = std::fs::remove_file(&pid_path);
}

struct PidFileGuard;

impl Drop for PidFileGuard {
  fn drop(&mut self) {
    remove_pid_file();
  }
}

fn process_alive(pid: u32) -> bool {
  unsafe { libc::kill(pid as i32, 0) == 0 }
}

async fn shutdown_signal(
  _state: Arc<SessionRegistry>,
  _persist_tx: mpsc::Sender<PersistCommand>,
  sync_shutdown_tx: Option<watch::Sender<bool>>,
  sync_writer_handle: Option<tokio::task::JoinHandle<()>>,
) {
  let _ = tokio::signal::ctrl_c().await;
  info!(
    component = "server",
    event = "server.shutdown",
    "Shutdown signal received — active direct sessions preserved for lazy resume"
  );

  if let Some(shutdown_tx) = sync_shutdown_tx {
    let _ = shutdown_tx.send(true);
  }

  if let Some(handle) = sync_writer_handle {
    match tokio::time::timeout(std::time::Duration::from_secs(35), handle).await {
      Ok(Ok(())) => {
        info!(
          component = "sync",
          event = "sync.writer.shutdown_joined",
          "Sync writer finished draining before shutdown"
        );
      }
      Ok(Err(join_error)) => {
        warn!(
            component = "sync",
            event = "sync.writer.shutdown_join_failed",
            error = %join_error,
            "Sync writer task failed while shutting down"
        );
      }
      Err(_) => {
        warn!(
          component = "sync",
          event = "sync.writer.shutdown_join_timeout",
          timeout_secs = 35_u64,
          "Timed out waiting for sync writer to finish draining"
        );
      }
    }
  }

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
  let claude_replay_options =
    crate::connectors::claude_hooks::ClaudeHookHandlingOptions::for_spool_replay();
  let codex_replay_options =
    crate::connectors::codex_hooks::CodexHookHandlingOptions::for_spool_replay();

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

    match crate::connectors::hook_handler::classify_hook_provider(&message) {
      Some(orbitdock_protocol::Provider::Claude) => {
        crate::connectors::claude_hooks::handle_hook_message_with_options(
          message,
          state,
          claude_replay_options.clone(),
        )
        .await;
      }
      Some(orbitdock_protocol::Provider::Codex) => {
        crate::connectors::codex_hooks::handle_hook_message_with_options(
          message,
          state,
          codex_replay_options.clone(),
        )
        .await;
      }
      None => {
        warn!(
          component = "spool",
          event = "spool.unsupported_message",
          path = %path.display(),
          "Skipping spooled message that is not a supported hook payload"
        );
        failed += 1;
        continue;
      }
    }
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

fn spawn_spool_replay(state: Arc<SessionRegistry>) {
  tokio::spawn(async move {
    let started_at = Instant::now();
    info!(
      component = "spool",
      event = "spool.replay.started",
      "Replaying spooled hooks in background"
    );
    drain_spool(&state).await;
    info!(
      component = "spool",
      event = "spool.replay.completed",
      elapsed_ms = started_at.elapsed().as_millis() as u64,
      "Background spool replay completed"
    );
  });
}

#[cfg(test)]
async fn wait_for_startup_resume_ready(
  startup_resume_ready: Vec<tokio::sync::oneshot::Receiver<()>>,
) {
  for startup_ready in startup_resume_ready {
    let _ = startup_ready.await;
  }
}

#[cfg(test)]
mod tests {
  use super::{drain_spool, resolve_workspace_provider_kind, wait_for_startup_resume_ready};
  use crate::support::test_support::{ensure_server_test_data_dir, new_test_session_registry};
  use orbitdock_protocol::{ClientMessage, Provider, WorkspaceProviderKind};
  use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
  };
  use tokio::sync::oneshot;

  #[test]
  fn workspace_provider_override_wins_over_persisted_value() {
    let resolved = resolve_workspace_provider_kind(
      Some(WorkspaceProviderKind::Local),
      Some("local".to_string()),
    )
    .expect("workspace provider should resolve");

    assert_eq!(resolved, WorkspaceProviderKind::Local);
  }

  #[test]
  fn workspace_provider_defaults_to_local_when_missing() {
    let resolved =
      resolve_workspace_provider_kind(None, None).expect("workspace provider should default");

    assert_eq!(resolved, WorkspaceProviderKind::Local);
  }

  #[tokio::test]
  async fn drain_spool_dispatches_mixed_provider_hook_messages() {
    ensure_server_test_data_dir();
    crate::infrastructure::paths::ensure_dirs().expect("create spool dirs");
    let spool_dir = crate::infrastructure::paths::spool_dir();
    let _ = std::fs::remove_dir_all(&spool_dir);
    std::fs::create_dir_all(&spool_dir).expect("recreate spool dir");

    let claude_payload = serde_json::to_string(&ClientMessage::ClaudeSessionStart {
      session_id: "claude-sdk-1".to_string(),
      cwd: "/tmp/claude-repo".to_string(),
      model: Some("claude-opus-4-6".to_string()),
      source: Some("startup".to_string()),
      context_label: None,
      transcript_path: Some("/tmp/claude-repo/transcript.jsonl".to_string()),
      permission_mode: None,
      agent_type: None,
      terminal_session_id: None,
      terminal_app: None,
    })
    .expect("serialize claude spool payload");
    let codex_payload = serde_json::to_string(&ClientMessage::CodexUserPromptSubmit {
      session_id: "codex-thread-1".to_string(),
      cwd: "/tmp/codex-repo".to_string(),
      transcript_path: Some("/tmp/codex-repo/transcript.jsonl".to_string()),
      model: Some("gpt-5-codex".to_string()),
      turn_id: Some("turn-1".to_string()),
      prompt: "Ship it".to_string(),
    })
    .expect("serialize codex spool payload");

    std::fs::write(spool_dir.join("001-claude.json"), claude_payload)
      .expect("write claude spool file");
    std::fs::write(spool_dir.join("002-codex.json"), codex_payload)
      .expect("write codex spool file");

    let state = new_test_session_registry(true);
    drain_spool(&state).await;
    tokio::task::yield_now().await;
    tokio::task::yield_now().await;

    assert_eq!(
      state.peek_pending_hook_cwd(Provider::Claude, "claude-sdk-1"),
      Some("/tmp/claude-repo".to_string())
    );

    let codex_session = state
      .get_session("codex-thread-1")
      .expect("codex spool replay should materialize passive session");
    let snapshot = codex_session.snapshot();
    assert_eq!(snapshot.provider, Provider::Codex);
    assert_eq!(
      snapshot.transcript_path.as_deref(),
      Some("/tmp/codex-repo/transcript.jsonl")
    );
  }

  #[tokio::test]
  async fn startup_resume_ready_waits_for_every_receiver() {
    let (ready_tx, ready_rx) = oneshot::channel();
    let (delayed_tx, delayed_rx) = oneshot::channel();
    let delayed_fired = Arc::new(AtomicBool::new(false));
    let delayed_fired_for_task = delayed_fired.clone();

    tokio::spawn(async move {
      tokio::task::yield_now().await;
      delayed_fired_for_task.store(true, Ordering::SeqCst);
      let _ = delayed_tx.send(());
    });

    let _ = ready_tx.send(());
    wait_for_startup_resume_ready(vec![ready_rx, delayed_rx]).await;

    assert!(delayed_fired.load(Ordering::SeqCst));
  }
}
