use anyhow::Result;
use clap::Parser;

mod cli;
mod client;
mod commands;
mod error;
mod output;

use cli::Cli;
use client::config::ClientConfig;

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let config = ClientConfig::resolve(&cli)?;
    let exit_code = commands::dispatch(&cli, &config).await;
    std::process::exit(exit_code);
}
