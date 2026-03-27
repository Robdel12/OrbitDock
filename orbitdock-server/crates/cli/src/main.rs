use clap::Parser;
use orbitdock_cli::cli::{BinaryCli as Cli, BinaryCommand as Command};
use std::io::IsTerminal;

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
    Some(Command::Pair { tunnel_url, no_qr }) => {
      return orbitdock_server::admin::print_pairing_details(tunnel_url.as_deref(), !*no_qr);
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
    Some(Command::RemoteSetup) => {
      return orbitdock_server::admin::guide_remote_setup(&data_dir);
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
    let runtime = tokio::runtime::Runtime::new()?;
    if let Some(exit_code) = runtime.block_on(orbitdock_cli::dispatch_binary(command, &cli_config))
    {
      std::process::exit(exit_code);
    }
  }

  if let Some(Command::Completions { shell }) = &cli.command {
    orbitdock_cli::cli::generate_binary_completions(*shell);
    return Ok(());
  }

  let (
    bind_addr,
    auth_token,
    allow_insecure_no_auth,
    startup_is_primary,
    tls_cert,
    tls_key,
    dev_console,
    no_web,
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
      no_web,
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
      no_web,
      managed,
      workspace_id,
      sync_url,
      sync_token,
      workspace_provider,
    ),
    _ => (
      cli.bind.unwrap_or_else(|| "0.0.0.0:4000".parse().unwrap()),
      None,
      false,
      true,
      None,
      None,
      false,
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

  let runtime = tokio::runtime::Runtime::new()?;
  let run_options = orbitdock_server::ServerRunOptions {
    bind_addr,
    auth_token,
    allow_insecure_no_auth,
    startup_is_primary,
    data_dir,
    tls_cert,
    tls_key,
    logging: orbitdock_server::ServerLoggingOptions::default(),
    serve_web: !no_web,
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
