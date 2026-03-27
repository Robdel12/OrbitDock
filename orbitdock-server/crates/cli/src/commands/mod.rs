mod approval;
mod codex;
mod config;
mod fs;
mod health;
mod mcp;
pub mod mcp_mission_tools;
mod mission;
mod model;
mod review;
mod server;
mod session;
mod shell;
mod usage;
mod worktree;
pub use session::run_managed_session_start;

use crate::cli::{binary_to_client_command, BinaryCommand, Command};
use crate::client::config::ClientConfig;
use crate::client::rest::RestClient;
use crate::output::Output;

/// Dispatch a CLI command and return an exit code.
pub async fn dispatch(command: &Command, config: &ClientConfig) -> i32 {
  let rest = RestClient::new(config);
  let output = Output::new(config);

  match command {
    Command::Health => health::run(&rest, &output).await,

    Command::Session { action } => session::run(action, &rest, &output, config).await,
    Command::Approval { action } => approval::run(action, &rest, &output).await,
    Command::Review { action } => review::run(action, &rest, &output).await,
    Command::Model { action } => model::run(action, &rest, &output).await,
    Command::Usage { action } => usage::run(action, &rest, &output).await,
    Command::Server { action } => server::run(action, &rest, &output).await,
    Command::Config { action } => config::run(action, &rest, &output).await,
    Command::Codex { action } => codex::run(action, &rest, &output).await,
    Command::Worktree { action } => worktree::run(action, &rest, &output).await,
    Command::Mission { action } => mission::run(action, &rest, &output).await,
    Command::Mcp { action } => mcp::run(action, &rest, &output).await,
    Command::Fs { action } => fs::run(action, &rest, &output).await,
    Command::Shell { action } => shell::run(action, &output, config).await,
    Command::Completions { shell } => {
      crate::cli::generate_completions(*shell);
      crate::error::EXIT_SUCCESS
    }
  }
}

/// Dispatch the client-owned subset of the merged binary command tree.
///
/// Returns `None` for server-admin and startup commands that still need the
/// outer binary to hand off to server-side APIs.
pub async fn dispatch_binary(command: &BinaryCommand, config: &ClientConfig) -> Option<i32> {
  let command = binary_to_client_command(command)?;
  Some(dispatch(&command, config).await)
}
