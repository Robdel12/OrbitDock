use clap::Parser;
use orbitdock_cli::cli::{BinaryCli as Cli, BinaryCommand as Command};

fn main() -> anyhow::Result<()> {
    let _arg0_guard = orbitdock_connector_codex::arg0_dispatch();

    let cli = Cli::parse();
    let data_dir = orbitdock_server::init_data_dir(cli.data_dir.as_deref());

    match &cli.command {
        Some(Command::Init { server_url }) => {
            return orbitdock_server::admin::initialize_data_dir(&data_dir, server_url)
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
        Some(Command::Tunnel { port, name }) => {
            return orbitdock_server::admin::start_cloudflare_tunnel(*port, name.as_deref());
        }
        Some(Command::Pair { tunnel_url, no_qr }) => {
            return orbitdock_server::admin::print_pairing_details(tunnel_url.as_deref(), !*no_qr);
        }
        Some(Command::Setup {
            local,
            remote,
            bind,
            server_url,
            skip_service,
            skip_hooks,
        }) => {
            let mode = if *remote {
                Some(orbitdock_server::admin::SetupMode::Remote)
            } else if *local {
                Some(orbitdock_server::admin::SetupMode::Local)
            } else {
                None
            };
            return orbitdock_server::admin::run_setup_wizard(
                &data_dir,
                orbitdock_server::admin::SetupOptions {
                    mode,
                    bind: *bind,
                    server_url: server_url.clone(),
                    skip_service: *skip_service,
                    skip_hooks: *skip_hooks,
                },
            );
        }
        Some(Command::RemoteSetup) => {
            return orbitdock_server::admin::guide_remote_setup(&data_dir);
        }
        _ => {}
    }

    let cli_config = orbitdock_cli::client::config::ClientConfig::resolve_binary(&cli)?;

    if let Some(command) = cli.command.as_ref() {
        let runtime = tokio::runtime::Runtime::new()?;
        if let Some(exit_code) =
            runtime.block_on(orbitdock_cli::dispatch_binary(command, &cli_config))
        {
            std::process::exit(exit_code);
        }
    }

    if let Some(Command::Completions { shell }) = &cli.command {
        orbitdock_cli::cli::generate_binary_completions(*shell);
        return Ok(());
    }

    let (bind_addr, auth_token, allow_insecure_no_auth, startup_is_primary, tls_cert, tls_key) =
        match cli.command {
            Some(Command::Start {
                bind,
                auth_token,
                allow_insecure_no_auth,
                secondary,
                tls_cert,
                tls_key,
            }) => (
                bind,
                auth_token,
                allow_insecure_no_auth,
                !secondary,
                tls_cert,
                tls_key,
            ),
            _ => (
                cli.bind
                    .unwrap_or_else(|| "127.0.0.1:4000".parse().unwrap()),
                None,
                false,
                true,
                None,
                None,
            ),
        };

    let runtime = tokio::runtime::Runtime::new()?;
    runtime.block_on(orbitdock_server::run_server(
        orbitdock_server::ServerRunOptions {
            bind_addr,
            auth_token,
            allow_insecure_no_auth,
            startup_is_primary,
            data_dir,
            tls_cert,
            tls_key,
        },
    ))
}
