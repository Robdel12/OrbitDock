use clap::Parser;
use orbitdock_cli::cli::{BinaryCli as Cli, BinaryCommand as Command};
use std::io::IsTerminal;

// Keep enough stack for embedded Codex app-server resume/start futures without
// making every runtime worker reserve the larger 16 MiB debug-era footprint.
const DEFAULT_TOKIO_WORKER_STACK_SIZE: usize = 8 * 1024 * 1024;
const DEFAULT_TOKIO_WORKER_THREAD_CAP: usize = 4;
const STACK_BYTES_PER_MIB: usize = 1024 * 1024;

fn build_runtime() -> anyhow::Result<tokio::runtime::Runtime> {
  let worker_stack_size = tokio_worker_stack_size()?;
  let worker_threads = tokio_worker_threads()?;

  Ok(
    tokio::runtime::Builder::new_multi_thread()
      .enable_all()
      .worker_threads(worker_threads)
      .thread_stack_size(worker_stack_size)
      .build()?,
  )
}

fn tokio_worker_stack_size() -> anyhow::Result<usize> {
  match parse_positive_usize_env("ORBITDOCK_TOKIO_WORKER_STACK_MB")? {
    Some(mib) => Ok(mib * STACK_BYTES_PER_MIB),
    None => Ok(DEFAULT_TOKIO_WORKER_STACK_SIZE),
  }
}

fn tokio_worker_threads() -> anyhow::Result<usize> {
  if let Some(configured) = parse_positive_usize_env("ORBITDOCK_TOKIO_WORKER_THREADS")? {
    return Ok(configured);
  }

  Ok(
    std::thread::available_parallelism()
      .map(|parallelism| parallelism.get().min(DEFAULT_TOKIO_WORKER_THREAD_CAP))
      .unwrap_or(DEFAULT_TOKIO_WORKER_THREAD_CAP),
  )
}

fn parse_positive_usize_env(name: &str) -> anyhow::Result<Option<usize>> {
  let Some(raw_value) = std::env::var_os(name) else {
    return Ok(None);
  };
  let value = raw_value.to_string_lossy();
  let parsed = value
    .parse::<usize>()
    .map_err(|_| anyhow::anyhow!("{name} must be a positive integer, got {value:?}"))?;
  if parsed == 0 {
    anyhow::bail!("{name} must be greater than zero");
  }
  Ok(Some(parsed))
}

fn main() -> anyhow::Result<()> {
  let _arg0_guard = orbitdock_connector_codex::arg0_dispatch();

  let cli = Cli::parse();
  let data_dir = orbitdock_server::init_data_dir(cli.data_dir.as_deref());

  match &cli.command {
    Some(Command::Init {
      server_url,
      workspace_provider,
    }) => {
      return orbitdock_server::admin::initialize_data_dir(
        &data_dir,
        server_url,
        *workspace_provider,
      )
    }
    Some(Command::InstallHooks {
      settings_path,
      server_url,
      auth_token,
    }) => {
      return orbitdock_server::admin::install_claude_hooks(
        settings_path.as_deref(),
        server_url.as_deref(),
        auth_token.as_deref(),
      );
    }
    Some(Command::HookForward {
      hook_type,
      server_url,
      auth_token,
    }) => {
      let hook_type = match hook_type {
        orbitdock_cli::cli::HookForwardType::ClaudeSessionStart => {
          orbitdock_server::admin::HookForwardType::SessionStart
        }
        orbitdock_cli::cli::HookForwardType::ClaudeSessionEnd => {
          orbitdock_server::admin::HookForwardType::SessionEnd
        }
        orbitdock_cli::cli::HookForwardType::ClaudeStatusEvent => {
          orbitdock_server::admin::HookForwardType::StatusEvent
        }
        orbitdock_cli::cli::HookForwardType::ClaudeToolEvent => {
          orbitdock_server::admin::HookForwardType::ToolEvent
        }
        orbitdock_cli::cli::HookForwardType::ClaudeSubagentEvent => {
          orbitdock_server::admin::HookForwardType::SubagentEvent
        }
      };
      return orbitdock_server::admin::forward_hook_event(
        hook_type,
        server_url.as_deref(),
        auth_token.as_deref(),
      );
    }
    Some(Command::ManagedSessionStart {
      server_url,
      request_base64,
    }) => {
      return orbitdock_cli::commands::run_managed_session_start(
        server_url.as_deref(),
        request_base64,
      );
    }
    Some(Command::McpMissionTools) => {
      return orbitdock_cli::commands::mcp_mission_tools::run();
    }
    Some(Command::InstallService {
      bind,
      enable,
      auth_token,
    }) => {
      return orbitdock_server::admin::install_background_service(
        &data_dir,
        *bind,
        *enable,
        auth_token.clone(),
      );
    }
    Some(Command::EnsurePath) => return orbitdock_server::admin::ensure_shell_path(),
    Some(Command::Status) => return orbitdock_server::admin::print_server_status(&data_dir),
    Some(Command::GenerateToken) => {
      return orbitdock_server::admin::print_generated_auth_token(&data_dir);
    }
    Some(Command::ListTokens) => return orbitdock_server::admin::print_auth_tokens(),
    Some(Command::RevokeToken { token_id }) => {
      return orbitdock_server::admin::revoke_auth_token(token_id);
    }
    Some(Command::Doctor) => return orbitdock_server::admin::print_diagnostics(&data_dir),
    Some(Command::Auth { action }) => {
      use orbitdock_cli::cli::AuthAction;
      match action {
        AuthAction::LocalToken => return orbitdock_server::admin::print_local_token(),
      }
    }
    Some(Command::Tunnel { port, name }) => {
      return orbitdock_server::admin::start_cloudflare_tunnel(*port, name.as_deref());
    }
    Some(Command::Pair { tunnel_url, .. }) => {
      return orbitdock_server::admin::print_pairing_details(tunnel_url.as_deref());
    }
    Some(Command::Setup { path }) => {
      let setup_path = path.map(|p| match p {
        orbitdock_cli::cli::SetupPath::Local => orbitdock_server::admin::SetupPath::Local,
        orbitdock_cli::cli::SetupPath::Server => orbitdock_server::admin::SetupPath::Server,
        orbitdock_cli::cli::SetupPath::Client => orbitdock_server::admin::SetupPath::Client,
      });
      return orbitdock_server::admin::run_setup_wizard(
        &data_dir,
        orbitdock_server::admin::SetupOptions { path: setup_path },
      );
    }
    Some(Command::Upgrade {
      check,
      channel,
      version,
      force,
      yes,
      restart,
    }) => {
      let json_output = cli.json || !std::io::stdout().is_terminal();
      if *check {
        return orbitdock_server::admin::check_for_update(json_output, channel.clone());
      }
      return orbitdock_server::admin::execute_upgrade(orbitdock_server::admin::UpgradeOptions {
        channel_override: channel.clone(),
        target_version: version.clone(),
        force: *force,
        yes: *yes,
        restart: *restart,
      });
    }
    None => {
      use clap::CommandFactory;
      Cli::command().print_help()?;
      return Ok(());
    }
    _ => {}
  }

  let cli_config = orbitdock_cli::client::config::ClientConfig::resolve_binary(&cli)?;

  if let Some(command) = cli.command.as_ref() {
    let runtime = build_runtime()?;
    if let Some(exit_code) = runtime.block_on(orbitdock_cli::dispatch_binary(command, &cli_config))
    {
      std::process::exit(exit_code);
    }
  }

  let (
    bind_addr,
    auth_token,
    allow_insecure_no_auth,
    startup_is_primary,
    tls_cert,
    tls_key,
    dev_console,
    managed,
    workspace_id,
    sync_url,
    sync_token,
    workspace_provider,
  ) = match cli.command {
    Some(Command::Start {
      bind,
      auth_token,
      allow_insecure_no_auth,
      secondary,
      tls_cert,
      tls_key,
      dev_console,
      managed,
      workspace_id,
      sync_url,
      sync_token,
      workspace_provider,
    }) => (
      bind,
      auth_token,
      allow_insecure_no_auth,
      !secondary,
      tls_cert,
      tls_key,
      dev_console,
      managed,
      workspace_id,
      sync_url,
      sync_token,
      workspace_provider,
    ),
    _ => (
      "0.0.0.0:4000".parse().unwrap(),
      None,
      false,
      true,
      None,
      None,
      false,
      false,
      None,
      None,
      None,
      None,
    ),
  };

  let managed_sync = if managed {
    let workspace_id = workspace_id
      .filter(|value| !value.trim().is_empty())
      .ok_or_else(|| anyhow::anyhow!("--managed requires --workspace-id"))?;
    let server_url = sync_url
      .filter(|value| !value.trim().is_empty())
      .ok_or_else(|| anyhow::anyhow!("--managed requires --sync-url"))?;
    let auth_token = sync_token
      .filter(|value| !value.trim().is_empty())
      .ok_or_else(|| anyhow::anyhow!("--managed requires --sync-token"))?;

    Some(orbitdock_server::ManagedSyncRunOptions {
      workspace_id,
      server_url,
      auth_token,
    })
  } else {
    None
  };

  let runtime = build_runtime()?;
  let run_options = orbitdock_server::ServerRunOptions {
    bind_addr,
    auth_token,
    allow_insecure_no_auth,
    startup_is_primary,
    data_dir,
    tls_cert,
    tls_key,
    logging: orbitdock_server::ServerLoggingOptions::default(),
    managed_sync,
    workspace_provider_override: workspace_provider,
  };

  let should_use_dev_console =
    dev_console && std::io::stdout().is_terminal() && std::io::stderr().is_terminal();
  if should_use_dev_console {
    match orbitdock_cli::dev_console::try_enter_terminal() {
      Ok(terminal) => {
        return runtime.block_on(orbitdock_cli::dev_console::run_server_with_dev_console(
          run_options,
          terminal,
        ));
      }
      Err(error) => {
        eprintln!("dev console unavailable, falling back to plain logs: {error:#}");
      }
    }
  }

  runtime.block_on(orbitdock_server::run_server(run_options))
}

#[cfg(test)]
mod tests {
  use super::*;
  use std::sync::Mutex;

  static ENV_LOCK: Mutex<()> = Mutex::new(());

  fn with_env_var<T>(name: &str, value: Option<&str>, test: impl FnOnce() -> T) -> T {
    let _guard = ENV_LOCK.lock().expect("env lock should not be poisoned");
    let previous = std::env::var_os(name);

    match value {
      Some(value) => std::env::set_var(name, value),
      None => std::env::remove_var(name),
    }

    let result = test();

    match previous {
      Some(previous) => std::env::set_var(name, previous),
      None => std::env::remove_var(name),
    }

    result
  }

  #[test]
  fn worker_stack_defaults_to_eight_mib() {
    with_env_var("ORBITDOCK_TOKIO_WORKER_STACK_MB", None, || {
      assert_eq!(tokio_worker_stack_size().unwrap(), 8 * STACK_BYTES_PER_MIB);
    });
  }

  #[test]
  fn worker_stack_can_be_overridden_by_env() {
    with_env_var("ORBITDOCK_TOKIO_WORKER_STACK_MB", Some("16"), || {
      assert_eq!(tokio_worker_stack_size().unwrap(), 16 * STACK_BYTES_PER_MIB);
    });
  }

  #[test]
  fn worker_threads_can_be_overridden_by_env() {
    with_env_var("ORBITDOCK_TOKIO_WORKER_THREADS", Some("2"), || {
      assert_eq!(tokio_worker_threads().unwrap(), 2);
    });
  }

  #[test]
  fn worker_threads_reject_zero() {
    with_env_var("ORBITDOCK_TOKIO_WORKER_THREADS", Some("0"), || {
      assert!(tokio_worker_threads().is_err());
    });
  }
}
