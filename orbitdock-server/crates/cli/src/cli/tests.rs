use clap::{CommandFactory, Parser};
use orbitdock_protocol::WorkspaceProviderKind;

use super::*;
use crate::client::config::ClientConfig;
use crate::commands::dispatch_binary;

#[test]
fn binary_cli_parses_start_command() {
  let cli = BinaryCli::try_parse_from(["orbitdock", "start", "--bind", "0.0.0.0:4000"])
    .expect("binary cli should parse start");

  match cli.command {
    Some(BinaryCommand::Start { bind, .. }) => {
      assert_eq!(
        bind,
        "0.0.0.0:4000".parse::<std::net::SocketAddr>().unwrap()
      );
    }
    other => panic!("expected start command, got {other:?}"),
  }
}

#[test]
fn binary_cli_start_defaults_to_lan_bind() {
  let cli = BinaryCli::try_parse_from(["orbitdock", "start"])
    .expect("binary cli should parse default start");

  match cli.command {
    Some(BinaryCommand::Start { bind, .. }) => {
      assert_eq!(
        bind,
        "0.0.0.0:4000".parse::<std::net::SocketAddr>().unwrap()
      );
    }
    other => panic!("expected start command, got {other:?}"),
  }
}

#[test]
fn binary_cli_maps_session_command_to_client_command() {
  let cli = BinaryCli::try_parse_from(["orbitdock", "session", "list"]).expect("should parse");
  let command = binary_to_client_command(cli.command.as_ref().expect("command present"))
    .expect("session should map to client command");

  match command {
    Command::Session {
      action: SessionAction::List { .. },
    } => {}
    other => panic!("expected session list, got {other:?}"),
  }
}

#[test]
fn binary_cli_maps_server_command_to_client_command() {
  let cli = BinaryCli::try_parse_from(["orbitdock", "server", "status"])
    .expect("should parse server status");
  let command = binary_to_client_command(cli.command.as_ref().expect("command present"))
    .expect("server should map to client command");

  match command {
    Command::Server {
      action: ServerAction::Status,
    } => {}
    other => panic!("expected server status, got {other:?}"),
  }
}

#[test]
fn binary_cli_resolves_client_config_from_merged_flags() {
  let cli = BinaryCli::try_parse_from([
    "orbitdock",
    "--server",
    "http://example.test:4000",
    "--token",
    "abc123",
    "--json",
    "health",
  ])
  .expect("should parse merged cli");

  let config = ClientConfig::resolve_binary(&cli).expect("binary config should resolve");
  assert_eq!(config.server_url, "http://example.test:4000");
  assert_eq!(config.token.as_deref(), Some("abc123"));
  assert!(config.json);
}

#[tokio::test]
async fn dispatch_binary_returns_none_for_admin_commands() {
  let tmp = std::env::temp_dir().join("orbitdock-test-dispatch");
  let _ = std::fs::create_dir_all(&tmp);
  orbitdock_server::init_data_dir(Some(&tmp));

  let config = ClientConfig::from_sources(None, None, true, None);
  let command = BinaryCommand::Status;

  let result = dispatch_binary(&command, &config).await;
  assert!(result.is_none());
}

#[test]
fn hook_forward_reads_env_vars() {
  let cli = BinaryCli::try_parse_from([
    "orbitdock",
    "hook-forward",
    "--server-url",
    "http://flag:4000",
    "--auth-token",
    "flag-token",
    "claude-session-start",
  ])
  .expect("should parse with explicit flags");

  match cli.command {
    Some(BinaryCommand::HookForward {
      server_url,
      auth_token,
      ..
    }) => {
      assert_eq!(server_url.as_deref(), Some("http://flag:4000"));
      assert_eq!(auth_token.as_deref(), Some("flag-token"));
    }
    other => panic!("expected hook-forward, got {other:?}"),
  }

  std::env::set_var("ORBITDOCK_URL", "http://env:4000");
  std::env::set_var("ORBITDOCK_AUTH_TOKEN", "env-token");

  let cli = BinaryCli::try_parse_from(["orbitdock", "hook-forward", "claude-status-event"])
    .expect("should parse from env vars");

  std::env::remove_var("ORBITDOCK_URL");
  std::env::remove_var("ORBITDOCK_AUTH_TOKEN");

  match cli.command {
    Some(BinaryCommand::HookForward {
      server_url,
      auth_token,
      hook_type,
    }) => {
      assert_eq!(server_url.as_deref(), Some("http://env:4000"));
      assert_eq!(auth_token.as_deref(), Some("env-token"));
      assert!(matches!(hook_type, HookForwardType::ClaudeStatusEvent));
    }
    other => panic!("expected hook-forward, got {other:?}"),
  }
}

#[test]
fn binary_cli_parses_start_dev_console_flag() {
  let cli = BinaryCli::try_parse_from(["orbitdock", "start", "--dev-console"])
    .expect("binary cli should parse dev console flag");

  match cli.command {
    Some(BinaryCommand::Start { dev_console, .. }) => {
      assert!(dev_console);
    }
    other => panic!("expected start command, got {other:?}"),
  }
}

#[test]
fn binary_cli_parses_managed_start_flags() {
  let cli = BinaryCli::try_parse_from([
    "orbitdock",
    "start",
    "--managed",
    "--workspace-id",
    "workspace-1",
    "--sync-url",
    "https://sync.example",
    "--sync-token",
    "sync-token-1",
    "--workspace-provider",
    "local",
  ])
  .expect("binary cli should parse managed start flags");

  match cli.command {
    Some(BinaryCommand::Start {
      managed,
      workspace_id,
      sync_url,
      sync_token,
      workspace_provider,
      ..
    }) => {
      assert!(managed);
      assert_eq!(workspace_id.as_deref(), Some("workspace-1"));
      assert_eq!(sync_url.as_deref(), Some("https://sync.example"));
      assert_eq!(sync_token.as_deref(), Some("sync-token-1"));
      assert_eq!(workspace_provider, Some(WorkspaceProviderKind::Local));
    }
    other => panic!("expected start command, got {other:?}"),
  }
}

#[test]
fn binary_cli_parses_init_workspace_provider() {
  let cli = BinaryCli::try_parse_from(["orbitdock", "init", "--workspace-provider", "local"])
    .expect("binary cli should parse init workspace provider");

  match cli.command {
    Some(BinaryCommand::Init {
      workspace_provider, ..
    }) => {
      assert_eq!(workspace_provider, WorkspaceProviderKind::Local);
    }
    other => panic!("expected init command, got {other:?}"),
  }
}

#[test]
fn binary_cli_parses_config_set_workspace_provider() {
  let cli =
    BinaryCli::try_parse_from(["orbitdock", "config", "set", "workspace-provider", "local"])
      .expect("binary cli should parse config set");

  match cli.command {
    Some(BinaryCommand::Config {
      action: ConfigAction::Set {
        key: ConfigKey::WorkspaceProvider,
        value,
      },
    }) => assert_eq!(value, "local"),
    other => panic!("expected config set command, got {other:?}"),
  }
}

#[test]
fn binary_cli_parses_mission_provider_get() {
  let cli = BinaryCli::try_parse_from(["orbitdock", "mission", "provider", "get"])
    .expect("binary cli should parse mission provider get");

  match cli.command {
    Some(BinaryCommand::Mission {
      action: MissionAction::Provider {
        action: MissionProviderAction::Get,
      },
    }) => {}
    other => panic!("expected mission provider get command, got {other:?}"),
  }
}

#[test]
fn binary_cli_parses_mission_provider_set() {
  let cli = BinaryCli::try_parse_from(["orbitdock", "mission", "provider", "set", "daytona"])
    .expect("binary cli should parse mission provider set");

  match cli.command {
    Some(BinaryCommand::Mission {
      action:
        MissionAction::Provider {
          action: MissionProviderAction::Set { provider },
        },
    }) => {
      assert_eq!(provider, WorkspaceProviderKind::Daytona);
    }
    other => panic!("expected mission provider set command, got {other:?}"),
  }
}

#[test]
fn binary_cli_parses_mission_provider_config_get() {
  let cli = BinaryCli::try_parse_from([
    "orbitdock",
    "mission",
    "provider",
    "config",
    "get",
    "daytona-api-url",
  ])
  .expect("binary cli should parse mission provider config get");

  match cli.command {
    Some(BinaryCommand::Mission {
      action:
        MissionAction::Provider {
          action:
            MissionProviderAction::Config {
              action:
                MissionProviderConfigAction::Get {
                  key: MissionProviderConfigKey::DaytonaApiUrl,
                },
            },
        },
    }) => {}
    other => panic!("expected mission provider config get command, got {other:?}"),
  }
}

#[test]
fn binary_cli_parses_mission_provider_config_set() {
  let cli = BinaryCli::try_parse_from([
    "orbitdock",
    "mission",
    "provider",
    "config",
    "set",
    "daytona-target",
    "team-a",
  ])
  .expect("binary cli should parse mission provider config set");

  match cli.command {
    Some(BinaryCommand::Mission {
      action:
        MissionAction::Provider {
          action:
            MissionProviderAction::Config {
              action:
                MissionProviderConfigAction::Set {
                  key: MissionProviderConfigKey::DaytonaTarget,
                  value,
                },
            },
        },
    }) => assert_eq!(value, "team-a"),
    other => panic!("expected mission provider config set command, got {other:?}"),
  }
}

#[test]
fn binary_cli_parses_mission_provider_test() {
  let cli = BinaryCli::try_parse_from(["orbitdock", "mission", "provider", "test"])
    .expect("binary cli should parse mission provider test");

  match cli.command {
    Some(BinaryCommand::Mission {
      action: MissionAction::Provider {
        action: MissionProviderAction::Test,
      },
    }) => {}
    other => panic!("expected mission provider test command, got {other:?}"),
  }
}

#[test]
fn binary_cli_help_lists_managed_start_flags() {
  let mut command = BinaryCli::command();
  let start = command
    .find_subcommand_mut("start")
    .expect("start subcommand should exist");
  let help = start.render_long_help().to_string();

  assert!(help.contains("--managed"));
  assert!(help.contains("--workspace-id"));
  assert!(help.contains("--sync-url"));
  assert!(help.contains("--sync-token"));
  assert!(help.contains("--workspace-provider"));
}
