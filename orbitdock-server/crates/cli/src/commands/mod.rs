mod approval;
mod codex;
mod fs;
mod health;
mod mcp;
mod model;
mod review;
mod server;
mod session;
mod shell;
mod usage;
mod worktree;

use crate::cli::{Cli, Command};
use crate::client::config::ClientConfig;
use crate::client::rest::RestClient;
use crate::output::Output;

/// Dispatch the CLI command and return an exit code.
pub async fn dispatch(cli: &Cli, config: &ClientConfig) -> i32 {
    let rest = RestClient::new(config);
    let output = Output::new(config);

    match &cli.command {
        Command::Health => health::run(&rest, &output).await,

        Command::Session { action } => session::run(action, &rest, &output, config).await,
        Command::Approval { action } => approval::run(action, &rest, &output).await,
        Command::Review { action } => review::run(action, &rest, &output).await,
        Command::Model { action } => model::run(action, &rest, &output).await,
        Command::Usage { action } => usage::run(action, &rest, &output).await,
        Command::Server { action } => server::run(action, &rest, &output).await,
        Command::Codex { action } => codex::run(action, &rest, &output).await,
        Command::Worktree { action } => worktree::run(action, &rest, &output).await,
        Command::Mcp { action } => mcp::run(action, &rest, &output).await,
        Command::Fs { action } => fs::run(action, &rest, &output).await,
        Command::Shell { action } => shell::run(action, &output, config).await,
        Command::Completions { shell } => {
            crate::cli::generate_completions(*shell);
            crate::error::EXIT_SUCCESS
        }
    }
}
